# Changelog

All notable changes to Skyformac are documented here, newest first. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
plain `MAJOR.MINOR.PATCH` without a strict semver contract, since this is a
single-developer app, not a library with a public API.

**[Unreleased]** is the `master`/dev branch — updated continuously as work lands,
with everything folded under a proper version heading (and dated) only once it's
actually tagged. Tags on GitHub: [v0.3.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.3.0),
[v0.2.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.2.0),
[v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12).

## [Unreleased]

### Added
- **Astronomy Knowledge** (Settings) — a user-editable folder of plain `.md`
  reference files (Messier/bright-object seasons, planet/Moon visibility
  mechanics) folded into every AI panel request, grounding a small local
  model (`qwen3:8b` and similar) in real astronomy facts instead of guessed
  ones. Add/edit/delete files directly in Finder; **Restore Default
  Content** resets just the shipped defaults, leaving anything else added
  untouched.

## [0.3.0] - 2026-08-14

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
  - **Multi-session AI project planning** — "the nicest Messier objects visible
    in August" becomes one session per object in a single plan; the AI asks a
    single clarifying question first if it genuinely needs one (an unclear
    date range, an ambiguous location) instead of guessing.
  - **Ask AI to Describe…** — a grounded, editable plain-English description
    for a project or session, applied as either its goal (**Set as Aim**) or a
    dated note (**Add as Note**).
  - **AI panel** (renamed from "Assistant") — a chat panel on the right of
    every page, grounded in the current project/session, the connected
    camera, an Insights snapshot, and (new) your own ratings/favorites/top-
    rated past actions. Can propose creating a project/session or changing
    camera settings, always behind an Approve/Reject card. Resizable sidebar
    width, a multi-line compose field, a model picker (also in Settings) that
    lists whatever's actually installed on the configured Ollama server, and
    an editable server URL. Forced detached (never embedded) while a camera
    session is running, returning to the sidebar automatically once you're
    back to browsing if that's where it was before.
  - **Ratings (1-5 stars) and favorites** for projects, sessions, and
    individual captures — favorites sort to the top of their lists.
  - **Equipment systems now persist as files** (one JSON file per system,
    under a configurable Equipment folder in Settings) instead of
    `UserDefaults`, migrating any existing systems automatically the first
    time.
  - **"Ideas for Next Time" is AI-computed** when Ollama is reachable, falling
    back to the existing catalog-derived list otherwise — never an empty
    state either way.
  - **A configurable AI "skill" for suggesting a full next session** (name,
    goal, objects, and project — not just an object), shown as a "Suggested
    Session" card on the Dashboard; the standing instructions behind it are
    editable in Settings without touching a prompt in code.
  - **Atlas view** — a third Projects-page view alongside the thumbnail grid
    and table: every session across every project plotted by its target's
    real sky position (the app's own bundled Messier/bright-star catalog),
    filterable by project/object/date range, with tap-to-open navigation.
  - **Save As Project…**/**Load Project…** (File menu) — package/unpack a
    whole project folder (metadata, sessions, captures) as one `.zip`, for
    sharing a project across users/machines; an imported project always gets
    a fresh identity so it can never collide with one already in the library.
  - **"Show All Projects"** (Project menu) and a dedicated **Equipment** menu
    (View/Add New…) in the menu bar.
  - Bulk select on the Projects page (Archive/Delete over a whole selection).
  - Ollama connectivity diagnostics in Settings (**Test Connection** — checks
    both reachability and which models are actually installed, reporting
    exactly which one would be used).
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
- The Camera and Sidebar Tab menu-bar menus now only appear while a camera
  session is actually running, instead of always showing (often nonsensical)
  items regardless of what page is open.
- Removed the Home page's "Settings" tile from Common Tasks — Settings stays
  reachable from the toolbar button and ⌘,.
- Home page's "Common Tasks" cards (Equipment/Insights/Settings) now share a
  uniform width with New Project/All Projects, instead of each sizing itself
  to its own title/subtitle text length.

### Fixed
- Ollama planning calls failing against a real (non-mocked) server, and
  requests timing out against a slower local reasoning model.
- Blank frames no longer get written into `.ser` recordings.
- Night Mode no longer tints the live image itself, only the surrounding UI.
- Removed the "SDK x.x.x" connected/disconnected toolbar badge — reported as
  not useful; connection state is already shown contextually elsewhere.
- Fixed the Insights/Dashboard activity chart showing phantom past-dated ticks
  for months with no real activity (a continuous date axis interpolating gaps
  between real data points; now a categorical month axis).
- Fixed the Atlas view crashing the app immediately on open — an invalid
  reversed axis range (`360...0`) that trapped at runtime.
- Cleared a GitHub Actions Node.js 20 deprecation warning (`actions/checkout`
  bumped to a Node 24 release).
- Widened a UI test's timeout after an isolated CI scheduling flake.

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
