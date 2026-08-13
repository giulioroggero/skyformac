# Features

Everything in the original spec's four milestones is implemented (discovery,
RAW8 preview, dynamic controls, RAW16 + debayer + histogram). On top of that:

**Capture sources**
- **ZWO ASI cameras** over USB, via the vendored SDK — full dynamic control
  set (gain, exposure, offset, cooler, whatever the connected camera reports),
  RAW8/RAW16 video streaming, and single long exposures via
  `ASIStartExposure`/`ASIGetDataAfterExp`. ZWO's own recommended Gain/Offset
  reference points (Highest Dynamic Range/Unity Gain/Lowest Read Noise, plus
  a Low/Middle/High shortcut on models that report it) are one tap away, a
  dropped-frame counter refreshes live (useful for tuning Bandwidth against
  your actual USB setup), and Sensor Temperature now actually keeps updating
  instead of freezing at its connect-time reading. ST4 guide-port pulse
  guiding (single manual N/S/E/W corrections) is wired up too, shown only for
  cameras that report a real guide port — **unverified against real
  hardware**, since this project has never had an actual ST4-cabled mount to
  confirm against; see [`docs/design-notes.md`](design-notes.md).
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
  handheld-video stabilization), and the bugs these replaced. An
  **"Experimental" mesh-based alternative** tracks an NxN grid of points
  instead of one, triangulating the mesh and blending each triangle's
  displacement with barycentric interpolation (the actual primitive
  real-time rendering/games rasterize — not a 3D reconstruction, just the
  standard unambiguous way to interpolate across a 2D deformation mesh) —
  covers field rotation and differential drift a single global shift
  can't, at the cost of a rougher (single-pass, no background subtraction)
  per-point measurement. Mesh
  size, search-window overlap, and reaction sensitivity are all
  user-configurable, with a live preview overlay showing the actual tracked
  grid and displacement vectors. Takes priority over the single-star lock
  when both are on — they're alternatives, not combinable. **Pause**
  freezes a running stack exactly as it is (to actually look at it — focus,
  alignment) without discarding it the way **Reset** does. Exporting
  FITS/PNG/TIFF while stacking is active exports the actual stacked average
  on both render paths and both camera types — not the latest raw single
  frame; a "Save Stacked Image…" button right in the Live Stack panel does
  the same as a one-click PNG
  snapshot, without a trip to the Export section below.
- **Smart Live Stack (Autopilot)** — live, self-curating stacking: each
  incoming frame is GPU-sharpness-scored and only folded into the stack if
  it's at least a configurable fraction as sharp as the session's best frame
  so far, or discarded outright on a Cloud Sentinel alert. Curates *while*
  the session runs instead of the traditional record-everything-then-curate-
  in-another-tool workflow — the stack you're watching build is already the
  curated one. Live kept/rejected counters, and a real (not fabricated)
  estimated-SNR-gain-from-more-frames readout (`sqrt(N)` stacking-SNR
  scaling) for judging when a session is past the point of diminishing
  returns. See [`docs/design-notes.md`](design-notes.md) for the full
  reasoning and its honest scope (quality curation, not autoguiding/
  dithering/sequencing).
- **Lucky imaging** — burst capture, sharpness-ranked (Laplacian variance,
  CPU or GPU), keeping and stacking only the sharpest fraction. Works for a
  webcam/iPhone source too (`SharpnessScorer`/`FrameArithmetic` both have an
  RGB24 case — no debayer needed, the frame is already color). Pause/Resume
  and Cancel work mid-burst; "Save Stacked Image…" saves the result
  directly; "Browse Frames…" lists every captured frame by sharpness rank
  (the same ranking `stackBest` uses internally) and previews/saves one
  specific frame instead of only the averaged stack.
