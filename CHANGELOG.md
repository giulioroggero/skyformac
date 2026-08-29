# Changelog

All notable changes to Skyformac are documented here, newest first. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
plain `MAJOR.MINOR.PATCH` without a strict semver contract, since this is a
single-developer app, not a library with a public API.

**[Unreleased]** is the `master`/dev branch — updated continuously as work lands,
with everything folded under a proper version heading (and dated) only once it's
actually tagged. Tags on GitHub: [v0.6.2](https://github.com/giulioroggero/skyformac/releases/tag/v0.6.2),
[v0.6.1](https://github.com/giulioroggero/skyformac/releases/tag/v0.6.1),
[v0.6.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.6.0),
[v0.5.3](https://github.com/giulioroggero/skyformac/releases/tag/v0.5.3),
[v0.5.2](https://github.com/giulioroggero/skyformac/releases/tag/v0.5.2),
[v0.5.1](https://github.com/giulioroggero/skyformac/releases/tag/v0.5.1),
[v0.5.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.5.0),
[v0.4.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.4.0),
[v0.3.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.3.0),
[v0.2.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.2.0),
[v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12).

## [Unreleased]

### Added
- "What to See" now also lists the Moon and every naked-eye planet that clears the minimum
  altitude, each with its rise/peak/set time, alongside the deep-sky catalog results — and every
  result row (deep-sky or planet) opens a detail sheet on tap showing when it rises, peaks, and is
  no longer visible.
- That detail sheet can also show a Wikipedia description and photo — a new "Online Object Info"
  toggle in Settings › AI (off by default) gates this, since it's the only place Skyformac makes a
  live network request; "Search on AstroBin…"/"Search r/astrophotography…" just open your browser
  and work regardless of that toggle. First phase of a larger planned integration (Gaia/HYG for
  precise stellar data, exoplanet catalogs, SDSS SkyServer imagery still to come).
- A new "What to See" page: pick a date, a location (or "Use Current Location"), and a minimum
  altitude, and it scans the bundled Messier/Caldwell/NGC catalog against that night's actual dark
  window to list every object that clears the threshold from there, sorted by how high it peaks
  and when. Each result can directly become a new project, a new session added to an existing
  project, or launch straight into the camera view against an existing session — no need to look
  the object up separately and start from scratch. Also shows the Moon's phase for the selected
  date and any planet/Moon conjunctions (naked-eye planets plus the Moon passing within 5° of each
  other) within a week of it, from a new low-precision planetary position model
  (`PlanetaryPositionCalculator`) — real satellite passes (the ISS, say) need frequently-updated
  orbital data this app has no source for, so those are left out rather than faked.
- A new menu-bar item ("Sky Tonight"): at a glance, without opening the main window, see whether
  tonight's actually dark from your set location, the Moon's phase, and which of your existing
  sessions' planned objects clear the horizon tonight.
- The Gallery page's toolbar was missing the "Home" button every other browser page already has
  next to "Back."
- Opening an elaborated image full-screen (from the Gallery, a project, or a session's own gallery)
  now has Previous/Next controls (arrow buttons or the ← / → keys) to step through every other
  image in that same grid without closing the viewer. "Set as Thumbnail" and the "More" menu stay
  scoped to whichever image was actually opened, since navigating away lands on a different image's
  project/session context those actions don't apply to.
- The Equipment page's toolbar was missing the "Home" button every other browser page already has.
- Every "Common Tasks" tile is 35pt narrower, so all 8 fit in one row without needing to scroll;
  reordered to Quick Start, New Project, All Projects, What to See, Gallery, Equipment, Insights,
  Guiding Log.
- "What to See" results now show each object's type (with a representative icon — see this
  session's own note on why not a real per-object photo), magnitude, and peak time, and the list
  can be sorted (name, type, magnitude, peak altitude, peak time, either direction) and filtered by
  type.
- A new "Guiding Log" page: import a PHD2 `.log` file (this app has no autoguiding loop of its own
  to generate one from) and see RMS/peak RA and Dec error, a chart of guide error over time, an
  RA/Dec orthogonality readout (are the two axes actually guiding independently, or is there real
  cross-talk pointing at a guide camera that isn't square to the mount), and a periodogram to spot
  worm-gear periodic error and its period.
- Edit Image gains Undo/Redo buttons (⌘Z/⇧⌘Z) — every adjustment slider and crop edit is now
  undoable, coalesced per gesture rather than one entry per intermediate slider tick.

### Fixed
- A project/session page's Cover thumbnail column had an ambiguous horizontal alignment
  (`.frame(width:)` with no explicit alignment) — made explicit as `.leading` to match the Stats/
  Equipment/Tags row below it.
- `nightWindow` (the dark-window calculator behind "What to See"/Sky Tonight) returned "no window"
  for a location in deep polar winter — the Sun never climbing back above the twilight threshold
  within the scanned 24h was treated the same as it never *dropping* below it (polar day), when
  it's the opposite case: permanent darkness. Now correctly reports the rest of the scan as dark.
- Planetary Post-Processing's "AI Suggest Settings" failing with a generic "the model's reply
  didn't contain a usable plan" gave no clue why. It now shows the model's own raw reply instead,
  so a non-vision-capable model answering in prose (the actual, confirmed failure mode) is
  immediately obvious rather than a dead end.
- Edit Image: a slider adjustment made *after* AI Enhance (which bakes in an "AI - Sky For Mac"
  watermark) was rendering that adjustment on top of the watermark's own pixels, distorting it.
  The watermark is now removed before further edits render and reapplied as the very last step
  instead, on both the live preview and the saved file.

## [0.6.2] - 2026-08-29

### Added
- Capture Detail's AI chat can now actually see the capture currently on screen (a JPEG snapshot,
  the same vision-grounding Edit Image's own AI Assistant already does) — "what is that?" gets a
  real answer instead of only ever guessing from surrounding metadata. Updates automatically when
  stepping through captures with Previous/Next.
- The AI Assistant panel gains a genuine full-screen mode (filling the whole window, not opening a
  second OS window) via a new toggle button in its header, alongside a redesigned empty state: a
  brand-new conversation shows a centered, 4-line-tall composer instead of the same cramped
  bottom-anchored input bar a populated conversation uses; the input can always grow past its
  starting height as a message gets longer.
- "New Chat" is now its own icon-only button, to the left of the history button, instead of being
  buried as the first item inside that menu.
- The sidebar AI assistant's context and action vocabulary is extended beyond project/session/
  camera facts: it now knows the current Live Stack/Lucky Imaging state (method, frame count,
  gain/exposure/mode, GPU vs CPU render path), a summary of the Gallery (elaborated image count,
  most recent titles), and which equipment system is assigned to the current project. It can also
  now *propose* (always with an Approve/Reject confirmation, like every other assistant action)
  starting/stopping Live Stack, starting a Lucky Imaging burst, stacking an already-completed
  burst's sharpest frames, and creating a new equipment system.
- The assistant panel is now reachable from the Gallery and Equipment pages too (previously only
  Home, Project, Session, Capture, and the live camera view).
- Settings gains an "AI Enhance Model" picker for Edit Image's AI Enhance — previously hardcoded to
  `gemini-2.5-flash-image`; now choose among every current Gemini image-generation model
  (`gemini-2.5-flash-image`, `gemini-3.1-flash-lite-image`, `gemini-3.1-flash-image`,
  `gemini-3-pro-image`).
- Planetary Post-Processing's "Set Up Stacking" step gains an "AI Suggest Settings" button — sends
  a representative frame to the AI, which identifies whether it's a planet/the Moon or a deep-sky
  target and proposes matching keep-best-percent, stack method, per-layer wavelet gains, denoise,
  RGB channel alignment, black/white point, and log stretch settings; shown as an Approve/Dismiss
  card, never applied until approved.
- Settings gains a new "AI Instructions" tab: every distinct AI task's system instructions (session
  and project planning, the sidebar assistant, Planetary Post-Processing's stacking suggestions,
  Edit Image's assistant, "Ask AI to Describe…", tag suggestions, and the existing "suggest next
  session" skill) are now visible and directly editable there, each with its own "Reset to Default."

### Fixed
- The sidebar assistant surfaced "the model's reply didn't contain a usable plan — try again, or
  try a different model" for perfectly normal conversational questions (confirmed live: "what is
  the best session?") whenever the model ignored the "respond with ONLY a JSON object" instruction
  and just answered in plain prose. Falls back to showing that plain-text answer directly instead
  of treating it as an error.
- The AI Enhance-produced watermark ("AI - Sky For Mac") was too opaque, standing out more than
  intended against the image. Both the label and its background box are now noticeably more
  transparent.
- Zooming or comparing Original/Edited in the single-image post-processing editor drifted the image
  toward the bottom-left instead of zooming/staying centered — a `ZStack(alignment: .topLeading)`
  meant for a small corner label was misaligning the whole image underneath it too. The label now
  gets its own `.overlay(alignment: .topLeading)` instead, leaving the image itself centered.
- The sidebar assistant had no idea what project/session was actually open while just browsing
  (not recording) — "what's the best capture in this session?" asked from a Session page got "I
  don't have any information about what's been captured in this current session," since the
  context builder only ever looked at the live-recording session, never the one on screen. Project
  and Session detail pages now tell the assistant what they're showing.
- Two CI-only UI test failures (`testEquipmentTileOpensTheEquipmentPage`,
  `testInsightsTileOpensTheInsightsPage`): on CI's narrower 1024×768 virtual display, the "Common
  Tasks" tile row's later tiles sit partly behind the AI sidebar, and `XCUIElement.isHittable`
  wrongly reported them tappable there — the synthesized tap landed on the sidebar instead of the
  tile. Tile taps for that row now check the tile's actual on-screen frame against the scroll
  view's own frame before tapping, a real geometry check instead of trusting the accessibility
  layer's hit-test result.

## [0.6.1] - 2026-08-29

### Added
- Edit Image's "AI Enhance" now uses whatever's typed into the chat bar's own text field as its
  instruction ("remove the gradient and boost the nebula's red," say) instead of only a generic
  "just improve this" — one field, and either the Send button or AI Enhance acts on it, recorded
  into the chat transcript either way so the bar reads as one continuous conversation.
- An imported plain video file (`.mov`/`.mp4`/`.m4v`, from "Import…") can now be opened with
  "Post-Process…" the same way a `.serVideo` capture already could — `VideoFrameReader` decodes it
  into the same frame shape `SERReader` produces for a `.ser`, so the existing registration/
  stacking pipeline (`PlanetaryPostProcessor`) works on an imported video without needing its own
  separate editor. Imported still images (`.fits`/`.png`/`.tiff`, including JPEG/HEIC) were already
  fully editable via "Edit Image…" — only imported video was actually missing this.
- Edit Image gains an **AI Assistant** section, grounded in the actual image currently shown in
  the preview (not just a text description of the sliders) — attaches a JPEG of the live preview
  to every question sent to whichever AI provider is set in Settings, so it can answer "what's
  wrong with this image" or propose a specific set of adjustment slider values from what it
  actually sees, shown as an Approve/Reject card like the sidebar assistant's own proposals — never
  applied until you tap Apply. A local Ollama model needs to itself be vision-capable (e.g.
  `llava`, `llama3.2-vision`) to actually see the attached image.
  Also adds **AI Enhance** (Google Gemini only, `gemini-2.5-flash-image`) — sends the image to
  Gemini's own image-generation model for a genuine AI-regenerated result, not this app's own
  filters, since neither Anthropic's nor a local Ollama model's API can output an edited image at
  all. The result is watermarked "AI - Sky For Mac" in its bottom-right corner so anyone looking at
  a shared image afterward can tell it wasn't purely this app's own deterministic tools.
- Settings' Google Gemini provider gains a "Use Vertex AI" toggle — routes every Gemini request
  through a GCP project's Vertex AI endpoint instead of the plain Gemini API, authenticated with an
  imported service-account JSON key rather than a simple API key. Vertex has no `?key=` auth at
  all, so this signs its own OAuth2 JWT Bearer assertion from the service account's private key
  (`VertexServiceAccountAuthenticator`) and exchanges it for a real access token — no `gcloud` CLI
  or Google Cloud SDK dependency, just `URLSession` and the Security framework.
- Edit Image and Planetary Post-Processing's "Single Shot" tab gain an **AI** section with two
  on-device Core ML tools, both GPU/ANE-accelerated and run off the main thread:
  - **Remove Cosmic Rays** — a Core ML conversion of [deepCR](https://github.com/profjsb/deepCR)'s
    cosmic-ray mask model (BSD-3-Clause), repairing flagged pixels with a median-filtered fill.
  - **Tikhonov Deconvolution** — regularized deblurring (Landweber iteration) via Accelerate/vDSP,
    a smoother, more noise-robust alternative to the existing Richardson-Lucy Deconvolution slider.
  See `SBOM.md`/`THIRD_PARTY_NOTICES.md` for exactly what's bundled and its license.
- Settings gains an AI Provider picker — Ollama (local, the existing default) or, with your own
  API key stored in the macOS Keychain, Anthropic Claude or Google Gemini — for the sidebar
  assistant and session-planning features.
- A session's Timeline gains "Import…" — adds pictures or videos you already have (Finder files,
  a whole folder, or Apple Photos) directly as captures, alongside whatever the camera itself
  produced. A new `.video` capture kind covers a plain imported video file, distinct from this
  app's own `.ser` planetary format or a continuous-recording folder.
- Session Timeline/Table's bulk action bar gains "Stack…" alongside "Compose Mosaic…" for 2+
  selected PNG/TIFF/FITS captures — aligns and averages same-field-of-view captures
  (`StillImageStacker`, reusing `MosaicComposer`'s star-pattern registration) for a better-SNR
  combine, rather than stitching them side by side into a wider frame.
- The elaborated-image/capture full-screen viewer (`FullScreenImageViewer`) gains explicit Zoom
  In/Zoom Out/Fit to Window buttons — pinch/scroll-wheel zoom already worked via `NSScrollView`,
  but nothing on screen said so, and there was no way to re-fit after zooming/panning away from
  the auto-fit that only ever ran once when the image first appeared.
- Edit Image gains Photos.app-equivalent Vibrance and Warmth/Tint white-balance sliders
  (`CIVibrance`/`CITemperatureAndTint`) — a smarter saturation boost that protects already-vivid
  star colors, and a sky-glow/moonlight color-cast fix independent of the existing green-cast
  SCNR tool.
- Edit Image (and Planetary Post-Processing's "Single Shot" tab) gain "Remove Background
  Gradient" — samples plain sky background away from stars/nebulosity, fits a smooth 2nd-order
  gradient, and subtracts it (`GradientExtractor`), the light-pollution/vignetting removal step
  previously only reachable by handing the image off to GraXpert.
- "Reduce Star Size" now scopes its erosion to just the detected star locations
  (`ImageEditor.computeStarMask`) instead of eroding the whole image uniformly — nebulosity/
  galaxy structure away from any star is left completely untouched instead of being softened
  right along with the stars.
- Edit Image gains a Deconvolution sharpening control (Richardson-Lucy, modeling the blur as a
  Gaussian PSF) alongside the existing unsharp-mask Sharpen — recovers detail a real point-spread
  function (seeing, focus, diffraction) actually destroyed, instead of just boosting existing
  edge contrast.

### Changed
- Debug (local development) builds now store API keys/service-account credentials in a plain file
  under `~/Library/Application Support/Skyformac` instead of the macOS Keychain — an ad-hoc-signed
  dev build has no stable Team ID, so every rebuild is a "different" app from the Keychain's own
  access-control perspective and it re-prompts for access on every relaunch after a rebuild no
  matter how many times "Always Allow" is clicked. Release builds (the actual distributed app)
  are unaffected and keep using the real Keychain.

### Fixed
- "Remove Gradient" could take minutes on a full-resolution image with no progress feedback at
  all, reading as a hang — its per-pixel correction pass allocated a fresh 6-element array (and
  built a `zip`/`reduce` iterator) for every single pixel, three times over. Replaced with direct
  polynomial arithmetic over an unsafe buffer, the same "expensive per-pixel work with no fast
  path" root cause and fix shape as this session's earlier Tikhonov Deconvolution hang.
- Edit Image's AI Assistant chat bar was buried at the very bottom of the sidebar's own long
  scrollable sliders list — easy to miss entirely, reading as "this page has no chat" rather than
  "scroll down for it." It's now a persistent bar spanning the full window, below both the preview
  pane and the sidebar, always visible regardless of scroll position — the same place AI Enhance
  now lives too. Also reuses the sidebar assistant's own Markdown-rendering/bubble styling
  (`ChatBubbleRendering`, factored out of `AssistantChatPanel`) instead of a separate, plainer copy.
- Google Gemini's default model, `gemini-3.0-flash`, was never a real model ID — confirmed live:
  Gemini's API rejected every request with "models/gemini-3.0-flash is not found." Defaults to
  `gemini-2.5-flash` now, a real, stable, generally-available model ID.
- Vertex AI requests 404'd outright — the default region (`us-central1`) doesn't serve current
  Gemini models at all; confirmed live, most of them are only available from Vertex's "global"
  location, which also needs an unprefixed host (`aiplatform.googleapis.com`, not
  `global-aiplatform.googleapis.com`). `global` is now the default; a specific region is still
  honored for the older/regional-only models that do support one.
- Vertex AI rejected every Gemini request with "Please use a valid role: user, model." — the
  request's own `contents` entry never included a `role` field at all; the plain Gemini API
  silently defaults a missing one to `"user"`, but Vertex's own validator doesn't. Every Gemini
  request now sends `"role": "user"` explicitly, working the same way against both.
- "Remove Cosmic Rays" could crash the app outright (`EXC_BAD_ACCESS`) on a Mac with an ANE —
  the code assumed the Core ML model's output was always a packed `Float32` buffer, but which
  compute unit (ANE/GPU/CPU) actually ran the model — which varies by hardware — can change both
  its element type and its memory layout. Now branches on the array's own reported type and
  indexes via its own strides instead of assuming a fixed layout; a second, subtler miscalculation
  this surfaced (using the array's logical element count as if it were the physical buffer's
  capacity, silently dropping real pixels near any padded row) is fixed too.
- "Tikhonov Deconvolution" could take minutes on a full-resolution image with no progress feedback
  at all, reading as a hang — its Gaussian blur pass has been replaced with a single native
  `vImage` convolution instead of a hand-rolled row/column loop whose column pass was extremely
  cache-unfriendly; the same test image now completes in a couple of seconds.
- The Edit Image sidebar's Auto-Fix button row (Magic Wand/Center Object/Remove Background
  Gradient/Reset/Compare) had grown too many long-labeled buttons for one line and become
  unreadable — now two buttons per row, with Compare to Original on its own row below. The AI
  section's own two buttons (also long-labeled) are now one per row, full width. Both sections
  moved to the very end of the sidebar (after every other adjustment), and Compare mode's split
  view now supports the same pinch-zoom/drag-to-pan as the normal preview, sharing one zoom/pan
  state between both halves — moving one moves the other, and the zoom level survives toggling
  Compare on and off.
- Settings' Anthropic/Gemini API Key field only saved to the Keychain on pressing Return
  (`.onSubmit`) — typing a key and simply closing Settings left it unsaved, so the next request
  went out with an empty key and Anthropic's API reported it as "x-api-key header is required,"
  which reads like the key was never entered rather than just never saved. Now saves as you type,
  same as every other Settings field.
- "Compose Mosaic…" only ever worked on starfields — `MosaicStarMatcher`'s point-source matching
  had nothing to grab onto on a Moon mosaic's crater/terminator detail or a plain terrestrial
  photo, so those tile sets always failed to register. Falls back to Vision's own general-purpose
  homographic image registration (`GenericImageRegistrar`) whenever a tile pair has too few
  matchable stars — locks onto whatever real structure the content offers instead, so a lunar or
  terrestrial mosaic composes the same way a starfield one always did.
- Edit Image's Auto-Fix section had Reset and Compare to Original crammed awkwardly into the
  button grid — Reset now sits beside the "Auto-Fix" title itself, and Compare to Original fills
  the slot next to Remove Gradient, both freeing up a cleaner two-per-row button grid.
- `scripts/build_astro_catalog.py`'s own header comment (and this changelog/SBOM) incorrectly
  cited Stellarium's bundled DSO catalog data as CC-BY-SA-4.0 — verified against Stellarium's own
  `COPYING`/`CREDITS.md`: the catalog data is GPLv2 (CC-BY-SA-4.0 only applies to specific
  texture/image assets elsewhere in that project). `THIRD_PARTY_NOTICES.md`'s existing GPLv2
  characterization was already correct.
- "Compose Mosaic…"/"Stack…" failed outright with a cryptic `CGImageRenderer.LoadError` if any
  selected tile was corrupt/unreadable (e.g. an interrupted write) — unreadable tiles are now
  skipped and named in the UI instead, only failing if fewer than 2 usable tiles remain.
- "Stack…" could composite a tile at the wrong position/rotation — visible as a ghosted
  rectangle in the result — when a dense field (a globular cluster, a rich Milky Way star field)
  gave the star matcher enough candidate triangles to genuinely fit a real-but-wrong transform
  between two captures that don't actually correspond. A fitted alignment implausible for
  same-field captures (large rotation/scale/translation) is now rejected and the tile skipped,
  and the star matcher requires more corroborating votes for this path.
- A change made from a detached window — most visibly "Set as Thumbnail" from a capture's or an
  elaborated image's full-screen preview — didn't show up on the Project/Session/Capture page
  still open underneath until it was left and reopened. Each page now reads its project/session/
  capture live from the shared library on every render instead of trusting the value snapshot it
  was originally pushed with.
- The elaborated-image viewer opened at its own smaller, independently hardcoded window size
  instead of matching every Edit Image/Post-Processing/Mosaic window.
- `GPUFrameCalibratorTests` (and other suites dispatching Metal kernels directly) could fail
  intermittently in CI — several tests submitting GPU command buffers concurrently against each
  other, not a bug in the kernels themselves. Those suites now run their own tests serially;
  `make test` also retries a failed test up to 3 times as a backstop for other transient CI
  contention.

## [0.6.0] - 2026-08-27

### Added
- Post-Process buttons (the Capture page's prominent one, and the session Timeline's bulk "Post-
  Process Together…") now show a spinner and disable themselves the instant they're clicked,
  until their window actually opens — "show a loader until the modal is shown, for GB files it
  takes some time to load."
- Session page follow-up to the earlier Dashboard density fix: History/Equipment/Stats/Tags/Notes
  group into a "Details" cluster, Elaborated/stray-files into "Extras" (both collapsible, both
  reusing the same `PageSectionCluster` the Dashboard's own clusters use — extracted as a shared
  component instead of a second copy). "Recent Projects" and "Highlighted Sessions" no longer show
  the same single-session project's activity twice. "New Project…" gets the same hover tooltip
  every other Projects-browser toolbar button already had.
- Sky Atlas improvements: points are now grouped by object (not one dot per session — every
  session on the same object shares one point), sized by how many sessions have targeted it — a
  quick "where have I actually spent my time" read instead of stacked identical dots with no way
  to tell "shot once" from "shot a dozen times." Each point is labeled with its object name.
  Selecting one now shows every session that targeted it (not just one). A shaded band shows
  roughly what's up overnight (opposite the Sun — `SolarPosition`, a real if deliberately rough
  low-precision solar-position formula, no location data needed), turning the atlas from a static
  "where have my sessions been" chart into a rough "what's worth pointing at tonight" one too.
  Catalog coverage also grew — a new bundled NGC/IC subset (254 objects, V mag < 9.0, extracted
  from the same real Stellarium DSO catalog Messier/Caldwell already came from, excluding anything
  already covered by those two) means far fewer sessions land in "Not Shown on the Atlas."
- Whole-app UX/simplification pass, from a self-review: the Dashboard's 7 independently-stacked
  sections (a real returning user with history saw every one of them at once, the densest screen
  in the app) are now organized into named, collapsible "Explore" (Observation Timeline/Recent
  Projects/Highlighted Sessions) and "Insights" (Activity/Suggested Session) clusters — "Resume
  Where You Left Off" and "Common Tasks" stay top-level since those are what's reached for first.
  Nothing is hidden by default, only grouped; a returning user who wants less scrolling can
  collapse a cluster they don't need right now. The Projects browser's "Atlas" view-mode segment
  (icon-only, no room for a subtitle the way a Dashboard tile has) now has a hover tooltip
  explaining what it actually shows, since "Atlas" alone assumes the reader already knows.

- UX pass on the new Mosaic feature, from a self-review of its own discoverability: "Capture
  Mosaic Tile" moved out of the Capture page's collapsed "Export" section into its own
  always-visible one — the button was undiscoverable to anyone who didn't already know to expand
  Export first. It now shows a running "N tiles captured this session" count with a direct pointer
  to the next step ("select them in the Timeline below and choose Compose Mosaic…"), closing the
  gap where capturing and composing were two disconnected surfaces with nothing linking them.
  Separately, every Planetary Post-Processing/Edit Image/Mosaic Composer window's own title now
  includes its source file/capture count (e.g. "Edit Image — moon_0042.png") instead of a bare,
  identical-across-instances name — with several of these real windows open at once now routine,
  the standard macOS Window menu's own window list can finally tell them apart.
- Mosaic capture and composition — "different parts of the Moon to get a full Moon, or different
  captures of Andromeda, composed together." A new "Capture Mosaic Tile" button (Capture page,
  right next to FITS/PNG/TIFF export — reuses the exact same `exportCurrentFrame(as: .png)` every
  other export button already calls) captures each overlapping tile; multi-selecting 2+ of them in
  the session's Timeline and choosing "Compose Mosaic…" stitches them into one larger image via
  real star-pattern (asterism) tile registration — genuinely different from
  `PlanetaryPostProcessor`'s own registration, which assumes every frame shares the *same* field of
  view and would actively reject a real tile offset as noise. Detects each tile's stars
  (`StarDetector`, already used for live focus-assist), matches them between adjacent tiles via
  triangle-similarity voting (the same technique `StarPatternRecognizer` already uses to match
  detected stars against a named catalog, generalized here to two anonymous point sets), fits a
  similarity transform (rotation/scale/translation) via closed-form least squares (the same OLS
  spirit as `LiveWCSSolver`'s own pixel<->sky fit), then composites the tiles with feathered edges
  for a smooth seam. New "Mosaic Composer" window reuses `ImageAdjustmentsControls` for the same
  touch-up pass every other post-processing screen offers, and saves into the project's Elaborated
  gallery like everything else there.
- A "Posterize" slider in Edit Image/Planetary Post-Processing's Single Shot tab (`CIColorPosterize`)
  — a stylistic finishing effect, off by default, in its own "Stylize" section since it's not a
  restoration tool like everything else there.
- A "Window" menu now offers "Tile Windows" and "Cascade Windows" — with Planetary
  Post-Processing/Edit Image/the full-screen preview each opening in a real, independently
  movable/resizable window now, having several open at once is common, and macOS has no built-in
  per-app "arrange all my windows" command (only per-window Move & Resize, and the system-wide
  Dock-icon "Tile Windows" that mixes in every other app's windows too) — the same convenience a
  multi-window code editor's own Window menu offers.
- The Capture Detail page's "File" box now shows Disk Usage (this one capture's own file size).
  Its session-wide "Stats" box (total captures, counts by kind) is gone — that's the session's own
  aggregate, not a property of the one capture this page is about; it's still on the Session page.
  "Post-Process…"/"Edit Image…" — the single most likely next action for a capture — is now a
  prominent button directly under the image, instead of a line item buried inside a long list of
  Show in Finder/Move to Session/Delete and everything else this page offers.
- Six new `SkyformacUITests` covering customer journeys the existing 9 didn't reach: the Gallery
  and Equipment Dashboard tiles, cancelling out of the New Project sheet, Settings' "Done" button
  actually returning to the underlying page, the AI panel's minimize/expand round trip, and the
  full Quick Start → active session → "End Session" → the resulting project showing up in the
  Dashboard's "Recent Projects" → opening it lands on that project's own detail page.
- A "Center Object" button in Edit Image and Planetary Post-Processing's Single Shot tab — shifts
  the image so its brightness-weighted centroid lands in the exact middle of the frame, the same
  intensity-weighted-sum idea registration already uses for a whole burst, run once here directly
  on the finished image.
- Planetary Post-Processing's Single Shot tab now shares its actual controls
  (`ImageAdjustmentsControls`) with Edit Image's own Color & Contrast/Clean Up/Sharpen/Astronomy
  Tools sections, instead of a second, separately maintained flat list of the same ~15 sliders —
  a change to one's sliders (or a bug fix in how one behaves) now automatically applies to both.
- Stacking/Restacking's log now states which one it actually used once a run finishes — "Stacking
  used the GPU"/"...used the CPU" — instead of only stating an intent ("GPU when available")
  beforehand. The same method can legitimately go either way run to run (no usable GPU in this
  environment at all, or a real GPU call that failed mid-burst and fell back), so only the actual
  outcome is a definitive answer.
- Planetary Post-Processing, Edit Image, and the full-screen image preview now each open in a
  real, independent window (`DetachedContentWindowController`) instead of a `.sheet` — a macOS
  sheet is permanently attached below its parent window's own title bar and can never be dragged
  to another position on screen or resized past what the presenting view declares, so "the
  edit/preview windows can be moved across the screen and resized" needed a genuinely separate
  window instead. Each still opens at roughly the same near-fullscreen starting size as before,
  but the window itself is now freely movable, resizable, and (via the standard Window menu)
  minimizable.
- A "Chroma Noise Reduction" slider in Edit Image's Clean Up section and Planetary
  Post-Processing's Single Shot tab — cleans up the colored speckle ("puntini colorati") long
  exposures/high gain leave in the background, distinct from the existing Denoise (which smooths
  brightness noise and would soften real detail to touch color speckle) and Remove Green Cast
  (a systematic color shift, not per-pixel randomness). Blurs only the image's color, not its
  brightness (`CIColorBlendMode` recombining a blurred copy's hue/saturation with the original's
  own luminosity), so stars and real detail stay sharp.
- An elaborated image's full-screen preview now has a "More" menu with everything its
  right-click context menu already offers (Info…, Show in Finder, Publish to AstroBin…, Redo
  from Original…, Edit Image…, Third-Party Tools, Delete…) — previously only reachable by
  right-clicking the small thumbnail, not from the preview itself.
- Planetary Post-Processing's ready-screen sidebar now has two tabs — "Video" (the existing
  Stacking/Wavelet/Color/Stretch controls) and "Single Shot Adjustments," reusing the same
  `ImageEditor` touch-up tools "Edit Image…" offers (tone, sharpen, denoise, green-cast removal,
  star-size reduction, a Magic Wand auto-fix) applied straight to the stacked result — no need to
  save first and reopen it in Edit Image separately. Recorded alongside the rest of a saved
  result's settings, and restored by "Redo from Original…" like everything else there.
- A session's capture Timeline and Table now support multi-select — a "Select" toggle on the
  filmstrip (the Table already had native ⌘/shift-click selection), feeding a shared
  "Post-Process Together…" bulk action that pools every selected `.ser`'s own frames into one
  registration/stacking run, instead of only ever being able to post-process one capture at a
  time. `PlanetaryPostProcessor.loadSequence(from:)` gained a `[URL]` overload for this; combining
  captures with mismatched frame size or color mode raises a clear error instead of silently
  producing nonsense.
- Planetary Post-Processing's setup screen now also includes the Color (Align RGB Channels) and
  Stretch (black/white point, log intensity) controls, not just Stacking/Wavelet — every
  configurable parameter is now choosable before "Start Processing," not only after. Fixed a bug
  this surfaced: `alignRGBChannels` was silently reset to the source's own color-camera flag right
  after loading, discarding whatever the user (or "Redo from Original…") had already set it to.
- Every timeline thumbnail (a session's own strip, and Home's cross-project timeline) now shows
  a small badge indicating whether it's a single still capture, an SER video, or a lucky-imaging
  recording — visible even once a real thumbnail image loads over the plain fallback icon that
  used to be the only place this showed. Tapping the badge jumps straight to post-processing that
  capture (Planetary Post-Processing for an SER video, Edit Image for a still), bypassing the
  Capture page for the common "just process this" case.
- Home's activity chart is now per-day over the last 30 days (a fixed, immediately-legible
  window), not per-month over all-time — and the chart itself is now clickable (not just the "See
  Full Insights…" text underneath it), opening Insights.
- Planetary Post-Processing and Edit Image now open genuinely full-screen (the whole visible
  screen area, not that minus a margin) — they were already sized close to it, but noticeably
  short of actually filling the screen.
- An elaborated image (its context menu, and its Info sheet) now offers two ways to
  post-process it further, alongside the existing external hand-offs: "Redo from Original…"
  re-runs Planetary Post-Processing on the actual `.ser` this result was stacked from, seeded
  with the exact settings that produced it (`ElaboratedImage.planetarySettings`), rather than
  hand-tuning every slider again from scratch; "Edit Image…" runs the already-finished PNG
  through Edit Image's own controls (crop, color, curves, sharpen), the same tool already used
  on any other PNG capture. Only offered where there's something to run it on — "Redo from
  Original…" needs the source capture to still exist and be a `.ser`.
- A new Gallery page (Home's "Common Tasks" row, or Project → Show Gallery) — every
  post-processed image across every active project, newest first, in one place instead of having
  to open each project's own Elaborated section separately to find one. Reuses the same card
  (tap to view full screen, Info sheet, Third-Party Tools menu) a project's own gallery already
  shows.
- Capture page and an elaborated image's own menus now separate Skyformac's own tools (Post-
  Process, Edit Image — favored first, since Planetary Post-Processing does its own GPU-
  accelerated registration/stacking in-app now) from anything that hands off to an external app
  (Siril, GraXpert, StarNet, PixInsight), which now live together under their own "Third-Party
  Tools" group/menu instead of mixed in with Skyformac's own actions.

### Changed
- The session Timeline's filmstrip "Select" mode toggle is now a real checkbox instead of a
  "Select"/"Done Selecting" text button — same toggle either way (on: tapping a thumbnail selects
  it instead of opening the Capture page; multi-select and "Post-Process Together…"/"Compose
  Mosaic…" already worked here, same as the Table view), just a more immediately recognizable
  control for "this is a mode, not an action."
- The "Third-Party Tools" menu (GraXpert/StarNet/PixInsight/Siril hand-off) had been copy-pasted
  three times across `ProjectDetailPane.swift` — an elaborated image's context menu, its
  full-screen preview's "More" menu, and its Info sheet's button row — a real risk of the three
  drifting out of sync (a tool added to one but not the others). Extracted into one shared
  `ThirdPartyToolsMenu`; each call site still supplies its own action closures, so this only
  unifies the menu's shape, not what any button actually does. No user-visible change.

### Fixed
- Live Capture's own frame browser (the "iPhone Live Photo"-style scrubber shown after a Live
  Capture burst) stayed stuck on a loading spinner forever when the Metal (GPU) renderer was
  active — confirmed live: a frame was selected and scored ("Frame 3 of 10 · sharpness 415.6"),
  but the preview pane stayed black. `refreshCurrentImage()` deliberately only renders
  `currentImage` in CPU mode (`MetalPreviewView` reads `currentFrame` directly in GPU mode instead,
  for the *live streaming* preview) — but `LiveCaptureBrowserView` has its own separate preview
  pane that only ever reads `currentImage`, so browsing an already-captured burst's frames in GPU
  mode had nothing to show. `showLiveCaptureFrame(atIndex:)` now renders on demand in GPU mode too
  — the same "rare, user-initiated action" fallback `currentDisplayImage()` already uses for
  export/polar alignment, costing nothing like what makes the live per-frame path skip it.
- Project thumbnails on the Projects browser's own grid didn't render at a consistent size — the
  grid's `GridItem(.adaptive(minimum: 220, maximum: 280))` let each card's own width *stretch* to
  fill leftover space in its row, so two cards in the same row could land at genuinely different
  pixel widths depending on how many happened to fit. Pinned `maximum` to the same 220 the
  Dashboard's own "Recent Projects" row already uses, so every `ProjectCard` is exactly 220×130
  everywhere it appears, not just self-consistent within one grid. (Session and capture thumbnails
  were already consistent everywhere they're shown — no bug found there.)
- **Projects could silently vanish from "All Projects."** Confirmed live on real, otherwise-valid
  projects: adding `posterizeLevels` to `ImageEditor.Adjustments` this session, without a custom
  decoder, meant any *already-saved* elaborated image's `planetarySettings.singleShotAdjustments`
  predating that field had no such key in its JSON at all — `Project`'s decode is all-or-nothing,
  so a `keyNotFound` on that one nested field failed the *entire* project's decode, and
  `ProjectStore.loadAllProjects()` silently skips a project whose `project.json` fails to decode
  (the whole point of that being silent is one hand-edited/incompatible file shouldn't break every
  other project — but this made a perfectly good file look incompatible). `Adjustments` now has
  the same "`decodeIfPresent` a newer field, default it for older saved data" custom `init(from:)`
  `CaptureRecord.rating` already established for the identical failure mode — no data was ever
  lost (the files on disk were always fine), only how many of them the app would actually load.
- Closed the remaining gaps behind "post-processing still pins the CPU after it finishes, and a
  manual Restack only brings it partway back down": `autoStretch()` (the automatic stretch that
  runs right after the very first stack) used to spawn a completely untracked, uncancellable
  `Task` — no `@State` reference at all, unlike every other stage — so it could never be stopped
  or superseded once started; `alignRGBChannels`/`histogram(of:)` also never accepted an
  `isCancelled` check the way `waveletSharpen`/`renderImage` now do. All three now use the same
  cancellation-flag pattern, and closing this window or hitting "Cancel" now stops every in-flight
  stage (Stage 1-5), not just Stage 1-3's own registration/stacking.
- Planetary Post-Processing's live wavelet-sharpen/stretch preview (Stage 4-5 — the wavelet-layer,
  denoise, RGB-align, black/white-point, and log-stretch sliders) could pin every CPU core at once
  and stay pinned, confirmed live on a real stuck process: several `Task.detached` closures piled
  up running full-resolution work concurrently, none of them actually stoppable once started.
  `sharpenTask?.cancel()`/`renderTask?.cancel()` only cancelled the outer wrapper `Task` — the
  actual CPU-bound work runs inside a *separate*, unstructured `Task.detached` that cancelling the
  wrapper never reaches, and `waveletSharpen`/`renderImage` never checked `Task.isCancelled`
  internally anyway, so a superseded pass ran to completion regardless (an image nobody would ever
  see) instead of stopping. A burst of near-simultaneous slider/state changes — several sliders
  dragged in quick succession, or "Redo from Original" setting five wavelet-affecting properties
  at once, each independently triggering the full pipeline via its own `.onChange` — could queue up
  that many full-resolution passes running in parallel, exactly matching "every core pinned."
  `waveletSharpen`/`renderImage` now take an `isCancelled` closure (the same shape
  `scoreAndRegister`/`stack` already use for their own `DispatchQueue.concurrentPerform` work),
  checked periodically inside their loops so a superseded pass actually stops instead of computing
  an image nobody will see.
- Opening Planetary Post-Processing, Edit Image, or the full-screen image preview could land the
  new window somewhere other than over the page you were actually looking at — `center()` alone
  centers on whichever screen AppKit happens to pick for a window that's never been shown, not
  necessarily the one (or position) the presenting page is actually on, e.g. a multi-monitor setup
  where the main window lives on a secondary display. It now re-centers over the current key
  window's own frame instead (clamped to that window's screen), and explicitly activates the app
  when showing, so it's guaranteed to land visibly on top of the page instead of just "somewhere."
  Moving/resizing already worked (a standard titled+resizable `NSWindow`) — this was purely about
  where it first appears.
- Stacking/Restacking's pre-run log line no longer guesses "(GPU when available)" for Mean
  combination — whether a given run actually uses the GPU isn't knowable until it finishes (see
  the "Stacking used the GPU/CPU" line already added below), so stating an intent upfront read as
  a claim next to that later, definitive line. Median's line still states its own CPU-only note
  upfront, since that one's a fact known in advance, not a guess.
- A raw capture's own full-screen preview (opened from a Timeline thumbnail's "Open," or a
  capture's detail page) had no "More" menu at all, unlike an elaborated image's own preview —
  `moreMenuItems` was never passed at that call site, so "Edit Image…" (along with Show in
  Finder/Publish to AstroBin/Open in Siril/Delete) had no way to be reached from the preview
  itself. Wired up the same menu, with "Edit Image…" leading, matching the elaborated-image
  preview's own ordering.
- The Chroma Noise Reduction slider (and every other slider using the same two helpers) was
  squeezed down to a sliver by its own label sitting beside it — `LabeledContent`'s side-by-side
  layout gave a long label like "Chroma Noise Reduction" most of the row's width, leaving barely
  any for the slider itself. Moved the label to its own line above the slider instead.
- The setup screen's "Start Processing" button stopped showing after Color/Stretch were added to
  it — the newly-scrollable settings panel had nothing bounding its height, so it greedily
  claimed all available vertical space and squeezed the button (sandwiched between two plain
  `Spacer()`s) down to nothing. Rearranged into a fixed-height footer below a properly
  height-bounded settings area instead.
- Opening Planetary Post-Processing or Edit Image shifted the whole app window down by roughly
  the sheet's own title-bar height, cutting off the bottom of the window — sizing the sheet to
  exactly the screen's visible area (its own recent fix) left no room for macOS to fit that title
  bar without repositioning the presenting window itself. Restored a small margin so the sheet
  stays safely smaller than the screen instead.
- The Capture page's Histogram tab (combined mode) could clip its Black/White Point sliders at
  the bottom — its content already ran close to the tab area's 260pt height cap even without any
  clipping warning showing, and the extra row `clippingWarningView` adds while capturing
  something bright enough to actually clip (exactly when this got reported) pushed it over, with
  no `ScrollView` fallback in combined mode to catch the overflow. Raised the cap to 340pt.
- The CPU renderer path recomputed a full per-pixel histogram synchronously on the main actor
  every time `HistogramView`'s `body` re-rendered — once per live frame — which is what "when
  capture and the histogram change the image freeze a little bit" actually was: a real main-thread
  stall, not just something that looked slow. Moved it to a background `Task.detached`, keyed off
  `CameraManager.frameID` so a slow pass never races a newer frame's result back in; the GPU
  renderer path was never affected (`gpuHistogramCounts` is already precomputed elsewhere before
  this view reads it).
- The Done button on an elaborated image's full-screen preview (and Planetary Post-Processing's
  and Edit Image's own Done/Cancel) could fail to actually close the window — AppKit's default
  `isReleasedWhenClosed = true` let `close()` deallocate the window while its own delegate
  (`DetachedContentWindowController` itself) was still on the call stack synchronously calling
  `onClose()`, which drops the caller's last strong reference to that same controller: a
  reentrant-teardown race. Set `isReleasedWhenClosed = false` and deferred `onClose()` by one
  run-loop tick so `close()` finishes unwinding before the controller can be released.
- "Edit Image…" now leads an elaborated image's full-screen "More" menu, right-click context
  menu, and Info sheet's button row, instead of sitting after Info/Show in Finder/Publish to
  AstroBin — it's the action someone opening an elaborated image reaches for most.

## [0.5.3] - 2026-08-27

### Added
- Planetary Post-Processing: saving now optionally asks for a title and description, records the
  exact stacking/wavelet/color settings the result was produced with (visible in the elaborated
  image's own Info sheet), and — once you've already saved once this session — asks whether to
  save the new result as another version or overwrite the one you already saved. The log during
  Stacking/Restacking now also says whether that run used the GPU (Mean) or CPU (Median, which
  has no GPU equivalent — a true per-pixel median needs every sample resident to pick from) so
  it's no longer a mystery why a Median restack feels slower than the very first stack (which
  also includes a fast GPU registration pass diluting the wait; a restack is only the combine
  step, so a CPU-bound Median restack has nothing faster running alongside it).
- Planetary Post-Processing: drawing an "Object to Track" box is now required before "Start
  Processing" is enabled (unless the preview itself failed to load, in which case there's
  nothing to draw a box on). The pointer also switches to a crosshair while it's over the
  selector, on both this screen and Siril's own crop-to-region — previously nothing signaled
  "draw a box here" until you actually started dragging.
- A full-screen, zoomable image viewer (pinch/scroll-wheel zoom, pan) shared by every "Open" on
  a viewable image: the Capture page's "Open" (PNG/TIFF captures) and tapping an elaborated
  image both open it now, instead of handing off to an external app or a small non-zoomable
  sheet. Its toolbar adds Save As…, Save to Photos, Share, and Set as Thumbnail (session-scoped
  from a capture, project-scoped from an elaborated image) — actions that weren't reachable from
  either "Open" path before.
- Capture page: a Copy button next to File, Camera Settings, Session, and Stats — copies that
  section as plain "Label: Value" text, ready to paste into a forum post or bug report. Also a
  "Copy All Details" action (in File's action list) that combines every section on the page
  into one block.
- Planetary Post-Processing: Wavelet Sharpening is now adjustable on the initial "Set Up
  Stacking" screen too, not only after a stack exists — the same sliders/state the ready
  screen's own copy binds to, so whatever's dialed in before "Start Processing" is already
  applied to the very first result instead of needing a second pass to fix.
- Capture page: the File section's actions (up to 9-10 depending on capture kind — Open, Show
  in Finder, Publish to AstroBin, Open in Siril, Post-Process, Edit Image, Move to Session,
  Split into New Session, Copy All Details, Delete) are now grouped under small labeled
  sub-headers — View, Process, Share, Organize, then Delete on its own — instead of one long
  flat stack of buttons with nothing separating "just look at this" from "reprocess this."
- Planetary Post-Processing: an "Object to Track" crop selector on the "Set Up Stacking"
  screen, restricting registration's centroid search to just the drawn box.
- Planetary Post-Processing registration now runs on the GPU when one's available
  (`PlanetaryGPURegistrar`, mirroring the debayer step's own existing Metal path) — the
  per-frame sharpness score and centroid, the two full-resolution CPU scalar passes left in
  that stage after debayering moved to Metal. Falls back to the identical CPU path with no
  behavior change wherever there's no usable GPU (e.g. sandboxed CI).
- Planetary Post-Processing Mean stacking now runs on the GPU too (`PlanetaryGPUStacker`) —
  each selected frame's bilinear shift and its accumulation into the running average happen in
  one Metal pass, streamed one frame at a time instead of holding every shifted frame in memory
  at once like the CPU path does. Median stacking (which needs every sample resident to pick a
  middle value from) is unaffected and stays on the existing multi-core CPU path. Falls back to
  the identical CPU path with no behavior change wherever there's no usable GPU.
- "Align RGB Channels" now reuses `PlanetaryGPURegistrar`'s GPU centroid (the same math
  `scoreAndRegister` already runs on the GPU) for its own per-channel centroid instead of a third
  CPU implementation — the last CPU-only registration-style math left in the pipeline. Falls back
  to the identical CPU path with no behavior change wherever there's no usable GPU.

### Fixed
- The three GPU wrapper classes (`PlanetaryGPULuminanceConverter`, `PlanetaryGPURegistrar`,
  `PlanetaryGPUStacker`) each share one instance across every call site; two concurrent calls
  from different threads (surfaced as an intermittent, full-suite-only test failure) could race
  on that shared instance's cached textures and corrupt each other's result. Each now serializes
  its own calls with a lock instead of assuming they'll never overlap.
- Planetary Post-Processing could stack into a ghosted/duplicated-looking result whenever the
  frame had more than one bright thing in it (a moon, a companion star, a reflection) —
  registration's intensity-weighted centroid weighed all of them at once, and which point it
  landed on could shift frame to frame as their relative brightness/position changed, so frames
  ended up registered against different points instead of the same one. The new "Object to
  Track" selector (see Added) fixes this by letting registration search only the selected
  region; leaving it empty keeps the previous whole-frame behavior.
- Planetary Post-Processing: "Align RGB Channels" could stack R/G/B into three entirely
  separate, non-overlapping colored blobs instead of one aligned image — the same whole-frame
  intensity-centroid weakness as the ghosting fix above, applied per color channel with no
  bound on the resulting shift, so a small/faint target against a mostly-empty frame could have
  its per-channel centroid dominated by noise/background rather than the target itself,
  computing an implausibly large "correction" instead of the few-pixel nudge real atmospheric
  dispersion needs. Now uses the same "Object to Track" region when one's selected, and clamps
  the maximum shift to a small fraction of that region's size — a channel whose computed shift
  exceeds it is left unaligned (visible fringing, at worst) rather than moved somewhere else
  entirely.
- The v0.5.2 (and, in the `.zip`'s case, v0.5.0/v0.5.1 too) release assets shipped with real
  packaging bugs, not app bugs — re-uploaded corrected `v0.5.2` assets and updated the Homebrew
  Cask's sha256 to match, no app-code or version change needed:
  - The `.zip` asset was missing `Fix Gatekeeper Warning.command` entirely — packaging only
    ditto'd the `.app`, so the README's own "unzip, then run the script" instructions had
    nothing to run (`./Fix Gatekeeper Warning.command: zsh: exec format error` when a shell
    tried to execute the nonexistent path some other way).
  - Both assets' `skyformac.app` had Apple's XCTest/Testing frameworks embedded in
    `Contents/Frameworks` — dead weight from the shared build scheme that the app never
    actually links against, confirmed via `otool -L`, but still roughly doubling the shipped
    size. Stripped.
  - The `.zip` specifically (not the `.dmg`) was built with `ditto -c -k`, which scatters
    AppleDouble resource-fork sidecar files *inside* the app bundle's own directory tree —
    extracting that zip and running `codesign --verify` on the result failed with "a sealed
    resource is missing or invalid" (Gatekeeper would refuse to launch it). Switched to plain
    `zip`, which doesn't have this problem; confirmed by actually extracting the rebuilt zip
    and re-verifying the signature. See `docs/distribution.md`'s new "Ad-hoc manual releases"
    section for the full writeup.
- README's manual quarantine-removal fallback used `xattr -dr com.apple.quarantine
  skyformac.app` — some `xattr` builds don't recognize `-r` and just print a usage error. `-d`
  alone is enough; the flag that blocks Gatekeeper lives on the `.app` bundle itself.

## [0.5.2] - 2026-08-25

### Added
- "Publish to AstroBin…" on any capture (FITS/PNG/TIFF), elaborated image, and freshly-saved
  Edit Image result — reveals the file in Finder and opens AstroBin's uploader in the default
  browser, already signed in via the user's own session. Not a real in-app upload: AstroBin's
  only public API is documented as read-only with no upload endpoint and no OAuth/write
  credentials issued, so this hands off to the browser instead of reverse-engineering their
  private session/upload calls — see `AstroBinPublisher`'s own doc comment.
- Homebrew installation is actually live now: `brew tap giulioroggero/skyformac` /
  `brew install --cask skyformac`, published from
  [giulioroggero/homebrew-skyformac](https://github.com/giulioroggero/homebrew-skyformac).
  `Casks/skyformac.rb` in this repo was previously a template only, with no real tap behind it.
- Capture page: the "Camera Settings" section now also shows the equipment system actually in
  use at capture time (`capture.equipmentSystemID`, the same snapshot-not-live-reference the
  gain/exposure/ROI fields there already are), matching what the Session page's own stats
  already show for the session as a whole.

### Fixed
- "Open in Siril…"/"Elaborate…" on a `.ser` capture failed outright with "No files were found
  for conversion": against Siril 1.4.4, `convert` only picks up loose frame images (FITS/TIFF/
  PNG/...) sitting in the working directory, not an existing sequence container like a `.ser` —
  confirmed by reproducing the exact failure directly against Siril's CLI. `stack` can reference
  a `.ser` directly by name instead (Siril auto-generates the `.seq` index it needs), so the
  now-unnecessary `convert` step is gone from the planetary/lunar recipe. "Open Siril Directly…"
  on a `.ser` no longer attempts (and fails) the same broken conversion either — a `.ser` is
  staged and opened as-is, the same as before this integration existed.

## [0.5.1] - 2026-08-22

### Added
- Project pages: a **Table** view for a project's Sessions list, alongside the existing card
  list — same Thumbnails/Table tradeoff as the Home page's own project view toggle. Sortable
  columns include disk usage and capture count per session, with native multi-select
  (⌘/⇧-click) driving a bulk action bar (Archive, Delete) above the list.
- Session pages: the same **Table** view treatment for the capture Timeline, alongside the
  existing filmstrip — sortable columns (date, file, kind, object, disk usage, note) with
  native multi-select driving a bulk Delete action above the list, behind a confirmation
  dialog (this deletes the actual files, not a 30-day-grace-period soft delete).
- Edit Image: a "Compare to Original" toggle next to Reset — splits the preview vertically,
  the untouched original above the live edit below, instead of only ever showing the edit.
- Home's "Resume Where You Left Off" row now shows the session's own cover thumbnail (same
  custom-thumbnail-wins-else-most-recent-capture rule every other session cover already
  follows), instead of no image at all.
- A brief launch splash (`LaunchSplashView`) — the app icon, a rotating loading-status line,
  and a rotating set of short real facts about common observing targets (the Orion Nebula,
  Saturn's rings, Albireo, and the like) — covers `RootView` for its first couple of seconds
  instead of snapping straight to a populated Home page.

### Fixed
- "Open Siril Directly…" handed Siril the raw FITS/SER file as-is, with no debayer step —
  Siril's GUI doesn't auto-debayer a raw file on load even when its `BAYERPAT` header says
  it's color, so color captures came in as black & white. Now runs the same
  `calibrate_single`/`convert -debayer` conversion the automated recipes already use before
  opening Siril, the same way opening a whole burst does for a "Post-Process…" run.
- Magic Wand (Edit Image) bakes its auto-enhance result directly into the image's pixels but
  never touched the `Adjustments` sliders below it, so they kept showing stale pre-wand
  values — looking like the wand did nothing or the values were wrong. Now resets them to
  identity so they honestly reflect the new baseline.
- "Hardware Bin" (an on-sensor `ASI_HARDWARE_BIN` toggle) and the separate 2×2 ROI/pixel
  binning were two uncoordinated binning mechanisms — active together, the sensor's already
  on-chip-binned data got averaged a second time and no longer had a clean Bayer mosaic, but
  the debayer step fed it through unchanged, producing scattered green/blue dot artifacts.
  Now enforces a single binning source: turning either on turns the other off first.
- Live Capture could look permanently stuck "Capturing…": `startLiveCapture`'s delayed timer
  had no way to tell if the burst it was scheduled for had since been superseded by a new
  Lucky Imaging/Live Capture burst (they share one session) — the stale timer still fired and
  froze the *new* session's frame intake before it ever reached completion. Now checks a
  generation counter before acting. Separately, `LiveCaptureBrowserView`'s preview could stay
  on a spinner forever if the user never touched the scrubber (it only ever requested frame 0,
  before the burst had one) — now re-requests a frame once the burst actually finishes.
- Sidebar/breadcrumb looked "not fully dark" with washed-out white text: `nightModeTint(_:)`
  applied `.colorMultiply` unconditionally, even the `.white` "no Night Mode" value — that
  forces an offscreen compositing pass that defeats macOS's native sidebar/toolbar vibrancy
  material, same class of bug as the live-preview latency fix below. Now only applies the
  modifier when Night Mode is actually on.
- Capture page: Previous/Next (and the left/right arrow keys) sorted captures newest-first,
  opposite `TimelineStripView`'s own oldest-first, left-to-right filmstrip order — so the left
  arrow moved to a *more* recent capture and the right arrow to an *older* one, backwards from
  the filmstrip and from the on-image chevrons' own convention. Now sorts the same way the
  filmstrip does.
- "Move to Session…" sorted candidates by project name first, but the picker's prominent label
  is the session name (project name is only the small secondary caption) — so the visible list
  of session names wasn't actually in alphabetical order, only alphabetical within each
  project's own run. Now sorts by session name first.
- Live preview multi-second delay for real ASI cameras: `CaptureEngine.frames()` used the
  default *unbounded* `AsyncStream` buffer, unlike `WebcamCaptureEngine.frames()` (already
  `.bufferingNewest(1)`). Any stretch where per-frame processing on `@MainActor` took even
  slightly longer than the camera's real frame interval let the backlog grow without bound —
  the preview fell further and further behind real time the longer streaming ran, instead of
  just dropping frames it couldn't keep up with. Now matches the webcam path.
- Live preview latency regression: the preview image itself was wrapped in `.colorMultiply`
  unconditionally (even with Night Mode off), forcing an extra compositing pass on every
  incoming frame. Now only applied when the tint is actually active.
- "Reset to Default" (and any other ROI/binning change requesting settings already in
  effect) always tore the live stream down and rebuilt it, briefly disabling every control
  gated on a live frame and spiking CPU — `changeCaptureROI` now no-ops when nothing is
  actually changing, matching `changeImageType`'s existing guard.
- `resumeLiveView()` (after a single exposure or dark-frame capture) could race an
  in-flight ROI/image-type restart: it started a fresh preview without cancelling the
  previous frame consumer or serializing behind other restarts, which could leave one
  stream feeding nothing (controls stuck disabled) while an orphaned one kept polling
  (elevated CPU). It now goes through the same serialized restart path as ROI/image-type
  changes.

## [0.5.0] - 2026-08-21

### Added
- A native Planetary/Lunar Post-Processing pipeline for `.ser` captures ("Post-Process…"):
  quality-scoring & registration, median/mean stacking, à trous wavelet sharpening, RGB
  channel alignment, and auto-stretch, all in-app — an alternative to sending the capture to
  Siril. Interactive parameters with a live preview, a pre-stacking setup screen, background
  cancellable processing with real progress feedback, GPU-accelerated debayering (falls back to
  CPU where Metal isn't available), and an optional GraXpert pass without leaving the modal.
- "Edit Image…" on any single FITS/PNG/TIFF capture: GPU-backed (Core Image) brightness,
  contrast, saturation, a gamma curve, sharpen (now up to 5x), rotate, crop, a denoise slider
  (widened noise-level range, eased detail retention, and a compounding second pass in the top
  half of the slider — max strength is now meaningfully stronger than "barely more than a
  little"), and a hot-pixel/cosmic-ray "clean up" filter, plus three more astronomy-specific
  tools — green-cast (SCNR) removal, star-size reduction, and shadow/highlight recovery — and a
  one-tap "Magic Wand" auto-fix (the same auto-enhance analysis behind Photos.app). Every slider
  has its own reset control, not just one global reset. Saved as a new Elaborated Image; Lucky
  Imaging/Live Capture results become editable here too once saved as a capture.
- "Live Capture": buffers a few seconds of the live feed (default 3, adjustable), then lets you
  scrub through every frame it captured and export whichever one actually looked sharpest as
  PNG/TIFF — an iPhone-Live-Photo-style alternative to timing one manual capture.
- An always-visible "PNG" export button next to the RAW8/RAW16 picker — saves the current frame
  exactly like Export > PNG, without opening the Export menu first.
- A plain-English focus-quality readout ("Focus: Good/Fair/Poor") next to the live HFD trend,
  with a manual guidance hint ("reverse the focuser" / "keep turning the same way") derived from
  the live trend direction rather than any fixed clockwise/counterclockwise mapping — software
  has no way to know which way a given focuser's knob actually turns.
- Session pages now surface files sitting in a session's own folder that aren't tracked captures
  (e.g. a result an external post-processing tool dropped straight into the folder), via a new
  "Browse Files…" modal — a multi-select list (native ⌘/⇧-click, or "Select All") with a live
  preview pane and bulk actions (Delete, Show in Finder) over however many files are selected,
  instead of only reachable one at a time via "Show in Finder."
- The Home page's Observation Timeline now shows a big "MM.DD.YY"-style date header above the
  strip that tracks whatever's actually scrolled into view (not always today/the single most
  recent capture). Captures still visually overlap the same way they always have when zoomed
  out — only the date/object label under a capture too close to its neighbor to fit legibly is
  hidden (the thumbnail itself, and its tooltip, stay fully there), instead of letting two labels
  collide into illegible overlapping text. Spacing between thumbnails is now purely index-based
  (how many captures there are), not proportional to real elapsed time, so there's never dead
  empty space between two thumbnails just because a lot of quiet time passed between them. Below
  25pt of spacing per thumbnail, some thumbnails now hide entirely (not just their text) so every
  one still shown gets a real 25pt — zooming back in reveals them again.
- "Edit Image" now has a zoom control (pinch, or the slider under the preview) with drag-to-pan
  once zoomed in, for checking a sharpen/denoise/star-size result at real pixel scale instead of
  only ever seeing the whole image shrunk to fit the pane.
- Session pages: **Other Files in This Folder** now also shows their combined disk usage right
  in the "Browse…" button, and moved to sit directly above the session's own
  Elaborate/Archive/Move/Delete action row; **Elaborated** moved up to sit directly under
  **Timeline**.
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
- Settings reorganized into tabs (**Folders / Rendering / AI / Storage / Siril / Community**) and
  enlarged to make room — **Storage** manages disk usage across every project; **Community**
  shows this repo's open/resolved GitHub issues live, with a one-click "Report an Issue…".
- Optional **Siril integration** (Settings > Siril, off by default — Siril is a separate app,
  not bundled): **Elaborate…** next to a session or capture sends its raw FITS/SER data to
  Siril's command-line tool for stacking/registration/stretching, then brings the result back
  into the project's own new **Elaborated** section. The recipe (single-frame debayer+stretch,
  planetary stack-without-registration, or deep-sky register+stack) is auto-suggested from the
  session/capture's own target but always user-overridable before running.

### Changed
- The session Timeline strip now lays out oldest → newest, left to right — it previously
  disagreed with the Home page's own Observation Timeline, which has always gone the same way.
- The Home page's Observation Timeline compresses any gap longer than 6 hours between captures
  instead of stretching it proportionally to how much real time actually passed — a quiet month
  between sessions no longer pushes everything else off-screen.
- Removed the "?" help-tip buttons next to the ROI/GPU/Night Mode/All-Sky Monitor toolbar
  toggles.

### Fixed
- Planetary Post-Processing: on a machine whose core count produced a specific mismatch in the
  final stacking step's chunk-splitting math, a trailing chunk could start past the pixel
  array's end and crash. Never reproduced on every machine tested, but fixed at the source
  (verified against every count/requested-chunk-count pairing, not just the one that crashed)
  rather than left as a latent risk.
- The Observation Timeline's "jump to most recent capture" button could scroll to the wrong
  spot — every thumbnail was positioned with `.offset()`, a purely visual transform that doesn't
  change what the scroll view believes a view's actual position is. Positioning is now done
  with real layout (padding-based).
- Zooming the Observation Timeline in/out could leave the view scrolled all the way back to the
  oldest, first thumbnail — changing the zoom changes the strip's total width, and the scroll
  view was left wherever its old absolute scroll offset happened to clamp to against that new
  width. It now re-anchors to whatever was actually in view right before the zoom change.
- Exporting an image (PNG/TIFF/FITS) froze the whole app and spun the pointer for a full-detail
  write — the actual file encode now runs off the main actor instead of blocking it.
- Capturing a dark or flat calibration frame left the live preview frozen/blank afterward, with
  no way to recover short of restarting the app — live view now resumes automatically once the
  calibration capture finishes, the same way it already did for a single exposure.
- Changing the Capture ROI while a previous change was still being applied could repeatedly
  tear/flash the live preview until the whole backlog of restarts finally drained — the ROI
  controls now disable themselves while a restart is actually in flight.
- Planetary Post-Processing: restacking showed no progress at all, the old preview vanished to
  black during a restack, and cancelling left the CPU pegged at ~900% — progress now updates
  continuously with periodic log lines, the old preview stays visible (dimmed) during a
  restack, and cancelling now actually reaches the parallel per-pixel stacking step.
- Planetary Post-Processing: the default wavelet-sharpening gains exactly reconstructed the
  unsharpened stack (a no-op), so the result looked like "just a fog" no matter what — the
  defaults now genuinely sharpen out of the box.
- Planetary Post-Processing: nudging the stretch (black/white point, log toggle) re-ran the
  entire sharpen/align pass instead of just re-rendering, making it feel unresponsive; it's
  cached separately now so stretch changes are live.
- FITS "Record to Disk" had no guard against a genuinely blank/flat frame reaching the file,
  unlike the `.ser` recorder — one such frame in a sequence was enough to trip Siril's "MAD is
  null. Statistics cannot be computed." during stacking. Now shares the same guard `.ser`
  recording already had.
- The AI chat panel's visible/minimized/detached state was in-memory only, so closing it (e.g.
  on the camera page) didn't survive a relaunch — now persisted like every other preference.
- Zooming the live preview (pinch, or the fullscreen zoom slider) drifted whatever was centered
  off toward one side the further you zoomed afterward, instead of keeping it centered.

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
