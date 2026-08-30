# Skyformac Roadmap: Closing the N.I.N.A. Gap

## 1. Objective

Skyformac is currently an **interactive capture + processing + planning companion** — strong
on live stacking, AI assistance, and its own post-processing pipeline, but with no
unattended-automation backbone. N.I.N.A. (Nighttime Imaging 'N' Astronomy, the leading Windows
imaging suite) is built around the opposite: a sequencer that runs a multi-target plan overnight
with no one watching, backed by device automation (autofocus, autoguiding, plate-solve + mount
sync) and a real plugin ecosystem.

This spec is the roadmap for closing that gap — not a single feature, but the top-level plan
this repo's [GitHub Project](https://github.com/users/giulioroggero/projects) tracks, one item
per gap below. Each gap gets its **own dedicated `skyformac_<FeatureName>_Spec.md`** (per
`specs/README.md`'s own convention) once a maintainer prioritizes it — this document is the
map, not the itinerary for any one of them.

## 2. Process this roadmap follows

See `CONTRIBUTING.md` for the full lifecycle. In short: every gap below becomes a GitHub Issue,
every issue is tracked on the Project board, a maintainer sets its priority, and — in priority
order — each one goes through: **AI spec written → implemented → tested → alpha → beta → GA**.

## 3. The gaps, in the order this roadmap recommends tackling them

Recommended order: **(1) is what actually defines "N.I.N.A.-class,"** and (2)–(4) are largely
what a sequencer needs to orchestrate, so a device abstraction layer underneath all of them
(item 5) is really a prerequisite, not a separate independent gap.

### 3.1 Sequencer / unattended automation — *the biggest gap*
- **Problem:** Every Skyformac capture is one interactively-run session. There is no multi-target
  queue, no conditional loop/trigger system (autofocus-on-temperature-change, meridian flip,
  time-of-night), and no reusable session templates.
- **Goal:** A sequencing model — an ordered/conditional list of instructions (slew, filter change,
  N exposures, autofocus, dither) a user can build once and let run overnight across multiple
  targets, the same shape N.I.N.A.'s Advanced Sequencer occupies.
- **Depends on:** Device abstraction (3.5) for anything beyond pure camera exposures; benefits
  from — but doesn't strictly require — autofocus (3.4) and plate-solve/sync (3.3) to be useful
  for a real unattended night.

### 3.2 Live autoguiding integration
- **Problem:** Skyformac only reads PHD2 **logs** after the fact (`PHD2GuideLogAnalyzer`); it
  doesn't drive PHD2 (or any guider) live, so there's no closed-loop guiding or dithering during
  capture.
- **Goal:** Drive an external guider (PHD2's own Server API over TCP is the realistic first
  target — well-documented, already the guider this app has diagnostic tooling for) for
  calibrate/start-guiding/dither/stop, gated behind the sequencer waiting on "settled" before
  each exposure.

### 3.3 Real plate solving + mount sync/slew
- **Problem:** `LiveWCSSolver`/`PolarAlignmentSolver` are both explicitly scoped as *not* full
  astrometric solvers (small-angle approximate fits for HUD overlay / polar-axis finding only,
  no absolute RA/Dec output). Skyformac has no mount slew/GoTo control at all — only a single
  manual ST4 pulse-guide sanity check.
- **Goal:** A real plate-solve backend (ASTAP or astrometry.net's `solve-field`, both scriptable
  local CLIs — consistent with this app's existing Siril/GraXpert/StarNet CLI hand-off pattern,
  not a network dependency) plus a mount-control abstraction that can slew/sync, so "center on
  this target" becomes a real, automatable action.

### 3.4 Active autofocus
- **Problem:** `FocusTracker`/`HFDCalculator` only do **passive** HFD trend monitoring (flagging
  thermal drift) — there is no focuser motor control anywhere in the codebase, so nothing can
  actually *run* an autofocus routine.
- **Goal:** Focuser device control (see 3.5) plus a V-curve/HFD-minimization autofocus routine,
  triggerable manually and by the sequencer (temperature change, filter change, time elapsed).

### 3.5 Device abstraction layer (ASCOM/INDI-equivalent)
- **Problem:** Skyformac only speaks to ZWO ASI cameras (native SDK), Continuity Camera, and
  webcams. Filter wheels exist only as **equipment catalog metadata** (a text label in the gear
  inventory), not live-controlled hardware. No rotator, dome, safety monitor, or weather-device
  integration exists.
- **Goal:** A minimal device-abstraction protocol (per device class: focuser, filter wheel,
  rotator, mount, dome, safety monitor) that real drivers plug into — INDI is the natural fit on
  macOS (open protocol, existing macOS server implementations) where ASCOM (Windows-only COM)
  is not.
- **Note:** This is what 3.1–3.4 actually automate *against* — sequencing several exposures is
  moot if nothing but the camera itself is under this app's control.

### 3.6 Plugin ecosystem
- **Problem:** Third-party integrations (Siril, GraXpert, StarNet, AstroBin) are hardcoded CLI
  hand-offs baked into the app, not something a third party can add to without a PR.
- **Goal:** A defined extension point (new capture-post-processing step, new sequencer
  instruction type, or new device driver) with a documented interface, even before any actual
  dynamic-loading mechanism exists.

### 3.7 Framing Assistant
- **Problem:** Skyformac's SDSS integration fetches a fixed-size cutout for an *object detail*
  view — useful for "what does this look like," not for composing a shot. There's no tool that
  overlays the actual camera+telescope field-of-view rectangle on a real sky image before
  shooting.
- **Goal:** A FOV-rectangle overlay on a real sky-survey image (SDSS where in-footprint, DSS
  elsewhere) sized from the equipment library's own focal-length/sensor data, for framing/mosaic
  planning before a session starts.

## 4. Non-goals (for this roadmap document itself)

This document does not commit to a timeline, does not pick a device protocol beyond the
recommendation in 3.5, and does not spec any single gap in implementation detail — that's each
gap's own future `skyformac_<FeatureName>_Spec.md`, written when a maintainer prioritizes it.

## 5. Milestones

- [ ] File one GitHub Issue per gap (3.1–3.7), each linking back to this document.
- [ ] Create the GitHub Project and add all seven issues to it.
- [ ] Maintainer sets an initial priority order on the Project board.
- [ ] `CONTRIBUTING.md` describes this whole issue → project → priority → spec → implement → test
      → alpha → beta → GA lifecycle.
- [ ] For each gap, in priority order: write `specs/skyformac_<FeatureName>_Spec.md`, implement,
      test, ship alpha → beta → GA, then check it off here.
