# Changelog

All notable changes to Skyformac are documented here, newest first. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
plain `MAJOR.MINOR.PATCH` without a strict semver contract, since this is a
single-developer app, not a library with a public API.

**[Unreleased]** is the `master`/dev branch — updated continuously as work lands,
with everything folded under a proper version heading (and dated) only once it's
actually tagged. Tags on GitHub: [v0.4.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.4.0),
[v0.3.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.3.0),
[v0.2.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.2.0),
[v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12).

## [Unreleased]

### Added
- A bundled `Fix Gatekeeper Warning.command` script alongside `skyformac.app` in both the
  `.zip` and a new `.dmg` release — moves the app into `/Applications` (avoiding macOS App
  Translocation, which otherwise silently breaks Camera permission prompts for the iPhone/
  webcam source), clears the quarantine flag, and resets the Camera TCC permission in one step.
- A signed-adjacent, drag-to-Applications `.dmg` installer alongside the existing `.zip`.
- GitHub community health files (Code of Conduct, Contributing, Security policy, Support doc,
  issue templates, PR template) and Discussions enabled.
- A brief flash + shutter sound on every successful capture — pressing the capture button
  previously gave no feedback at all that anything happened.
- Captures now crop to match the live preview's on-screen zoom for PNG/TIFF exports (raw FITS
  stays full-frame, to keep the Bayer pattern's alignment intact for calibration/stacking).
- Disk usage shown per project, session, and capture throughout the Projects browser and
  Settings; a new **Delete…** action on individual captures (file + thumbnail + record) to
  reclaim space without deleting a whole session.
- Settings reorganized into tabs (**Folders / Rendering / AI / Storage / Community**) and
  enlarged to make room — **Storage** manages disk usage across every project; **Community**
  shows this repo's open/resolved GitHub issues live, with a one-click "Report an Issue…".

### Fixed
- FITS "Record to Disk" had no guard against a genuinely blank/flat frame reaching the file,
  unlike the `.ser` recorder — one such frame in a sequence was enough to trip Siril's "MAD is
  null. Statistics cannot be computed." during stacking. Now shares the same guard `.ser`
  recording already had.
- The AI chat panel's visible/minimized/detached state was in-memory only, so closing it (e.g.
  on the camera page) didn't survive a relaunch — now persisted like every other preference.

## [0.4.0] - 2026-08-15

### Added
- **Astronomy Knowledge** (Settings) — a user-editable folder of plain `.md`
  reference files (Messier/bright-object seasons, planet/Moon visibility
  mechanics) folded into every AI panel request, grounding a small local
  model (`qwen3:8b` and similar) in real astronomy facts instead of guessed
  ones. Add/edit/delete files directly in Finder; **Restore Default
  Content** resets just the shipped defaults, leaving anything else added
  untouched.
- The AI panel now includes the current date/time and observer location
  (session's, else project's, else the last GPS fix) in every request, and
  the **Caldwell catalog** (109 objects, Patrick Moore's "beyond Messier"
  complement) alongside Messier in the bundled sky catalog — used by the
  Atlas view, `SkyAtlasLookup`, and the Filters popover's object list.
- A **Stop** button next to the AI panel's "Thinking…" indicator cancels an
  in-flight request; replies now render as Markdown instead of literal
  `**asterisks**`; AI planning/chat failures are logged to the Application
  Log, not just shown inline.
- **Multi-session AI chat history** — create a new conversation, browse/
  rename/delete past ones, and resume exactly where one left off; each is
  persisted as its own file (same "one file per item" shape as Equipment).
- **Streaming AI responses** — replies (including "Ask AI to Describe…")
  now stream in live instead of a bare "Asking Ollama…" spinner for the
  whole wait, and a configurable **Max Response Length** (Settings) bounds
  how long a single reply may generate.
- **Camera Settings** on the Capture detail page — every field of that
  specific capture's own settings snapshot (mode, gain, exposure, ROI,
  drift reduction, Smart Live Stack, Lucky Imaging burst count, SER
  duration), previously recorded but never shown anywhere.
- **Previous/Next Capture** buttons directly overlaid on the capture image
  itself, and **Open Previous Session** (only "Open Next Session" existed
  before) in the Project menu.
