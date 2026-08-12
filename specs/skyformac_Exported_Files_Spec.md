# Exported Files Spec

## 1. Objective

skyformac could write FITS/PNG/TIFF/SER files but never read any of them back — a
write-only capture tool with no way to revisit "what did I just save" short of
digging through Finder, and no way to look at a previously-captured FITS frame
without a separate app. This feature adds:

1. **A persistent export history** — every single-frame export, continuous-
   recording folder, and SER recording this app writes, recorded with a
   timestamp, surviving a relaunch.
2. **An "Open File…" path** to open any FITS/PNG/TIFF/JPEG file directly, from
   history or from anywhere on disk.
3. **An in-app viewer** for FITS/PNG/TIFF files — for FITS specifically, re-run
   through this app's own debayer/stretch pipeline with adjustable Black
   Point/White Point sliders, since a raw FITS frame isn't a picture on its
   own.

This is deliberately a *viewer*, not an editor or a second processing suite —
no re-stacking, no plate solving, no saving edits back to the file. Real
elaboration (alignment, wavelet sharpening at full strength, stacking) stays
the job of PixInsight/Siril/AutoStakkert!3/RegiStax, matching the scope line
this app already draws for SER recording (`skyformac_AI_Features_Pipeline_Spec.md`
draws an analogous line for streak masking, `docs/design-notes.md` for the
declined AI Denoise/Super-Resolution features).

## 2. Architecture / technical approach

- **`FITSReader`** (new, `skyformac/Rendering/FITSReader.swift`) — the inverse
  of the pre-existing `FITSWriter`: parses the exact subset of the FITS
  standard `FITSWriter` itself produces (`SIMPLE`/`BITPIX`/`NAXIS1`/`NAXIS2`/
  `BZERO`/`BSCALE`/`INSTRUME`/`BAYERPAT` cards, 8- or 16-bit integer pixel
  data) back into a `CapturedFrame`. Not a general-purpose FITS reader —
  multi-HDU files, WCS keywords, and floating-point pixel data are all
  explicitly out of scope, the same way `FITSWriter` never needed to write
  them.
- **`FITSWriter` gains a `BAYERPAT` header card** (`RGGB`/`BGGR`/`GRBG`/
  `GBRG`, the same convention PixInsight/Siril/SharpCap already use) when the
  source was a color camera — without it, a re-opened FITS file has no way to
  know whether/how to debayer at all. Both of `FITSWriter`'s existing call
  sites (single-frame export, continuous recording) now pass the connected
  camera's real `isColorCamera`/`bayerPattern` instead of writing color-blind
  files.
- **`ExportHistoryEntry`** (new, `skyformac/CameraManagement/
  ExportHistoryEntry.swift`) — `{ url, kind (fits/png/tiff/serVideo/
  recordingFolder), date }`, `Codable`, persisted via a new
  `AppSettings.exportHistory` (JSON-encoded in `UserDefaults`, capped at 50
  entries). `CameraManager.recordExport(url:kind:)` appends to it at each of
  the three write sites (`finishExport`, `startRecording`,
  `startSERRecording`).
- **`CameraManager.openExportedFile(_:)`** — dispatches on file extension:
  `.fits`/`.fit` through `FITSReader`, `.png`/`.tif`/`.tiff`/`.jpg`/`.jpeg`
  through `NSImage(contentsOf:)`, anything else reports an error rather than
  guessing. Result lands in `CameraManager.viewingExportedFile`
  (`ExportedFileContent`: `.rawFrame`/`.image`/`.error`).
- **`ExportedFileViewerView`** (new, `skyformac/Views/
  ExportedFileViewerView.swift`) — a `.sheet` on `ContentView` bound to
  `viewingExportedFile != nil`. For `.rawFrame`, re-renders through
  `CGImageRenderer.makeDisplayImage` on every stretch-slider change (an
  on-demand, user-initiated render — the same "rare enough not to need a
  background task" reasoning `currentDisplayImage()` already documents
  elsewhere), auto-stretched on first appearance via the existing
  `DisplayStretch.autoStretch(histogram:)`. Includes a "Debayer as color"
  override + Bayer pattern picker, since a re-opened file's embedded
  metadata might be missing (an older export, predating `BAYERPAT`) or
  simply wrong for what the user wants to see.
- **UI**: a new "Exported Files" `DisclosureGroup` in `ControlsPanelView`'s
  Camera Controls tab, right after **Export** — history list (Reveal in
  Finder / View in skyformac per row, `Kind.isViewableInApp` gating the
  latter) plus an "Open File…" `NSOpenPanel` button and a "Clear History"
  action.

## 3. Milestones

- [x] `FITSWriter` writes a `BAYERPAT` card for color-camera frames; both
      call sites pass real camera color info.
- [x] `FITSReader.read(from:)` round-trips `FITSWriter`'s own output exactly
      (RAW8 mono, RAW16 mono, color with `BAYERPAT`, mono without it),
      verified by `FITSReaderTests`.
- [x] `ExportHistoryEntry`/`AppSettings.exportHistory` persist across a
      simulated relaunch (`UserDefaults`-backed, capped at 50).
- [x] `CameraManager.recordExport` wired into all three write sites
      (`finishExport`, `startRecording`, `startSERRecording`).
- [x] `ExportedFileViewerView` renders FITS (with adjustable stretch) and
      PNG/TIFF/JPEG (direct display), with a working "Reveal in Finder" and
      "Done".
- [x] "Exported Files" section in `ControlsPanelView`, with Help content
      (`setting.exportedFiles`) and a working "?" link to it.
- [x] Drag-and-drop: dropping a FITS/PNG/TIFF/JPEG file anywhere on the main
      window (`ContentView.dropDestination(for: URL.self)`) opens it the
      same way "Open File…" does — the native macOS "just drop it on the
      app" interaction, not gated behind a menu/button every time.
- [x] Exporting "the current frame" while Live Stack is running on the GPU
      render path exports the actual stacked average
      (`MetalFrameRenderer.currentAccumulatedFrame`), not the latest raw
      single frame — a real, previously-undiscovered bug found while
      verifying this feature's own "export correctly" premise; see
      `docs/design-notes.md`.
- [ ] Real end-to-end verification against an actual ZWO camera capture →
      export → reopen round trip — outside what this environment can do
      without physical hardware (see `docs/design-notes.md`'s existing
      "real-hardware validation... outstanding" entry; this feature's
      correctness is verified at the file-format level, not hardware-to-app).

## 4. Directives / constraints

- **Never attempt to become a second image-processing suite.** No re-stacking,
  no plate solving, no wavelet sharpening beyond what `ImageEnhancer`/the GPU
  kernels already do live, no writing modifications back to an opened file.
  If a future request asks for more "elaboration" than a stretch slider and a
  debayer override, that's a signal to point at PixInsight/Siril/
  AutoStakkert!3 instead of building it here.
- **`FITSReader` must never attempt to ASCII-decode pixel data.** The first
  implementation attempt did exactly this (decoding a size-capped prefix of
  the *whole file*, header and pixel bytes together, as one ASCII string) and
  silently failed ("not a FITS file") on any frame whose real sensor values
  happened to include a byte ≥ 128 — i.e., almost any real 8/16-bit image,
  not an edge case. Header cards must be decoded strictly block-by-block
  (2880 bytes at a time), stopping the instant `END` is found, never touching
  bytes past the header's own blocks.
- **`.ser`/recording-folder entries are not viewable in-app, by design** —
  `ExportHistoryEntry.Kind.isViewableInApp` encodes this; don't add SER
  frame extraction/preview without a real justification beyond "why not," per
  the "don't become a second processing suite" directive above.
