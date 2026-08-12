# Features

Everything in the original spec's four milestones is implemented (discovery,
RAW8 preview, dynamic controls, RAW16 + debayer + histogram). On top of that:

**Capture sources**
- **ZWO ASI cameras** over USB, via the vendored SDK — full dynamic control
  set (gain, exposure, offset, cooler, whatever the connected camera reports),
  RAW8/RAW16 video streaming, and single long exposures via
  `ASIStartExposure`/`ASIGetDataAfterExp`.
- **iPhone (Continuity Camera) or any other USB webcam** as a primary capture
  source — e.g. holding an iPhone to a telescope eyepiece (afocal projection)
  for lunar/planetary shots. Runs the same debayer/histogram/live-stacking
  pipeline as a ZWO camera; single-exposure "capture" freezes on the current
  live frame rather than pretending to expose, since a webcam has no
  controllable hardware exposure.
- **iPhone/webcam focus lock** — freezes `AVCaptureDevice`'s continuous
  autofocus at its current position, since it otherwise actively fights
  afocal projection (it keeps hunting for a "normal" subject distance and
  refocuses away from the telescope's focal plane).
- **iPhone/webcam Night Mode (10s / 60s)** — accumulates that many seconds of
  live frames via the same running-average technique Live Stack uses, then
  freezes on the brighter result. Not a literal single long sensor exposure
  (a webcam has no such thing) — the same computational multi-frame-stacking
  mechanism Apple's own iPhone Night Mode uses internally.

**Rendering**
- **GPU render pass** — `Shaders.metal` compute kernels for RAW8/RAW16
  debayer/stretch, RGB24 (webcam) stretch, histogram, denoise (both mono and
  RGB24), wavelet-sharpen (both mono and RGB24), and live-stack accumulation
  (mono only — see "Live stacking" below for the webcam/iPhone fallback);
  toggle "GPU/CPU" in the toolbar (⌘M). GPU is the default.
- **Exposure control spans microseconds to hundreds of seconds** on a
  log-scale slider with adaptive µs/ms/s display, matching what a real ASI
  sensor actually supports (a linear slider can't cover that range at any
  usable resolution).
- Pinch-to-zoom (1×–8×) and drag-to-pan on the live preview, on both render
  paths.
- **Fullscreen live preview** — fills the whole window with just the video
  and its overlays (focus assist, Catalog HUD, etc.), plus an explicit zoom
  slider for precise control when pinch-to-zoom isn't precise/discoverable
  enough — for seeing faint stars without sidebar/histogram clutter.
  Reachable three ways (View menu ⌘⇧F, the sidebar's vertical tab strip's
  "Full Screen" button, or the preview's own overlay button), all driving
  the same `CameraManager.isPreviewFullScreenEnabled`. Esc, ⌘⇧F again, or
  the overlay's close button returns to the normal layout.

**Calibration & stacking**
- **Dark-frame and flat-frame calibration**, any number of named frames per
  type (`CalibrationLibrary`), independently toggleable subtraction/correction
  (`FlatFieldCorrector`).
- **Live stacking** — CPU running-average, or a genuine GPU running-sum
  compute kernel end to end when the Metal renderer is active, for a ZWO
  camera's mono RAW8/RAW16 data. A webcam/iPhone (RGB24) source always
  accumulates on the CPU running-average instead — the GPU accumulator is a
  single-channel kernel with no RGB24 path — while the GPU renderer still
  handles that source's own live stretch/denoise/sharpen, so the preview
  stays GPU-accelerated either way; see
  [`docs/design-notes.md`](design-notes.md) for the "silently did nothing for
  webcam/iPhone" bug this replaced. Optional GPU drift reduction (single-star
  lock-on, sub-pixel aligned accumulation) for mounts that don't track
  perfectly, e.g. alt-azimuth — ZWO cameras only. The lock-on centroid is
  measured against the search window's own local sky background (sigma-
  clipped, not raw pixel intensity), the initial lock rejects isolated
  hot/warm pixels by their lack of a spread-out point-spread footprint, and
  losing the lock (drift bigger than the search window can follow) re-scans
  the whole frame to re-acquire instead of giving up for the rest of the
  session — see [`docs/design-notes.md`](design-notes.md) for exactly what
  it does and doesn't correct for (it's single-point translation lock-on
  built for real mount tracking error against a star field, not general
  handheld-video stabilization), and the bugs these replaced. **Pause**
  freezes a running stack exactly as it is (to actually look at it — focus,
  alignment) without discarding it the way **Reset** does. Exporting
  FITS/PNG/TIFF while stacking is active exports the actual stacked average
  on both render paths and both camera types — not the latest raw single
  frame; a "Save Stacked Image…" button right in the Live Stack panel does
  the same as a one-click PNG
  snapshot, without a trip to the Export section below.
