# Design notes

Decisions and gotchas worth knowing before changing the capture/rendering
pipeline — mostly real bugs caught during development, and the scoping calls
made along the way.

- **App Sandbox is disabled** (`skyformac/Resources/skyformac.entitlements`).
  ZWO's SDK talks to the camera over raw USB in a way that doesn't reliably
  work under the sandboxed USB entitlement for arbitrary vendor devices. This
  app is meant to be distributed Developer ID–signed + notarized (outside the
  Mac App Store) — the same model ZWO's own ASIStudio uses. Hardened runtime
  is on, with `com.apple.security.cs.disable-library-validation` set so the
  embedded (non-Apple-signed) `libASICamera2.dylib` can load under it.
- **`vImageBayerToRGB` doesn't exist.** There is no Bayer/demosaic API anywhere
  in the current Accelerate/vImage headers, despite it being a natural-looking
  name for one. `Debayer.swift` implements standard bilinear demosaicing by
  hand instead (verified against known-value test fixtures in
  `skyformacTests/DebayerTests.swift`).
- **Deployment target is 14.0.** `@Observable` (used for `CameraManager`)
  requires macOS 14.
- **Connecting a real ZWO camera hung the whole app.** `CameraManager.connect(to:)` is
  `@MainActor` (the whole class is), and its first version called `ZWOSDK.open`/`initCamera`/
  `allControlCaps`/`getControlValue` directly — real, blocking `ASIOpenCamera`/`ASIInitCamera`
  USB firmware handshakes, plus one blocking round-trip per reported control type — straight on
  the main thread, before `CaptureEngine` (the `actor` that's supposed to be the *only* place
  these calls are allowed to happen, per its own doc comment) was even constructed. A webcam
  connection never hit this because `WebcamCaptureEngine` goes through AVFoundation instead.
  Fixed by moving `open`/`initCamera`/`allControlCaps`/`getControlValue` into a new
  `CaptureEngine.openAndEnumerateControls()`, called via `await` on the actor *before*
  `CameraManager` touches any of its own state — same fix shape as `resumeLiveView()`'s and
  `WebcamCaptureEngine`'s earlier hangs, another instance of "a blocking SDK call reached
  `@MainActor` by skipping the actor boundary that exists specifically to prevent that."
  `disconnect()`'s `ZWOSDK.close` had the same problem (called directly on `@MainActor` inside a
  plain `Task { }`, which inherits the caller's actor) — moved to a `CaptureEngine.close()` for
  the same reason.
- **`stretch` (the base black/white-point display stretch) and `gpuControls` are plain in-memory
  session state on `CameraManager` — nothing resets them across a disconnect/reconnect, even to a
  completely different camera.** Connecting a real ZWO camera (16-bit RAW, often a dim night-sky
  target) right after a webcam/iPhone session (8-bit RGB24, typically bright/indoor) inherits
  whatever black/white point that session left `stretch` at, which on a totally different signal
  scale renders as solid white or solid black with no usable live view — not a camera/SDK problem,
  a leftover-UI-state problem. `connect(to:)` and `connectToWebcam` now reset `stretch = .identity`
  on every fresh connection; `connect(to:)` additionally forces `gpuControls.isEnabled = false`
  (the three-stage GPU pipeline's own tuning is just as session-specific) and sets `ASI_GAIN` to a
  fixed, conservative `5` rather than trusting `ASI_CONTROL_CAPS.DefaultValue` (frequently near the
  top of the camera's range — tuned by ZWO for bright test/demo conditions, not a real night sky).
- **Some `ASI_CONTROL_TYPE`s aren't freely-draggable ranges — `ASICamera2.h` defines them as
  fixed small sets of values, and the generic slider row didn't know that.** `ASI_HARDWARE_BIN`,
  `ASI_HIGH_SPEED_MODE`, and `ASI_MONO_BIN` are plain 0/1 booleans (now `toggleRow`, joining
  `ASI_COOLER_ON`/`ASI_FAN_ON`/`ASI_ANTI_DEW_HEATER`); `ASI_FLIP` is a 4-way mode
  (`ASI_FLIP_NONE`/`HORIZ`/`VERT`/`BOTH`, values 0...3 — now a segmented `Picker`, not a boolean
  and not a free-drag range either).
- **The per-camera `ASI_EXPOSURE` control (live-view video exposure) and the "Single Exposure"
  section (one-shot `ASIStartExposure` still capture) are two different things that used to look
  like the same "Exposure" control shown twice** — because the per-camera one used a plain linear
  `Slider` over the camera's raw microsecond range, the same "can't cover µs-to-seconds at any
  usable resolution" problem already documented above for the Single Exposure field, and had no
  label distinguishing it. Now labeled "Live Exposure" and reuses the same log-scale
  `ExposureField`.
- **`ASI_GAIN`'s full range (often 0...500+) on a plain linear `Slider` gives unusably coarse
  control right at the low, conservative end (0...20) this app actually defaults into and
  recommends** (`ASI_GAIN = 5` on connect, see above) — one pixel of slider drag jumps several
  real gain steps there. `GainField` devotes 70% of the slider's width to `minValue...20` and the
  rest to `20...maxValue`, a piecewise-linear remap (not logarithmic like `ExposureField` — gain
  doesn't have exposure's natural spread across decades, it just needed one deliberate breakpoint
  at the range that matters).
- **`Task { }` (not `.detached`) inherits the isolation of the actor-isolated code that creates
  it — so a plain `Task { }` written inside `@MainActor` code stays on `@MainActor` for its whole
  synchronous portion, including calls that look like they're "in a background task."** This bit
  four different per-frame AI Suite/tracking features:
  - `scheduleQualityScoreIfNeeded` (Lucky Imaging's live score) had no `Task` at all — it ran
    `SharpnessScorer.score`'s full per-pixel Laplacian-variance pass (debayering first) *inline*,
    synchronously, in `ingest()` itself, unconditionally for every 5th frame of *any* connected
    camera — no enable/disable toggle gating it, unlike every other feature in this list. This was
    the single biggest cause of "the app is really slow / the pointer keeps going into wait mode
    with a camera connected" — a real ZWO camera's higher resolution and sustained frame rate (vs.
    the webcam this was mostly developed against) turned an always-on cost that was easy to miss
    into main-thread stutter on every 5th frame, indefinitely.
  - `scheduleFocusAssistIfNeeded` (`StarDetector`/`StarPatternRecognizer`/`LiveWCSSolver`),
    `schedulePlanetTrackingIfNeeded` (`PlanetDetector`, plus a `CGImageRenderer.makeDisplayImage`
    debayer/stretch call that ran fully inline *before* even reaching its `Task`), and
    `scheduleStreakDetectionIfNeeded` (`StreakDetector`'s Vision pass) all used plain `Task { }`,
    silently running their real Vision/CPU work on `@MainActor` instead of in the background the
    code visually suggested — only a problem when their respective toggles are on, but each one
    is a settings toggle that persists across app relaunches, so "off in this session" doesn't
    mean "off in general."
  All four now use `Task.detached`, matching `enhancementTask`'s existing (correct) pattern — the
  actual Vision/scoring/render work happens off the main actor, with only the final state
  assignment hopping back via `await MainActor.run`.
- **The Improvements/Advanced "Disable All" checkboxes are one-way, not a stored master switch.**
  `ControlsPanelView`'s `allImprovementsDisabled`/`allAdvancedDisabled` bindings' `get` returns
  `true` only when every underlying toggle in that tab already happens to be off, and `set`
  ignores `false` entirely — checking the box forces everything off, but unchecking it does
  nothing (no "restore what was on before" state is kept). This was a deliberate simplification:
  a real master switch would need to snapshot which individual features were on before the mass
  disable, and only some of those (e.g. "Live Stack") have meaningful side effects to preserve
  (accumulated frames) vs. others that don't (a boolean toggle). Turning things back on one at a
  time, deliberately, avoids ever silently restoring a feature the user didn't explicitly ask
  for.
- **The "Disable All" checkboxes were unclickable after the sidebar tab picker moved out to the
  vertical trailing strip — a regression, not a new instance of the same old mystery.** Once the
  horizontal tab picker left the `ScrollView` entirely (see the vertical-tab-strip entry above),
  each checkbox became the literal first row of `improvementsTabContent`/`advancedTabContent` —
  exactly the screen position already established to be unreliable for clicks, regardless of
  which control sits there. Fixed by moving both checkboxes to the *end* of their tab's list
  (after every `DisclosureGroup`, not before) — still one click to disable everything in the tab,
  just no longer the pane's first rendered row.
- **Verify against real APIs and real data — mistakes in this shape keep
  happening.** The ZWO SDK has no per-gain read-noise API (`ASIGetGainOffset`
  returns a recommended *gain setting*, not read noise in electrons) —
  `ExposureOptimizer` measures it from a real bias frame instead.
  `PlanetDetector`'s first version picked "the single largest Vision contour"
  as the planet disk and silently failed 100% of the time on a banded target
  like Jupiter, because each band edge is its own long-thin contour and none
  pass a combined width+height size filter — caught by running it against a
  synthetic banded-disk fixture and inspecting the contours, fixed by unioning
  every non-trivial contour's bounding box instead (see `PlanetDetector`'s doc
  comment and the regression test in `PlanetDetectorTests`).
- **"Apple Neural Engine AI Denoising" is a classical bilateral filter, not a
  trained model.** Shipping a genuine Core ML denoiser needs training data and
  a model file that can't be conjured from a feature request.
  `isDenoisingEnabled` delivers the same real-time noise-suppression outcome
  via a well-understood, verifiable, non-ML technique instead.
- **The Catalog HUD's WCS is a real (if small-scale) fit, not blind plate
  solving.** `StarPatternRecognizer` identifies which of a small hand-curated
  bright-star catalog are in frame via triangle-similarity voting, then
  resolves actual pixel<->star correspondences by testing all 6 vertex-label
  orderings of each candidate catalog triangle against each detected triple —
  the shape-voting step alone can't tell you *which* point is *which* star,
  only that some catalog triangle's shape matches. `LiveWCSSolver` then fits a
  `WCSFrame` (center RA/Dec, rotation, plate scale) from those
  correspondences via ordinary least squares on the exact linear form
  `WCSFrame.projectToPixel` already defines. This is real geometry, verified
  by round-tripping a known `WCSFrame` through `projectToPixel` and checking
  the solver recovers it (`LiveWCSSolverTests`) — but it's a small-angle fit
  with no distortion model and no robust outlier rejection beyond a vote-count
  threshold, not a general-purpose blind solver like astrometry.net.
- **Live stacking, lucky imaging, and continuous recording all do zero
  geometric alignment/registration** between frames — every one of them
  assumes a tracked, stationary mount, the same honest scoping SharpCap's
  basic (non-aligned) live-stack mode uses.
- **The CPU denoise/wavelet-sharpen fallback froze the app for 10+ seconds per
  frame** in its first version, because it ran synchronously on `@MainActor`
  inside `refreshCurrentImage()`. Fixed two ways: `ImageEnhancer.waveletBlur`
  was rewritten as a separable (horizontal-then-vertical) convolution instead
  of a full 2D 25-tap kernel, and the whole computation moved into a
  `Task.detached(priority: .userInitiated)` with a frame-ID staleness guard —
  mirroring `scheduleFocusAssistIfNeeded`'s pattern — so the un-enhanced frame
  displays immediately and the enhanced one swaps in asynchronously.
- **A webcam/iPhone source can deliver frames faster than the render pipeline
  can draw them — the consumer, not just the producer, needs back-pressure.**
  `WebcamCaptureEngine`'s first version handed every incoming frame to the
  main actor via its own unstructured `Task`, with no limit on how many could
  be in flight at once. A `.high`-preset camera delivers 30-60fps; the
  (originally CPU-only) render path couldn't keep up, so those `Task`s —
  each holding a full converted frame's `Data` — piled up faster than they
  drained, and both memory and CPU grew without bound until the app stopped
  responding entirely, including to Cmd-Q. Fixed by giving `WebcamCaptureEngine`
  the same single-consumer, pull-based `AsyncStream` shape `CaptureEngine`
  already uses for real ZWO cameras, with `bufferingPolicy: .bufferingNewest(1)`
  — a slow renderer now just sees a lower effective frame rate instead of an
  unbounded backlog.
- **RGB24 (webcam/iPhone) frames need their own Metal path — not a texture.**
  `MetalFrameRenderer` originally only handled RAW8/RAW16 (mono, one texture
  channel); RGB24 frames fell through to the CPU (`CGImageRenderer`) path
  unconditionally, which couldn't keep up with live video. RGB24 (3
  bytes/pixel) also isn't a valid Metal texture pixel format, so
  `stretchRGB24`/`histogramReduceRGB24` (`Shaders.metal`) read the raw byte
  buffer directly via `device const uchar *` instead of a
  `texture2d<...>` binding, writing the stretched result into the same
  `rgba8Unorm` output texture the mono path uses. Denoise/wavelet-sharpen have
  since grown RGB24 color analogs (`bilateralDenoiseRGBA`/`waveletBlurRGBA`/
  `waveletCombineRGBA`); GPU live-stack *accumulation* (`accumulateMono`)
  remains genuinely mono-only (a single-channel `r32Float` running sum), but
  `CameraManager.ingest` now falls back to the CPU `LiveStacker` specifically
  for RGB24 frames even while the GPU render path is active, so Live Stack
  still works end-to-end (preview and export) for a webcam/iPhone source —
  see the "Live Stack and Lucky Imaging silently did nothing for webcam/
  iPhone sources" entry below for the full bug this replaced.
- **A linear exposure-time slider can't span a real camera's actual range.**
  ASI sensors expose microsecond-scale exposures (planetary/lucky imaging)
  through hundreds of seconds (deep sky) — a 0.1s-resolution linear slider
  over that range can't dial in, say, 500µs. `ExposureField` (in
  `ControlsPanelView`) operates in log10(seconds) space instead, so every
  decade (µs/ms/s) gets equal room on the slider, with the displayed unit
  chosen adaptively; the underlying value stays plain seconds, so
  `captureSingleExposure`/`captureDarkFrame`/`captureFlatFrame` didn't need to
  change.
- **`Info.plist` needs `CFBundleIdentifier` spelled out explicitly.** With
  `GENERATE_INFOPLIST_FILE = NO`, Xcode doesn't auto-merge
  `PRODUCT_BUNDLE_IDENTIFIER` into a hand-written Info.plist — it has to be
  spelled out as `$(PRODUCT_BUNDLE_IDENTIFIER)` explicitly, along with
  `CFBundleName`, `CFBundleExecutable`, etc. This silently doesn't matter for
  normal launches, but breaks `XCUITest`'s bundle-ID-based app lookup outright.
- **`MPSImageBilateralScale` doesn't exist.** `MetalPerformanceShaders` has no bilateral-filter
  image kernel — `MPSImageBilinearScale`/`MPSImageLanczosScale` are *resizing* filters with a
  similar-sounding name, not a denoise operation. The "Live GPU Enhancement Controls" feature
  (`specs/skyformac_GPU_Live_Controls_Spec.md`) reuses `Shaders.metal`'s existing hand-written
  `bilateralDenoise` compute kernel instead — see that spec's own "Implementation Notes" section
  for the rest of its deliberate deviations from the literal spec text.
- **A `didSet` that reassigns its own property recurses on every call, not just when the value
  changes.** `GPUControlSettings`'s clamping setters (`blackPoint = blackPoint.clamped(to:)` etc.)
  first shipped without checking whether clamping actually changed anything — since `didSet`
  fires on every assignment including ones made from inside itself, that recursed unconditionally
  and stack-overflowed (`SIGBUS`, `Could not determine thread index for stack guard region`) the
  first time a test exercised it. Fixed by comparing the clamped value against the current one
  first, and only reassigning (which re-enters `didSet` exactly once more, now idempotent) when
  they actually differ.
- **Two of the five `skyformac_AI_Features_Pipeline_Spec.md` features can't be
  built as literally specced, for the same reason as the Neural Engine
  denoiser above: they require a trained Core ML model that doesn't exist and
  can't be produced from a feature request.** "AI Denoise via the Neural
  Engine" (Feature 1) and "AI Super-Resolution" (Feature 4) are both declined
  outright rather than faked under an AI-sounding name — the existing
  bilateral/temporal denoise and CPU/GPU stretch pipeline already covers the
  same real-time-usable ground. See that spec's own "Implementation Notes"
  section for the full reasoning per feature.
- **Lucky Imaging's live quality score (Feature 2) reuses the existing
  Laplacian-variance `SharpnessScorer`, not a Vision/Core-ML aesthetic
  model.** The spec's "AI-Estimated Quality Score" language doesn't name a
  concrete, verifiable API — the sharpness metric already driving lucky
  imaging's keep/discard ranking is a real, tested measurement of the same
  underlying thing (how much of a star's fine structure survived seeing/
  tracking-error blur), just surfaced live in the Lucky Imaging panel instead
  of only after a burst finishes.
- **Satellite/aircraft trail masking (Feature 3) is CPU live-stacking only —
  the GPU live-stack accumulate kernel can't do per-pixel masking without a
  bigger, riskier rewrite.** `Shaders.metal`'s `accumulateMono` divides every
  pixel by one shared scalar frame count; skipping specific pixels in specific
  frames needs a *per-pixel* count instead, which would mean threading a
  second accumulator texture through `accumulateMono`,
  `stretchMono`/`debayerAndStretch`, and `histogramReduce` all at once. `
  StreakDetector` (Vision `VNDetectContoursRequest`, the same request
  `StarDetector` already uses, with an inverted elongated-vs-round geometric
  filter) and `StreakMask` (a per-pixel keep/mask grid) only wire into the CPU
  `LiveStacker`; `ControlsPanelView` shows a warning when the GPU renderer is
  active and streak masking is toggled on, rather than silently doing
  nothing.
- **A normalized bounding-box's upper edge is exclusive, not inclusive —
  rounding it the wrong way spills a mask into the next pixel.** `StreakMask`
  converts a Vision-normalized box (`0...1`) to a pixel-index range by
  `floor`-ing the lower bound and `ceil`-ing the upper one; the first version
  used the `ceil`'d value directly as the last included index, which is
  correct for a non-boundary-aligned box but wrong whenever the upper edge
  lands exactly on a pixel boundary — e.g. a box of width `0.5` on a
  2px-wide frame gives `ceil(0.5 * 2) = ceil(1.0) = 1`, wrongly keeping pixel
  index 1 too (pixel `i` spans `[i/width, (i+1)/width)`, so index 1 is
  entirely outside a box ending at exactly `0.5`). Caught by
  `LiveStackerTests.maskedPixelIsExcludedFromThatFramesContribution` failing
  with both pixels masked instead of one; fixed by subtracting 1 from the
  `ceil`'d value on both axes.
- **Cloud & Drift Sentinel (Feature 5) reuses the existing All-Sky monitor's
  cloud/light-alert analysis exactly, applied to the main capture pipeline
  instead of a second webcam feed.** `CloudDriftSentinel` mirrors
  `AllSkyMonitor.applyAnalysis`'s unconditional exponential-moving-average
  baseline update (`baseline * 0.98 + brightness * 0.02` every sample, even
  while already alerting) and calls the same `AllSkyAnalyzer.isCloudOrLightAlert`
  threshold check — brightness is sampled cheaply via
  `HistogramComputer.meanBrightness` (stride-sampled, not a full per-pixel
  scan) rather than adding a second real-time analysis path. "Pause capture"
  on alert is `stopRecording()`; there's no separate concept of pausing vs.
  stopping elsewhere in the capture pipeline to hook into instead.
