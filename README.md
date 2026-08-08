# MacZWO

A native macOS astrophotography capture app built directly on the ZWO ASI Camera SDK — no ASCOM/INDI bridging layer. See `spec/MacZWO_ClaudeCode_Spec.md` for the original spec.

## Requirements

- Xcode 26+ (Swift 6), macOS 14.0+ deployment target.
- The Metal toolchain component (`xcodebuild -downloadComponent MetalToolchain`) — needed once, to compile `Shaders.metal`.

## Building

```
make build   # build into ./build
make test    # run the unit tests (MacZWOTests) and UI tests (MacZWOUITests)
make run     # build and launch MacZWO.app
make clean   # remove ./build
make open    # open the project in Xcode
```

CI: `.github/workflows/ci.yml` runs `make build`/`make test` on `macos-15` GitHub Actions
runners on every push/PR. Not verified against real GitHub infrastructure from this environment
(no access to trigger an actual Actions run) — the YAML is validated and the underlying `make`
commands are exactly what's been run and verified locally throughout development, but the runner
image's Xcode/Metal-toolchain version could still need adjusting the first time it actually runs.

(`make` alone runs `build`. See `make help` for the full list.) Or open `MacZWO.xcodeproj` in
Xcode and run/test normally (⌘R / ⌘U). The Makefile just wraps the equivalent `xcodebuild`
invocations with a pinned `-derivedDataPath ./build`, if you'd rather call those directly.

No camera required to build, run, or test — see "Try it without hardware" below.

## Project layout

- `Vendor/ZWO/` — vendored ZWO SDK: `include/ASICamera2.h` and a universal (arm64 + x86_64)
  `libASICamera2.dylib`, `lipo`'d together from the official SDK's `mac_arm64` and `mac`
  builds (`ASI_Camera_SDK/ASI_linux_mac_SDK_V1.41/lib/`) and ad-hoc re-signed. The dylib is
  linked and embedded into the app bundle (`Contents/Frameworks/`) via a Copy Files build phase.
- `MacZWO/Bridging/` — the C-to-Swift bridge (`ZWOSDK`, `ZWOError`, `ZWOCameraInfo`,
  `ZWOControlCaps`). No raw C struct or pointer crosses out of this layer.
- `MacZWO/Capture/` — `CaptureEngine` (an `actor` owning the `ASIGetVideoData` poll loop, off
  the main thread by construction), `FrameBuffer` (the preallocated poll buffer), and
  `TestPatternGenerator` (synthetic frames for the no-hardware debug path).
- `MacZWO/CameraManagement/` — `CameraManager`, the `@Observable` `@MainActor` view model.
- `MacZWO/Rendering/` — both render paths: `CGImageRenderer` + `Debayer` + `HistogramComputer`
  (CPU), and `MetalFrameRenderer` + `Shaders.metal` (GPU, including the histogram compute
  kernel). `DisplayStretch` is the shared black/white-point model. `FrameArithmetic` (subtract/
  average), `SharpnessScorer` (Laplacian-variance), `FITSWriter`, and `ImageExporter` (PNG/TIFF)
  live here too — all pure, directly-testable pixel/byte math with no camera dependency.
- `MacZWO/Capture/` also has `LiveStacker` (CPU running-average accumulator),
  `LuckyImagingSession` (burst capture + sharpness-ranked stacking), `SkyCatalog` +
  `DemoTargetGenerator` (real-data-backed demo targets), and `AllSkyMonitor` (the secondary
  webcam/Continuity Camera safety monitor, built on plain `AVFoundation`).
- `MacZWO/Rendering/` also has `ExposureOptimizer` (sub-exposure length calculator),
  `PlanetDetector` + `PlanetTracker` + `FrameCropper` (planetary auto-center/crop),
  `PolarAlignmentSolver` (rotation-center geometry), `HFDCalculator` + `FocusTracker`
  (focus-quality tracking), `StarPatternRecognizer` (simplified star-field ID), and
  `GPUSharpnessScorer` (the recording quality gate).
