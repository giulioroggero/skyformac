# Changelog

All notable changes to Skyformac are documented here, newest first. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
plain `MAJOR.MINOR.PATCH` without a strict semver contract, since this is a
single-developer app, not a library with a public API.

**[Unreleased]** is the `master`/dev branch — updated continuously as work lands,
with everything folded under a proper version heading (and dated) only once it's
actually tagged. Tags on GitHub: [v0.2.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.2.0),
[v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12).

## [Unreleased]

### Added
- **Observation Projects** — a whole new feature area, built up over many steps:
  - Project/session data model with one-folder-per-project/session filesystem
    persistence (plain JSON, no database).
  - The Projects browser itself: initially a three-column iMovie-style library,
    later replaced with a full-width drill-down page stack (**Home → Projects →
    Project → Session**), and finally topped with a proper orientation
    **Dashboard** as Home — resume the last session, common-task shortcuts,
    recent projects, highlighted sessions, an activity chart, and suggestions —
    with the original project grid/table moving one level down as its own
    **Projects** page.
  - GPS or hand-entered **location** on both projects and sessions.
  - Free-text + date-range **search**, later extended with a Filters popover
    (exact tag, observed object, equipment system, date range).
  - **Ollama-backed AI session/project planning** ("Ask AI to Plan…"), with a
    generous timeout and a `qwen3:8b` model preference (falling back to
    whatever's actually installed).
  - **Quick Start** — pick a common target and skip creating a project/session
    by hand; a consolidated **Project** menu; a project/session breadcrumb in
    the camera view.
  - Session cards, richer session history, and per-kind capture-count stats on
    both the Project and Session pages (later upgraded to a real resizable
    `Table`, replacing a capped-width grid).
  - **Equipment management** — named systems (camera/mount/optical tube plus
    optional tracking/imaging/autoguiding/power/eyepiece/smartphone-mount/other
    categories), a curated common-brand catalog, custom items, and
    project/session association with inheritance.
  - **Plain-English capture notes** ("Captured Saturn in Live Stack as FITS")
    generated automatically for every capture, shown on the timeline.
  - **Per-capture action records** — every capture now also snapshots the
    object observed, effective location, effective equipment system, and every
    acquisition parameter (gain/exposure/ROI/mode) in effect at that moment.
  - **Recall Parameters** — reapply a past action's exact camera settings to
    speed up setting up a similar shot again.
  - **New Session Like This…** — duplicate a session's goal/objects/location/
    equipment into a fresh session, without its captures.
  - **Insights** page — most-captured objects, most-used equipment, most
    common acquisition mode, a monthly activity chart, and "try this next"
    suggestions, aggregated across every project.
  - **Archive projects/sessions**, and **delete with a 30-day grace period**
    (Recently Deleted page, restore or purge immediately).
- **Acquisition Wizard** — pick a target (planet, Moon, or curated deep-sky
  object), get its recommended gain/exposure/mode, and save/load setups as
  reusable presets.
- **Smart Live Stack** — live, self-curating deep-sky/planetary stacking that
  discards frames below a rolling sharpness threshold.
- **Mesh Drift Correction** (Experimental) in the Acquisition Wizard, with a
  triangulated interpolation and a live overlay of each vertex's search window.
- **Per-channel (Red/Green/Blue) histogram** and an independent **Curves** tab,
  in a detachable panel.
- **ZWO gain/offset presets**, a live dropped-frame counter, and **ST4 pulse
  guiding**.
- **Exported-files viewer**, GPU streak masking, an RGB24 processing pipeline
  (for iPhone/webcam sources), drift reduction, SER video recording, and
  planetary presets, later given telescope-specific exposure scaling.
- A "Running" status list next to the camera view for active pipelines.
- **In-app Application Log** (`skyformac → Show Log…`, ⌘⇧D) — every connection
  event, error, Quick Start, and Ollama failure, with copy/export.
- **Settings window** (⌘,) — the Projects folder location (choose a custom
  folder, takes effect next launch) plus the renderer/Night Mode toggles.
- README badge row (CI/platform/Swift/license/release), a centered title/link
  header, a full-width hero GIF, and a dedicated `EXAMPLES.md` catalog.

### Changed
- Made the Projects browser the app's actual main window — the camera view
  only shows once a session is actually running.
- Widened/reordered the sidebar; split each right-hand tab into common
  controls plus a collapsed Advanced section; reordered the Home grid so Quick
  Start leads and New Project trails every existing project.
- Full-width Session, Capture, and Project Detail pages (no more `Form`-capped
  side margins), plus a dedicated Capture detail page for timeline thumbnails.
- Auto-open the Projects browser on a true first run.

### Fixed
- Ollama planning calls failing against a real (non-mocked) server, and
  requests timing out against a slower local reasoning model.
- Blank frames no longer get written into `.ser` recordings.
- Night Mode no longer tints the live image itself, only the surrounding UI.
- Removed the "SDK x.x.x" connected/disconnected toolbar badge — reported as
  not useful; connection state is already shown contextually elsewhere.

## [0.2.0] - 2026-08-12

- Added the Acquisition Wizard, Smart Live Stack, Mesh Drift Correction, the
  per-channel histogram/Curves tab, ZWO gain/offset presets, ST4 pulse guiding,
  the exported-files viewer, GPU streak masking, the RGB24 pipeline, drift
  reduction, SER recording, and planetary presets — see Unreleased above for
  the detailed breakdown (all now folded into this release).
- Fixed a capture-ROI bug always landing at the sensor's top-left corner
  (added manual size/center entry), a small-ROI live-view flicker/slowdown, a
  live-view slowdown regression, and a GPU sharpness-scorer hang from a
  missing resolution cap.
- Fixed Live Stack and Lucky Imaging for iPhone/webcam (RGB24) sources, and
  rejected drift-lock candidates that were actually huge overexposed blobs.
- Fixed three CI build failures under Xcode 16.4's stricter Swift 6
  concurrency checking.
- Added example photos/recordings.

## [0.1.12] - 2026-08-10

- First working version: native macOS live capture from a ZWO ASI camera over
  USB, tested against real hardware for the first time.
- iPhone-as-capture-source support with a frame-stacked Night Mode.
- In-app Help system and general GPU pipeline improvements.
- Assorted bug fixes from the initial field-testing pass.
