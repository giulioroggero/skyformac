# Architecture

What's in each part of the codebase, folder by folder.

- **`Vendor/ZWO/`** — vendored ZWO SDK: `include/ASICamera2.h` and a universal
  (arm64 + x86_64) `libASICamera2.dylib`, `lipo`'d together from the official
  SDK's `mac_arm64` and `mac` builds (`ASI_Camera_SDK/ASI_linux_mac_SDK_V1.41/lib/`)
  and ad-hoc re-signed. The dylib is linked and embedded into the app bundle
  (`Contents/Frameworks/`) via a Copy Files build phase.
- **`skyformac/Bridging/`** — the C-to-Swift bridge (`ZWOSDK`, `ZWOError`,
  `ZWOCameraInfo`, `ZWOControlCaps`). No raw C struct or pointer crosses out of
  this layer.
- **`skyformac/Capture/`**:
  - `CaptureEngine` — an `actor` owning the `ASIGetVideoData` poll loop for a
    real ZWO camera, off the main thread by construction, and `FrameBuffer`
    (the preallocated poll buffer).
  - `WebcamCaptureEngine` — the Continuity Camera/USB-webcam capture path
    (`AVCaptureSession`), feeding the same `CapturedFrame` pipeline as a ZWO
    camera. See [design-notes.md](design-notes.md) for the frame-backpressure
    design this needed.
  - `AllSkyMonitor` + `AllSkyAnalyzer` — the secondary webcam/Continuity Camera
    safety monitor (picture-in-picture), independent of the main ZWO pipeline;
    `AllSkyAnalyzer` is the pure, unit-tested brightness/motion-alert logic
    behind it.
  - `LiveStacker` (CPU running-average accumulator), `LuckyImagingSession`
    (burst capture + sharpness-ranked stacking), `CalibrationLibrary`
    (multiple named dark *and* flat frames), `SkyCatalog` (the bundled
    Messier + bright-star data `StarPatternRecognizer` matches against).
- **`skyformac/CameraManagement/`** — `CameraManager`, the `@Observable`
  `@MainActor` view model that owns camera discovery/lifecycle, the dynamic
  control set, and the capture pipeline entry point (`ingest`).
  `AppSettings.swift` is the typed `UserDefaults` wrapper for preferences that
  survive a relaunch (render path, enhancement toggles, which overlays are
  on) — session state (calibration frames, live-stack accumulation,
  in-progress polar alignment) deliberately isn't persisted, it always starts
  fresh.
- **`skyformac/Rendering/`** — both render paths:
  - CPU: `CGImageRenderer` + `Debayer` + `HistogramComputer`.
  - GPU: `MetalFrameRenderer` + `Shaders.metal` (RAW8/RAW16 debayer/stretch,
    RGB24 stretch for webcam sources, plus the histogram/denoise/wavelet-
    sharpen/live-stack compute kernels).
  - `DisplayStretch` is the shared black/white-point model both paths use.
  - `FrameArithmetic` (subtract/average), `SharpnessScorer` +
    `GPUSharpnessScorer` (Laplacian-variance, CPU and GPU), `FITSWriter`, and
    `ImageExporter` (PNG/TIFF) — pure, directly-testable pixel/byte math with
    no camera dependency.
  - `ExposureOptimizer` (sub-exposure length calculator), `PlanetDetector` +
    `PlanetTracker` + `FrameCropper` (planetary auto-center/crop),
    `PolarAlignmentSolver` (rotation-center geometry), `HFDCalculator` +
    `FocusTracker` (focus-quality tracking), `StarDetector` +
    `StarPatternRecognizer` (star detection and catalog identification),
    `ImageEnhancer` (CPU fallback for the Metal denoise/wavelet-sharpen
    kernels, off-`@MainActor` and throttled — see design-notes.md),
    `DiskSpaceChecker` (continuous-recording disk-space guardrail).