- `MacZWO/Resources/SkyCatalog/` — `messier.json` (110 Messier objects, extracted from
  Stellarium's real DSO catalog at `stellarium/nebulae/default/catalog.txt`) and
  `bright_stars.json` (a small hand-curated bright-star list, public J2000 coordinates).
- `MacZWO/CameraManagement/AppSettings.swift` — typed `UserDefaults` wrapper for the preferences
  that survive a relaunch (render path, enhancement toggles, which overlays are on). Session
  state (calibration frames, live-stack accumulation, polar-alignment progress) deliberately
  isn't persisted — it always starts fresh.
- `MacZWO/Capture/CalibrationLibrary.swift` — multiple named dark *and* flat frames (not just
  one of each); `MacZWO/Rendering/FlatFieldCorrector.swift` does the division-based flat
  correction.
- `MacZWO/Rendering/ImageEnhancer.swift` — CPU fallback for the Metal denoise/wavelet-sharpen
  kernels, run off-`@MainActor` and throttled (see "Design decisions" — the naive synchronous
  version froze the app for 10+ seconds/frame).
- `MacZWO/Rendering/DiskSpaceChecker.swift` — the continuous-recording disk-space guardrail.
- `MacZWO/Capture/AllSkyAnalyzer.swift` — pure, unit-testable brightness/motion-alert logic
  behind `AllSkyMonitor`'s `AVCaptureVideoDataOutput` analysis.
- `MacZWO/App/MacZWOCommands.swift` — menu bar commands (export, camera connect/rescan, toolbar
  toggles) with keyboard shortcuts.
- `MacZWO/Views/` — SwiftUI. `ControlsPanelView` has a `ControlMode` picker (General/Planetary/
  Deep Sky/All Tools) filtering which of its ~15 tool sections show, via `ToolSection`.
- `MacZWOTests/` — unit tests (Swift Testing), **100 across 25 suites**, covering every piece of
  pixel/geometry/signal-processing math in the app: debayer, the stretch LUT, `ASI_ERROR_CODE`
  mapping, frame arithmetic, live-stack averaging, lucky-imaging selection, sharpness scoring
  (CPU and GPU), FITS/PNG/TIFF I/O, the sky catalog + demo generator, star-pattern recognition,
  frame cropping, planet detection/tracking, polar-alignment rotation-center solving, HFD/focus
  tracking, the exposure-length optimizer, flat-field correction, the calibration library, the
  CPU image enhancer, the all-sky brightness/motion analyzer, and disk-space checking.
- `MacZWOUITests/` — **4 XCUITest UI-level tests** driving the actual SwiftUI view tree
  (launch, sidebar contents, clicking "Simulate Mono" and observing the status text change) —
  these exercise the real accessibility-tree/view hierarchy, not just the underlying logic.

## Try it without hardware

No physical ASI camera on hand? In the camera list sidebar:
- **Simulate Mono** / **Simulate Color** feed an abstract test pattern through the full pipeline.
- **Demo Target…** renders a recognizable Jupiter/Saturn/Mars, a star field, or a real Messier
  object (`M31`, `M42`, `M13`, ...) with genuine positions/magnitudes/angular sizes pulled from
  `SkyCatalog` — enough to exercise star detection, planet tracking, and polar alignment
  end-to-end with nothing plugged in.

Toggle **Metal Renderer** in the toolbar to compare the CPU (`CGImage`) and GPU (Metal compute
shader) render paths side by side — denoise, wavelet sharpening, and GPU live stacking all
require this toggle to be on, since they're implemented purely as `Shaders.metal` kernels with
no CPU equivalent.

## Design decisions worth knowing about

- **App Sandbox is disabled** (`MacZWO/Resources/MacZWO.entitlements`). ZWO's SDK talks to the
  camera over raw USB in a way that doesn't reliably work under the sandboxed USB entitlement
  for arbitrary vendor devices. This app is meant to be distributed Developer ID–signed +
  notarized (outside the Mac App Store) — the same model ZWO's own ASIStudio uses. Hardened
  runtime is on, with `com.apple.security.cs.disable-library-validation` set so the embedded
  (non-Apple-signed) `libASICamera2.dylib` can load under it.
- **`vImageBayerToRGB` doesn't exist.** The original spec suggested it as the CPU debayer
  approach; there is no Bayer/demosaic API anywhere in the current Accelerate/vImage headers.
  `Debayer.swift` implements standard bilinear demosaicing by hand instead (verified against
  known-value test fixtures in `MacZWOTests/DebayerTests.swift`).
- **Deployment target is 14.0, not the spec's 13.0.** `@Observable` (used for `CameraManager`)
  requires macOS 14.
- **`vImageBayerToRGB`-shaped mistakes keep happening — verify against real APIs and real data.**
  Two more were caught during development, not from a spec this time: (1) the ZWO SDK has no
  per-gain read-noise API (`ASIGetGainOffset` returns a recommended *gain setting*, not read
  noise in electrons) — `ExposureOptimizer` measures it from a real bias frame instead. (2)
  `PlanetDetector`'s first version picked "the single largest Vision contour" as the planet disk
  and it silently failed 100% of the time on a banded target like Jupiter, because each band edge
  is its own long-thin contour and none pass a combined width+height size filter — caught by
  actually running it against the Jupiter demo target and inspecting the contours, fixed by
  unioning every non-trivial contour's bounding box instead (see `PlanetDetector`'s doc comment
  and the regression test in `PlanetDetectorTests`).
