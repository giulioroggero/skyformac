# Specs

This folder is how Skyformac does **spec-driven development**: before a non-trivial
feature gets built, it gets written down first — objective, architecture, and a
concrete milestone checklist — as a Markdown document in this folder. The spec is
the source of truth an implementation (by a person or an AI coding agent) is built
against and checked off, and it stays in the repo afterward as the historical
record of *why* that part of the app looks the way it does.

This isn't process for its own sake: a spec forces the scoping and architecture
decisions to happen up front, in text that can be reviewed and referenced, instead
of being improvised mid-implementation. It's especially valuable when an AI coding
agent is doing the implementation — a good spec is what keeps that work aimed at
the right target across a long session.

## Existing specs

- **`skyformac_ClaudeCode_Spec.md`** — the original spec this whole app was built
  from: a native macOS ZWO ASI camera capture app (discovery, preview, controls,
  RAW16 + debayer + histogram), in four milestones.
- **`skyformac_Catalog_HUD_Spec.md`** — the on-screen catalog-object overlay
  (`SkyHUDView`/`CatalogRepository`/`WCSProjection`): what it needs from a solved
  WCS, the bundled SQLite catalog schema, and the level-of-detail rules for what
  shows at a given field of view.

Implementation status/design notes that came out of building against these specs
live in `docs/`, not here — specs describe intent going in, `docs/` describes what
the codebase actually does.

## Adding a new feature spec

1. **Name it** `skyformac_<FeatureName>_Spec.md`.
2. **Write it before writing code.** A spec that documents a feature already built
   is just documentation with extra steps — the point is deciding the shape of the
   thing before implementation choices get made ad hoc.
3. **Cover these sections** (see the existing specs for the level of detail to aim
   for):
   - **Objective** — what the feature is and why it belongs in the app, in a
     couple of sentences.
   - **Architecture / technical approach** — what new types/files are involved,
     which existing systems it plugs into, any real algorithm or data-model
     decisions (not implementation-level line-by-line detail — the *shape* of the
     solution).
   - **Milestones** — a checklist of concrete, independently-verifiable steps.
     Check them off as they land; a spec with unchecked boxes still in the repo is
     a legitimate signal of what's left to do.
   - **Directives / constraints** — anything a future implementer (human or AI)
     needs to be told explicitly rather than discover the hard way: threading
     rules, things that must not regress, permissions/entitlements implications,
     APIs that don't exist despite looking like they should.
4. **Keep scope honest.** If something is out of scope (no real plate solver, no
   geometric frame alignment, whatever the constraint is), say so in the spec
   itself — that's what lets `docs/design-notes.md` and code comments cite it
   later instead of re-litigating the scoping decision.
5. **Implement against it**, checking off milestones as they're done. If reality
   forces a deviation from the spec (an API turns out not to exist, a milestone
   turns out to be the wrong shape), update the spec to match what was actually
   built — it should stay an accurate record, not a stale plan.
6. **Leave it in the repo** once the feature ships. Specs aren't deleted after
   implementation; they're the paper trail for why the architecture looks the way
   it does.
