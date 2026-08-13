# Examples

Every picture and video in [`examples/`](examples/), captured with Skyformac
itself — no post-processing beyond whatever the app's own live pipeline
(debayer/stretch, GPU enhancement, live stacking) already applied. This file
is meant to be kept up to date: when a new example is added to `examples/`,
add a row for it here in the same pass.

Pictures are checked into the repository directly. Videos are **not** —
they're well over GitHub's 100MB per-file push limit — instead they're
attached to a [GitHub release](https://github.com/giulioroggero/skyformac/releases)
and linked from here; see [`.gitignore`](.gitignore)'s `examples/*.mov` rule.

## Pictures

| File | Subject | Notes |
| --- | --- | --- |
| [`saturn-live-stacking.gif`](examples/saturn-live-stacking.gif) | Saturn, live stacking | Animated GIF derived from `saturn-live-stacking.mov` (2x speed, downscaled) — the README's top banner. |
| [`saturn-live-stacking.png`](examples/saturn-live-stacking.png) | Saturn, live stacking | A single frame from the same session as the GIF above. |
| [`saturn-2.png`](examples/saturn-2.png) | Saturn | 3840×2160. |
| [`M57 - live.png`](<examples/M57 - live.png>) | M57 (Ring Nebula), live view | Straight off the live preview. |
| [`M57 - night mode.png`](<examples/M57 - night mode.png>) | M57 (Ring Nebula), Night Mode | Same target with Night Mode's red UI tint on — shows the surrounding chrome tinted while the live image itself stays untinted. |
| [`arcturus-first-test-picture.png`](examples/arcturus-first-test-picture.png) | Arcturus | First-light test — see below. |
| [`m13-test-picture.png`](examples/m13-test-picture.png) | M13 (Hercules Cluster) | First-light test, with Live GPU Enhancement Controls on — see below. |

## Videos (GitHub release assets, not in the repository)

| File | Subject | Duration | Released with |
| --- | --- | --- | --- |
| [`saturn-live-stacking.mov`](https://github.com/giulioroggero/skyformac/releases) | Saturn, live stacking | ~21s | Not yet attached to a release — see note below. |
| [`saturn-full-screen.mov`](https://github.com/giulioroggero/skyformac/releases) | Saturn, full-screen preview | ~71s | Not yet attached to a release — see note below. |
| [`arcturus-first-test.mov`](https://github.com/giulioroggero/skyformac/releases/download/v0.1.12/arcturus-first-test.mov) | Arcturus | ~94s | [v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12) |
| [`m13-test.mov`](https://github.com/giulioroggero/skyformac/releases/download/v0.1.12/m13-test.mov) | M13 (Hercules Cluster) | ~49s | [v0.1.12](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12) |

> **Note:** `saturn-live-stacking.mov` and `saturn-full-screen.mov` are newer
> than the last tagged release and aren't attached to any release yet — the
> GIF/PNG derived from the first one are already in this file, but the raw
> `.mov`s themselves need to ride along with the *next* release (`gh release
> upload <tag> examples/saturn-live-stacking.mov examples/saturn-full-screen.mov`)
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