- **"Apple Neural Engine AI Denoising" is a classical bilateral filter, not a trained model.**
  Shipping a genuine Core ML denoiser needs training data and a model file that can't be
  conjured from a feature request. `isDenoisingEnabled` delivers the same real-time
  noise-suppression outcome via a well-understood, verifiable, non-ML technique instead.
- **Polar alignment and star-field "recognition" are intentionally not full plate solving.**
  Neither computes an absolute WCS (RA/Dec/orientation/plate scale). `PolarAlignmentSolver`
  correctly solves a 2D rotation center from star correspondences (real least-squares geometry,
  verified with synthetic rotated star fields) but can't tell you the true celestial pole's
  position without a real plate solver on top. `StarPatternRecognizer` matches a live field
  against a ~14-star catalog via triangle-similarity voting — a real, if small-scale, technique,
  not astrometry.net-grade blind solving.
- **Live stacking, lucky imaging, and continuous recording all do zero geometric
  alignment/registration** between frames — every one of them assumes a tracked, stationary
  mount, the same honest scoping SharpCap's basic (non-aligned) live-stack mode uses.
- **The CPU denoise/wavelet-sharpen fallback froze the app for 10+ seconds per frame** in its
  first version, because it ran synchronously on `@MainActor` inside `refreshCurrentImage()`.
  Fixed two ways: `ImageEnhancer.waveletBlur` was rewritten as a separable (horizontal-then-
  vertical) convolution instead of a full 2D 25-tap kernel, and the whole computation moved into
  a `Task.detached(priority: .userInitiated)` with a frame-ID staleness guard — mirroring the
  existing `scheduleFocusAssistIfNeeded` pattern — so the un-enhanced frame displays immediately
  and the enhanced one swaps in asynchronously. Caught via a headless self-test where the
  expected log line took ~20s to appear instead of ~2s.
- **`Info.plist` was missing `CFBundleIdentifier`.** With `GENERATE_INFOPLIST_FILE = NO`, Xcode
  doesn't auto-merge `PRODUCT_BUNDLE_IDENTIFIER` into a hand-written Info.plist — it has to be
  spelled out as `$(PRODUCT_BUNDLE_IDENTIFIER)` explicitly, along with `CFBundleName`,
  `CFBundleExecutable`, etc. This silently didn't matter for normal launches, but broke
  `XCUITest`'s bundle-ID-based app lookup outright. Caught when `MacZWOUITests` failed to launch
  the app at all; fixed by adding the missing keys (see `MacZWO/Resources/Info.plist`).
- **No custom Bluetooth video-streaming companion app.** Bluetooth (classic or BLE) doesn't have
  the throughput for live video — Apple's own Continuity Camera deliberately uses Wi-Fi/peer-to-
  peer for the video itself and only touches Bluetooth for discovery. Building a bespoke iOS
  companion app to push frames over Bluetooth would either not work or ship a feature that looks
  functional but silently can't carry a usable picture. Instead, the All-Sky monitor's existing
  Continuity Camera support (which already lets any signed-in nearby iPhone act as a camera) got
  a real "Add iPhone" UI: a sheet documenting the actual (system-level) pairing prerequisites,
  live discovery feedback, and a picker that separates "iPhone (Continuity Camera)" from other
  webcams. This was a deliberate, asked-for scope narrowing (confirmed with the user), not a
  silent cut.