- **A control sitting in `ControlsPanelView`'s topmost screen position — directly under the
  window's toolbar — was reliably unclickable, independent of the control type *and* independent
  of whether it was inside or outside the `ScrollView`.** What's now the sidebar tab picker went
  through three placements chasing this: a `Picker(selection:)` with `.pickerStyle(.menu)` (an
  `NSPopUpButton`) as the `ScrollView` content's first row; then a `Menu` (an `NSMenu` off a plain
  button) in the same spot; then a segmented `Picker` pulled *out* of the `ScrollView` entirely
  into its own fixed header `HStack` above it. All three were unclickable — only
  `SkyformacCommands`'s menu-bar equivalent (bound to the same `@AppStorage` key) ever worked,
  which ruled out the state/binding and the specific control type, and the fixed-header attempt
  ruled out "it's specifically the `ScrollView`'s first row" too. What's left in common is the
  literal screen position: that strip directly under the window's native toolbar, regardless of
  which SwiftUI container puts a view there. Never fully root-caused (a toolbar-hit-testing
  overlap is the leading theory, but unconfirmed) — worked around by keeping the tab picker as
  ordinary content inside the `ScrollView`'s normal scroll flow, several rows away from that
  strip, at the cost of it scrolling away with everything else instead of staying pinned. The
  menu-bar path (`SkyformacCommands`, ⌘1-⌘4) remains the reliable way to switch tabs regardless.
- **A single actor serializes *everything* routed through it — one call that never suspends
  monopolizes the actor forever, blocking every other call waiting on it too, not just its own
  caller.** Real root cause of "pressing Capture while live view is streaming hangs, and live view
  never comes back afterward": `CaptureEngine.pollLoop()` (the live-view frame loop, running for
  as long as streaming is active) called the blocking `ASIGetVideoData` *directly, inline*, inside
  a `while` loop with no `await` anywhere in its body. An `actor` only ever runs one call at a
  time and only switches to another queued call at an `await` suspension point — a loop with none
  never gives the actor back, so `captureSingleExposure` (routed through the same actor) couldn't
  so much as *start* running for as long as `pollLoop` kept looping, i.e. for as long as live view
  was on. Not a slow-hardware problem — it would hang on any camera, every time, as soon as a
  frame was actively streaming when Capture was pressed (which is the normal case). Fixed by
  wrapping the blocking call in `fetchVideoData`, which runs it on a background
  `DispatchQueue` and resumes via a `CheckedContinuation` — a genuine suspension point, so the
  actor can interleave `captureSingleExposure`, `stop()`, or anything else between poll
  iterations, the way any other actor is expected to behave. `UnsafeMutableRawBufferPointer` isn't
  `Sendable`, so crossing that continuation boundary needed an `@unchecked Sendable` wrapper
  (`UnsafeSendableBuffer`) — safe specifically because `pollLoop` awaits each call before starting
  the next, and `stop()` (see below) now waits for the poll task to fully exit before anything
  reallocates the buffer it was writing into.
  - `stop()` itself had to become `async`, awaiting `pollTask?.value` after cancelling it — every
    call site already used `await engine.stop()`/`await engine?.stop()` (an actor method call is
    always `await`-prefixed regardless), so this needed no caller changes, but it closes a real
    use-after-free window: `captureSingleExposure` calls `stop()` then immediately reuses/
    reallocates `frameBuffer` (`FrameBuffer.ensureCapacity` deallocates the old pointer outright)
    — without waiting for the last in-flight background `fetchVideoData` call to actually finish
    writing into that same buffer first, that reallocation could race it.
  - Once `pollLoop` could no longer starve the actor, a second, previously-unreachable bug
    surfaced: `captureSingleExposure`'s own `ASIGetExpStatus` poll loop had no upper bound either,
    so a real hardware hiccup (camera never reports `ASI_EXP_SUCCESS`/`ASI_EXP_FAILED`) could still
    hang indefinitely once the call *did* get to start running. Bounded to 1.5x the requested
    exposure length plus a flat 5s overhead margin, calling `ASIStopExposure` before throwing
    `ZWOError.timeout` so the camera lands back in a state `resumeLiveView()` can actually restart
    from.
  - Also uncovered a third, compounding bug in the same path: `startPreview` set
    `isLiveViewActive = true` *optimistically*, before `engine.startStreaming(...)` had actually
    succeeded, so a restart failure left `isLiveViewActive` stuck `true` — which hides the "Resume
    Live View" button (only shown when it's `false`), removing the only way to retry short of
    disconnecting and reconnecting the camera entirely. Fixed by only leaving it `true` on the
    success path.
