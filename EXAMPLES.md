# Examples

Every picture and video in [`examples/`](examples/), captured with Skyformac
itself. Most are straight off the app's own live pipeline (debayer/stretch,
GPU enhancement, live stacking) with no further post-processing — the
[Post-processed results](#post-processed-results) section below is the one
exception, showing what Planetary Post-Processing/Edit Image actually
produce from that same raw data. This file is meant to be kept up to date:
when a new example is added to `examples/`, add a row for it here in the
same pass.

Pictures are checked into the repository directly. Videos are **not** —
they're well over GitHub's 100MB per-file push limit — instead they're
attached to a [GitHub release](https://github.com/giulioroggero/skyformac/releases)
and linked from here; see [`.gitignore`](.gitignore)'s `examples/*.mov` rule.

## Post-processed results

Real results from real sessions — not the raw live view, but what actually
comes out the other end of Planetary Post-Processing (Saturn: registration,
stacking, wavelet sharpening, color alignment) and Edit Image (Moon, M57:
crop/curves/denoise/astronomy tools). Straight from the author's own
projects, unedited beyond what the app itself did.

| File | Subject | Notes |
| --- | --- | --- |
| [`moon-detail-result.png`](examples/moon-detail-result.png) | The Moon | Edit Image — crater/terminator detail from a Lucky Imaging session. |
| [`m57-ring-nebula-result.png`](examples/m57-ring-nebula-result.png) | M57 (Ring Nebula) | Edit Image, from a live-stacked deep-sky session — the ring's own shape resolved clearly despite a bright suburban sky. |
| [`saturn-post-processed-result.png`](examples/saturn-post-processed-result.png) | Saturn | Planetary Post-Processing — registration, stacking, wavelet sharpening, and RGB channel alignment from a `.ser` recording, with the rings and disk clearly separated. |

## Pictures

| File | Subject | Notes |
| --- | --- | --- |
| [`quick-tour.gif`](examples/quick-tour.gif) | App tour | Animated GIF derived from `quick-tour.mov` (first 16s, downscaled, 12fps) — the README/website's top banner. |
| [`saturn-live-stacking.gif`](examples/saturn-live-stacking.gif) | Saturn, live stacking | Animated GIF derived from `saturn-live-stacking.mov` (2x speed, downscaled) — the README's second banner image. |
| [`saturn-live-stacking.png`](examples/saturn-live-stacking.png) | Saturn, live stacking | A single frame from the same session as the GIF above. |
| [`saturn-2.png`](examples/saturn-2.png) | Saturn | 3840×2160. |
| [`M57 - live.png`](<examples/M57 - live.png>) | M57 (Ring Nebula), live view | Straight off the live preview. |
| [`M57 - night mode.png`](<examples/M57 - night mode.png>) | M57 (Ring Nebula), Night Mode | Same target with Night Mode's red UI tint on — shows the surrounding chrome tinted while the live image itself stays untinted. |
| [`arcturus-first-test-picture.png`](examples/arcturus-first-test-picture.png) | Arcturus | First-light test — see below. |
| [`m13-test-picture.png`](examples/m13-test-picture.png) | M13 (Hercules Cluster) | First-light test, with Live GPU Enhancement Controls on — see below. |

## App screenshots

Screens of the app itself, rather than a captured target — shown in the README's own
[Screenshots](README.md#screenshots) section.

| File | Page | Notes |
| --- | --- | --- |
| [`Home Page.png`](<examples/Home Page.png>) | Dashboard/Home | "Resume Where You Left Off," Common Tasks, Recent Projects, Highlighted Sessions. |
| [`New Timeline.png`](<examples/New Timeline.png>) | Dashboard/Home (Observation Timeline) | The Home page's own zoomable timeline — big date header, count-based spacing (not proportional to real elapsed time), and a zoom slider. |
| [`Quick Start.png`](<examples/Quick Start.png>) | Quick Start picker | Over the Projects grid — Planets & Moon and Deep Sky target lists. |
| [`Project.png`](examples/Project.png) | Project Detail | Stats, the zoomable Activity Timeline chart, Equipment, Tags. |
| [`Sessions.png`](examples/Sessions.png) | Project Detail (session list) | Tags/Notes, and every session with a one-click Resume. |
| [`Sessions Details.ong.png`](<examples/Sessions Details.ong.png>) | Session Detail | Aim/Objects/Location, Run/Recall Parameters/New Session Like This/Ask AI, History, Stats. |
| [`Session Capture Timeline.png`](<examples/Session Capture Timeline.png>) | Session Detail (timeline) | The capture filmstrip, oldest to most recent, each with its own plain-English note. |
| [`New Project  Home.png`](<examples/New Project  Home.png>) | Session Detail | Cover, Session Summary, History/Equipment/Stats/Tags, and the capture Timeline together on one page (M110 session). |
| [`Nebula Capture.png`](<examples/Nebula Capture.png>) | Capture Detail | Full preview with Prev/Next overlay buttons, plus the per-capture Camera Settings (mode/gain/exposure). |
| [`Direct Edit SIngle Capture Image.png`](<examples/Direct Edit SIngle Capture Image.png>) | Capture Detail | The "Edit Image…" action alongside Open/Show in Finder/Move/Split/Delete. |
| [`Edit Image And Save in project.png`](<examples/Edit Image And Save in project.png>) | Edit Image | GPU-backed crop/rotate/color/curves, Magic Wand auto-fix, denoise, hot-pixel clean-up, and the astronomy-specific tools (green-cast removal, star-size reduction, shadow/highlight recovery). |
| [`Send to Siril via CLI or UI.png`](<examples/Send to Siril via CLI or UI.png>) | Elaborate with Siril | Planetary vs. Deep Sky recipe, crop-to-region, and Siril's own stacking-rejection parameters, for a Moon `.ser` recording. |
| [`Stats.png`](examples/Stats.png) | Insights | Overview, Activity Over Time, Most Captured Objects, Most Used Equipment, Most Common Acquisition Mode. |
| [`Equipment.png`](examples/Equipment.png) | Equipment system detail | Camera/Mount/Optical Tube sections for one named system. |

## Videos (GitHub release assets, not in the repository)

| File | Subject | Duration | Released with |
| --- | --- | --- | --- |
| [`quick-tour.mov`](https://github.com/giulioroggero/skyformac/releases) | App tour | ~122s | Not yet attached to a release — see note below. |
| [`saturn-live-stacking.mov`](https://github.com/giulioroggero/skyformac/releases) | Saturn, live stacking | ~21s | Not yet attached to a release — see note below. |
| [`saturn-full-screen.mov`](https://github.com/giulioroggero/skyformac/releases) | Saturn, full-screen preview | ~71s | Not yet attached to a release — see note below. |
| [`arcturus-first-test.mov`](https://github.com/giulioroggero/skyformac/releases/download/v0.1.12/arcturus-first-test.mov) | Arcturus | ~94s | [v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12) |
| [`m13-test.mov`](https://github.com/giulioroggero/skyformac/releases/download/v0.1.12/m13-test.mov) | M13 (Hercules Cluster) | ~49s | [v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12) |

> **Note:** `quick-tour.mov`, `saturn-live-stacking.mov`, and `saturn-full-screen.mov` are newer
> than the last tagged release and aren't attached to any release yet — the
> GIF/PNG derived from them are already in this file, but the raw
> `.mov`s themselves need to ride along with the *next* release (`gh release
> upload <tag> examples/quick-tour.mov examples/saturn-live-stacking.mov examples/saturn-full-screen.mov`)
> before the links above will resolve.

## First-light test session

August 10, 2026, from a not-so-dark suburban sky, on a Maksutov 125/1500mm on
an alt-azimuth mount, with a ZWO ASI 678MC. No dark/flat calibration, no
stacking beyond the app's own live GPU enhancement pipeline — straight off
the live view.

- **Arcturus** — an initial bright-star test to confirm focus and framing
  before hunting anything fainter. High gain (402) and a not-so-dark sky
  show up as real sensor/sky noise here, which is expected and exactly what
  this shot was for.
- **M13 (Hercules Globular Cluster)** — individual stars resolved live, with
  Live GPU Enhancement Controls (temporal + spatial denoise, non-linear
  contrast stretch) enabled, straight off the ASI678MC's live feed with no
  post-processing.
