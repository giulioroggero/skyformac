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
- **No custom Bluetooth video-streaming companion app.** Bluetooth (classic or
  BLE) doesn't have the throughput for live video — Apple's own Continuity
  Camera deliberately uses Wi-Fi/peer-to-peer for the video itself and only
  touches Bluetooth for discovery. The All-Sky monitor's Continuity Camera
  support (any signed-in nearby iPhone can act as a camera) has a real "Add
  iPhone" UI instead: a sheet documenting the actual (system-level) pairing
  prerequisites, live discovery feedback, and a picker that separates
  "iPhone (Continuity Camera)" from other webcams.