- **FITS/PNG/TIFF export**, for the current frame or a live stack. Color-camera
  FITS exports embed a `BAYERPAT` header card so downstream tools (and
  skyformac's own reader, below) know how to debayer them.
- **Exported Files** — a persistent history of every export/recording, an
  **Open File…** browser for any FITS/PNG/TIFF/JPEG file, and an in-app
  viewer (`FITSReader` + the existing debayer/stretch pipeline for FITS,
  direct display for the rest) with adjustable Black/White Point sliders.
  The live histogram can also switch to a "By Channel" (Red/Green/Blue) view
  instead of the combined one — useful for spotting a single channel
  clipping or unbalanced on its own — for any color source (ZWO color camera
  or webcam/iPhone); not shown for a mono camera, since there's nothing to
  split into channels. Turning "By Channel" on also switches the Black/White
  Point sliders from one combined pair to three fully independent pairs (one
  per channel), for compensating a color imbalance (e.g. a light-polluted
  sky's orange cast) directly at the stretch stage.
  Deliberately a viewer, not a second processing suite — see
  [`specs/skyformac_Exported_Files_Spec.md`](../specs/skyformac_Exported_Files_Spec.md).
- **Curves** — a second tab next to the histogram with Photoshop-style
  tone-curve grading: drag control points on a 256-step response curve, per
  channel (a master "RGB" curve applied to all three identically, plus
  independent Red/Green/Blue curves layered on top of it). Off by default
  ("Enable" checkbox); applies as a post-stretch pass on both the GPU and CPU
  live-preview render paths, on top of whatever Black/White Point (and
  "Independent Channels") stretch is already dialed in. Works for a mono
  camera too (master curve only, since there's nothing to split into
  channels), not just a color source.
- **Detachable Histogram/Curves panel** — a button next to the tabs pops
  both into a separate floating window that can overlap the main one and
  stay open while working elsewhere; closing it (its own close button, or
  a "Dock" button in the main window) puts them back inline.
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
  own alignment, best-frame selection, and wavelet sharpening from. Two
  fixed-size quick presets (640×480/800×600) plus manual width/height/center
  entry for any rectangle at any position — the ROI is genuinely centered on
  the sensor (or wherever you place it) via `ASISetStartPos`, not pinned to
  the sensor's top-left corner the way it silently was before. The live
  preview's own refresh rate is capped independently (~30fps) so a small,
  very-high-frame-rate ROI can't flood the display pipeline into a growing,
  flickering backlog — recording (SER/FITS) and Lucky Imaging still process
  every real frame regardless, only the visible preview is rate-limited. A
  second stall source (the sensor-temperature/dropped-frame diagnostics poll
  briefly blocking the main thread every 2 seconds, worse the higher the
  real frame rate) was found and fixed the same way — routed through the
  capture actor instead of running directly on the main thread. See
  [`docs/design-notes.md`](design-notes.md) for exactly what each piece does.
- **Planetary Presets** (ZWO cameras only) — one tap sets RAW8, a small
  Capture ROI, and a safe starting exposure/gain for Saturn, Jupiter, Mars,
  Venus, or the Moon, tuned around a modern ~2µm-pixel planetary camera
  (e.g. ASI678MC) behind a modest f/10-f/12 Maksutov/SCT. Also sets the SER
  recording duration slider to that target's recommended session length.
- **Acquisition Wizard** (⌘⇧W, or "Acquisition Wizard…" in the Planetary/
  Deep Sky tabs) — pick a target (Moon, Venus, Mars, Jupiter, Saturn, or a
  curated deep-sky list: M13, M56, M31, M42, M45, M51, M57, M27, M81, M8)
  and set up ROI, gain, exposure, and which of Live Stack/Reduce Drift/Smart
  Live Stack/Lucky Imaging/Mesh Drift Correction (Experimental) to use, in
  one step. Mesh Drift Correction is never recommended on by default —
  worth trying deliberately for a long, multi-minute-plus integration where
  field rotation matters, not something a starting-point preset should
  silently enable — but it's an editable row for any target the preset
  turns Live Stack on for. The Moon is the one target
  that turns on *both* Live Stack and Lucky Imaging at once (high-res
  crater detail plus a lower-noise full-disk shot); other planets are
  Lucky-Imaging-only, every deep-sky object is Live-Stack-only with Reduce
  Drift on by default. Works on a webcam/iPhone source too — Live Stack/
  Lucky Imaging/Smart Live Stack all apply normally there; ROI/gain/
  exposure/Reduce Drift don't (no hardware equivalent, or a mono-only GPU
  accumulator), which the Wizard says outright rather than blocking Apply
  or implying they took effect. Presets round-trip to their own JSON file
  (one file per preset) via Save/Load Preset, so a favorite setup for a
  specific object under a specific telescope/camera pairing survives beyond
  one session. Doesn't auto-start a Lucky Imaging burst or SER recording —
  framing/focus should be confirmed against the real target first. See
  [`docs/design-notes.md`](design-notes.md) for the full reasoning.
- **Save/Load Preset, standalone** — saving or loading a preset doesn't need
  the Wizard sheet open at all. "Save Preset…" snapshots *whatever's
  currently configured* (not a target's recommendation) into its own file;
  "Load Preset…" loads a file and applies it immediately. Available from
  the **Camera** menu (⌘⇧S/⌘⇧L), from a new "Acquisition" section in the
  left camera-list sidebar right under the connected camera (not tucked
  into the right-hand Controls panel, since these work regardless of which
  Controls tab happens to be showing), and Wizard/Load sit right next to
  each camera's own Disconnect button too, for the fastest path to either.
- **"Running" status list** (next to the camera, above the "Acquisition"
  section) — every currently-active pipeline (Live Stack, Lucky Imaging,
  Recording to Disk, SER recording, Planetary Tracking, Polar Alignment,
  Cloud Sentinel, Focus Assist), each with a one-click button to jump to
  its own tab in the right-hand Controls panel and a one-click Stop button,
  so nothing left running from a previous session (or just easy to forget
  about once its own tab isn't the one showing) stays invisible.
- **Reset to Default** (next to the camera, same "Acquisition" section) —
  full sensor ROI, a safe starting gain, and every capture-affecting toggle
  (Live Stack/Smart Live Stack/Reduce Drift, Lucky Imaging, Dark/Flat
  correction, Focus Assist, Planetary tracking/crop, Image Enhancement, the
  AI Suite) plus any active recording, all back off in one action — undoes
  a Wizard preset or any manual adjustment without hunting down each toggle.

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

**Observation Projects**
(see [`docs/design-notes.md`](design-notes.md) for the folder-per-project/
session persistence design and the browser-as-main-window architecture)
- **The Projects browser is the app's main window** — there's no camera UI
  reachable without a running session: the window shows the projects
  browser (project → session → history) whenever no session is active, and
  switches to the camera view only once one is actually running. A project
  groups sessions under a shared goal and optional planned date range; each
  session plans its own goal, objects (e.g. "M13, M57, Saturn"), and date.
- **Create/run/manage** — "New Project…" (Home page toolbar, or ⌘⇧N) is the
  one modal in the feature — it requires a name up front, so the project's
  name is always visible from the moment it exists. Clicking a session that
  has no captures yet runs it directly (switches to the camera view);
  clicking one that's already been run shows its history instead. While
  running, the toolbar's project/session menu (and `CommandMenu("Session")`)
  covers End Session, Open Next Session, New Session in Project, and
  Delete This Session without a trip back to the browser.
- **Home page: thumbnail cards or a table, your choice** — a toolbar toggle
  switches between a grid of cover-thumbnail cards (default, generated from
  each project's single most recent capture with a thumbnail — see
  `ProjectStore.mostRecentThumbnailURL`) and a sortable `Table` (name, goal,
  session/capture counts, location, tags, last activity) for comparing a
  lot of projects by their numbers instead. Either way each project shows
  its session count, total capture count, location, tags, and last
  activity date, not just its name.
- **One folder per project/session** — every project gets its own folder
  under `~/Documents/Skyformac Projects/`, with one subfolder per session
  holding that session's actual capture files, a `Thumbnails/` folder, and
  the project's own `project.json` metadata. Renaming a project/session
  never moves its folder.
- **Session cards, not plain rows** — the Project Detail page's session list
  shows each one as a card: its own cover thumbnail, a Not Run Yet/Archived
  status badge, aim, objects, planned date (or last capture time), capture
  count, and location, with Run/Resume right there — enough to tell sessions
  apart and judge their status without opening each one.
- **Session History: the full record** — date/time (created, planned, first
  and last capture, duration), position, aim, and objects, plus a per-kind
  capture breakdown, laid out as a proper historical record rather than just
  the same editable fields used to plan it. A session's planned date is now
  itself editable (`Toggle` + `DatePicker`) — previously write-only in the
  data model with no UI at all.
- **Stats on both levels** — the Project Detail page shows session counts
  (active/archived), total captures, first/last activity, and a per-kind
  breakdown (FITS/PNG/TIFF/SER Video/Recording); the Session History page
  shows the same breakdown scoped to that one session (`StatsGridView`,
  shared by both).
- **Timelines with thumbnails** — every session shows its captures as a
  filmstrip (date + a small JPEG thumbnail generated from the same image
  already being exported), the iMovie-style browsing this feature is built
  around.
- **Active session capture filing** — exporting a frame or finishing a SER
  recording while a session is running also files a copy of it into that
  session's timeline, alongside the normal Export History.
- **Location** — GPS (`CoreLocationProvider`, one fix per request) or
  hand-entered coordinates, tracked independently on a project and each of
  its sessions — settable from the browser without needing to run the
  session first.
- **Tags, notes, and search** — free-text annotations and tags on both
  projects and sessions; a single search box matches name, goal, tags,
  planned/observed objects, and note text, optionally narrowed to a date
  range.
- **AI-assisted planning** — "Ask AI to Plan…" sends a one-line goal to a
  local Ollama server (`OllamaPlanner`) and shows the suggested session(s)
  before anything is created; no cloud dependency, matches this app's
  everything-runs-locally stance. The model to use is auto-detected from
  whatever's actually installed (`ollama list`) rather than a hardcoded
  name that may not be pulled — errors surface the server's own explanation
  (a missing model, an unreachable server) instead of a generic failure.

**Monitoring & UI**
- **All-Sky / rig monitor** — picture-in-picture feed from a secondary webcam
  or a nearby iPhone via Continuity Camera, independent of the main ZWO
  pipeline, with its own brightness/motion-alert analysis and an "Add iPhone"
  affordance documenting Continuity Camera's real pairing prerequisites.
- **Night mode** — red-only UI for dark adaptation.
- **Controls panel tabs** — a vertical icon tab strip (Camera / Improve /
  Planetary / Deep Sky) on the sidebar's trailing edge. Camera Controls and
  Improve are grouped by role (raw per-camera hardware controls; opt-in
  visual enhancements — denoise/sharpen/GPU pipeline/AI Suite); Planetary and
  Deep Sky are grouped by imaging genre instead — Planetary Presets/Capture
  ROI/Record SER Video/Lucky Imaging/Planetary Auto-Center in one, Live
  Stack/Calibration/Polar Alignment/ST4 Guiding/Smart Exposure/Record to Disk
  in the other (Focus Assist appears in both — it genuinely serves either
  genre). Improve, Planetary, and Deep Sky each have a single "Disable All"
  checkbox to instantly fall back to the camera's own unmodified output.
  Also reachable from the menu bar (Sidebar Tab menu, ⌘1-⌘4) — a fully
  independent path to the same `@AppStorage("sidebarTab")` state, not just a
  shortcut to the same button.
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
  example values), a Projects topic, deep-sky and planetary observation
  workflows, troubleshooting, Q&A, and license/credits (with a link to the
  GitHub repository). Plain structured content (`HelpContent.swift`)
  rendered with real SwiftUI typography, not a bundled webpage.

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
