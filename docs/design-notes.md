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
  `rgba8Unorm` output texture the mono path uses. Denoise/wavelet-sharpen/GPU
  live-stacking are still mono-only kernels and aren't wired up for RGB24 —
  same gap the CPU path already has.
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
  menu-bar path (`SkyformacCommands`, ⌘1-⌘3) remains the reliable way to switch tabs regardless.
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