- **`.identity` (`blackPoint: 0, whitePoint: 1`) as the post-connect display stretch renders solid
  black on real ZWO sensor data — it's a bad default, not just a neutral one.** A real linear
  sensor's actual signal (sky background + stars, especially at a conservative gain like the `5`
  `connect(to:)` now defaults to) typically occupies a small fraction of its full digital range;
  stretching the *entire* range across the visible 0...255 output means that small fraction rounds
  down to black. This was a self-inflicted regression: `.identity` was chosen specifically to stop
  a *previous* webcam session's leftover black/white point from carrying over onto a freshly
  connected real camera (see the `stretch`/`gpuControls` entry above) — but swapped one bad
  default for another, since `.identity` itself doesn't fit real sensor data either. Fixed with
  `DisplayStretch.autoStretch(histogram:)` — the same 1st/99th-percentile approach
  `GPUControlSettings.autoStretch` already uses for its own independent stretch — computed once
  from the very first live frame's own histogram after a ZWO connect (`CameraManager
  .pendingAutoStretch`, consumed in `ingest()`), rather than guessed at connect time before any
  frame data exists to guess from.
- **`captureSingleExposure` writes a (typically much longer) exposure length into `ASI_EXPOSURE` —
  the same shared hardware register live-view video streaming reads every frame — and never
  restored it.** After a single-exposure capture, `resumeLiveView()` would restart video streaming
  still set to that capture's exposure length; a live view updating once every few seconds (or
  longer) is visually indistinguishable from a frozen black screen. Fixed by reading the previous
  `ASI_EXPOSURE` value before overwriting it and restoring it in a function-scope `defer` in
  `CaptureEngine.captureSingleExposure`, so it's restored on every exit path (success, thrown
  error, or cancellation) — not nested inside the `if exposureCaps != nil` block that sets it,
  which would have made the `defer` fire at the end of *that* block instead of the function.
- **Fullscreen preview's own overlay button was reported unclickable — same screen-position
  pattern as the sidebar tab picker** (top-right corner of the preview, near the window's
  toolbar; see the entry above). Rather than chase the exact mechanism again, added two more
  independent paths to the same `CameraManager.isPreviewFullScreenEnabled` state: a "Full Screen
  Preview" menu bar item (`SkyformacCommands`, ⌘⇧F) and a "Full Screen" button in the sidebar's
  vertical tab strip (`ControlsPanelView`) — the same "when a screen position won't take clicks,
  add a path that doesn't depend on that position" approach already used for the sidebar tab
  picker.
- **"iPhone Night Mode (10s/60s)" can't be a literal single long sensor exposure — a live video
  pipeline has no such thing.** `AVCaptureVideoDataOutput` delivers a continuous stream of
  individual frames at a real frame rate; there's no operation that produces one frame tens of
  seconds long, unlike `CaptureEngine.captureSingleExposure`'s real `ASIStartExposure` for ZWO
  cameras. `CameraManager.startIPhoneNightModeCapture` instead accumulates that many seconds of
  live frames into their own `LiveStacker` instance (kept separate from `liveStacker` so it
  doesn't interact with the user's own Live Stack toggle) and freezes on the running average once
  the timer elapses — this is not a fabricated stand-in for Apple's Night Mode, it's the same
  computational multi-frame-stacking approach Apple's own iPhone Night Mode actually uses
  internally, just triggered from here instead of the iPhone's own Camera app.
- **A webcam/Continuity Camera device's continuous autofocus actively fights afocal projection.**
  It's designed to refocus on whatever looks like a normal subject, so pointed at a telescope
  eyepiece it keeps hunting and drifting away from the actual focal plane. `AVCaptureDevice
  .focusMode = .locked` (real, documented API — set with no explicit lens position, it freezes at
  whatever position autofocus currently sits at) fixes this directly; exposed as
  `WebcamCaptureEngine.setFocusLocked`, dispatched on `sessionQueue` like every other touch of
  `device`, since `lockForConfiguration()` is documented as a hardware-property lock other capture
  sessions sharing the device should only hold briefly.
- **The standard macOS "About" panel already covers app name, version, author, and license — no
  custom About UI needed.** SwiftUI's default `CommandGroup(.appInfo)` reads `CFBundleDisplayName`
  (app name — set to "Sky for Mac", distinct from the actual product/target/bundle-ID name
  `skyformac`, which stays unchanged: `PRODUCT_NAME`/`CFBundleName` still says `skyformac`, only
  the user-visible display name differs, the same split many apps use between a technical and a
  marketing name), `CFBundleShortVersionString` (`MARKETING_VERSION`, already dynamic per build),
  and `NSHumanReadableCopyright` (set to the actual copyright + GPLv3 notice) automatically. The
  in-app Help's License & Credits page covers everything in more depth (the GPLv3 §7 exception
  text, the ZWO SDK notice, a GitHub link) for anyone who wants it, but the native About panel
  didn't need its own bespoke implementation to say the load-bearing facts correctly.
- **The app icon (`AppIcon.appiconset`) is rasterized from one hand-authored SVG
  (`skyformac/Resources/Branding/skyformac-logo.svg`), not drawn separately at each size.**
  `qlmanage -t -s <N>` (macOS's built-in QuickLook thumbnailer, which already knows how to render
  SVG) is a genuinely available rasterizer without installing anything — no `rsvg-convert`/
  `cairosvg`/Inkscape was present on this machine — piped through `sips -z` to force exact target
  pixel dimensions (QuickLook's own output is close but not always exact). Generated once at each
  of the 7 sizes `Contents.json` actually needs (16/32/64/128/256/512/1024), not re-derived at
  build time — regenerate all of them by hand (same two-command pipeline) if the SVG changes.
- **The window's own toolbar overlaps `ControlsPanelView`'s content area by more than 40pt — a
  real, mechanical overlap, not the unexplained mystery earlier entries here treated it as.**
  Every "control at the top of the sidebar is unclickable" report (the old Mode picker, both
  "Disable All" checkboxes after the vertical-tab-strip redesign) was this one thing. First fixed
  with `.padding(.top, 40)`, which turned out to still leave the "Disable All" checkbox
  unclickable — the actual overlap is closer to 70pt. `body`'s `ScrollView` content and
  `verticalTabStrip` both use `.padding(.top, 70)` now, kept in sync with each other — with real
  clearance in place, a "Disable All" master switch can safely go back to being the first row
  in its tab, which is where `improvementsTabContent`/`advancedTabContent` put it originally, so
  it's back there now.
- **A custom SwiftUI `Button` label's tappable area is the tight bounding box of its own content
  (glyphs/text), not the frame/background applied around it, unless told otherwise.**
  `verticalTabStrip`'s tab buttons build their label from an `Image` + `Text` inside a
  `.frame(width: 56)` with a `RoundedRectangle` background — visually a full 56pt-wide button, but
  without `.contentShape(Rectangle())` the actual click target was only the icon/text pixels
  themselves, so clicking the visible background around them (most of the button) did nothing.
  Added `.contentShape(Rectangle())` after the frame/background to make the whole visual button
  responsive, not just the "ink" inside it.
- **`LiveStacker.add`'s `switch frame.imageType` had no `ASI_IMG_RGB24` case.** Webcam/iPhone
  frames are always this format (see `WebcamCaptureEngine`'s doc comment), so every webcam frame
  silently hit `default: return` — `frameCount` never advanced, `currentAverage()` always came
  back `nil`. This is what made "iPhone Night Mode" (built directly on this accumulator) do
  nothing, and it silently broke plain "Live Stack" for webcam/iPhone sources the exact same way
  from well before Night Mode existed — nobody had reported it because nothing else exercised
  `LiveStacker` with RGB24 data until Night Mode did. Fixed by adding a real `ASI_IMG_RGB24` case
  (`sums` now sized 3x — one slot per channel, not per pixel, for this case only) to both `add`
  and `currentAverage`.
- **Focus lock (`WebcamCaptureEngine.setFocusLocked`) reportedly still doesn't visibly change
  anything on an iPhone/Continuity Camera source.** Unlike the Night Mode bug above, no code-level
  bug was found here — `isFocusModeSupported(.locked)`/`focusMode = .locked` are real, correctly-
  called APIs (see the function's own doc comment), and if `isFocusModeSupported` genuinely
  returns `false` for this device, the call now surfaces a clear, described error instead of
  `WebcamCaptureError`'s previous bare enum-case-name message. It's a real, open possibility that
  Continuity Camera's bridge doesn't forward manual focus control to the iPhone's own camera
  hardware at all — Apple designed it as a webcam substitute, not a full remote-manual-control
  API — in which case this would report `isFocusModeSupported(.locked) == true` and set the mode
  successfully while the physical iPhone's autofocus keeps running anyway. Unconfirmed either way
  without testing against real Continuity Camera hardware.
- **The Cameras sidebar, once collapsed via the native `NavigationSplitView` toggle button, had no
  way back — that button was reported to have no effect the second time.** `NavigationSplitView`
  was used with no `columnVisibility` binding of its own, so that toggle button was the *only*
  path to that state; whatever went wrong with it left no fallback. Fixed by giving `ContentView`
  an explicit binding (`CameraManager.isCameraListSidebarVisible` — `true` maps to
  `.all`, `false` to `.detailOnly`) and a "Camera List Sidebar" menu item (⌃⌘S) driving the same
  state — the same "independent path that doesn't depend on whatever's wrong with the click
  target" fix already used for the sidebar tab picker, Full Screen, and Help.
- **`PreviewView`'s `.onExitCommand` (Esc, in fullscreen) only fires while it or a descendant is
  actually first responder — not guaranteed for a view that just became the whole window's
  content with nothing in particular focused.** `ContentView.fullScreenPreview` now also carries a
  hidden `Button` with an explicit `.keyboardShortcut(.escape, modifiers: [])` — a real menu-
  command-equivalent shortcut, not tied to first-responder status — as a second, more reliable
  path to the same exit action.
- **iPhone/webcam live view specifically (never a ZWO camera) wasn't fluid — a real per-frame CPU
  cost unique to that path, not a general app slowness issue.** `WebcamSampleBufferForwarder
  .captureOutput` converted every incoming frame from the camera's native BGRA to this app's
  RGB24 with a hand-written scalar Swift loop — one bounds-checked array read/write per pixel,
  per channel. For a Continuity Camera `.high`-preset frame (1920x1080 ≈ 2.07 million pixels),
  that's real, measurable per-frame work competing with everything else on `sessionQueue`, at
  whatever frame rate the camera delivers. A ZWO camera never hits this: `ZWOSDK.getVideoData`
  hands over already-packed RAW8/RAW16 with no such conversion step. Fixed by replacing the
  scalar loop with `vImageConvert_BGRA8888toRGB888` (Accelerate/vImage) — a real, existing
  function for exactly this conversion (BGRA source -> packed R,G,B destination, dropping alpha),
  vectorized rather than one scalar iteration per pixel.
- **The GPU render path had no aspect-ratio-preserving logic at all — it stretched every frame to
  fill whatever shape the view happened to be, unconditionally.** `MetalFrameRenderer.draw(in:)`
  drew a full-screen triangle covering the entire drawable with no viewport adjustment, so
  `outputTexture` (in its own real width:height ratio) got stretched to match the view's shape
  regardless of whether that matched the actual image. Compounded by `PreviewView`'s SwiftUI-side
  container being hardcoded to a fixed `4.0 / 3.0` regardless of the real camera/frame dimensions.
  Neither was obviously broken for most ZWO cameras, whose sensors happen to be close enough to
  4:3 to hide both problems — a webcam/iPhone frame (typically 16:9) made the distortion obvious.
  Fixed two ways: `PreviewView.actualAspectRatio` now reads the real `currentFrame`'s (or, before
  one exists, the connected camera's) actual width:height ratio instead of a hardcoded constant
  (and updates live if a planetary auto-crop ROI changes the displayed frame's own dimensions);
  and `MetalFrameRenderer.letterboxViewport` computes an explicit `MTLViewport` — the GPU
  equivalent of SwiftUI's `contentMode: .fit` — so the GPU path preserves the image's real aspect
  ratio the same way the CPU path already did for free from `Image(...).aspectRatio(contentMode:
  .fit)`. Bars fill the rest via the `MTKView`'s own black `clearColor`.
- **`refreshCurrentImage()` forced a synchronous full CPU debayer+stretch render on `@MainActor`,
  every single incoming frame, whenever Focus Assist (hence "Recognize Stars") was enabled —
  regardless of whether the GPU or CPU render path was actually active.** The previous fixes to
  `scheduleFocusAssistIfNeeded`/`scheduleStreakDetectionIfNeeded` (moving the actual Vision
  detection work onto `Task.detached`) didn't touch this: both still depended on `currentImage`
  already being rendered, so their caller kept doing that render inline, synchronously, before
  ever reaching the part that was already off the main actor. A full CPU debayer+stretch pass is
  real, measurable per-frame work (the same category of cost `ImageEnhancer`'s "measured at 10+
  seconds" entry above documents) — this is what actually made the app unresponsive with
  Recognize Stars on, not the Vision detection itself. Fixed by having each of those two features
  render its own `CGImage` from the raw frame *inside* its own `Task.detached`, the same pattern
  `schedulePlanetTrackingIfNeeded` already used — `refreshCurrentImage()` now only renders
  `currentImage` synchronously when the CPU display path actually needs it
  (`!useMetalRenderer`), not as a side effect of some other feature being on.
- **Focus Assist/streak detection's own CGImage render (moved off `@MainActor` in the fix above)
  still ran on the CPU — `CGImageRenderer.makeDisplayImage` does `Debayer`'s bilinear demosaic
  plus a per-pixel Swift LUT stretch, real work regardless of which thread it runs on.** Since
  the app already has a full Metal debayer+stretch pipeline (`MetalFrameRenderer`, used for the
  live GPU preview), the natural fix is to run that same category of work on the GPU here too —
  but reusing `MetalFrameRenderer` itself directly wasn't safe: it's tightly coupled to the live
  display loop's own accumulation state (live-stack averaging, temporal denoise, wavelet-sharpen
  textures), and calling into it from an independent, differently-timed background task risked
  corrupting that state (e.g. double-advancing a frame counter). Added `GPUStillImageRenderer`
  instead — a small, standalone Metal pipeline with its own `sourceTexture`/`outputTexture`/
  `rgbSourceBuffer`, built from the same three kernels (`stretchMono`, `stretchRGB24`,
  `debayerAndStretch` in `Shaders.metal`) but with none of the live-display extras, that just
  debayers+stretches one frame and reads the result back into a `CGImage`. It's an `actor` (not a
  plain class) because `CameraManager` shares one instance between `scheduleFocusAssistIfNeeded`
  and `scheduleStreakDetectionIfNeeded`, whose two `Task.detached` calls can genuinely run
  concurrently — without actor isolation, both could mutate the same texture/buffer at once, a
  real data race, not just wasted GPU contention. `CameraManager` falls back to the CPU
  `CGImageRenderer` if the GPU renderer failed to initialize (no Metal device) or the frame is
  `ASI_IMG_Y8` (not wired up in either GPU renderer yet).
- **Audit: is GPU actually used everywhere it reasonably can be?** Walked every per-frame CPU
  processing path in `CameraManager` to check for cases where Metal rendering is enabled
  (`useMetalRenderer == true`) but some step still silently runs on the CPU anyway. Findings:
  denoise/wavelet-sharpen (`ImageEnhancer`) and histogram (`HistogramComputer`) are both already
  correctly gated to the CPU render path only (`scheduleCPUEnhancementIfNeeded`'s `!
  useMetalRenderer` guard; `HistogramView`'s `useMetalRenderer ? gpuHistogramCounts : ...`) — when
  GPU rendering is on, both instead use `MetalFrameRenderer`/`Shaders.metal`'s own denoise, wavelet
  sharpen, and `histogramReduce` kernels, so there's no gap there. `LiveStacker` (the CPU
  accumulator) is likewise only live when `isLiveStackingEnabled && !useMetalRenderer` — GPU mode
  does its own accumulation via `MetalFrameRenderer`'s temporal-accumulator kernel. The one
  genuine gap found: **dark/flat calibration (`applyDarkSubtraction`, `FrameArithmetic.subtract`,
  `FlatFieldCorrector.correct`) runs on the CPU unconditionally, regardless of the Metal
  toggle.** This isn't actually a bug to "move to GPU", though — `ingest()`'s calibrated
  `processed` frame feeds several other CPU-side consumers besides the live preview (planetary
  tracking, lucky imaging, FITS recording), so the corrected pixel data has to exist as CPU-
  resident `Data` either way; round-tripping it through the GPU and back just for the preview
  would add a texture upload/readback for no benefit. What *was* a real, avoidable cost:
  `FlatFieldCorrector.correct` recomputed `mean(flat)` — a full extra pass over the flat frame's
  pixels — from scratch on *every single incoming video frame* for as long as flat correction
  stayed enabled, even though the active flat frame is static until the user recaptures or
  switches it. Fixed by computing it once, in `CalibrationFrame.init` (`CalibrationLibrary.swift`)
  when the flat is captured, and threading that precomputed `meanBrightness` through
  `FlatFieldCorrector.correct(light:flat:precomputedFlatMean:)` — `applyDarkSubtraction` now reads
  `calibrationLibrary.activeFlat?.meanBrightness` instead of asking `FlatFieldCorrector` to
  re-derive it every frame. `precomputedFlatMean` defaults to `nil` (falls back to the old
  from-scratch computation) so existing test call sites that only have a bare `CapturedFrame`
  keep working unchanged.
- **Follow-up: dark/flat calibration moved to the GPU after all.** The entry above argued
  calibration should stay CPU-only since `applyDarkSubtraction`'s output feeds several CPU-side
  consumers (planetary tracking, lucky imaging, FITS recording) besides the live preview — true,
  but that's an argument against calibration staying GPU-*resident*, not against computing it
  *on* the GPU and reading the result back. Reconsidered: added `GPUFrameCalibrator`, a small
  Metal actor combining dark-subtract and flat-divide into one dispatch (`calibrateRaw8`/
  `calibrateRaw16` in `Shaders.metal`) over the same raw sensor buffer `FrameArithmetic.subtract`/
  `FlatFieldCorrector.correct` operate on, then reads the result back into CPU-resident `Data` so
  every downstream consumer still gets a normal `CapturedFrame`, unchanged. `applyDarkSubtraction`
  now tries this first when `useMetalRenderer` is on, and only falls back to the CPU scalar loops
  if the GPU path is unavailable or declines the frame (dimension/type mismatch, no Metal device).
  Since Metal requires a bound resource at every buffer index a kernel references even along an
  untaken branch, `hasDark`/`hasFlat` flags let one kernel invocation cover dark-only, flat-only,
  or both, with a shared 1-byte placeholder buffer bound wherever a stage is skipped. Making this
  possible required `ingest()` (and `applyDarkSubtraction` itself) to become `async` — both of its
  call sites were already inside a `Task { for await frame in stream { ... } }` loop, so this was
  just adding `await`, not restructuring the frame-consumption flow. Verified via
  `GPUFrameCalibratorTests` (new), which asserts the GPU kernels produce byte-for-byte identical
  output to the CPU reference implementations across dark-only/flat-only/combined RAW8/RAW16
  cases, not just "doesn't crash" — a numerically wrong calibration would be a much worse
  regression than a slow one for an imaging app.
- **No custom Bluetooth video-streaming companion app.** Bluetooth (classic or
  BLE) doesn't have the throughput for live video — Apple's own Continuity
  Camera deliberately uses Wi-Fi/peer-to-peer for the video itself and only
  touches Bluetooth for discovery. The All-Sky monitor's Continuity Camera
  support (any signed-in nearby iPhone can act as a camera) has a real "Add
  iPhone" UI instead: a sheet documenting the actual (system-level) pairing
  prerequisites, live discovery feedback, and a picker that separates
  "iPhone (Continuity Camera)" from other webcams.
- **iPhone Night Mode froze `currentFrame` on the averaged result but never actually stopped the
  live webcam stream, so the result vanished (almost) as soon as it appeared.** `finishIPhone
  NightModeCapture` set `currentFrame = result` directly, but `frameConsumerTask` (the `for await
  frame in stream` loop over the webcam's `AsyncStream`) kept running — its very next frame,
  arriving within a video frame interval (~33ms), overwrote `currentFrame` right back to a single
  unstacked live frame via the normal `ingest()` path, before the UI could meaningfully show it or
  before Export's FITS/PNG/TIFF buttons (gated on `currentFrame != nil`, not on any Night-Mode-
  specific state) could be clicked against the *stacked* result rather than whatever live frame
  happened to land a moment later. `captureSingleExposure` already gets this right — it cancels
  `frameConsumerTask` before freezing on its captured frame — `finishIPhoneNightModeCapture` just
  never copied that step. Fixed by cancelling `frameConsumerTask` there too, matching
  `captureSingleExposure`'s pattern; "Resume Live View" (already shown whenever `!isLiveViewActive`)
  re-subscribes via the existing `resumeLiveView()` path unchanged.
- **Live Stack's "no star alignment" caveat got a real, opt-in fix: GPU drift reduction.**
  Plain Live Stack (`accumulateMono`) always added each incoming frame into the running sum at
  its own native pixel position — fine for a well-tracked equatorial mount, but a mount that
  drifts even slightly (an alt-az mount especially, which also field-rotates over a session, not
  just translates) slowly smears stars into short trails across a long stack. Added
  `MetalFrameRenderer`'s "Drift reduction": on the first stacked frame of a session, a one-time
  full-frame GPU max-search (`findBrightestPartial`) picks the brightest point as an initial
  lock-on guess, refined by a weighted-intensity-centroid GPU reduction (`centroidPartial`) over a
  small (`driftROISize` = 64px) window around it — that becomes the session's fixed reference
  position. Every subsequent frame, the same centroid search re-locates the star in a window
  centered on where it was found *last* frame (so the lock follows slow drift instead of only
  ever searching one fixed spot), and the frame is accumulated via a new `accumulateMonoAligned`
  kernel that samples the source texture at a sub-pixel (bilinear, `access::sample`) offset equal
  to how far the star has moved from the reference, instead of `accumulateMono`'s direct
  unshifted read — pulling the drifted frame back into alignment before it's summed.
  - **Real, deliberate tradeoff: this makes `process()` synchronously block on a small extra
    GPU round-trip once per live-stack frame** (`computeDriftShift` commits its own command
    buffer and calls `waitUntilCompleted` before the main per-frame command buffer's accumulate
    dispatch, since the shift has to be known before that dispatch can be encoded). Kept
    acceptable by keeping both GPU-side searches tiny: the full-frame max-search only ever runs
    once per stacking session (to find the initial lock), and the per-frame centroid search is
    bounded to a 64×64 window, not the whole frame.
  - **Correctly scoped as translation-only, not full registration.** This corrects drift (the
    whole frame shifting) via one tracked star, not field rotation — a real alt-az effect over a
    longer session that a single-point lock structurally can't capture (would need at least two
    tracked points to solve for rotation too). Documented as such in `HelpContent` rather than
    oversold as full multi-star geometric alignment.
  - **Fails safe, not silent-wrong.** If the tracked star's window sums to ~zero signal (lost
    behind a cloud, or drifted out of the search window entirely), `DriftAligner.centroid`
    returns `nil` and that one frame falls back to plain unaligned `accumulateMono` rather than
    accumulating with a stale or nonsensical shift — a single missed frame is a minor blur
    contribution, not a corrupted stack.
  - **The reduction math itself (`DriftAligner`) is deliberately separated from the GPU dispatch
    plumbing** (`findBrightestPoint`/`computeCentroid`/`computeDriftShift` in
    `MetalFrameRenderer`) specifically so it has real unit test coverage
    (`DriftAlignerTests`) without needing a Metal-dependent test harness for the arithmetic
    itself — the same split `GPUFrameCalibrator`/its tests didn't need (that one's correctness
    was verified by comparing whole-pipeline output against the CPU reference instead), chosen
    here because there's no separate CPU reference implementation of drift tracking to compare
    against.
  - CPU-only sessions (`useMetalRenderer == false`) don't get this — the toggle is disabled in
    the UI rather than silently doing nothing, since `LiveStacker` (the CPU accumulator) has no
    equivalent aligned-accumulate path.
- **Added the actual "small ROI, high FPS" planetary/lunar lucky-imaging workflow (a real
  technique: FireCapture/SharpCap users routinely set a small ROI, then record raw SER video for
  AutoStakkert!3/PIPP/RegiStax to align, stack, and sharpen) — this app had none of the three
  pieces it needs.** All three real gaps closed:
  - **`startStreaming`/`captureSingleExposure` always requested the full sensor.**
    `CaptureEngine` called `ASISetROIFormat` with `camera.maxWidth`/`maxHeight` unconditionally —
    there was no way to request a smaller region at all, and a smaller ROI is what actually
    increases achievable frame rate (less data read off the sensor per frame), not just a
    post-readout software crop (`FrameCropper`, used for planetary auto-crop, crops *after* the
    full-resolution frame already arrived — no FPS benefit). Added `CaptureEngine.setROI(width:
    height:)`, storing the desired dimensions as actor-local state (`desiredWidth`/
    `desiredHeight`, defaulting to the full sensor) that both `startStreaming` and
    `captureSingleExposure` now read instead of the hardcoded maximum — centralizing it in the
    actor itself, rather than threading a parameter through every call site, is what makes a
    chosen ROI persist automatically across live streaming, single exposures, *and* dark/flat
    calibration captures (which all reuse `captureSingleExposure`) without each one needing to
    remember to pass it along. Validated/clamped to `ASISetROIFormat`'s own hard constraints
    (width a multiple of 8, height a multiple of 2) rather than trusting the caller.
    `CameraManager.changeCaptureROI(width:height:)` restarts the stream for a new ROI to take
    effect, mirroring `changeImageType`'s existing RAW8/RAW16-switch pattern exactly. UI: a
    "Capture ROI" section (Camera Controls tab, ZWO only) with Full Sensor/640×480/800×600
    presets.
  - **No raw, undiscarded video export — only single-frame FITS/PNG/TIFF, and a *sharpness-gated*
    continuous FITS recorder** (`recordIfNeeded`) that discards frames below a threshold before
    they hit disk. That's the wrong shape for this workflow: AutoStakkert!3 does its own,
    better-informed frame ranking and alignment from the *complete* video — pre-discarding frames
    in the capture app would take that choice away from it, not help it.
  - **No SER writer at all**, and downstream tools expect exactly that container, not FITS.
    Added `SERWriter` — an incremental (`FileHandle`-based, not buffer-then-write) implementation
    of the open SER format spec: a 178-byte header (patched in `close()` once the real frame count
    is known — SER has no length prefix elsewhere), each frame's raw bytes appended as it arrives,
    then a per-frame `.NET`-tick timestamp trailer. Incremental specifically because the whole
    point of a small ROI is a *high* frame rate sustained over minutes — tens of thousands of
    frames, easily multiple gigabytes, that an in-memory-buffer-then-write approach would have to
    hold before writing a single byte. `CameraManager.startSERRecording(to:durationSeconds:)`
    writes every incoming (dark-subtracted) frame unconditionally via a new, separate
    `recordSERFrameIfNeeded` — deliberately not reusing `recordIfNeeded`'s sharpness gate, for the
    reason above. Colors correctly: mono for a non-color camera, the connected camera's actual
    Bayer pattern for a color one, and SER's `.rgb` ColorID (not `.bgr`) for webcam/iPhone RGB24
    frames, matching the R,G,B byte order `WebcamCaptureEngine` already produces.
  - Tested at the file-format level (`SERWriterTests`): header field values/offsets, the
    frame-count patch actually landing after `close()`, frame-data byte-for-byte round-tripping,
    Bayer-pattern-to-ColorID mapping, and the RGB24 3-planes-per-pixel case — not end-to-end
    against a real ZWO camera or real AutoStakkert!3 ingestion, which is outside what a unit test
    can reach; the format itself (byte layout, header offsets) is what's verified.
  - **Follow-up: `PlanetaryPreset` + `CameraManager.applyPlanetaryPreset`.** The ROI/SER pieces
    above are the mechanism; this is the actual per-target numbers (ROI size, exposure/gain
    starting points, recommended SER duration, target histogram percentage) real planetary
    imagers already work from for Saturn/Jupiter/Mars/Venus/Moon, tuned around a ~2µm-pixel
    camera (ASI678MC) behind an f/10-f/12 Mak/SCT. Applying a preset sets RAW8, the ROI, and
    starting exposure/gain in one step (deliberately the *low* end of each range — the actual
    histogram target still needs the operator's own live adjustment, which depends on the
    night's real seeing/transparency, not just the target) — and `ControlsPanelView` separately
    sets its own SER-duration `@AppStorage` state from `preset.recommendedMaxDurationSeconds`,
    since `CameraManager` has no reason to know about that view-local setting. `PlanetaryPreset`
    is plain declarative data (ranges/constants, no GPU or hardware calls), so `PlanetaryPresetTests`
    covers it directly rather than needing a device/mock-camera harness.
- **Audit pass: closed the real gaps found in a "what's not fully implemented yet" review**,
  leaving the deliberately-scoped ones (no full plate solving, no geometric alignment beyond
  single-star drift reduction, the declined AI Neural-Engine/super-resolution features, real
  ZWO-hardware/notarization validation) untouched — those are documented design decisions or
  external-resource dependencies, not bugs.
  - **`ASI_IMG_Y8` silently produced a blank GPU preview.** `MetalFrameRenderer.process` and
    `GPUStillImageRenderer.makeDisplayImage` both explicitly excluded `ASI_IMG_Y8` from their
    RAW8/RAW16 guards/switches with a "not wired up yet" comment, even though Y8 is mono
    1-byte/pixel — identical in layout to RAW8 — and every *other* Y8-aware path in the app
    (`LiveStacker`, `CalibrationLibrary`, `FrameArithmetic`, `GPUFrameCalibrator`,
    `HistogramComputer`, `FrameCropper`, `CGImageRenderer`, `FITSWriter`, `SERWriter`, ...)
    already treats it exactly like RAW8. The two GPU display paths just hadn't been updated to
    match — widened both guards to include `ASI_IMG_Y8`; no new code needed, since `renderMono`'s
    pixel-format selection already falls into the correct 1-byte/`.r8Unorm` branch for anything
    that isn't `ASI_IMG_RAW16`.
  - **Denoise and Wavelet Sharpening silently did nothing for webcam/iPhone (RGB24) sources —
    on *both* render paths.** `Shaders.metal`'s `bilateralDenoise`/`waveletBlur`/`waveletCombine`
    are mono-only (`texture2d<float,...>` reads exposed a single channel), so
    `MetalFrameRenderer.processRGB24` never ran them at all; the CPU fallback
    (`ImageEnhancer.denoise`/`waveletSharpen`) called `normalizedSamples`, whose `switch` had no
    RGB24 case and returned `nil`, silently no-opping in `CameraManager.scheduleCPUEnhancementIfNeeded`. A real capability gap for the whole iPhone/webcam capture source, not a documented scoping choice.
    - **GPU fix**: added `bilateralDenoiseRGBA`/`waveletBlurRGBA`/`waveletCombineRGBA` — direct
      color analogs of the mono kernels. The blur weights are color-agnostic, so
      `waveletBlurRGBA` just runs the identical taps on all three channels via `float3` math; the
      bilateral filter's *range* (intensity-similarity) weight is the one place color needed real
      thought — using full RGB Euclidean distance (`length(sample.rgb - center.rgb)`) rather than
      three independent per-channel weights, since independent weights would let each channel
      blend by a different amount and introduce color fringing at edges.
      `MetalFrameRenderer.processRGB24` now chains stretch → (denoise) → (wavelet-sharpen) →
      display, with whichever stage runs *last* always targeting `outputTexture` directly —
      avoiding an unconditional extra scratch-to-`outputTexture` copy pass on the common
      "neither enabled" path, which still behaves exactly as before this fix (stretch writes
      straight into `outputTexture`, nothing else runs).
    - **CPU fix**: added `ImageEnhancer.denoiseRGB24`/`waveletSharpenRGB24`, using the exact same
      math as their GPU counterparts (full-RGB-distance range weight; per-channel-independent
      blur) so the CPU and GPU render paths produce matching results for a webcam/iPhone source,
      not just visually-similar ones. `denoise`/`waveletSharpen` now dispatch on
      `frame.imageType` internally, so `CameraManager`'s call sites needed no changes.
    - GPU live-stacking (`accumulateMono`) remains mono-only — the Controls panel already
      discloses this (`isStreakMaskingEnabled`'s GPU-only warning is a related, separate gap: the
      CPU `LiveStacker`'s per-pixel streak mask has no GPU-accumulator equivalent yet, since that
      needs a second per-pixel contribution-count texture threaded through the accumulate
      kernels, not just a color-aware version of an existing one — left as the one remaining,
      already-disclosed gap from this audit, scoped but not attempted here).
    - Tested on both render paths' math: `ImageEnhancerTests` adds RGB24 cases for noise-variance
      reduction, flat-field stability, edge-contrast increase, near-identity at zero gain, and a
      color-fringing check (a hard red/green edge should stay red- and green-dominant on its
      respective side after denoising, not bleed into an unexpected color). The GPU kernels
      themselves aren't independently unit-tested (no existing precedent in this codebase for
      testing `.metal` kernel output directly without a full render-pipeline harness), but share
      the exact same math as the now-tested CPU path.
  - **Follow-up: closed the "GPU live-stacking doesn't support streak masking" gap left open
    above** — `specs/skyformac_AI_Features_Pipeline_Spec.md`'s Implementation Notes had
    explicitly deferred this as too big/risky a change to already-shipped GPU code, since
    `accumulateMono` (and everything downstream of it — `stretchMono`/`debayerAndStretch`/
    `histogramReduce`) all divide by one shared *scalar* frame count, and masking needs a
    *per-pixel* count instead. The actual fix avoids the cost that deferral worried about: rather
    than thread a per-pixel-count-aware variant through every one of those kernels, a masked
    frame accumulates into a separate `(sum, count)` texture pair via a new
    `accumulateMonoMasked` kernel; a second new kernel, `normalizeMaskedAccumulator`, then
    collapses that pair into a true per-pixel average written into the *existing*
    `accumulationTexture` — so `stretchMono`/`debayerAndStretch`/`histogramReduce` need zero
    changes at all, they just read `accumulationTexture` with `divisor = 1.0`, exactly as if it
    held one already-averaged frame. Two new kernels, not N modified ones.
    - **A real correctness hazard this design has to guard against explicitly**:
      `accumulationTexture` means two different things depending on whether masking is active
      this frame — a running *sum* (the pre-existing unmasked path) vs. an already-normalized
      *average* (the new masked path). Toggling masking on/off mid-session, or a dimension change,
      would silently corrupt it if a raw-sum accumulate landed on top of a previous frame's
      already-divided average. `MetalFrameRenderer` tracks `wasAccumulatingMasked` and forces a
      full `resetLiveStack()` the moment the mode would otherwise change frame-to-frame, the same
      way enabling/disabling Live Stack itself already resets via `liveStackGeneration`.
    - **Masking takes priority over GPU drift-reduction alignment** when both are enabled at
      once (satellite masking and single-star drift-lock are largely orthogonal use cases —
      combining them would need a third kernel variant this feature's scope doesn't justify);
      the Controls panel now says so instead of quietly not aligning.
    - **Verified against real dispatch, not just reasoning about the math**: `MaskedLiveStackGPUTests`
      loads and dispatches the actual `accumulateMonoMasked`/`normalizeMaskedAccumulator` kernels
      against a real `MTLDevice` (same pattern `GPUFrameCalibratorTests` already established) and
      confirms a masked-out pixel's average comes out as if that frame never existed for it (not
      as if it contributed a zero) — the exact CPU behavior `LiveStacker.add(_:mask:)` already has.
- **CI has never actually passed, on any commit, going back to the first one — every push failed
  the same way.** Three separate, pre-existing Swift 6 "sending" concurrency diagnostics, all
  reproducible on Xcode 16.4 (the `macos-15` GitHub Actions runner image) but not on a newer local
  Xcode, which is exactly why nobody had noticed locally:
  1. **Every `Task.detached(priority:) { [weak self] in ... await MainActor.run { ...self... } }`
     in `CameraManager`** (`scheduleQualityScoreIfNeeded`, `scheduleStreakDetectionIfNeeded`,
     `scheduleCPUEnhancementIfNeeded`, `schedulePlanetTrackingIfNeeded`,
     `scheduleFocusAssistIfNeeded`) failed with "sending 'self' risks causing data races" / "task-
     isolated 'self' is captured by a main actor-isolated closure." Fixed by replacing the nested
     `MainActor.run { ... }` closure with a call to a plain method on the class (already
     `@MainActor` since the class itself is) — `await self?.applyFoo(...)` instead of `await
     MainActor.run { guard let self ...; self.foo = ... }`. This sidesteps the diagnostic
     structurally (no second closure literal "sends" `self` anywhere) rather than arguing with it.
     Plain (non-`.detached`) `Task { [weak self] in ... }` blocks elsewhere in the same file
     (`startIPhoneNightModeCapture`, catalog object fetching) were never affected — they inherit
     the caller's `@MainActor` context directly, so there's no nonisolated-task boundary for the
     diagnostic to fire on in the first place.
  2. **`try #require(GPUFrameCalibrator(device: device))` in `GPUFrameCalibratorTests`** — wrapping
     an actor's failable initializer call directly inside `#require`'s macro-generated
     autoclosure failed with "sending '$1' risks causing data races." Fixed by binding the
     constructor's result to a plain local optional first, then `#require`-ing that instead —
     the macro never needs to embed the constructor call itself in its expansion.
  3. **`SkyformacUITests` had no `@MainActor` annotation** on a class whose methods call
     `XCUIApplication`/`XCUIElement` APIs that are `@MainActor`-isolated in the SDK Xcode 16.4
     builds against — failed with "call to main actor-isolated ... in a synchronous nonisolated
     context." Fixed by adding `@MainActor` to the class; XCTest already runs these methods on the
     main thread, so this just tells the compiler what was already true.

  All three fixed as isolated, individually-verified commits (each built and tested standalone in
  a throwaway `git worktree` at the exact commit CI was failing on, before merging into the real
  working tree) rather than bundled with unrelated in-progress feature work, specifically so a
  bisect or revert of any one fix stays clean.
