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
- **No custom Bluetooth video-streaming companion app.** Bluetooth (classic or
  BLE) doesn't have the throughput for live video — Apple's own Continuity
  Camera deliberately uses Wi-Fi/peer-to-peer for the video itself and only
  touches Bluetooth for discovery. The All-Sky monitor's Continuity Camera
  support (any signed-in nearby iPhone can act as a camera) has a real "Add
  iPhone" UI instead: a sheet documenting the actual (system-level) pairing
  prerequisites, live discovery feedback, and a picker that separates
  "iPhone (Continuity Camera)" from other webcams.