- **Open**/**Open in Viewer** buttons on the Capture detail page for SER/
  recording/other non-image captures — FITS reuses the app's own real
  viewer, everything else opens in whatever the system already handles it
  with.
- **Zoom (like the Histogram) and manual entry** on the Gain and Exposure
  sliders, for dialing in an exact value directly instead of only dragging.
- **Move a session to a different project**, and **Next/Previous**
  navigation on the Project, Session, and Capture pages.
- A **zoomable, project-wide Activity Timeline** chart, and real session
  times (not just a bare date) on session cards.
- The camera view's toolbar now shows the running session's planned
  objects, so "what am I supposed to be pointing at" doesn't require a
  trip back to the session page.
- Captures now **auto-save directly into the active session's own folder**
  — no folder-choice dialog — named `<object>-<date>-<time>` (e.g.
  `M13-2026-08-15-213045.fits`); the app already organizes captures by
  project/session, so asking again was a redundant step. Falls back to the
  old save panel only when no session is active to organize into.
- **Developer ID + notarization distribution** set up (`make release`,
  `docs/distribution.md`, a Homebrew Cask template) — Skyformac ships as a
  signed `.dmg` via GitHub Releases, not through the Mac App Store; see
  `docs/app-store-readiness.md` for why that path isn't being pursued.
- README: a development-status notice, a **Screenshots** gallery of the
  app itself, and links to the project's [website](https://giulioroggero.github.io/skyformac-website/)
  and `docs/distribution.md`.
- Credited [Stellarium](https://stellarium.org) for the bundled Messier/
  Caldwell/bright-star catalog data (GPLv2) in `THIRD_PARTY_NOTICES.md`.

### Changed
- Removed "Ideas for Next Time" (the bare-object-name suggestion list) from
  the Dashboard and Insights pages — the AI panel chat is the intended
  place to ask what to look at next, and the Dashboard's own "Suggested
  Session" card already covers the same ground with a fuller answer.
- Reduced the Projects browser/Dashboard's minimum width so the whole
  window (browser + AI sidebar) can no longer be forced wider than a
  1024pt-wide screen — on a smaller display this previously pushed the
  Settings toolbar button and the rightmost "Common Tasks" tile out of
  reach entirely, not just visually cramped (caught via two CI-only UI
  test failures that never reproduced locally, tracked down by downloading
  and inspecting the actual `.xcresult` from a failed run).
- The AI panel's Minimize/Detach/Close/Dock header buttons are icon-only now
  (a tooltip on hover), instead of showing text labels alongside the icons.
- Reduced Focus Assist/Planetary Tracking/Streak Detection's per-frame
  analysis cadence and the diagnostics poll interval as a modest, easily
  reverted energy tweak.
- Internal refactoring, from a full-codebase audit for dead code,
  duplication, and performance: the Gain/Exposure zoom+manual-entry
  scaffolding collapsed into one shared generic component; a cached
  thumbnail loader replacing four separate uncached `NSImage(contentsOf:)`
  call sites; a shared root-directory-resolution helper across the
  Projects/Equipment/AI-Chat/Knowledge-Base file stores; several
  `CameraManager` helpers deduped (blocking-capture preamble, control-cap
  lookup); `StatsGridView` switched from a `Table` (whose manually-guessed
  height could clip a section with enough rows) to a self-sizing `Grid`.

### Fixed
- The AI panel failing to reopen as a detached window if closed while still
  in camera mode.
- Live GPU/CPU image enhancement (denoise, wavelet sharpening, Live GPU
  Controls) applying to the *next* captured frame instead of the one
  currently on screen when a setting changed.
- Live Stack's display stretch never re-adapting as the accumulated stack's
  own signal-to-noise improved, so it didn't visibly brighten.
- `AcquisitionMode` mislabeling a plain single exposure (neither Live Stack
  nor a Lucky Imaging burst) as "Lucky Imaging" in history/Insights.
- A GPU scratch-texture allocation failure could silently skip the final
  render stage, freezing the live preview with no error shown.
- The Camera Error alert's dismiss button was a no-op — a dismissed error
  could silently reappear on the next unrelated re-render.
- "Move to Project…" swallowing a failed move and navigating away as if it
  had succeeded; `ProjectStore`'s delete/move helpers could otherwise leave
  a session's on-disk files orphaned or a `CaptureRecord` pointing at a
  file that no longer existed.
- Unplugging a camera or losing a webcam mid-recording didn't stop/finalize
  an in-progress SER/FITS recording, risking a corrupted file on reconnect.
- Any camera streaming error other than "removed" silently froze live view
  with no error shown and no way to resume without a full reconnect.
- AI-created projects/sessions (and Quick Start) reported success even when
  the underlying disk write actually failed.
- A previously-latent bug in the shared Xcode scheme (`buildForArchiving`
  left on for the test targets) that made every `xcodebuild archive`
  attempt fail outright — found while setting up the release process.

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