- **Added FITS round-trip (`FITSReader`) — reading, not just writing.** The app could write FITS
  but never read one back, so "open a file I exported earlier" or "view a dark frame I captured
  last week" had no in-app path at all. `FITSReader.read(from:)` parses exactly what `FITSWriter`
  itself produces back into a `CapturedFrame` — deliberately not a general-purpose FITS reader
  (no multi-HDU, no WCS keywords, no floating-point pixel data), matching the same "don't build
  more than this app actually needs" discipline as everywhere else in this codebase.
  - **`FITSWriter` gained a `BAYERPAT` header card** (`RGGB`/`BGGR`/`GRBG`/`GBRG` — the same
    convention PixInsight/Siril/SharpCap already use) for color-camera exports; without it, a
    reopened file has no way to know whether/how to debayer at all, since FITS itself carries no
    color information otherwise. Both existing `FITSWriter.write` call sites now pass the
    connected camera's real `isColorCamera`/`bayerPattern` instead of writing color-blind files.
  - **Real bug caught while writing `FITSReaderTests`, not just designed around in the abstract**:
    the first `parseHeaderCards` implementation ASCII-decoded a size-capped *prefix of the whole
    file* — header and pixel data together — as one string, then scanned it for 80-character
    cards. `String(data:encoding:.ascii)` returns `nil` outright the instant it's handed even one
    byte ≥ 128, and real sensor pixel data (RAW16 especially, and RAW8 values ≥ 128) routinely
    contains such bytes — so this "worked" only for the RAW8 mono test whose specific fixture
    bytes all happened to be < 128, and silently reported "not a FITS file" for RAW16 and any
    color/`BAYERPAT` fixture the moment real byte values were involved. Fixed by decoding strictly
    one 2880-byte block at a time and stopping the instant `END` is found, never touching a byte
    past the header's own blocks — the same fix shape as `MetalFrameRenderer`'s known "always
    verify byte layout against what real data actually contains, not just a convenient test
    fixture" lesson from earlier in this project's history.
  - New "Exported Files" section (`ControlsPanelView`, Camera Controls tab): a persisted
    (`AppSettings.exportHistory`, JSON-encoded, capped at 50 entries) history of every export/
    recording, an "Open File…" browser, and `ExportedFileViewerView` — a `.sheet` rendering a
    reopened FITS frame through the app's own `CGImageRenderer`/`DisplayStretch` pipeline with
    adjustable Black/White Point sliders and a "Debayer as color" override, or displaying PNG/
    TIFF/JPEG directly. Deliberately a viewer, not a second processing suite — see
    `specs/skyformac_Exported_Files_Spec.md`'s directives for exactly where that line is drawn.
- **Real bug found while verifying "does exporting the stack actually export the stack": on the
  GPU render path (the default), it didn't — exporting FITS/PNG/TIFF while Live Stack was
  running silently exported the latest raw single frame instead.** `CameraManager.currentFrame`
  is only ever the raw per-frame data when `useMetalRenderer == true` — the GPU accumulation
  happens entirely inside `MetalFrameRenderer`, display-only, with no path handing the running
  average back out to `CameraManager` at all. `finishExport`'s FITS case read `currentFrame`
  directly; the PNG/TIFF case went through `currentDisplayImage()`, which (in GPU mode,
  `currentImage` being `nil`) re-rendered `currentFrame` — same raw frame either way. The CPU
  render path never had this bug: `ingest()` already sets `currentFrame = liveStacker
  .currentAverage() ?? processed` there, so `currentFrame` genuinely is the stack.
  - **Fix**: `MetalFrameRenderer.currentAccumulatedFrame(imageType:)` reads the GPU accumulator
    texture back into a real, full-bit-depth `CapturedFrame` — accounting for the two different
    things `accumulationTexture` can hold (a running *sum* of normalized `0...1` texture reads
    for plain unmasked accumulation, needing `sum / accumulatedFrameCount * maxValue`; an
    already-`normalizeMaskedAccumulator`-divided true average when masking was active, needing
    `divisor = 1.0` instead — reusing `wasAccumulatingMasked`, the same flag the masked-
    accumulation correctness fix earlier added). `CameraManager.gpuAccumulatedFrameProvider` (a
    closure set by `MetalPreviewView`, since `CameraManager` otherwise has no reference at all to
    the `MetalFrameRenderer` instance living inside that view's own `Coordinator`) is how
    `CameraManager` pulls this on demand, from the new `frameForExport()`/`imageForExport()` —
    used only by `finishExport`, deliberately *not* substituted into `currentDisplayImage()`
    itself, since that function's other two callers (`capturePolarAlignmentReferenceFrame`/
    `solvePolarAlignment`) specifically want the single raw current frame for star-position
    detection — averaging across drift would blur exactly the star positions polar alignment
    needs precise, not stacked.
  - The actual "GPU accumulator sum → real sensor pixel value" arithmetic is factored into
    `MetalFrameRenderer.rawPixelValue(fromAccumulatedSum:divisor:maxValue:)`, a pure function with
    direct unit tests (`MetalFrameRendererTests`) covering the unmasked-average, masked-already-
    normalized, RAW16-range, and rounding-not-truncating cases — the same "factor the easy-to-get-
    subtly-wrong math out into something testable without a full render pipeline" pattern
    `DriftAligner` already established.
  - **Known remaining edge case, not fixed**: if Live Stack *and* an in-progress Lucky Imaging
    "Stack" result are both active at once (an unusual combination — different, largely
    orthogonal workflows), `frameForExport()` currently prefers the GPU Live Stack accumulator
    over whatever Lucky Imaging's own `stackLuckyImagingBest` just wrote into `currentFrame`.
    Lucky Imaging's own result is arguably the more deliberate, more recent user action in that
    specific overlap; not resolved here since it's a narrow, rare combination rather than the
    common case this fix targets.