- **`skyformac/Catalog/`** — the on-screen catalog overlay (see
  `specs/skyformac_Catalog_HUD_Spec.md`): `WCSProjection` (`WCSFrame`, the
  gnomonic pixel<->sky projection), `CatalogRepository` (read-only SQLite
  access to the bundled astronomical catalog), and `LiveWCSSolver` (fits a
  `WCSFrame` from real star correspondences — see design-notes.md).
- **`skyformac/Projects/`** — the Projects feature's model and services,
  independent of any UI: `ObservationModels.swift` (`Project`, `Session`,
  `GeoLocation`, `Annotation`, `CaptureRecord` — all `Codable`, with a
  `folderName` computed once at creation and never recomputed from a later
  rename), `ProjectStore` (filesystem persistence — one folder per
  project/session, one `project.json` per project, no database),
  `ProjectsLibrary` (the `@Observable` in-memory list the browser UI reads,
  the thing that makes an unnamed project's edits never touch disk),
  `ThumbnailGenerator` (`CGContext`/`CGImageDestination` JPEG downscaling,
  no third-party imaging library), `CoreLocationProvider` (GPS behind an
  injectable `LocationRequesting` protocol so it's testable without real
  Core Location permissions), `ProjectSearch` (free-text + date-range
  search), and `OllamaPlanner` (talks to a local Ollama server behind an
  `OllamaTransport` protocol for the same reason).
- **`skyformac/Resources/`**:
  - `SkyCatalog/` — `messier.json` (110 Messier objects, extracted from
    Stellarium's real DSO catalog at `stellarium/nebulae/default/catalog.txt`)
    and `bright_stars.json` (a small hand-curated bright-star list, public
    J2000 coordinates) — what `SkyCatalog.swift` loads.
  - `AstroCatalog/astro_catalog.sqlite` — the bundled catalog
    `CatalogRepository` queries; rebuilt by `scripts/build_astro_catalog.py`.
- **`skyformac/App/`** — `SkyformacApp` (the `@main` entry point) and
  `SkyformacCommands` (menu bar commands: export, camera connect/rescan,
  toolbar toggles, all with keyboard shortcuts).
- **`skyformac/Views/`** — SwiftUI. `RootView` is `SkyformacApp`'s actual
  `WindowGroup` content — it swaps between `ProjectsBrowserView` and
  `ContentView` in the same window based on `CameraManager.activeSession`,
  never a second `Scene` (per `SkyformacApp`'s single-window design).
  `ControlsPanelView` has a `ControlMode` picker (General/Planetary/Deep
  Sky/All Tools) filtering which of its tool sections show, via
  `ToolSection`. `ProjectsBrowserView` (a three-column `NavigationSplitView`
  — projects, sessions, session detail) plus
  `ProjectDetailPane`/`SessionDetailPane`/`TimelineStripView`/
  `AIPlanSheets` are the Projects feature's UI, built on
  `skyformac/Projects/`'s model layer.
- **`skyformacTests/`** — unit tests (Swift Testing) covering every piece of
  pixel/geometry/signal-processing math in the app: debayer, the stretch LUT,
  `ASI_ERROR_CODE` mapping, frame arithmetic, live-stack averaging,
  lucky-imaging selection, sharpness scoring (CPU and GPU), FITS/PNG/TIFF I/O,
  the sky catalog, star-pattern recognition and correspondence resolution,
  live-WCS solving, frame cropping, planet detection/tracking, polar-alignment
  rotation-center solving, HFD/focus tracking, the exposure-length optimizer,
  flat-field correction, the calibration library, the CPU image enhancer, the
  all-sky brightness/motion analyzer, disk-space checking, and the Projects
  feature (folder persistence and rename-safety, thumbnail generation,
  active-session capture filing, GPS/manual location, free-text search, and
  Ollama plan parsing against a fake transport).
- **`skyformacUITests/`** — XCUITest UI-level tests driving the actual SwiftUI
  view tree (launch, sidebar contents, the toolbar renderer toggle) — these
  exercise the real accessibility-tree/view hierarchy, not just the
  underlying logic.