## Permissions

First connection to a USB ASI camera may prompt via System Settings → Privacy & Security. Keep
the camera connected when you grant the prompt. The optional All-Sky Monitor (a secondary webcam
or nearby iPhone via Continuity Camera) requests separate camera access the first time it's
started — declined or ignored, the rest of the app is entirely unaffected, since it doesn't touch
the ZWO capture pipeline at all. No other special entitlements are required beyond what's already
configured (see above).

## Status

Everything in the spec's four milestones is implemented (discovery, RAW8 preview, dynamic
controls, RAW16 + debayer + histogram). On top of that:

**Core upgrades**
- **GPU render pass** — `Shaders.metal` debayer/stretch/histogram compute kernels; toggle
  "Metal Renderer" in the toolbar.
- **Single-exposure capture** — `ASIStartExposure`/`ASIGetExpStatus`/`ASIGetDataAfterExp` for
  long deep-sky exposures, in Controls → "Single Exposure".
- **Focus assist** — Vision `VNDetectContoursRequest` star detection overlay with a sharpness
  readout, in Controls → "Focus Assist".
- **Dark-frame subtraction, live stacking, lucky imaging, FITS/PNG/TIFF export** — Controls →
  "Dark Frame" / "Live Stack" / "Lucky Imaging" / "Export".

**This round's additions**
- **Demo mode with real data** — Jupiter/Saturn/Mars, a star field, and Messier deep-sky objects,
  positioned/sized/magnitude'd from Stellarium's real catalog. Camera list → "Demo Target…".
- **Star-field recognition** — simplified triangle-pattern matching against a small bright-star
  catalog. Controls → "Recognize Stars" (needs Focus Assist on).
- **Night mode** — red-only UI for dark adaptation. Toolbar toggle.
- **Plate-solved-style polar alignment** — 2-frame rotation-center solving from star
  correspondences, with a live on-screen correction vector. Controls → "Polar Alignment".
- **Smart Exposure Brain** — measures read noise + sky brightness from real frames, recommends
  an optimal sub-exposure length. Controls → "Smart Exposure".
- **Planetary auto-center & crop** — Vision-tracked disk with a dynamic cropped ROI. Controls →
  "Planetary Auto-Center".
- **GPU live stacking** — the Metal renderer's stacking runs as a genuine GPU running-sum
  compute kernel end to end, not just GPU-rendered display of a CPU-computed average.
- **Real-time denoise + wavelet sharpening** — classical bilateral denoise and a 2-level à trous
  wavelet sharpen (RegiStax-style), both Metal compute kernels. Controls → "Image Enhancement".
- **HFD focus tracking + thermal drift alert** — per-star Half-Flux-Diameter, a rolling curve,
  and a linear-regression drift alert. Shown under Controls → "Focus Assist" once stars are found.
- **GPU sharpness frame filter for continuous recording** — writes every sufficiently-sharp
  incoming frame to disk as FITS, scored by a GPU Laplacian-energy kernel. Controls → "Record
  to Disk".
- **All-Sky / rig monitor** — picture-in-picture feed from a secondary webcam or a nearby iPhone
  via Continuity Camera, independent of the ZWO pipeline. Toolbar → "All-Sky Monitor".

**Gap-filling round (making the above production-shaped, not just feature-complete)**
- **Settings persistence** — renderer choice, enhancement toggles, and which overlays are on
  survive a relaunch, via `AppSettings` (`UserDefaults`-backed). Session state (calibration
  frames, live-stack accumulation, in-progress polar alignment) intentionally still resets fresh.
- **Controls panel mode picker** — `ControlsPanelView` had grown to ~15 always-visible
  `DisclosureGroup`s; a `Picker("Mode", ...)` (General / Planetary / Deep Sky / All Tools) now
  filters which sections show, via `ToolSection.isVisible(in:)`.
- **Calibration library (multi-dark + flats)** — `CalibrationLibrary` holds any number of named
  dark *and* flat frames, not just one of each; `FlatFieldCorrector` does division-based flat
  correction, composed with the existing dark subtraction.