- **Lucky imaging** — burst capture, sharpness-ranked (Laplacian variance,
  CPU or GPU), keeping and stacking only the sharpest fraction. Works for a
  webcam/iPhone source too (`SharpnessScorer`/`FrameArithmetic` both have an
  RGB24 case — no debayer needed, the frame is already color).
- **FITS/PNG/TIFF export**, for the current frame or a live stack. Color-camera
  FITS exports embed a `BAYERPAT` header card so downstream tools (and
  skyformac's own reader, below) know how to debayer them.
- **Exported Files** — a persistent history of every export/recording, an
  **Open File…** browser for any FITS/PNG/TIFF/JPEG file, and an in-app
  viewer (`FITSReader` + the existing debayer/stretch pipeline for FITS,
  direct display for the rest) with adjustable Black/White Point sliders.
  Deliberately a viewer, not a second processing suite — see
  [`specs/skyformac_Exported_Files_Spec.md`](../specs/skyformac_Exported_Files_Spec.md).
- **Continuous recording** with a GPU sharpness frame filter (only writes
  frames sharp enough to be worth keeping, scored by a GPU Laplacian-energy
  kernel) and a disk-space guardrail that stops recording before it can fill
  the disk.
- **Capture ROI + SER video recording** (ZWO cameras only) — the standard
  "small ROI, high FPS" planetary/lunar lucky-imaging workflow: request a
  smaller-than-full-sensor region from the camera itself (increases
  achievable frame rate, not just a display crop), then record every
  incoming frame undiscarded into a single `.ser` video for a set duration —
  the raw-video container AutoStakkert!3/PIPP/RegiStax expect to do their
  own alignment, best-frame selection, and wavelet sharpening from. See
  [`docs/design-notes.md`](design-notes.md) for exactly what each piece does.
- **Planetary Presets** (ZWO cameras only) — one tap sets RAW8, a small
  Capture ROI, and a safe starting exposure/gain for Saturn, Jupiter, Mars,
  Venus, or the Moon, tuned around a modern ~2µm-pixel planetary camera
  (e.g. ASI678MC) behind a modest f/10-f/12 Maksutov/SCT. Also sets the SER
  recording duration slider to that target's recommended session length.

**Focus & tracking**
- **Focus assist** — Vision `VNDetectContoursRequest` star detection overlay
  with a sharpness readout.
- **HFD focus tracking** — per-star Half-Flux-Diameter, a rolling curve, and
  a linear-regression thermal-drift alert.
- **Planetary auto-center & crop** — Vision-tracked disk with a dynamic
  cropped ROI.
- **Smart Exposure** — measures read noise (from a real bias frame) and sky
  background brightness (from a real test exposure), recommends an optimal
  sub-exposure length.

**Sky recognition & the Catalog HUD**
- **Star-field recognition** — triangle-similarity matching of detected stars
  against a small hand-curated bright-star catalog, plus real point-to-point
  correspondence resolution (not just "these stars are plausibly present" —
  actually *which* detected point is *which* catalog star).
- **Live WCS solving** — once enough star correspondences are confidently
  resolved, `LiveWCSSolver` fits a real (small-angle, least-squares)
  astrometric calibration (pointing, rotation, plate scale) from them. The
  Catalog HUD (`SkyHUDView`) then overlays real catalog objects — galaxies,
  nebulae, clusters, named stars, from a bundled SQLite catalog with dynamic
  level-of-detail — directly on the live view. See
  [`docs/design-notes.md`](design-notes.md) for exactly how this differs from
  full blind plate solving.
- **Plate-solved-style polar alignment** — two-frame rotation-center solving
  from star correspondences, with a live on-screen correction vector.

**Image enhancement**
- Real-time denoise (classical bilateral filter) and 2-level à trous wavelet
  sharpening (RegiStax-style), as Metal compute kernels with a CPU fallback
  (throttled, off-`@MainActor`) for when the GPU renderer is off. Works for
  both ZWO RAW8/RAW16/Y8 (mono kernels) and iPhone/webcam RGB24 sources
  (color-aware kernels, matching CPU/GPU math) — see
  [`docs/design-notes.md`](design-notes.md) for the color-fringing
  consideration that took.
- **Live GPU Enhancement Controls** (`specs/skyformac_GPU_Live_Controls_Spec.md`,
  GPU renderer only, opt-in) — a second, independent three-stage pipeline:
  temporal (exponential-moving-average) denoise across frames, a second
  user-adjustable bilateral spatial denoise pass, and a non-linear
  (inverse-hyperbolic-sine) contrast stretch layered on top of the base
  black/white-point stretch. Controls → "Live GPU Enhancement Controls",
  including an "Auto-Stretch Safety Lock" button that sets black/white point
  and boost from the current frame's histogram.

**AI & Machine Learning Suite**
(`specs/skyformac_AI_Features_Pipeline_Spec.md` — Controls → "AI & Machine
Learning Suite"; see [`docs/design-notes.md`](design-notes.md) for why two of
the spec's five features are declined rather than faked)
- **Live quality score** — the Lucky Imaging panel shows the current frame's
  Laplacian-variance sharpness score live, the same metric that already ranks
  frames for stacking.
- **Satellite/aircraft trail masking** — Vision-based streak detection
  (`StreakDetector`) excludes detected trails from the live stack on a
  per-pixel, per-frame basis, on both the CPU (`StreakMask`/`LiveStacker`)
  and GPU (`accumulateMonoMasked`/`normalizeMaskedAccumulator` in
  `Shaders.metal`) render paths, so a passing satellite doesn't bake a
  bright line into the average. Takes priority over GPU drift-reduction
  live-stack alignment if both are on at once — see
  [`docs/design-notes.md`](design-notes.md).
- **Cloud & Drift Sentinel** — reuses the All-Sky monitor's cloud/light-alert
  detection against the main capture feed's own brightness, with a one-shot
  local notification and a "pause capture" action when triggered.
- *Declined:* a genuine Neural-Engine AI denoiser and AI super-resolution both
  need a trained Core ML model that doesn't exist yet; see the spec's
  Implementation Notes.

**Monitoring & UI**
- **All-Sky / rig monitor** — picture-in-picture feed from a secondary webcam
  or a nearby iPhone via Continuity Camera, independent of the main ZWO
  pipeline, with its own brightness/motion-alert analysis and an "Add iPhone"
  affordance documenting Continuity Camera's real pairing prerequisites.
- **Night mode** — red-only UI for dark adaptation.
- **Controls panel tabs** — a vertical icon tab strip (Camera / Improve /
  Advanced) on the sidebar's trailing edge, grouping
  the sidebar's ~15 sections by role: raw per-camera hardware controls, opt-in
  visual enhancements (denoise/sharpen/GPU pipeline/AI Suite), and imaging
  workflows (focus/tracking/stacking/calibration/recording). The
  Improvements and Advanced tabs each have a single "Disable All" checkbox to
  instantly fall back to the camera's own unmodified output. Also reachable
  from the menu bar (Sidebar Tab menu, ⌘1-⌘3) — a fully independent path to
  the same `@AppStorage("sidebarTab")` state, not just a shortcut to the same
  button.
- **Menu bar commands** — export (⌘E/⌘⇧E), camera rescan/connect (⌘R/⌘K), and
  toolbar toggles (⌘M, ⌘⇧N, ⌘⇧A), all with keyboard shortcuts.
- **Settings persistence** — renderer choice, enhancement toggles, and which
  overlays are on survive a relaunch; session state (calibration frames,
  live-stack accumulation, in-progress polar alignment) intentionally starts
  fresh every time.

**Help**
- **In-app Help** (Help menu, ⌘?) — a sheet on the app's one window (this app
  is deliberately single-window, no separate Help `Window` scene) covering
  5-minute quick starts for both capture sources, how-to guides for
  iPhone/ZWO, a full configuration reference (what every control does, with
  example values), deep-sky and planetary observation workflows,
  troubleshooting, Q&A, and license/credits (with a link to the GitHub
  repository). Plain structured content (`HelpContent.swift`) rendered with
  real SwiftUI typography, not a bundled webpage.

**Testing**
- `skyformacTests` — 137 unit tests (Swift Testing) across 31 suites, covering
  every piece of pixel/geometry/signal-processing math in the app.
- `skyformacUITests` — XCUITest UI-level tests driving the real SwiftUI view
  tree.
- CI (`.github/workflows/ci.yml`) runs `make build`/`make test` on GitHub
  Actions' `macos-15` runners on every push/PR.

Real-hardware validation against an actual ZWO USB camera is still outstanding
— everything above has been exercised against real webcam/iPhone input and the
automated test suite, but not yet a physical ASI sensor. Distribution/
notarization (Developer ID signing, notarization, a real `DEVELOPMENT_TEAM`)
is likewise still outstanding.