- **Live Stack and Lucky Imaging both silently did nothing for a webcam/iPhone (RGB24) source —
  found while checking "can I stack and lucky-image with an iPhone paired camera" against the
  actual code path instead of assuming the answer was yes.** Three separate gaps, all in
  code paths that only ever see RAW8/RAW16 mono data from a real ZWO camera and had simply never
  been extended to RGB24:
  - `SharpnessScorer.luminanceGrid`'s `switch` had no `ASI_IMG_RGB24` case (`default: return nil`
    → `score(for:)` always `0`), so every frame in a Lucky Imaging burst from a webcam/iPhone
    source tied at score `0` — "keep the sharpest fraction" had nothing real to rank.
  - `FrameArithmetic.average`'s `switch` had the same gap (`default: return nil`), so
    `LuckyImagingSession.stackBest` — which calls it directly — returned `nil` for every
    webcam/iPhone burst. Lucky Imaging produced literally nothing for that source, independent
    of the scoring gap above.
  - `CameraManager.ingest`'s Live Stack branch was `isLiveStackingEnabled && !useMetalRenderer` —
    meaning CPU accumulation (the only kind that supports RGB24, see `LiveStacker.add`'s own
    RGB24 case) only ran with the GPU render path *off*. With the GPU path on (the app's
    default), RGB24 frames hit `MetalFrameRenderer.process`'s early-return `processRGB24` branch,
    which never accumulates at all — so `currentFrame` just stayed the latest raw frame, live
    stack toggle or not.
  - **Fix**: `SharpnessScorer` gained an `ASI_IMG_RGB24` case reusing the existing `luma8` helper
    directly — webcam/iPhone frames are already packed R,G,B triplets (`WebcamCaptureEngine`'s
    doc comment), the same layout `luma8` already expects for an already-debayered ZWO color
    frame, so no new conversion code was needed, just wiring it up. `FrameArithmetic` gained
    `average24`, the RGB24 analog of `average8`/`average16` (per-channel independent mean).
    `ingest`'s condition became `isLiveStackingEnabled && (!useMetalRenderer || processed.imageType
    == ASI_IMG_RGB24)` — RGB24 always accumulates on the CPU `LiveStacker` regardless of the
    render-path toggle, since GPU accumulation for it doesn't exist and wouldn't be worth adding
    (the CPU path is plenty fast at webcam/iPhone frame sizes); the GPU renderer still does its
    own per-frame stretch/denoise/sharpen of whatever `currentFrame` holds, so the live preview
    stays GPU-accelerated even though the *stacking* itself is CPU-side for this source.
    `liveStackedFrameCount` (the Controls panel's live frame-count readout) had the matching gap
    — it read `gpuLiveStackFrameCount`, which never advances for RGB24, whenever
    `useMetalRenderer` was true; changed to check `!isExternalWebcam` too, so the readout tracks
    `liveStacker.frameCount` (the counter actually advancing) for a webcam/iPhone source on
    either render path.
- **Reduce Drift's centroid tracking was dominated by sky background, not the star it was
  supposed to track — reported as "the image is overlapped without the drift reduction," i.e.
  visibly no better than plain unaligned stacking.** Two compounding bugs, both in
  `MetalFrameRenderer`'s drift-reduction math (`computeCentroid`/`findBrightestPoint`, backed by
  `DriftAligner`'s pure functions):
  - `centroidPartial` weighted every pixel in the `driftROISize`×`driftROISize` (64×64) search
    window by its *raw* intensity. A star occupies a handful of pixels near 0.9; the sky
    background around it, typically ~0.05, covers the other ~4000+ pixels — summed across the
    whole ROI, the background's total contribution can be an order of magnitude larger than the
    star's, pulling the intensity-weighted centroid toward the ROI's own geometric center
    regardless of where the star actually sits. Since that center barely changes frame to frame,
    the computed "drift" was close to zero even while the real stars visibly smeared across the
    stack — alignment was running, just computing shifts that didn't mean anything.
  - `findBrightestPartial` (the one-time initial lock-on search) picked the single brightest
    *texel* in the whole frame — on a real sensor, a hot or warm pixel can easily be brighter
    than any star, and unlike a star it sits at a fixed sensor location. Locking onto one means
    the "tracked" position never appears to drift at all (it's not part of the sky), reproducing
    exactly the same "no visible alignment" symptom, permanently, for that entire session.
  - **Fix**: `computeCentroid` is now a genuine two-GPU-pass measurement — a new `roiStatsPartial`
    kernel first measures the ROI's own local background (mean + stddev via `DriftAligner
    .backgroundThreshold`'s sigma-clipping arithmetic), then `centroidPartial` weights only pixels
    more than 3σ above that background, by how far above the *mean* (not the raw value) they are.
    Background contributes exactly zero instead of swamping the sum. `findBrightestPartial` now
    scores each candidate by a 3×3-neighborhood average instead of the single texel — a real
    star's PSF spreads over multiple pixels so its averaged score barely drops, while an isolated
    hot pixel's drops by roughly 9×, so the search naturally prefers real stars. Both fixes are
    pure-GPU-side except the background/threshold arithmetic itself, which is `DriftAligner
    .backgroundThreshold` — a testable pure function (`DriftAlignerTests`) for the same "keep the
    easy-to-get-wrong math outside the GPU dispatch plumbing" reason `DriftAligner`'s other
    functions already are.
- **Added a "Save Stacked Image…" button directly in the Live Stack panel** — calls the existing
  `exportCurrentFrame(as: .png)`/`frameForExport()` machinery (already correct for both the GPU
  and CPU accumulators, and for a webcam/iPhone source, per the fixes above), just surfaced right
  next to the stack it's for instead of requiring a trip to the separate Export section below.
- **Added a Pause/Resume control for Live Stack, so a session can actually be looked at without
  losing it.** Before this, the only way to stop a stack from changing while you examined it was
  `Reset`, which discards it. `CameraManager.isLiveStackPaused` freezes accumulation on both
  render paths — `ingest`'s CPU path skips `liveStacker.add(...)` but still displays
  `liveStacker.currentAverage()`; `MetalFrameRenderer.process`'s GPU path skips the accumulate
  dispatch and the frame-count/drift-lock bookkeeping but still reads back `accumulationTexture`
  at its existing (unchanged) divisor — so a paused stack reads as "holding still," not as a
  silent reset. Resuming just un-pauses; nothing about the accumulator changes across the pause.
- **Reduce Drift still couldn't hold alignment against large or sustained drift — a real-world
  test (a handheld camera panned across a room, tracking a chair) showed the same fully-smeared
  result as with drift reduction off.** Root cause, on top of the background-subtraction fix
  above: `computeDriftShift`'s local re-locate only ever searched a small (`driftROISize`, 64px)
  window centered on the star's *last known* position. Once drift in a single frame exceeded half
  that window — a real possibility for a poorly-tracking mount over a longer gap between frames,
  and essentially guaranteed for anything panning fast — the tracked feature is no longer inside
  the window at all, the local search finds nothing above background, and (before this fix)
  `computeDriftShift` gave up for that frame *and every frame after it*, since the next frame's
  search is still centered on the same now-wrong last-known position. From that point on, drift
  reduction contributes nothing for the rest of the session — indistinguishable from being off.
  **Fix**: when the local search finds nothing, `computeDriftShift` now falls back to
  `reacquireLock` — the same whole-frame `findBrightestPoint` + background-subtracted-centroid
  search the very first frame of a session already uses — instead of giving up permanently. The
  re-acquired position is still measured against the session's original `driftReferenceCentroid`,
  so frames aligned before the jump and frames re-acquired after it land in the same place.
  - **Known remaining limitation, by design, not a bug**: this is still single-brightest-feature
    lock-on translation alignment, built for the kind of drift a real telescope mount actually
    produces (sub-pixel to a few pixels per frame from imperfect tracking) against a star field
    (many small, genuinely point-like sources). A handheld pan across an ordinary room, tracking
    an extended object like a chair with no real point source in frame at all, is a much harder
    problem — full-scene image registration, not single-point centroid tracking — and re-scanning
    for "the brightest thing in frame" after a big jump can just as easily lock onto a window or
    a lamp as the chair itself. The re-acquisition fix genuinely helps a real astro session (a
    star lost briefly to a bigger-than-expected drift, or a brief cloud, now recovers instead of
    derailing for the rest of the session); it does not turn this into a general handheld-video
    stabilizer, and testing it against night-sky drift (arcsec-scale, mount-tracking-error
    magnitude) rather than a room-scale handheld pan is the realistic way to judge whether it's
    working.
- **Reduce Drift, tested again with a real ZWO camera against a bright indoor scene, still
  smeared — but for a third, distinct reason on top of the two already fixed.** The scene
  (through a very wide/fisheye-style lens) had two enormous overexposed windows, each far bigger
  and brighter than anything a real star field would present. `findBrightestPoint`'s smoothed-max
  search and `computeCentroid`'s background-subtracted weighting both correctly identify "the
  brightest, most locally-uniform thing in frame" — but nothing before this fix distinguished a
  real star's small, few-dozen-pixel point-spread footprint from a lock candidate that's actually
  part of a huge saturated blob spanning a third of the search window or more. Locking onto a
  window's edge tracks that edge, not star motion — for a real sky target this would mean locking
  onto (say) a satellite's flare or a very close double star's combined blob instead of a single
  star, corrupting the whole session's alignment rather than just failing safely.
  **Fix**: `centroidPartial` now also counts how many pixels in the ROI actually cleared the
  sigma-clipped threshold (a 4th, `w` component on what was previously a `float3` partial —
  `MetalFrameRenderer`'s drift-partials buffer is sized generously enough for either already,
  since `SIMD3<Float>`/`SIMD4<Float>` share the same 16-byte stride on the Swift side).
  `DriftAligner.isLikelyPointSource(survivingPixelCount:roiArea:maxFraction:)` (default 15% of the
  ROI) rejects anything bigger than a generous star-footprint ceiling — `computeCentroid` returns
  `nil` instead of a centroid when that check fails, which `computeDriftShift` already treats the
  same as "lock lost" (fall back to unaligned accumulation this frame, or re-acquire via
  `reacquireLock`).
  - **This does not make Reduce Drift work on that specific test scene.** Two enormous, roughly
    equally bright windows with fisheye distortion between them isn't a scene this algorithm can
    align at all — rejecting the blob just means it now correctly finds *nothing* to lock onto
    there (falling back to plain unaligned accumulation) instead of confidently locking onto the
    wrong thing. The fix's real value is protecting a genuine star-field session from ever
    quietly mistracking a bright non-star object that happens to be the brightest thing in frame.
- **A Capture ROI smaller than the full sensor always landed at the sensor's top-left corner —
  `ASISetStartPos` was never called at all.** Reported as "cropping to 800×600 doesn't show the
  target" — a ROI genuinely was 800×600, just positioned at `(0, 0)` on the sensor every time
  regardless of where the actual framed target sat, since the ASI SDK's own default (used
  whenever `ASISetStartPos` is skipped) is the sensor's top-left corner, not its center. On a
  multi-thousand-pixel sensor, a target framed anywhere near the middle of the full-sensor
  preview — the normal case, once actually pointed at something — simply wasn't in an
  uncentered small ROI at all. **Fix**: `CaptureEngine.setROI(width:height:centerX:centerY:)`
  gained `centerX`/`centerY` (full-sensor pixel coordinates, `nil` = the sensor's own center);
  `ROIGeometry.startPosition` (a pure, unit-tested function) resolves them to the top-left
  `(startX, startY)` `ASISetStartPos` needs, clamped so the ROI never extends past the sensor's
  edge. Called right after `ASISetROIFormat` at both call sites that set one
  (`startStreaming`/`captureSingleExposure`, the latter covering every single-exposure/dark/flat
  capture too), per the SDK's own sample-code ordering. Defaults to sensor-centered for every
  existing caller (`Planetary Presets`, the quick-preset picker) — nothing needed to change there
  for the by-far-most-common case to now actually work.
- **Added manual width/height/center entry for Capture ROI** (`ControlsPanelView`'s "Custom size &
  center" fields), not just the two fixed presets (640×480/800×600) — any rectangle, and any
  on-sensor center, typed directly. `CameraManager.captureROICenterX/Y` surface what's actually
  applied (mirroring the existing `captureROIWidth/Height`), and a "Center on Sensor" button
  resets to the default without needing to know the sensor's real dimensions.
- **Surfaced three more genuine `ASICamera2.h` capabilities that were either unused dead code or
  never wrapped at all**, in response to "are there hidden parameters I can fine-tune":
  - **ZWO's own recommended Gain/Offset reference points** (`ASIGetGainOffset`/
    `ASIGetLMHGainOffset`, wrapped as `ZWOSDK.GainOffsetPresets`/`LMHGainOffsetPresets`) — the
    same "Highest Dynamic Range / Unity Gain / Lowest Read Noise" numbers SharpCap's gain presets
    and ZWO's own ASICap show, fetched once at connect (`CameraManager.refreshGainOffsetPresets`,
    a fixed camera-model characteristic, not something that changes mid-session) and one-tap
    `applyGainOffsetPreset(_:)`-able onto `ASI_GAIN`/`ASI_OFFSET`. Not every camera model supports
    the underlying call — a thrown error there is treated as "not available," not a hard failure,
    and the whole UI section only appears when at least one of the two calls actually succeeded.
    `ASIGetGainOffset` notably does *not* report a specific gain value for "Unity Gain" itself
    (only its offset) — `GainOffsetPreset.unityGain` deliberately leaves `ASI_GAIN` untouched
    rather than guessing at a number the SDK itself doesn't provide.
  - **Dropped-frame count** (`ASIGetDroppedFrames`) — a `ZWOSDK` wrapper already existed
    (`getDroppedFrames`) but nothing ever called it; genuinely dead code until now. Wired into a
    new `CameraManager.diagnosticsPollTask`, a 2-second loop (started on connect, cancelled on
    disconnect/camera-removed) that also re-reads `ASI_TEMPERATURE` — fixing a separate,
    previously-unnoticed staleness bug where Sensor Temperature was only ever read once, at
    connect time, and then silently froze at that value for the rest of the session, since nothing
    else ever refreshed `controlValues[ASI_TEMPERATURE]` afterward.
  - **ST4 guide-port pulse guiding** (`ASIPulseGuideOn`/`ASIPulseGuideOff`, wrapped as
    `ZWOSDK.pulseGuideOn/Off`, called from `CameraManager.pulseGuide(direction:durationMilliseconds:)`)
    — a manual single-pulse sanity-check UI (North/South/East/West buttons + a duration slider),
    shown only when `ZWOCameraInfo.hasST4Port` is true. **Explicitly unverified against real
    hardware** — this project has never had an ST4 cable wired to a real mount to confirm a pulse
    actually produces a guide correction end to end; the SDK calls are wired up faithfully per the
    header's own documented usage (`PulseGuideOn` then, after the requested duration,
    `PulseGuideOff` for the same direction), but that's "plumbing believed correct," not "tested."
    Explicitly requested even in this unverified state, rather than declined outright the way the
    truly infeasible AI Denoise/Super-Resolution features were — the difference being this is
    real, callable SDK surface with no missing dependency (no trained model, no unavailable
    hardware *class*), just no specific unit available to verify it against in this environment.
- **Smart Live Stack (Autopilot)** — asked to "think out of the box" for a genuinely new,
  fully-in-app live astrophotography workflow, rather than adding one more incremental control.
  The traditional deep-sky/planetary workflow curates quality *after* a session, in a separate
  tool, from a full recorded sequence (PixInsight's SubframeSelector/WeightedBatchPreprocessing,
  AutoStakkert!3's quality graph). This inverts that: curate live, frame by frame, so the stack
  on screen while a session runs is already the curated one — no separate tool, no post-session
  triage step.
  - **`SmartLiveStackGate.decide`** (new, pure, unit-tested) is the actual rule: reject a frame if
    Cloud Sentinel currently reports an alert (checked first — a sharp frame taken during a
    passing cloud is still a bad frame), otherwise reject if its `GPUSharpnessScorer` score (the
    same scorer `recordIfNeeded`'s quality gate already uses for Record to Disk — no new GPU
    resources needed, `CameraManager.sharpnessScorer` is one shared instance) is below
    `smartLiveStackQualityFraction` (default 50%, user-adjustable, persisted) of the sharpest
    frame this stacking session has actually seen. A frame that can't be scored at all (RGB24 —
    the scorer is mono-only) is always kept rather than silently excluded from a decision it
    can't make.
  - **Wiring reused the Pause mechanism rather than adding a second "skip this frame" path.**
    `CameraManager.effectiveLiveStackPaused` ORs the user's own Pause toggle with
    `smartStackSkipsCurrentFrame` (recomputed fresh every `ingest()` call, before either the CPU
    accumulation branch reads it directly or `MetalPreviewView` reads it building the GPU render
    path's `pendingUpdate`) — both mean the exact same thing to either accumulator: don't fold
    this frame in, keep displaying whatever's already there. No new "skip" concept needed in
    either `MetalFrameRenderer.process` or `LiveStacker` at all.
  - **`StackSNREstimator.relativeSNRGainPercent`** (new, pure, unit-tested) — the live "is this
    still worth it" readout, from real stacking-SNR math (`sqrt(N)` scaling for independent-noise
    frames), not a fabricated number. Deliberately documented that comparing gains across
    *different* `additionalFrames` values isn't meaningful (doubling always gives the same ~41%
    regardless of `N`) — only a *fixed* additional-frame-count's gain falling over the course of
    one session is the real "diminishing returns" signal, which is exactly what the UI shows
    (a fixed "next 20 frames" estimate, re-evaluated live).
  - **Scope note**: this curates quality, the same axis Lucky Imaging/Record-to-Disk's gates
    already work on — it is not autoguiding, dithering, or sequencing (the genuinely bigger gaps
    named when asked "what's missing for a professional"), and doesn't attempt to be. It's a real,
    shippable slice of "live, unattended, self-curating" that those bigger features would build on
    top of, not a replacement for them.
- **A small Capture ROI (800×600 or smaller) made live view slow down and flicker — worse the
  smaller the ROI.** The whole point of a smaller ROI is a *higher* frame rate (less sensor data
  read per frame), which is exactly what caused this: `CameraManager.ingest` ran its full
  per-frame pipeline — assigning `currentFrame`, bumping `frameID`, calling
  `refreshCurrentImage()` — completely unthrottled, once per real incoming frame, on
  `@MainActor`. `frameID` changing is what drives `MetalPreviewView.updateNSView`'s per-frame
  Metal dispatch (debayer/stretch/denoise/live-stack accumulate/histogram, one full GPU pass per
  tick). At a real camera's comfortable 100-200+fps on a small enough ROI, the previous frame's
  display work often hadn't finished before the next one arrived — frames piled up waiting their
  turn on `@MainActor`, and the visible result was a growing backlog being drawn in bursts: not a
  live view, but a slow, flickering slideshow that got worse the longer it ran.
  - **Fix**: `ingest` now rate-limits only the *visible* refresh (`frameID` bump +
    `refreshCurrentImage()` call) to ~30fps (`minimumDisplayRefreshInterval`, wall-clock via
    `Date`), while everything before that point in the function — dark subtraction,
    `recordIfNeeded`/`recordSERFrameIfNeeded` (SER/FITS recording), Lucky Imaging accumulation,
    the CPU `LiveStacker`'s own accumulation — still runs for every single real incoming frame,
    completely unthrottled. This was the deliberate design constraint driving the fix shape:
    **Record SER Video's own promise is "writes every incoming frame, undiscarded"** — capping
    the *capture*-side `AsyncStream` buffering (the more obvious-looking fix) would have silently
    broken that guarantee specifically in the small-ROI/high-FPS scenario SER recording is built
    for. Rate-limiting only the display refresh keeps recording lossless while fixing the actual
    visible bug.
  - At low/normal frame rates this is a no-op — the throttle condition is never true because the
    next real frame doesn't arrive within the 33ms window anyway. It only ever kicks in when
    frames are arriving faster than a human eye needs from a live preview.
  - One accepted trade-off: the GPU-native mono live-stack accumulator (`MetalFrameRenderer
    .accumulationTexture`) only accumulates on `frameID` ticks, so at extreme frame rates it now
    folds in at most ~30 frames/sec of a ROI that might be capturing 100-200+/sec, rather than
    every one. The CPU `LiveStacker` path (webcam/iPhone, or GPU renderer off) is unaffected — it
    accumulates every real frame regardless, per the fix above. Small-ROI-plus-Live-Stack is a
    narrow combination in practice (that ROI size is normally a planetary/lucky-imaging workflow,
    not deep-sky stacking), and "smooth, responsive live view" was judged the more important
    property to guarantee than "every physically-captured frame counted toward the GPU stack" for
    that narrow overlap.
- **Split the sidebar's `.advanced` tab back into `.planetary`/`.deepSky`** — reported as hard to
  navigate once both genres' workflow tools (Planetary Auto-Center/Lucky Imaging alongside Live
  Stack/Calibration/Polar Alignment/ST4 Guiding/Smart Exposure/Record to Disk) lived in one long
  scrolling list. See `SidebarTab`'s doc comment for the full reasoning, including why
  `.cameraControls`/`.improvements` stayed role-grouped rather than also splitting by genre, and
  why Focus Assist appears in both new tabs instead of forcing a choice of one over the other.
  `SkyformacCommands`' menu-bar tab shortcuts grew a fourth (⌘4); the "Disable All" checkbox split
  into `allPlanetaryDisabled`/`allDeepSkyDisabled` along the same lines, each covering only the
  toggles actually relevant to its own tab (both still include Focus Assist).
- **Added the Acquisition Wizard**: pick a target (a `PlanetaryPreset` or a new small curated
  `DeepSkyObject` list — M13/M56/M31/M42/M45, the same "curated presets, not the full `SkyCatalog`
  database" scoping `PlanetaryPreset` already uses for the solar-system side), see/edit its
  recommended `AcquisitionPreset` (mode, ROI, gain, exposure, Reduce Drift/Smart Live Stack), and
  apply it in one step (`CameraManager.applyAcquisitionPreset`). Presets round-trip to/from their
  own JSON file (`saveAcquisitionPreset`/`loadAcquisitionPreset`, one file per preset, via the
  same save/open-panel shape `exportCurrentFrame`/`openExportedFile` already use).
  - `AcquisitionTarget.recommendedMode`/`recommendedPreset(name:)` are pure functions of the
    target alone (`AcquisitionTargetTests`) — no camera, no GPU, so the actual "what's the right
    starting setup for this object" logic is fully unit-tested without hardware.
  - The Moon is the deliberate example of `.both` (Live Stack *and* Lucky Imaging at once) — Lucky
    Imaging for high-resolution crater/terminator detail, Live Stack for a lower-noise full-disk
    or earthshine shot; both are genuinely useful lunar techniques, not an arbitrary default.
    Every other planetary target stays Lucky-Imaging-only; every deep-sky object stays
    Live-Stack-only (with Reduce Drift defaulted on, since deep-sky integration runs long enough
    for mount tracking error to accumulate into real trailing — a planetary burst is over in
    seconds, so drift barely matters there).
  - **Deliberately does not auto-start a Lucky Imaging burst or SER recording.** Framing/focus
    should be confirmed against the *actual* target first — auto-firing a burst at whatever
    happened to be in frame when the wizard's Apply button was pressed would often just waste it
    on an unfocused or unframed capture. `luckyBurstCount`/`serDurationSeconds` are surfaced as
    recommendations for those still-manual steps, not applied automatically.
  - This is a *setup* step, not a new capture technique — every feature it configures (Live Stack,
    Reduce Drift, Smart Live Stack, Capture ROI, Lucky Imaging's burst count) already exists and
    is documented on its own terms elsewhere; the wizard's entire job is picking sensible starting
    values for them per target, the same "starting point, not a promise" philosophy
    `PlanetaryPreset` already uses.
- **GPU-reliance re-audit, requested after the Acquisition Wizard landed.** Every feature added
  this session that touches per-pixel data already runs on the GPU: Smart Live Stack's quality
  gate (`GPUSharpnessScorer`, the same instance Record to Disk's gate already uses), and all three
  Reduce Drift fixes (`roiStatsPartial`/`centroidPartial`/`findBrightestPartial`, all real Metal
  kernels). Nothing added this session does per-pixel work on the CPU that GPU could instead
  accelerate. The Acquisition Wizard itself, the Capture ROI center/position fix, Gain/Offset
  Presets, the dropped-frame counter, ST4 Guiding, the sidebar tab split, and the live-view
  refresh throttle are all configuration/orchestration/UI — none of them touch pixel data at all,
  so there's no GPU work to move there; correctly CPU-only, not a gap.
- **Save/Load Preset made standalone, not gated behind opening the Wizard sheet at all.** The
  Wizard's own use case is "pick a target, get its recommendation" — but a returning user with a
  setup they already like has no target to pick; they just want today's dialed-in settings saved,
  or a known-good file reloaded, in one action. `CameraManager.currentAcquisitionPreset(name:)`
  builds an `AcquisitionPreset` from *whatever's actually configured right now* (reads gain/
  exposure straight from `controlValues`, not a target's table) rather than a target's
  recommendation — `targetID` is left empty on purpose, matching nothing `AcquisitionTarget
  .resolve(id:)` can find, since there's no single target this snapshot is "for." Its mode comes
  from `AcquisitionMode.current(isLiveStackingEnabled:hasLuckyImagingSession:)`, a pure function
  (`AcquisitionTargetTests`) factored out of the live-state reading around it for the same "keep
  the actual decision testable, not just the plumbing that feeds it" reason `SmartLiveStackGate
  .decide`/`DriftAligner`'s functions already are. `saveCurrentSetupAsPreset`/
  `loadAndApplyAcquisitionPreset` wrap this and the existing save/load panels into one call each,
  surfaced in two places besides the Wizard sheet itself: the **Camera** menu (⌘⇧S/⌘⇧L), and a new
  "Acquisition" section in the left camera-list sidebar, directly under the connected camera —
  deliberately not tucked into the right-hand Controls panel, since these three actions work
  regardless of which Controls tab happens to be showing, and belong with the camera itself
  instead of any one tab's tools.
  - `luckyBurstCount`/`serDurationSeconds` come back `nil` from a "current settings" snapshot —
    both live as `@AppStorage` inside `ControlsPanelView`, not `CameraManager`, so there's nothing
    for this snapshot to read; loading such a preset back still restores everything this class
    itself actually tracks, just without a burst-count/SER-duration recommendation riding along.
- **Regression: small Capture ROI still slowed down/flickered after the earlier display-refresh
  throttle, and selecting a Planetary Preset made it worse — traced to the diagnostics poll added
  the same session, not the throttle itself.** `CameraManager.startDiagnosticsPolling`'s `Task { ...
  }` was a plain (non-`.detached`) task created from a `@MainActor`-isolated method — per Swift's
  isolation-inheritance rules, its *entire body*, including the blocking `ZWOSDK.getControlValue`/
  `getDroppedFrames` calls inside it, ran on `@MainActor`, every 2 seconds, for as long as a camera
  stayed connected. Live streaming's own `pollLoop` (`CaptureEngine`, an actor) is continuously
  calling `ASIGetVideoData` for that same camera ID on its own background queue the whole time —
  a second, concurrent blocking SDK call for the same camera arriving from the main thread every 2
  seconds could contend with it at the USB/firmware level, and since it ran directly on
  `@MainActor`, any such contention *was* a main-thread stall, not just a dropped frame somewhere.
  Worse at a small ROI's higher real frame rate for the same reason the original flicker bug was:
  more frames pile up during any given stall the faster they're arriving. Selecting a Planetary
  Preset doesn't touch this poll at all — it "regressed" because a small ROI (which every
  Planetary Preset sets) is exactly the condition that makes the poll's periodic stall visible.
  **Fix**: `CaptureEngine.refreshDiagnostics()` — the actor-isolated equivalent, added instead of
  ever putting these two calls back on `@MainActor` at all — matching the "Strict Threading" rule
  every *other* blocking `ZWOSDK` call in this codebase already follows. `startDiagnosticsPolling`
  now `await`s it, so the calls queue behind whatever `pollLoop` is doing on the actor's own
  background execution context instead of the main thread, and never race the video poll for the
  SDK itself since both now funnel through the same serializing actor. `refreshGainOffsetPresets`
  (the *other* direct-`ZWOSDK`-from-`@MainActor` call added the same session) stays as it was —
  safe specifically because it's one-time, called before `startPreview` starts the video poll at
  all, not a repeating loop racing an active one; its doc comment now points at this entry as the
  cautionary counter-example for why that distinction matters.
- **The sidebar's vertical tab strip was only shown once a camera was connected at all** —
  reported as "the sidebar doesn't have the two new [Planetary/Deep Sky] tabs," tried without a
  camera connected. Every tab's own content already handled "no camera connected" gracefully (a
  plain message, per tab) — hiding the *strip itself* until then just made every tab besides
  whichever one happened to be last selected undiscoverable with nothing connected yet. Fixed by
  always showing the strip; each tab's existing disconnected-state message still applies inside it.
- **Added "Reset to Default" next to the camera** (`CameraManager.resetToDefaultConfiguration`) —
  full sensor ROI, a safe starting gain (`5`, matching `connect(to:)`'s own reasoning for why that
  beats the camera's own bright-test-condition-tuned default), and every capture-affecting toggle
  this session's "Disable All" checkboxes already know about (Live Stack/Smart Live Stack/Reduce
  Drift, Lucky Imaging, Dark/Flat correction, Focus Assist, Planetary tracking/crop, Image
  Enhancement, the AI Suite) plus any active recording, all back off in one action — undoing a
  Wizard preset or any manual adjustment without needing to hunt down each toggle individually.
- **Wizard/Load Preset also placed directly beside Disconnect in each camera row**, not only in
  the fuller "Acquisition" section below the list — the two most-reached-for actions (open the
  Wizard, load an already-saved setup) live right where a user would naturally look for them,
  next to the button that just confirmed which camera they're working with.
- **Enlarged the Acquisition Wizard sheet** — reported as too small, with the recommended-setup
  fields effectively invisible. `minWidth: 640, minHeight: 460` wasn't enough room for the target
  list (two sections, several rows, each with a secondary caption line) plus the preset editor's
  own field grid at once; now `minWidth: 900`/`minHeight: 640`, opening at `idealWidth: 1100`/
  `idealHeight: 760` by default rather than at the bare minimum.
- **Two small dead-code cleanups, found by an audit for "other incomplete implementations":**
  - `CameraManager.clearDarkFrame`/`clearFlatFrame` existed (bulk-remove-all-and-disable) but had
    no UI call site — the Calibration section only ever wired per-frame removal. Wired up as a
    "Clear All" button next to each list's own enable toggle in `calibrationSubsection`, rather
    than deleting them — a real, useful action a per-frame trash icon doesn't replace.
  - `ZWOSDK.getStartPos` (the read half of `ASISetStartPos`/`ASIGetStartPos`) had no call site
    either — the app only ever *wrote* a ROI's position, never confirmed what the camera actually
    applied. Added `CaptureEngine.currentStartPosition()` and `CameraManager
    .captureROIAppliedStartX/Y`, read back right after every `changeCaptureROI` call and shown in
    the Capture ROI section as an explicit confirmation (or a flagged mismatch, if the camera
    clamped the request somewhere the app didn't expect) — the same "verify the fix actually took
    effect" spirit that found the original always-top-left-corner `ASISetStartPos` bug in the
    first place, now a standing check rather than a one-time investigation.
- **Acquisition Wizard now works for a webcam/iPhone source, not just ZWO.** The only thing
  actually blocking it was `applyAcquisitionPreset`/`resetToDefaultConfiguration`'s own guard
  (`camera.cameraID >= 0`) — everything the ROI/gain/exposure calls touch (`captureEngine`,
  `controls`) is already empty/`nil` for a webcam source, so they were already no-ops in practice;
  the guard was blocking the parts that *do* work there too (Live Stack/Lucky Imaging/Smart Live
  Stack, all already RGB24-capable from earlier fixes this session). Relaxed to `connectedCamera
  != nil`, with the ROI/gain/exposure block itself now conditioned on `camera.cameraID >= 0`
  internally. Reduce Drift is the one setting that still gets *set* but does nothing visible on
  that source (the GPU accumulator it needs is mono-only) — `AcquisitionWizardView` says so
  explicitly now rather than blocking Apply outright or silently implying it works.
- **Added 5 more curated deep-sky objects to the Wizard** (M51, M57, M27, M81, M8 — alongside the
  original M13/M56/M31/M42/M45), each with its own starting gain/exposure and a summary explaining
  *why* that starting point (surface brightness, dynamic range, angular size) — same "curated
  presets with real reasoning, not an exhaustive catalog dump" scoping the original five and
  `PlanetaryPreset` both already use.
- **The Wizard's target list was competing for space evenly with the editor pane** — now sized to
  roughly a 1:4 ratio (`idealWidth: 220` vs `880`, the list capped at `maxWidth: 320` so dragging
  it wider doesn't crowd out the editor) — it's a picker, not the main content, and shouldn't read
  as though it were.
- **Dragging the main window's left (Cameras) sidebar wider could push the whole window off-screen
  — `NavigationSplitView`'s sidebar column had no `max` width.** The "detail" side (the nested
  `HSplitView` holding `PreviewView`/`ControlsPanelView`) has its own real minimum width (480 +
  320 = 800pt combined); once the sidebar's requested width left less than that available,
  `NavigationSplitView` had only one way to satisfy both — grow the window itself, which could
  push it partly off a smaller display. Capped at `max: 280` so this column now always resizes
  within the existing window, the same way dragging the divider between `PreviewView`/
  `ControlsPanelView` already does (a plain `HSplitView`, which never grows the window either).
- **Wizard/Load Preset icon buttons added to the webcam/iPhone row too** — the backend
  (`applyAcquisitionPreset`/`resetToDefaultConfiguration`) and the fuller "Acquisition" section
  already worked for that source (see the entry above), but the same quick-access pair next to
  the *row's own* Connect/Disconnect only existed on the ZWO `cameraRow`, not `webcamSection`'s.
  Added there too, for parity — there was never a reason these should only be reachable one row
  down for a webcam source when everything they do already applies to it identically.
- **The app hung when the Moon's Acquisition Wizard preset was applied and a burst was started.**
  Root cause: `GPUSharpnessScorer` (Smart Live Stack's per-frame quality gate, and Record to
  Disk's) had no resolution cap at all — unlike `SharpnessScorer` (the CPU sibling Lucky Imaging's
  own ranking uses), which already downsamples to a `maxDimension` of 512 before scoring, for
  exactly this reason. The Moon is the one Acquisition Wizard target combining a full-sensor ROI
  (`PlanetaryPreset.moon.roi == nil` — deliberate, Moon detail work wants the whole frame) *with*
  Smart Live Stack turned on by default (the only planetary preset that does — every other planet
  is Lucky-Imaging-only, so `isSmartLiveStackEnabled` stays off for them). At a real camera's
  planetary-preset frame rate, that meant a full-native-resolution GPU Laplacian dispatch, texture
  upload, and CPU-side partial-sum reduction, all synchronously blocked on (`waitUntilCompleted`)
  — on `@MainActor`, since `CameraManager.updateSmartLiveStackGate` calls this directly — on every
  single incoming frame. Once frames arrived faster than that could complete, `@MainActor` fell
  further behind indefinitely (the same unbounded-`AsyncStream`-backlog mechanism the earlier
  small-ROI flicker bug was), which is what "hangs" actually looked like once a burst pushed the
  frame rate up further.
  - **Fix**: `sharpnessPartialSums` (`Shaders.metal`) now takes a `sampleStride` and samples a
    strided grid instead of every raw pixel; `GPUSharpnessScorer.score` computes
    `stride = max(1, max(width, height) / 512)` (same formula, same limit, as `SharpnessScorer`'s
    own `downsample`) and dispatches/reduces over the shrunken grid instead of the full one. Any
    frame at or under 512px on its longer edge (every real planetary ROI) gets `stride == 1` —
    unchanged behavior; only a full-sensor-sized frame is actually affected.
  - **Found via this fix, not before it**: nearest-neighbor stride sampling has a
    real aliasing edge case — a periodic test pattern whose period exactly matches the stride
    samples the *same phase* at every neighbor, making the Laplacian read as exactly zero
    regardless of how sharp the underlying content actually is. `GPUSharpnessScorerTests`'s own
    large-frame test hit this immediately with the existing period-2 `checkerboard` helper at
    `stride == 2`; needed a coarser `blockCheckerboard` (block size comfortably larger than the
    stride) to actually exercise the downsampled path correctly. This isn't a new weakness this
    fix introduced — `SharpnessScorer.downsample` uses the identical nearest-neighbor stride
    approach and has the exact same theoretical vulnerability, just never triggered by a
    checkerboard that fine at a size actually large enough to downsample. Real sensor data (star
    fields, planetary disks) doesn't have this kind of exact periodic structure, so it's a
    theoretical caveat worth knowing about, not a practical risk either scorer actually runs into.
- **Per-channel (Red/Green/Blue) histograms**, added alongside the existing combined-luma one.
  `HistogramView` gets a "By Channel" checkbox (only shown when a channel breakdown is actually
  available — i.e. never for a mono camera) that swaps the single bar chart for three overlaid
  translucent curves; the Black/White Point sliders below are unaffected either way, since the
  stretch itself is still one combined operation regardless of which view is showing.
  - **CPU path**: `HistogramComputer.channelHistograms(for:isColorCamera:bayerPattern:)`. For
    RAW8/RAW16 (a color camera's still-mosaiced Bayer data — the same pre-debayer domain the
    combined histogram already operates in) each raw sample is classified by which channel it
    directly measures via `Debayer.channel(atX:y:pattern:)` (made `internal`, was `private` —
    reused here rather than duplicating Bayer-pattern logic a third time) rather than debayering
    first, so it's a real per-photosite histogram, not an interpolated one. RGB24 bins the three
    packed bytes per pixel directly. Returns `nil` for a mono camera, and also for any image type
    other than RAW8/RAW16/RGB24 — the guard checks the *image type* explicitly rather than just
    `isColorCamera`, since a color camera can still be requesting an unrelated single-channel
    exposure format, and returning three all-zero channel arrays for one (a real, distinct bug
    caught by `HistogramComputerTests` while writing it, not a hypothetical) would have looked to
    `HistogramView` like a legitimately empty (but present) breakdown rather than "not available."
  - **GPU path**: two new `Shaders.metal` kernels mirroring the existing luma ones —
    `histogramReduceBayerChannels` (mono texture from a color ZWO camera, reusing the same
    `isRedAt`/`isBlueAt` inline classifiers `debayerAndStretch` already uses) and
    `histogramReduceRGB24Channels` (packed RGB24/webcam bytes, no Bayer classification needed).
    `MetalFrameRenderer` dispatches both right after its existing luma histogram dispatch (gated on
    `onChannelHistogramUpdate != nil` so the extra GPU work only happens while `HistogramView` is
    actually asking for it), reads back three 256-bucket device buffers via
    `addCompletedHandler`, and surfaces them through `CameraManager.gpuChannelHistogramCounts` —
    the same wiring shape as the existing `gpuHistogramCounts`.
- **"Independent Channels" stretch mode and a "Curves" tab**, both building directly on top of
  the per-channel histogram work above — the user's own framing was "is it possible to fine-tune
  the histogram by color?", answered here in full: independent black/white points *and* a
  Photoshop-style curve editor, not just the read-only by-channel view added earlier.
  - **`PerChannelStretch`** (`DisplayStretch.swift`) is three independent `DisplayStretch`es.
    `CameraManager.effectiveChannelStretch` is what every render path actually reads — either
    `channelStretch` verbatim (independent mode on) or `PerChannelStretch(uniform: stretch)` (off,
    all three channels sharing the one combined pair) — so `MetalFrameRenderer`/`CGImageRenderer`
    never need their own branch for the toggle; it's baked into which `PerChannelStretch` they're
    handed. `HistogramView`'s existing "By Channel" toggle now also flips
    `isIndependentChannelStretchEnabled` in lockstep, swapping the one combined Black/White Point
    slider pair for three independent ones — seeing the per-channel histograms is exactly when
    per-channel stretch editing is useful, so one toggle drives both.
  - **GPU**: `Shaders.metal` gained `ChannelStretchParams` (three black/white pairs + one shared
    `divisor` — `divisor` stays scalar since it's "how many live-stacked frames were summed," not
    a per-channel quantity) and `applyStretchBW`, the single-pair `applyStretch` now delegating to
    it. `debayerAndStretch`/`stretchRGB24` take `ChannelStretchParams` instead of the old
    single-pair `StretchParams`; `stretchMono` is untouched (a mono frame has no channels to be
    independent between).
  - **CPU**: `CGImageRenderer.makeDisplayImage` gained optional `channelStretch`/`toneCurves`
    parameters (default `nil` — every export/analysis call site keeps exactly its old behavior
    unchanged). Only `CameraManager.renderedCurrentImage`/`scheduleCPUEnhancementIfNeeded`'s
    render (the CPU live-preview path, which also backs PNG/TIFF export and polar alignment's star
    detection via `currentDisplayImage()`/`imageForExport()`) passes them — deliberately not the
    four other `CGImageRenderer`/`GPUStillImageRenderer` call sites in focus-assist/streak-
    detection/planet-tracking, which render their own internal Vision-analysis image and should see
    the base combined stretch only, unaffected by what's essentially cosmetic display grading.
  - **`ToneCurve`** (`ToneCurve.swift`) is a small set of user-placed control points sampled into
    a 256-entry lookup table via a **monotonic** cubic Hermite spline (Fritsch-Carlson) — not a
    plain natural spline, which can overshoot between widely-spaced hand-placed points and locally
    *reverse* brightness order (a visible banding artifact with only 2-4 points, the realistic case
    for a hand-tuned curve). `ChannelToneCurves` layers a master "RGB" curve (applied to all three
    channels identically) with independent Red/Green/Blue curves on top of it — `effectiveRedLUT`
    etc. compose the two LUTs (`firstLUT.map { secondLUT[Int($0)] }`), the same "apply master, then
    per-channel" convention most curve-grading tools use.
  - **Applying the curve**: rather than weaving it into `debayerAndStretch`/`stretchRGB24`
    (per-channel-stretch's approach), curves apply as one *additional*, final GPU stage
    (`applyToneCurveRGBA`) directly on `outputTexture` regardless of source path (mono, RAW8/16
    color, or RGB24) — simpler, and correct, since by the time `outputTexture` holds real RGBA
    values, per-channel grading no longer needs to know anything about Bayer patterns or source
    format. It takes a single `access::read_write` texture argument, mirroring `arcsinhStretch`
    right above it in `Shaders.metal` — safe because each thread only ever reads and writes its
    own texel (no neighbor sampling, unlike a blur/denoise kernel, where aliasing source and
    destination really would be a data race). Gated on `toneCurves != nil` (skips the dispatch
    entirely when the "Curves" tab's "Enable" checkbox is off) via the same
    `applyToneCurveIfNeeded` helper called from both `process` and `processRGB24`, right after the
    existing `applyArcsinhStretchIfNeeded` call and before `encoder.endEncoding()`. The CPU path
    mirrors this as `CGImageRenderer.channelLUTs`, composing each channel's stretch LUT with its
    tone-curve LUT the same way.
  - **`CurvesView.swift`** is the new tab itself: a segmented Channel picker (RGB/Red/Green/Blue),
    a `Canvas`-drawn curve (identity diagonal + light grid behind it) with draggable control-point
    circles (`DragGesture(minimumDistance: 0)`, hit-tested by index rather than position so a point
    dragged near another doesn't confuse itself with its neighbor), and Add/Remove/Reset buttons.
    Removing a point is disabled below 2 remaining points — `ToneCurve.lookupTable()` falls back to
    a plain identity LUT for a degenerate (<2-point) curve rather than dividing by zero, but the UI
    never actually lets that state happen via its own controls.
- **Histogram/Curves tab sizing, twice** — first pass gave the tab area a hardcoded
  `.frame(height:)`, which either wasted visible space below shorter content (the plain combined
  histogram) or clipped taller content ("By Channel" mode's extra sliders) depending on which tab
  was open — a fixed number can't fit both. Fixed by giving the live preview `.layoutPriority(1)`
  instead: it claims any extra vertical space first, so the tab area only ever gets exactly what
  its currently-selected tab's content actually needs (with `HistogramView`'s own `ScrollView` as
  the fallback for the one case that's still taller than a reasonable `maxHeight` cap, "By
  Channel" mode's 6 sliders).
- **Histogram/Curves panel, detachable.** `HistogramCurvesPanelController` is a plain `NSPanel`
  (`.utilityWindow`, `.nonactivatingPanel`) the app opens/closes itself from a "Detach" button next
  to the tabs — deliberately not a second SwiftUI `Window` scene, since `SkyformacApp`'s doc
  comment is explicit that this app is single-`Scene` (no second Window-menu entry, no
  window-tabbing surface); a panel the app manages itself doesn't add a scene at all, so that
  constraint holds regardless of whether one happens to be open. Its content is a thin wrapper
  view (`DetachedHistogramCurvesView`) that reads `cameraManager.useMetalRenderer` fresh inside its
  own `body` rather than being handed a static value once — the same pattern `ContentView` already
  uses, needed here too since `NSHostingView`'s `rootView` doesn't re-evaluate on its own unless
  something inside it actually re-reads the `@Observable` state. Closing the panel (its own close
  button, or `ContentView`'s "Dock" button once detached) re-docks the tabs inline via an
  `onClose` callback — `ContentView`'s `.onChange(of: isHistogramPanelDetached)` owns the actual
  create/destroy of the controller either direction.
- **"Experimental" mesh-based drift correction** — an alternative to the existing single-star-lock
  drift reduction (`DriftAligner`/`MetalFrameRenderer.computeDriftShift`), which tracks exactly one
  star and applies one rigid `(dx, dy)` shift to the whole frame, so it can't correct for field
  rotation or differential drift across a wide field (alt-az mounts without a rotator, imperfect
  polar alignment, mirror flop). This tracks an NxN grid of points instead, each drifting
  independently, blended with bilinear interpolation — the same "vertex skinning" technique used to
  blend bone transforms smoothly across a mesh in real-time rendering/games — into a smooth,
  spatially-varying correction instead of one global shift.
  - **`MeshDriftField`** (`Rendering/MeshDriftField.swift`) is the pure model: `vertexPositions`
    (cell centers), `roiHalfSize` (search-window size from `overlap`), `interpolatedDisplacement`
    (the bilinear blend, Swift-side twin of `Shaders.metal`'s `meshInterpolatedDisplacement`),
    `blend` (single-pole exponential smoothing by `sensitivity`), and `measuredCentroids` (the
    actual per-vertex measurement).
  - **Measurement is deliberately CPU-side, not `gridSize * gridSize` GPU round trips.** The
    existing single-star lock already does 1-2 synchronous GPU round trips
    (`commandBuffer.waitUntilCompleted()`) per frame for its own two-pass background-subtracted
    centroid (`computeCentroid`) — replicating that per mesh vertex (up to 64 for an 8x8 grid)
    would multiply that per-frame blocking cost by up to 64x, risking reintroducing exactly the
    kind of unbounded-cost hang the `GPUSharpnessScorer` fix (see above) exists to prevent.
    Instead, `measuredCentroids` operates on an already-downsampled luminance grid
    (`SharpnessScorer.luminanceGrid`, made `internal` for this reuse — its existing ≤512px-longer-
    edge cap is the same bounded-cost trick, reused rather than re-derived), computing a simple
    single-pass weighted centroid (weight by how far a sample is above its own ROI's mean) per
    vertex from that one shared downsample — one CPU pass over a bounded-size grid, regardless of
    mesh size or the camera's real resolution.
  - **Session state lives on `MetalFrameRenderer`** (`meshReferenceCentroids`/
    `meshSmoothedDisplacements`), mirroring where `driftReferenceCentroid`/`driftTrackedCentroid`
    already live — the GPU live-stack accumulator is already entirely self-contained there, and
    this fits the same shape: `computeMeshDisplacements` measures, updates each vertex's reference
    (fixed on its first successful measurement) and smoothed displacement (blended via
    `MeshDriftField.blend`, holding its last value through a frame where that vertex's window has
    no clear signal, the same "hold through a brief loss" reasoning the single-star lock's local-
    search fallback already uses), and returns the grid ready to upload. Reset alongside the rest
    of the live-stack session in `resetLiveStack()`.
  - **Applying it**: `Shaders.metal`'s `accumulateMonoMeshAligned` mirrors `accumulateMonoAligned`
    (the single-shift kernel) almost exactly — same `access::sample` + `filter::linear` sampler for
    the actual sub-pixel bilinear texture read, just with a per-pixel `shift` computed by
    `meshInterpolatedDisplacement` instead of one constant value. `MetalFrameRenderer.process`
    picks mesh correction over the single-star lock when both would otherwise apply (two
    alternative techniques for the same job, not a combinable pair) — see the `isDriftReductionEnabled`
    block's `else if let meshDriftConfig` branch.
  - **UI**: `ControlsPanelView`'s new "Experimental" section (Mesh Size/Vector Overlap/Drift
    Sensitivity sliders, an orange "Experimental" capsule tag) plus `MeshDriftOverlayView` — a
    `Canvas` overlay on the live preview drawing each vertex's actual search-window rectangle and
    a displacement arrow (exaggerated 8x for visibility — real sub-pixel/few-pixel drift would
    otherwise be an invisible sliver at typical preview zoom), so "Vector Overlap" is something
    you can actually *see* change, not just a number.
- **Mesh drift correction, round 2: triangulated interpolation, and the actual cause of the UI
  stutter this feature was reported to cause.**
  - **Triangles, not bilinear quads.** The original version blended each pixel's displacement
    from the bilinear weighting of its cell's 4 corner vertices. Bilinear is a real, valid
    interpolation scheme, but it's not the primitive real-time rendering/games actually use for
    mesh deformation — a GPU has no native "quad," every rasterized surface (including a
    deformed mesh) is triangles under the hood, and unlike bilinear (a smooth but not-quite-flat
    blend across the whole cell), barycentric interpolation across a triangle is exactly affine —
    a single flat plane fit through its 3 corner values. Switched `MeshDriftField
    .interpolatedDisplacement` (Swift) and `Shaders.metal`'s `meshInterpolatedDisplacement` (GPU)
    to split each quad cell into 2 triangles along the `v10`-`v01` diagonal and blend
    barycentrically within whichever triangle a pixel falls in; both triangles' formulas agree
    exactly along their shared diagonal (verified in `MeshDriftFieldTests
    .interpolatedDisplacementIsContinuousAcrossTheTriangleDiagonal`), so no seam is introduced by
    the split. `MeshDriftOverlayView` now draws the actual wireframe (horizontal/vertical mesh
    edges *and* each cell's diagonal) instead of just the per-vertex ROI rectangles, so what's
    on-screen matches what's actually being interpolated across.
    - Worth being explicit about: this is *not* a 3D reconstruction of anything, despite the
      resemblance to a face-tracking mesh (e.g. ARKit/MediaPipe's hundreds of triangulated
      landmark points) that motivated asking for it. A face mesh triangulates because it's
      fitting a real 3D surface with actual depth/curvature, recovered from a depth sensor or a
      trained shape model. There's no depth or parallax information to recover here at all — a
      camera pointed at the night sky sees every star as effectively infinitely distant, a flat
      2D field, not a 3D surface. The mesh in this feature is a 2D image-plane deformation field
      for motion compensation; triangles are used because they're the correct, standard,
      unambiguous primitive for *that* — not because there's 3D shape being fitted.
  - **The actual root cause of the reported UI stutter**: `computeMeshDisplacements` was calling
    `SharpnessScorer.luminanceGrid`, which — for a color camera — runs a full interpolating
    debayer (`Debayer.debayerRAW8`/`debayerRAW16`) over the *entire native-resolution* frame
    *before* its own bounded downsample. That's the right tradeoff for `SharpnessScorer`'s actual
    use (Lucky Imaging burst ranking needs a perceptually accurate sharpness metric, and runs on
    a bounded/paused burst, not continuously) — but calling it every single live-stack frame,
    continuously, for as long as mesh drift correction is on, meant a full-resolution CPU
    demosaic every frame regardless of the downstream downsample. That was real, unbounded
    (scales with native sensor resolution) CPU cost sitting directly in the per-frame path,
    independent of the GPU accumulate step (which really was cheap) — "GPU is used" was true of
    the *accumulate* stage, just not the *measurement* stage feeding it. Exactly the same shape of
    mistake the `GPUSharpnessScorer` hang fix (see above) exists to prevent, just on the CPU side
    of a different feature this time.
    - **Fix**: `MeshDriftField.cheapLuminanceGrid` — strides directly over the raw sensor bytes
      (RAW8/RAW16, no debayer at all) at the same bounded stride `SharpnessScorer`'s own
      `downsample` uses, `nil` for RGB24 (mesh drift never runs for a webcam/iPhone source
      anyway — the GPU accumulator is mono-only). Mesh-drift measurement doesn't need
      perceptually accurate demosaiced luminance in the first place, just an approximate
      brightness map to locate bright stars — a real star saturates every Bayer channel
      similarly, so a raw single-channel sample is a perfectly good brightness proxy for that.
      `computeMeshDisplacements` now calls this instead, and no longer needs `isColorCamera`/
      `bayerPattern` at all.
- **Histogram tab's dead space, actual root cause**: wrapping `HistogramView`'s whole `body` in a
  `ScrollView` (to handle "By Channel" mode's 6 sliders without clipping) made the *combined*
  mode's much shorter content request all the space its parent offered instead of reporting its
  own real height upward — a `ScrollView` is inherently a "fill what I'm given" container, not a
  "size to my content" one. `.layoutPriority(1)`/`.frame(maxHeight: .infinity)` on the surrounding
  columns (an earlier pass at this) couldn't fix that, because the thing lying about its own size
  was inside those columns, not their sizing logic. Fixed by only wrapping the taller "By
  Channel" case in a `ScrollView`; the normal combined-histogram case renders as a plain `VStack`
  that reports its actual content height, so the tab (and the preview above it) size correctly.
- **Mesh drift correction and the Acquisition Wizard.** `AcquisitionPreset` gained
  `isMeshDriftCorrectionEnabled: Bool?` — `Optional`, not a plain `Bool`, specifically so a preset
  file saved before this field existed still decodes via `decodeIfPresent`'s automatic `nil` for
  a missing key, rather than every previously-saved preset breaking the moment this field was
  added (`AcquisitionTargetTests.presetMissingMeshDriftCorrectionKeyStillDecodes` is the
  regression test for that). `recommendedPreset()` never sets it `true` for either target genre —
  worth trying deliberately for a long, multi-minute-plus deep-sky integration (where field
  rotation/differential drift a single global shift can't correct becomes real), not something a
  "recommended starting point" preset should silently turn on. It's still exposed as an editable
  row in the Wizard editor (with the same orange "Experimental" tag `ControlsPanelView`'s own
  toggle uses) for any target the preset turns Live Stack on for.
- **"Running" status list, next to the camera.** A pipeline (Live Stack, Lucky Imaging, Recording
  to Disk, SER recording, Planetary Tracking, Polar Alignment, Cloud Sentinel, Focus Assist) left
  on from a previous session — or just easy to forget about once its tab isn't the one currently
  showing in the right-hand Controls panel — was otherwise invisible until you happened to click
  over to check. `ActivePipelinesView.swift` surfaces every one that's currently active as its own
  row directly in `CameraListView` (right next to the camera, the same "lives where the camera
  itself is, not tucked into one tab" reasoning `acquisitionSection`'s own doc comment already
  uses), each with a "Focus Control" button (jumps `@AppStorage("sidebarTab")` to that pipeline's
  own tab) and a one-click "Stop" button calling that exact pipeline's existing stop
  method/toggle. `CameraManager.activePipelineStatuses` (an extension in the same file, since it
  needs `SidebarTab`, a Views-layer type) is the actual list-building logic — a pipeline's own
  *modifiers* (Smart Live Stack/Reduce Drift/Mesh Drift Correction are all specifically Live
  Stack's settings, not independent pipelines) fold into that pipeline's one-line detail string
  rather than getting their own row, so "Running" stays a list of actual processes, not every
  toggle that happens to be on. Lucky Imaging's row keeps showing after a burst *finishes*
  filling — `luckyImagingSession` stays alive (ready for `stackLuckyImagingBest`, possibly more
  than once with different fractions) until explicitly discarded — with its detail text saying
  "ready to stack" rather than implying a capture is still running.
- **Exposure countdown.** `captureSingleExposure`/`captureDarkFrame`/`captureFlatFrame` all set
  `CameraManager.capturingExposureStartDate`/`capturingExposureDurationSeconds` right alongside
  the existing `isCapturingExposure`, and clear all three together in the same `defer` block each
  already had. `ControlsPanelView`'s new `ExposureCountdownView` reads them via
  `TimelineView(.periodic(from: start, by: 0.1))` (redraws on its own schedule, no `Timer`/
  `@State` tick counter needed) and shows `max(0, duration - elapsed)` next to whichever Capture
  button is running — previously just an indeterminate `ProgressView` spinner, which gave no
  sense of how much longer a multi-second-or-longer exposure had left.
- **Night mode no longer tints the live image itself.** Previously one blanket `.colorMultiply`
  wrapped the *entire* window content (`ContentView.mainContent`/`fullScreenPreview`), including
  the actual live video — defeating the whole point of looking at it (true star colors, a
  correctly white-balanced RGB24 frame all read as pure red instead). Fixed by removing that one
  blanket modifier and applying `.colorMultiply` individually to everything *except* `PreviewView`:
  the sidebar, Controls panel, and Histogram/Curves tabs from `ContentView`, plus `PreviewView`'s
  *own* overlay chrome (zoom badge, corner controls, zoom bar — via its own `nightTint` property)
  from inside `PreviewView` itself, so those still get the dark-adaptation tint while the image
  underneath them doesn't. `MeshDriftOverlayView`/`AllSkyMonitorView` are likewise left untinted,
  for the same "it's image content, not chrome" reasoning.
- **A real recorded `.ser` file failed to load in Siril's stacking normalization** ("MAD is null.
  Statistics cannot be computed." on many scattered frames throughout an otherwise cleanly-loaded
  566-frame sequence). The container format itself was fine — Siril parsed the frame count and
  dimensions correctly, so this wasn't a header/offset bug. The actual cause: some individual
  *frames* were genuinely flat (every pixel byte identical) — a real captured frame, even a badly
  blurred one, always has some pixel-to-pixel variance from photon shot noise alone, so a
  perfectly flat one is degenerate for some other upstream reason (a Vision auto-crop ROI
  momentarily tracking blank sky with nothing bright in it, or a transient sensor read glitch) —
  and Siril's MAD-based per-frame normalization has no tolerance for one at all.
  - **Fix**: `SERWriter.write` now scans each frame's raw bytes for any variance at all
    (`hasVariance`, early-exiting on the first differing byte — negligible cost for any real
    frame) and throws a new `SERError.blankFrame` instead of writing one that has none.
    `CameraManager.recordSERFrameIfNeeded` catches that specific case separately from every other
    `SERWriter` error — it increments a new `serSkippedFrameCount` (shown next to the recording
    progress) and keeps recording, rather than treating it as the fatal error every *other*
    `SERError` case still is. The result: every frame that actually makes it into a `.ser` file
    is now guaranteed to have real per-frame statistics, so this exact failure can't recur
    regardless of what upstream condition produced the blank frame in the first place.
- **Sidebar tab order, and the camera row layout.** `SidebarTab`'s declaration order (which
  `CaseIterable.allCases` — and so `verticalTabStrip`'s `ForEach` — follows) is now Camera
  Controls, Planetary, Deep Sky, Improvements — the two imaging-genre tabs grouped together right
  after Camera, "always applies regardless of genre" Improvements last, before the separately-
  appended Full Screen button (unaffected by this reorder either way, since it's not part of the
  enum). `CameraListView.cameraRow`/`webcamSection`'s per-device row both switched from one
  crammed `HStack` (name + spec line + 1-3 buttons all competing for the same row's width) to a
  `VStack`: name, then (for the ZWO row) its spec line, then the buttons in their own row —
  avoids the name truncating or the spec line wrapping awkwardly next to the buttons, which is
  exactly what a longer camera/device name did before.
- **Each tab's own "Advanced" catch-all.** As each of Camera Controls/Planetary/Deep Sky
  accumulated more sections over this whole session, the handful actually reached for on every
  session (Gain/Live Exposure/Sensor Temperature/Export; Lucky Imaging/Record SER Video; Live
  Stack/Record to Disk) ended up competing for scroll-past attention with everything else that
  tab also offers. Nothing moved into a new "Advanced" `DisclosureGroup` (collapsed by default,
  one level further than before) lost any functionality or its help link — this is purely a
  visual/navigation grouping, decided per tab:
  - **Camera Controls**: `commonControls`/`advancedControls` split `cameraManager.controls`
    itself — `ASI_GAIN`/`ASI_EXPOSURE`/`ASI_TEMPERATURE` stay visible (in that fixed order,
    regardless of whatever order the camera reports its `ASI_CONTROL_CAPS` in), every other
    dynamic control (offset, cooler, flip, binning, bandwidth, ...) moves into Advanced, alongside
    the dropped-frame counter, Gain/Offset Presets, Single Exposure, iPhone/Webcam, and Exported
    Files. Export stays visible outside Advanced.
  - **Planetary**: Lucky Imaging and Record SER Video stay visible; Focus Assist, Planetary
    Auto-Center, Planetary Presets, and Capture ROI move into Advanced.
  - **Deep Sky**: Live Stack and Record to Disk stay visible; Focus Assist, Smart Exposure, Polar
    Alignment, ST4 Guiding, and Calibration (Dark/Flat) move into Advanced.
  - "Disable All ___ Features" and the Acquisition Wizard button stay at the top of their tab in
    all three cases, outside Advanced — they're not settings to reach for less often, they're the
    fastest way to undo or set up everything else on the tab at once.
- **Telescope-specific planetary presets.** `PlanetaryPreset`'s numbers were tuned for one
  specific reference setup ("a modern ~2µm-pixel planetary camera behind a modest f/10-f/12
  Mak/SCT") and had no way to account for a different telescope — reported as the Wizard's Saturn
  preset not matching what actually worked on a real Maksutov 127mm/1500mm session.
  - **`TelescopeProfile`** (next to `PlanetaryPreset` in `CameraManager.swift`) is a small curated
    list of common amateur telescope configurations (a few Maksutovs, SCTs, Newtonians,
    refractors) — aperture + focal length, from which `focalRatio` (`focalLength/aperture`, the
    same f/number a camera lens's own f/stop is) is derived. `.maksutov127` (127mm/1500mm, f/11.8)
    is `.reference` — squarely inside the "f/10-f/12" range `PlanetaryPreset`'s numbers already
    assumed, so scaling by it is a no-op.
  - **`PlanetaryPreset.startingExposureSeconds(for:)`/`exposureRangeSeconds(for:)`** scale by
    `(telescope.focalRatio / reference.focalRatio)²` — illuminance per pixel scales with
    `1/focalRatio²`, the same relationship an ordinary camera's exposure triangle already uses for
    f/stop — clamped to a sane absolute range (0.05ms...5s) so an extreme enough scope can't scale
    this into a nonsensical starting point. Deliberately doesn't also scale `startingGain` —
    exposure alone already captures the relationship, and touching gain too would double-
    compensate for it.
  - **Explicitly not the whole story**: camera sensitivity (a different sensor's own ADU-per-
    photon response) is a separate, likely *larger* factor than telescope focal ratio for how far
    off a generic starting point can be from what a specific rig actually needs — this only
    accounts for the optical side, and the real recorded discrepancy that prompted this feature
    was plausibly mostly a camera difference, not a telescope one. These stay starting points to
    fine-tune against the live histogram either way, same as before.
  - **`CameraManager.telescopeProfile`** (persisted via `AppSettings`, defaulting to `.reference`
    when never set or when a stored value doesn't match any current case) is what
    `applyPlanetaryPreset`/the Wizard's own telescope picker both read/write — a preference, not
    session state, since the telescope behind the camera doesn't change between sessions nearly
    as often as anything else this app tracks.
- **Lucky Imaging: Pause/Cancel mid-burst, Save, and a frame browser.** Previously a burst could
  only be stopped by letting it run to completion — there was no way to abort one early — and
  once stacked, the result only ever became `currentFrame`/the live preview with no dedicated way
  to save it (the generic Export section technically already worked on it, since it's the same
  `currentFrame`, but nothing in the Lucky Imaging section itself pointed at that).
  - **`CameraManager.isLuckyImagingPaused`** gates the existing `ingest()` call that feeds frames
    into `luckyImagingSession.add(...)` — the same "freeze without discarding" shape
    `isLiveStackPaused` already gives Live Stack. "Cancel Burst" (shown while capturing, not just
    after completion) reuses the existing `discardLuckyImagingSession()`.
  - **"Save Stacked Image…"** next to Stack/Discard is the exact same `exportCurrentFrame(as:
    .png)` call Live Stack's own "Save Stacked Image…" button already makes — `stackLuckyImagingBest`
    already sets `currentFrame` to the averaged result, so this was really a missing *button*, not
    a missing capability.
  - **`LuckyImagingSession.framesSortedByScore`** (sharpest first — the same ranking `stackBest`
    itself uses internally to decide which fraction to keep) backs a new "Browse Frames…" sheet
    (`LuckyImagingFrameBrowserView`), listing every captured frame by rank/score. Selecting one
    calls `CameraManager.showLuckyImagingFrame(atSortedIndex:)` — a real side effect (replaces
    `currentFrame`, same as `stackLuckyImagingBest`), not a thumbnail popup — so a specific frame
    can be inspected or saved directly instead of only ever seeing the averaged stack. Available
    once any frames exist, not just once the burst completes, since browsing what's captured so
    far is useful either way (the burst keeps running in the background if it isn't paused).

- **Observation Projects: folder-per-project persistence, rename-safety, and the first-run flow.**
  This app previously had no concept of an observing session spanning more than "whatever's
  currently in `currentFrame`/Export History" — nothing tied a night's captures to a goal, an
  object list, or a place. The whole feature had no precedent beyond `AcquisitionPreset`'s "one
  JSON file per preset" convention, extended to a folder-per-item level.
  - **`Project`/`Session` (`skyformac/Projects/ObservationModels.swift`)** are plain `Codable`
    structs; `ProjectStore` writes one `project.json` per project (the whole nested session tree
    in one file, not a database — the realistic number of a person's own projects/sessions is
    small enough that reading every `project.json` on launch is trivial). Each gets its own
    folder under `~/Documents/Skyformac Projects/`, with a session subfolder for its actual
    capture files and a `Thumbnails/` folder.
  - **`folderName` is computed once at creation (`makeFolderName(name:id:)`, a sanitized name +
    an 8-char UUID suffix) and never recomputed from a later rename** — the one design choice
    this feature couldn't skip. Without it, renaming a project would mean moving its entire
    folder (every capture file, every thumbnail) on every keystroke of a text field, which is
    both slow and fragile (a half-renamed folder if the app crashes mid-move). Decoupling display
    name from folder name makes rename a pure metadata edit.
  - **`ThumbnailGenerator`** downscales whatever `CGImage` a capture path already has in hand
    (the same image being exported/recorded, not a second decode pass) to a small JPEG via
    `CGContext`/`CGImageDestination` — no third-party imaging library, matching every other
    pixel-pushing piece of this app.
  - **Active-session capture filing copies, not moves.** `CameraManager.recordActiveSessionCapture`
    (wired into `exportCurrentFrame`'s `finishExport` and `stopSERRecording`) calls
    `ProjectStore.recordCapture(copyingFileAt:...)` rather than the move-based
    `recordCapture(movingFileAt:...)` used for capture paths that don't already have a
    user-chosen destination — the exported/recorded file already lives wherever the user picked
    via `NSSavePanel` (or the SER destination), and moving it out from under that would break the
    Export History entry pointing at it. The session folder gets its own curated copy instead.
  - **`CoreLocationProvider`** wraps `CLLocationManager` behind a small `LocationRequesting`
    protocol so its permission/fix-request logic is unit-testable without a real
    `NSLocationWhenInUseUsageDescription` prompt in a headless test process — the same shape
    `OllamaTransport` uses for `OllamaPlanner`'s HTTP call, for the same reason (no real network
    request in tests, and no real Ollama server needed either).
  - **`OllamaPlanner`** asks a local Ollama server for a plan and tolerates the response being
    wrapped in prose or a ` ```json ` fence (smaller local models don't reliably follow "respond
    with only JSON") by taking the substring between the first `{` and the last `}` rather than
    parsing the whole reply as JSON directly.
  - **`ProjectsLibrary.save(_:)`** updates its in-memory list unconditionally but only calls
    `ProjectStore.save` — touching disk at all — once a project has a non-empty name. (Originally
    this backed an auto-created "empty untitled project" at every launch with zero projects on
    disk; that's since been replaced by `NewProjectSheet` always collecting a name up front — see
    the later entry below — but `save`'s own "don't persist the unnamed case" guard stayed, since
    a project can still exist purely in a view's local state for a moment before its first save.)
  - **`ProjectsBrowserView`** was originally a fourth `.sheet` on `ContentView`, not a second
    `Scene` —
    `SkyformacApp` disables window tabbing and removes the default "New Window" command
    specifically to stay single-window (see the Histogram/Curves detachable-panel entry above for
    the same constraint solved with an `NSPanel` instead), so a Projects "window" had to be a sheet
    like Help/Export/the Acquisition Wizard rather than a new top-level window.

- **Observation Projects, take two: the browser becomes the main window, running a session
  becomes the one thing that switches to the camera view.** The sheet-based Projects browser
  above worked, but buried the actual hierarchy this feature is about — project → session →
  session *execution* — behind a modal you had to remember to open, with the camera view as the
  app's real default. Inverted that: the app now can't show any camera UI without a session
  actually running.
  - **`RootView`** (new) is `SkyformacApp`'s `WindowGroup` content now, not `ContentView` directly
    — it swaps between `ProjectsBrowserView` and `ContentView` in the same window based on one
    condition: `CameraManager.activeSession == nil`. Browsing projects, seeing a project's own
    history/sessions, even having a project "open" as context (`activeProject` set,
    `activeSession` still `nil`) all stay on the browser side of that gate — only a session
    actually running moves to the camera view. This is what "the application cannot run without a
    project" turned into structurally: there's no code path into `ContentView` that doesn't go
    through a real `Session`.
  - **Creating a project always goes through `NewProjectSheet`** now — the one remaining modal in
    the whole feature. There's no more unnamed project sitting in the browser waiting to be named
    later (see the corrected `ProjectsLibrary.save` note above); a name is required before anything
    exists at all, which is also what makes "the project name must always be visible" trivially
    true — it's never blank to begin with. `CameraManager.newProject()` just clears
    `activeProject`/`activeSession` and sets a one-shot `isCreatingNewProjectRequested` flag for
    `ProjectsBrowserView.onAppear` to consume, rather than creating anything itself.
  - **Clicking a session in `ProjectDetailPane` branches on whether it has any captures yet** —
    empty (`session.captures.isEmpty`) means "never run," so the click calls
    `CameraManager.setActive(project:session:)` directly (which flips `RootView`'s gate and runs
    it); non-empty pushes its Session History page instead, showing its timeline in
    `SessionDetailPane` — "Run This Session" there still starts/resumes it on purpose, for
    whenever picking up a previously-run session to capture more is genuinely what's wanted.
  - **`CameraManager.endActiveSession()`** clears only `activeSession`, not `activeProject` —
    landing back on the *same* project's session list (via `lastEndedSessionID`, which
    `ProjectsBrowserView.onAppear` reads once to re-select that session too) rather than the top
    of the whole project list. `setActive(project: nil, session: nil)` ("Switch Project") is the
    version that actually leaves the project context behind.
  - **`openNextSession()`/`createSessionInActiveProject()`/`deleteActiveSession()`** exist so the
    "end session, open the next one, add another, delete this one" cycle a real observing run
    needs doesn't require a trip back through the browser for each step — all reachable from
    `ContentView`'s toolbar menu and the new `CommandMenu("Session")` in `SkyformacCommands`.
  - **Location editing had to stop calling `setActive` as a side effect.** The original
    `useCurrentLocationForActiveSession()`/`setManualLocationForActiveSession(...)` mutated
    whatever `activeProject`/`activeSession` already were — harmless when the browser was a sheet
    over the (unaffected) camera view, but now that `activeSession` is the thing that switches the
    whole window, `LocationEditorView` calling `setActive` before setting a location would have
    yanked the user into the camera view just for filling in coordinates on a project they were
    only browsing. Both are now `useCurrentLocation(for:session:)`/`setManualLocation(for:session:
    latitude:longitude:name:)`, taking the project/session explicitly instead of relying on
    whatever's currently active, and only mirroring the edit into `activeProject`/`activeSession`
    when that happens to already be the open one.

- **Observation Projects, take three: a drill-down stack of pages, not a three-column browser.**
  The `NavigationSplitView` from take two showed the project list, a project's detail, and a
  session's history all at once, side by side — a real macOS pattern, but not what was actually
  asked for: "project list is the home page, project detail is a subpage with all sessions,
  camera management is a session page in a project." Replaced the whole `ProjectsBrowserView`
  body with a plain `NavigationStack` over three pages instead — Home → Project Detail → Session
  History — each one pushed and popped like a real drill-down, with `ContentView` (running a
  session) as the thing that replaces the entire stack rather than living inside it.
  - **Routes carry IDs, not `Project`/`Session` values.** A private `ProjectsRoute` enum
    (`.project(Project.ID)`, `.sessionHistory(Project.ID, Session.ID)`) is what
    `NavigationStack(path:)` actually stores; `ProjectsBrowserView.destination(for:)` re-fetches
    the current `Project`/`Session` from `projectsLibrary.projects` on every push instead of
    carrying a value-type snapshot that could go stale (renaming a project while its own session
    history page is open, say, needs the pushed pages to see the rename too).
  - **`ProjectDetailPane` lost its `@Binding var selectedSessionID`** in favor of an
    `onShowSessionHistory: (Session) -> Void` closure the parent uses to push — the whole "which
    session is selected" concept a persistent multi-column layout needs doesn't exist once
    there's no longer a third column sitting there waiting for a selection.
  - **Ending a session (or finishing "New Project…") restores the right spot in the stack**, not
    just the right selection in a column: `ProjectsBrowserView.onAppear` rebuilds `path` from
    `cameraManager.activeProject`/`lastEndedSessionID` (`[.project(id)]`, or
    `[.project(id), .sessionHistory(id, sessionID)]`) each time the browser reappears, since a
    fresh `NavigationStack` starts with an empty path otherwise.

- **Home page: thumbnail cards by default, a sortable table as the alternative.** A plain `List`
  of one-line rows didn't show enough about a project to actually recognize it or judge its
  progress at a glance — no cover image, no capture count, no sense of when it was last touched.
  - **`ProjectStore.mostRecentThumbnailURL(for:)`** walks every session's `captures`, picks the
    single newest one that actually has a `thumbnailFileName` (a capture can lack one — see
    `CaptureRecord`'s doc comment — so this skips those rather than picking a thumbnail-less
    "most recent" and rendering nothing), and resolves it to the actual file. Pure/testable
    against a plain `ProjectStore` + hand-built `Project`, no real captures needed.
  - **`Project.totalCaptureCount`/`lastActivityDate`** (new computed properties, same spot as
    `allPlannedObjects`) are what both the grid card and the table actually show beyond the name —
    session count alone didn't say anything about how much had actually happened, or when.
    `lastActivityDate` falls back to `createdDate` for a project with no captures yet, so sorting
    a fresh project doesn't require special-casing a missing value.
  - **`ProjectsHomeViewMode`** (`.thumbnail`/`.table`) is an `@AppStorage` choice, the same
    "picked once, remembered across relaunches, but defaults sensibly for a fresh install" pattern
    `ControlsPanelView`'s own sidebar-tab picker already uses — thumbnail is the default here
    specifically because it's the more recognizable, more "browsing a photo library" view this
    feature is modeled on (iMovie), with the table as the deliberate power-user alternative for
    comparing many projects by their numbers instead.
  - **The table's row double-click, not row selection, is what opens a project** —
    `.contextMenu(forSelectionType:primaryAction:)`'s `primaryAction` closure, the same "select
    highlights, double-click opens" convention Finder's own list/column views use, rather than a
    single click immediately navigating away (which would make browsing/comparing rows in the
    table annoying, since every click would leave the page).

- **Session cards, richer History, and Stats on both pages.** The Project Detail page's session
  list was a name and a capture count; the Session History page had no sense of *when* anything
  happened beyond the raw editable fields used to plan it — `plannedDate` existed on the model
  from day one but had genuinely no UI anywhere.
  - **`Session.firstCaptureDate`/`lastCaptureDate`/`duration`/`captureCountByKind`** and
    `Project.firstActivityDate`/`captureCountByKind`/`active`/`archivedSessionsCount` (new
    computed properties, same style as `totalCaptureCount`/`lastActivityDate`) are what both
    `SessionCard` and the new History/Stats sections actually show. `duration` is `nil` below two
    captures — a single capture (or none) has nothing meaningful to measure between.
  - **`StatsGridView`/`StatItem`** (new, in `ProjectDetailPane.swift` since that's the first of
    the two pages that needed it) is one small adaptive-grid component shared by both the Project
    Detail and Session History Stats sections, so "how much has actually happened" looks the same
    at either level instead of two bespoke layouts.
  - **`CaptureRecord.Kind` gained `Hashable`/`CaseIterable`/`displayName`** — `Hashable` because
    the per-kind breakdown is a `[Kind: Int]` dictionary (`Dictionary(grouping:by:)`),
    `CaseIterable` so the Stats sections can iterate every kind in a fixed order rather than
    whatever order a dictionary happens to produce, and `displayName` because `rawValue` alone
    reads fine for `fits`/`png`/`tiff` but not the camelCase `serVideo`.
  - **A session's planned date is now actually editable** — a `Toggle` gates a `DatePicker`
    (`SessionDetailPane`'s own `hasPlannedDate`/`plannedDate` `@State`, synced from/back to
    `session.plannedDate`), the same "off by default, reveals a control when turned on" shape
    used nowhere else in this feature yet but common enough elsewhere in the app (e.g. Calibration
    toggles revealing their own controls).
  - **History deliberately uses "Aim"/"Objects"/"Position"** as its own labels (not `goal`/
    `plannedObjects`/`location`, the model's actual field names) — this section's job is to read
    as a record of what a session actually was, in the terms an observer would use to describe it,
    not a dump of the underlying schema.

- **Fixed the Ollama API call actually failing on a real machine.** `OllamaPlanner` shipped
  defaulting to `model: "llama3.2"` — a specific model name that has to be separately
  `ollama pull`ed, which most real installs simply haven't done (confirmed against a real running
  Ollama instance during this fix: `curl .../api/generate -d '{"model":"llama3.2",...}'` → HTTP
  404, `{"error":"model 'llama3.2' not found"}`, while the exact same request with an actually-
  installed model returned 200 with a normal `response` field). Every prior test used a fake
  transport that never actually depended on any specific model existing, so this never showed up
  until someone tried it against a real server.
  - **`model` is now `String?`, defaulting to `nil`** — "auto-detect": `resolveModel()` calls the
    new `installedModels()` (`/api/tags`) and uses whichever model is first, rather than trusting
    a hardcoded name to exist. An explicit `model` still skips that round trip entirely (see
    `generateRequestUsesTheConfiguredModelAndPOSTsJSON`'s `requestedPaths` assertion) — this is
    strictly an improved default, not a removed capability.
  - **`OllamaError.badResponse` gained an associated `message: String?`**, populated from the
    server's own `{"error": "..."}` body when it has one (`URLSession.send`) — the old plain
    `.badResponse` case couldn't distinguish "wrong model name" from "server isn't running" from
    "internal server error," all three of which need different next steps from the user. A new
    `noModelsInstalled` case covers the one gap even a correct auto-detect can't fix: zero models
    pulled at all.
  - **`OllamaError.userFacingMessage`** is what `AIPlanSheets` actually shows now, instead of
    `String(describing: error)`'s `badResponse(message: Optional("..."))`-shaped debug dump.

- **Quick Start, a breadcrumb, and a consolidated Project menu.** Three related corrections
  after actually walking through the Projects flow: sessions need to be reachable without an
  extra "should I create a project first?" step for a spontaneous outing; tapping a not-yet-run
  session was jumping straight to the camera view with no chance to look at it first; and
  project/session actions were split awkwardly across the File menu, a separate "Session" menu,
  and a dropdown hidden behind the camera view's project/session label.
  - **`CameraManager.quickStart(with: AcquisitionTarget)`** creates a project and session named
    after the target (goal = the target's own summary, the session's one planned object = the
    target's name), saves it immediately (the name is never empty, so `ProjectsLibrary.save`
    persists on the spot), and applies `target.recommendedPreset(telescope:)` — reusing the exact
    same curated list (`AcquisitionTarget.all`) and recommendation logic the Acquisition Wizard
    already has, rather than a second target list or a second "what settings for this object"
    table.
  - **`applyAcquisitionPreset` silently no-ops without a connected camera** (its own existing
    guard) — which would have quietly thrown away Quick Start's entire point (the recommended
    gain/exposure/mode) for anyone who hadn't already connected a camera before picking a target,
    which is the common case coming straight from the Home page. `pendingAcquisitionPreset`
    holds the preset in that case and `connect(to:)` applies (then clears) it the moment a camera
    actually connects — Quick Start doesn't skip camera selection, it just doesn't lose the
    recommendation while waiting for it.
  - **Tapping a session in `ProjectDetailPane` always opens its Session page now** — no more
    branching on `session.captures.isEmpty` to jump straight to the camera view for a never-run
    one. The camera view opens *only* via an explicit Run/Resume button (the session card's own,
    or "Run This Session" on the Session page) — tapping a row is navigation, pressing a button
    is an action, and conflating the two meant an accidental tap on an empty session silently
    started recording into it.
  - **The camera view's toolbar item became an actual breadcrumb** (`ContentView.breadcrumb`) —
    Home / Project name / Session name, three independently pressable crumbs, replacing a single
    `Menu` labeled with the window title. `CameraManager.showProjectDetail()` (new) is what
    pressing the *project* name calls — same shape as `endActiveSession()` (clears
    `activeSession`, keeps `activeProject`) but deliberately doesn't set `lastEndedSessionID`, so
    the browser lands on the Project Detail page rather than jumping into the session's own
    History the way pressing the *session* name (still `endActiveSession()`) does.
  - **Every project/session action moved into one `CommandMenu("Project")`** — New Project, Quick
    Start, Go Home, Open Project Page, End Session, Open Next Session, New Session in Project,
    Delete This Session — replacing the File menu's project items and the standalone "Session"
    menu. Caught (and fixed) a real pre-existing shortcut collision while consolidating: "New
    Project…" and the toolbar's "Night Mode" toggle had both been bound to ⌘⇧N; New Project moved
    to ⌘⇧P.

- **Full-width Session/Capture pages, and a Capture page for timeline thumbnails.** `Form`'s
  `.formStyle(.grouped)` centers and caps its own content width on macOS — fine for the Home and
  Project Detail pages' more compact editors, but the Session page (its History/Stats/Timeline)
  read as unnecessarily boxed-in with wasted space down both sides on a wide window.
  - **`PageSection`** (new, in `ProjectDetailPane.swift` alongside the other shared Projects-UI
    components) replaces `Form`'s `Section` for both `SessionDetailPane` and the new
    `CaptureDetailPage` below — a plain `VStack` in a `.background(.background.secondary)` card,
    laid out in an outer `ScrollView`/`VStack` with `.frame(maxWidth: .infinity, alignment:
    .leading)` instead of a `Form` at all, so nothing constrains the page to less than the full
    window width.
  - **Explicit "Back to Project"/"Back to Session" toolbar buttons** on `SessionDetailPane`/
    `CaptureDetailPage` — `onBack: () -> Void`, supplied by `ProjectsBrowserView` as
    `{ path.removeLast() }` — alongside whatever back-navigation affordance `NavigationStack`
    already provides, since "how do I get back" deserves to be an obvious labeled button on a
    page this dense, not just a small chevron.
  - **`CaptureDetailPage`** (new) is what tapping a `TimelineStripView` thumbnail now pushes —
    `TimelineStripView` gained an `onSelect: (CaptureRecord) -> Void` for exactly this, with a new
    `.capture(Project.ID, Session.ID, CaptureRecord.ID)` route alongside `.project`/
    `.sessionHistory`. It shows a larger preview (the real PNG/TIFF file when `NSImage` can decode
    it directly, the capture's own thumbnail as a fallback for FITS/SER/recording-folder kinds it
    can't), the file's own info, the owning session's context (aim/objects/position) so there's no
    need to go back just to remember what session this was, and that session's own Stats —
    reusing `PageSection`/`StatsGridView` rather than inventing another layout.
