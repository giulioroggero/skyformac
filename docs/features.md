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

**Rendering**
- **GPU render pass** — `Shaders.metal` compute kernels for RAW8/RAW16
  debayer/stretch and RGB24 (webcam) stretch, plus histogram, denoise,
  wavelet-sharpen, and live-stacking kernels; toggle "GPU/CPU" in the toolbar
  (⌘M). GPU is the default.
- **Exposure control spans microseconds to hundreds of seconds** on a
  log-scale slider with adaptive µs/ms/s display, matching what a real ASI
  sensor actually supports (a linear slider can't cover that range at any
  usable resolution).
- Pinch-to-zoom (1×–8×) and drag-to-pan on the live preview, on both render
  paths.

**Calibration & stacking**
- **Dark-frame and flat-frame calibration**, any number of named frames per
  type (`CalibrationLibrary`), independently toggleable subtraction/correction
  (`FlatFieldCorrector`).
- **Live stacking** — CPU running-average, or a genuine GPU running-sum
  compute kernel end to end when the Metal renderer is active.
- **Lucky imaging** — burst capture, sharpness-ranked (Laplacian variance,
  CPU or GPU), keeping and stacking only the sharpest fraction.
- **FITS/PNG/TIFF export**, for the current frame or a live stack.
- **Continuous recording** with a GPU sharpness frame filter (only writes
  frames sharp enough to be worth keeping, scored by a GPU Laplacian-energy
  kernel) and a disk-space guardrail that stops recording before it can fill
  the disk.

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
  (throttled, off-`@MainActor`) for when the GPU renderer is off.
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
  (`StreakDetector`) excludes detected trails from the live CPU stack on a
  per-pixel, per-frame basis (`StreakMask`/`LiveStacker`) so a passing
  satellite doesn't bake a bright line into the average. GPU live-stacking
  only, not supported yet — the panel says so when both are on at once.
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
- **Controls panel mode picker** — General/Planetary/Deep Sky/All Tools,
  filtering which tool sections show. Also reachable from the menu bar
  (Mode menu, ⌘1-⌘4) — a fully independent path to the same
  `@AppStorage("controlMode")` state, not just a shortcut to the same button.
- **Menu bar commands** — export (⌘E/⌘⇧E), camera rescan/connect (⌘R/⌘K), and
  toolbar toggles (⌘M, ⌘⇧N, ⌘⇧A), all with keyboard shortcuts.
- **Settings persistence** — renderer choice, enhancement toggles, and which
  overlays are on survive a relaunch; session state (calibration frames,
  live-stack accumulation, in-progress polar alignment) intentionally starts
  fresh every time.

**Testing**
- `skyformacTests` — 134 unit tests (Swift Testing) across 31 suites, covering
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
