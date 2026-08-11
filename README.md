# Skyformac

Repository: [github.com/giulioroggero/skyformac](https://github.com/giulioroggero/skyformac)

Skyformac is a native macOS astrophotography capture app for ZWO ASI cameras —
built directly on the ZWO ASI Camera SDK, no ASCOM/INDI bridging layer. Think of
it as a SharpCap-style capture tool for the Mac: connect a camera, get a live
preview, adjust gain/exposure/binning and the rest of its controls, and capture
single exposures, dark/flat calibration frames, live stacks, or lucky-imaging
bursts, straight to FITS/PNG/TIFF.

If you don't have a ZWO camera to hand, an iPhone (via Continuity Camera) or any
other USB webcam works as a live source too — handy for afocal eyepiece
projection on the Moon and bright planets.

## Why a native Mac app?

Most software that can drive a ZWO ASI camera — SharpCap, FireCapture, and
others — is Windows-native or Java-based, running on a Mac only through
Wine/Parallels or a JVM, neither of which was built with this hardware or this
OS in mind. Skyformac is a ground-up SwiftUI/AppKit app instead, which is what
makes a few things possible that a ported or cross-platform tool generally
can't do as directly:

- **Real GPU acceleration, not a CPU fallback.** Debayering, the display
  stretch, denoise, wavelet sharpening, histogram computation, and
  live-stacking all run as actual Metal compute shaders (`Shaders.metal`) on
  Apple Silicon's GPU — a cross-platform tool's fast path is typically
  DirectX-only, leaving macOS on a slower CPU-only code path even when it
  runs at all.
- **An iPhone as a capture source, natively.** Continuity Camera — using a
  paired iPhone as a live afocal-projection camera, with real focus-lock and
  frame-stacked Night Mode support — is an Apple-ecosystem capability tied to
  macOS/iOS; it isn't something a cross-platform or Windows-native tool can
  offer at all, on any OS.
- **Apple's Vision framework for real detection**, not a bundled third-party
  computer-vision library — star/streak/planet detection and the live WCS
  solve all go through the same system framework macOS itself uses for
  on-device vision tasks.
- **Swift's actor model enforces the hardware-threading rules other apps
  only document.** Every blocking ZWO SDK call is structurally isolated onto
  `CaptureEngine`'s own actor — not just a convention to remember, but
  something the compiler checks — which is what keeps a multi-second USB
  handshake or a long exposure from ever freezing the UI (see
  [`docs/design-notes.md`](docs/design-notes.md) for the real hangs this
  caught and fixed during development).
- **Runs entirely locally.** No telemetry, no cloud account, no network
  dependency for anything the camera itself doesn't need — and the source is
  open (GPLv3, see [License](#license) below), so any of this is
  independently verifiable rather than taken on faith.

## Requirements

- macOS 14.0+ to run the app.
- To build it yourself: Xcode 26+ (Swift 6), and the Metal toolchain component
  (`xcodebuild -downloadComponent MetalToolchain` — needed once, to compile
  `Shaders.metal`).
- A ZWO ASI camera connected over USB, or a webcam/iPhone — see
  [Connecting a camera](#connecting-a-camera) below for what to do without either.

## Building and running

```
make build   # build into ./build
make test    # run the unit tests (skyformacTests) and UI tests (skyformacUITests)
make run     # build and launch skyformac.app
make clean   # remove ./build
make open    # open the project in Xcode
```

`make` alone runs `build`; see `make help` for the full list. Or open
`skyformac.xcodeproj` in Xcode and run/test normally (⌘R / ⌘U) — the Makefile
just wraps the equivalent `xcodebuild` invocations with a pinned
`-derivedDataPath ./build`.

CI (`.github/workflows/ci.yml`) runs `make build`/`make test` on GitHub Actions'
`macos-15` runners on every push/PR.

## Using Skyformac

### Connecting a camera

The sidebar's **Cameras** list shows any ZWO ASI camera currently connected over
USB — click **Connect**. Below it, **iPhone / Webcam** lists Continuity Camera
and other AVFoundation sources (an iPhone needs to be wired over USB, or nearby
and signed into the same Apple ID for wireless Continuity Camera); click
**Connect** there for a webcam/iPhone source instead. Use the refresh button at
the top of the sidebar to rescan either list.

Once connected, the toolbar's status pill shows the connection state and ZWO SDK
version, and the main pane starts streaming a live preview.

### The live preview and toolbar

- **GPU / CPU** toggle (⌘M) — switches between the Metal (GPU compute shader)
  and CGImage (CPU) render paths for debayer/stretch/histogram. GPU is the
  default; denoise, wavelet sharpening, and GPU live stacking need it on.
- **Night Mode** (⌘⇧N) — a red-only UI tint, to preserve dark adaptation.
- **All-Sky Monitor** (⌘⇧A) — a picture-in-picture feed from a secondary
  webcam or nearby iPhone, independent of the main capture pipeline, for
  keeping an eye on clouds or cabling. Has its own brightness/motion alerts.
- Pinch (or the zoom badge) to zoom into the preview 1×–8×, drag to pan once
  zoomed in; double-click to reset.
- The format picker (RAW8/RAW16) appears when the connected camera supports
  more than one; webcam/iPhone sources are always RGB24, so it's hidden then.

### Controls panel

The right-hand panel always shows **Single Exposure** (with a log-scale slider
spanning microseconds to tens of seconds — real ASI exposure ranges don't fit a
linear slider) and **Export**. A **Mode** picker (General / Planetary / Deep
Sky / All Tools) filters the rest down to what's relevant for the session type;
"All Tools" always shows everything:

- **Focus Assist** — live star detection with a sharpness readout; turn on
  **Recognize Stars** underneath it to identify which catalog stars are in
  frame and (once identification is confident enough) show real catalog-object
  badges over the live view.
- **Smart Exposure** — measures read noise and sky background from real frames
  and recommends a sub-exposure length.
- **Planetary Auto-Center** — Vision-tracked disk with an optional
  auto-cropped ROI, for planetary work.
- **Polar Alignment** — two-frame rotation-center solve from star
  correspondences, with a live on-screen correction vector.
- **Image Enhancement** — real-time denoise and wavelet sharpening.
- **Calibration (Dark/Flat)** — capture and manage any number of named dark
  and flat frames; toggle subtraction/correction independently.
- **Live Stack** — running-average stacking of the live feed.
- **Lucky Imaging** — burst capture, keeping only the sharpest fraction,
  stacked.
- **Export** — PNG/TIFF/FITS, for the current frame or a stack.
- **Record to Disk** — continuous recording with a GPU sharpness gate (only
  writes frames sharp enough to be worth keeping) and a disk-space guardrail.

Dynamic per-camera controls (gain, offset, cooler, etc. — whatever the
connected ZWO camera actually reports) show below the fixed sections.

### Permissions

First connection to a USB ASI camera may prompt via System Settings → Privacy &
Security — keep the camera connected when you grant it. Using a webcam/iPhone
source, or the optional All-Sky Monitor, requests separate camera access the
first time each is used; declining either leaves the rest of the app unaffected.

## Examples

First real first-light test session — August 10, 2026, from a not-so-dark
suburban sky, on a Maksutov 125/1500mm on an alt-azimuth mount, with a ZWO ASI
678MC. No dark/flat calibration, no stacking beyond the app's own live GPU
enhancement pipeline — straight off the live view.

**Arcturus** — an initial bright-star test to confirm focus and framing before
hunting anything fainter. High gain (402) and a not-so-dark sky show up as
real sensor/sky noise here, which is expected and exactly what this shot was
for:

![Arcturus live view](examples/arcturus-first-test-picture.png)

[▶ Watch the live-view recording](https://github.com/giulioroggero/skyformac/releases/download/v0.1.12/arcturus-first-test.mov) (94s, 3018×1902)

**M13 (Hercules Globular Cluster)** — individual stars resolved live, with
Live GPU Enhancement Controls (temporal + spatial denoise, non-linear
contrast stretch) enabled, straight off the ASI678MC's live feed with no
post-processing:

![M13 live view with GPU enhancement](examples/m13-test-picture.png)

[▶ Watch the live-view recording](https://github.com/giulioroggero/skyformac/releases/download/v0.1.12/m13-test.mov) (49s, 3018×1902)

The two `.mov` recordings above are hosted as [release assets](https://github.com/giulioroggero/skyformac/releases/tag/v0.1.12) rather than checked into the repository directly — they're well over GitHub's 100MB per-file limit for a normal git push.

## Project documentation

Technical details — project layout, rendering/threading architecture, and the
non-obvious design decisions behind them — live in [`docs/`](docs/):

- [`docs/architecture.md`](docs/architecture.md) — what's in each part of the
  codebase.
- [`docs/design-notes.md`](docs/design-notes.md) — decisions and gotchas worth
  knowing before changing the capture/rendering pipeline.
- [`docs/features.md`](docs/features.md) — the current feature set in detail.

## Contributing

New non-trivial features go through spec-driven development — see
[`specs/README.md`](specs/README.md) for how that works and how to add one.

## License

GPLv3 — see [`LICENSE.md`](LICENSE.md), including the additional permission
(GPLv3 §7) that specifically allows linking this GPLv3 code against
closed-source camera driver SDKs. The vendored ZWO ASI Camera SDK under
`Vendor/ZWO/` (`ASICamera2.h`, `libASICamera2.dylib`) is proprietary
third-party software, © ZWO Co., Ltd., under its own SDK terms, used here
under that permission — see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
for the full notice.