- **CPU fallback for denoise/sharpen** — `ImageEnhancer` mirrors the Metal bilateral-denoise and
  à-trous wavelet kernels on the CPU (throttled off-`@MainActor`, see "Design decisions"), so
  those effects work with "Metal Renderer" off too.
- **All-Sky monitor does real analysis, not just PiP** — `AllSkyAnalyzer` (pure, unit-tested
  logic) computes brightness/motion from the live feed via `AVCaptureVideoDataOutput`, and the
  view now surfaces cloud/light and motion alert banners instead of a bare video feed.
- **Recording disk-space guardrail** — continuous recording tracks bytes written and estimated
  bytes/frame, checks free space via `DiskSpaceChecker`, and stops itself (with a visible warning)
  before it can fill the disk.
- **Menu bar commands** — `MacZWOCommands` adds real `Commands`-based menu items with keyboard
  shortcuts for export (⌘E/⌘⇧E), camera rescan/connect (⌘R/⌘K), and toolbar toggles (⌘M, ⌘⇧N,
  ⌘⇧A) — not just toolbar-only actions.
- **CI** — `.github/workflows/ci.yml` runs `make build`/`make test` on GitHub Actions' `macos-15`
  runners on every push/PR (see "Building" above for the honest caveat on it).
- **UI-level automated tests** — `MacZWOUITests` (XCUITest) drives the real SwiftUI view tree:
  app launch, sidebar contents, and clicking "Simulate Mono" through to a "Streaming" status.

**Preview & rig-monitor polish**
- **GPU rendering is now the default** — `AppSettings.useMetalRenderer` defaults to `true` on a
  fresh install; toggle it off in the toolbar (⌘M) or Controls if you specifically want the CPU
  `CGImage` path.
- **Zoom & pan on the live preview** — pinch-to-zoom (1×–8×, trackpad `MagnifyGesture`) and
  drag-to-pan once zoomed in, on both the CPU and Metal render paths. Double-click the preview,
  or click the zoom badge, to reset. `PreviewView.swift`.
- **"Add iPhone" affordance on the All-Sky monitor** — a new iPhone-badge button opens a sheet
  explaining Continuity Camera's actual (system-level, not in-app) pairing prerequisites and
  live-checks whether one has been discovered; the device picker itself now groups
  "iPhone (Continuity Camera)" separately from other webcams, and defaults to an iPhone when one
  is available. There is intentionally no custom Bluetooth video-streaming companion app — see
  "Design decisions" below for why.

All of the above has been verified without a physical camera attached: the app builds, launches,
and runs cleanly with zero cameras connected; the test suite passes (`MacZWOTests`, **100 unit
tests across 25 suites**, plus `MacZWOUITests`, **4 UI tests** — 104 total, via both direct
`xcodebuild` and `make build`/`make test`); and headless integration smoke tests (temporarily
wiring `CameraManager` actions into `MacZWOApp`'s launch, then reverting before committing — the
same technique used throughout development) exercised every feature above, individually and
combined in a single run, against synthetic demo frames with no crashes or logged exceptions.
Four real bugs were caught and fixed this way in total (see "Design decisions" above): the
star-field demo's stars were too small for Vision to detect, the planet detector's "largest
single contour" heuristic silently found nothing on a banded target, the CPU enhancement path
froze the app for 10+ seconds per frame, and `Info.plist` was missing `CFBundleIdentifier` (which
broke `XCUITest` app launch specifically). (FITS/export/recording file-write logic is
additionally unit-tested directly; `NSSavePanel`/`NSOpenPanel` UI glue wasn't exercised
headlessly since those open modal dialogs.)

Real-hardware validation (does a real camera actually enumerate/stream/expose correctly, and do
the Vision-based features behave the same on real noisy sensor data as on clean synthetic demo
frames) is still outstanding and should be the first thing to check once a camera is available —
nothing here has touched actual ZWO USB hardware yet. Distribution/notarization (Developer ID
signing, notarization, a real `DEVELOPMENT_TEAM`) is likewise still outstanding — everything so
far has been built and run ad-hoc/locally-signed.
