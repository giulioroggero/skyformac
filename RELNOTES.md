# Release Notes

Curated, human-readable highlights for each Skyformac release. For the
complete, unabridged technical log — every change, not just the notable
ones — see [`CHANGELOG.md`](CHANGELOG.md).

## v0.6.0 — 2026-08-27

### New: Mosaic capture and composition

Capture overlapping tiles of a target too large for one frame — different
parts of the Moon to build a full-disk mosaic, or adjacent fields of a wide
object like Andromeda — with a dedicated "Capture Mosaic Tile" button, then
select 2 or more of them in a session's Timeline and choose "Compose
Mosaic…" to stitch them together. This is real star-pattern (asterism) tile
registration: each tile's stars are detected and matched against its
neighbor's, a similarity transform (rotation/scale/translation) is fit via
least squares, and the tiles are composited with feathered edges for a
smooth seam — not the same-field-of-view stacking Planetary Post-Processing
already does, which would reject a genuine tile offset as noise.

### New: Sky Atlas improvements

The Projects browser's Sky Atlas view (a real RA/Dec chart of every
session's target) now groups points by object instead of one dot per
session, sizes each point by how many sessions have targeted it, and labels
points with the object's name. A shaded band shows roughly what's up
overnight, opposite the Sun. The bundled catalog also grew by 254 real
NGC/IC objects, so far fewer sessions land in "Not Shown on the Atlas."

### New: multi-select post-processing, everywhere

A session's capture Timeline (filmstrip, with a real checkbox to enable
selection) and Table both support multi-select, feeding the same bulk
actions: "Post-Process Together…" (stack multiple `.ser` captures as one
run) and "Compose Mosaic…" (see above).

### New: Post-Processing/Edit Image/preview windows you can actually move

Planetary Post-Processing, Edit Image, and the full-screen image preview
each open in a real, independently movable and resizable window instead of
a sheet stuck to the parent window — with a new **Window** menu offering
"Tile Windows" and "Cascade Windows" once you've got several open.

### New adjustments

- **Chroma Noise Reduction** — cleans up colored speckle in the background
  without touching real detail.
- **Posterize** — a stylistic finishing effect.
- **Center Object** — shifts the image so its brightness-weighted centroid
  lands in the exact middle of the frame.
- A new **Gallery** page collects every post-processed/elaborated image
  across all projects in one place.

### Fixed

- **Projects could silently vanish from "All Projects."** A backward-
  compatibility bug in how a saved image's adjustment settings decode meant
  a project with an older elaborated image could fail to load at all — no
  data was ever at risk (the files on disk were always valid), but the app
  wouldn't show them. Fixed.
- Live Capture's own frame browser could get stuck on a loading spinner
  forever when the Metal (GPU) renderer was active. Fixed.
- Planetary Post-Processing's live wavelet-sharpen/stretch preview could pin
  every CPU core after a burst of slider changes, and stay pinned even after
  closing the window. Fixed — a superseded render now actually stops instead
  of running to completion unseen.
- Project thumbnails on the Projects browser's grid didn't render at a
  consistent size. Fixed.
- Various smaller fixes: a full-screen preview's "Done" button not
  reliably closing the window, the Capture page's histogram clipping at the
  bottom and briefly freezing the live view, a cramped slider layout, and
  more — see `CHANGELOG.md` for the complete list.

### Changed

- Menus that hand an elaborated image off to an external tool
  (Siril/GraXpert/StarNet/PixInsight) now consistently lead with Skyformac's
  own "Edit Image…" first, and are consolidated into one shared "Third-Party
  Tools" submenu instead of being mixed in with in-app actions.
- The Dashboard and Session pages group related sections into named,
  collapsible clusters instead of stacking everything independently — less
  scrolling for a project with a lot of history, nothing hidden by default.
