# Contributing to Skyformac

Skyformac is still in active development, and contributions are very
welcome — testing against real cameras/mounts, feature proposals, code, bug
reports, anything.

## Ways to help

- **Test against real hardware.** Only the ZWO ASI camera line is verified
  against physical devices today; the webcam/Continuity Camera path and
  guiding (ST4) support need real-world testing. If you have a ZWO (or
  other) camera, mount, or other astro gear you'd be willing to lend or send
  to the author for compatibility testing, that's especially appreciated.
- **Report bugs** via [Issues](https://github.com/giulioroggero/skyformac/issues)
  using the bug report template — include macOS version, camera/hardware
  model, and steps to reproduce.
- **Propose features** via [Issues](https://github.com/giulioroggero/skyformac/issues)
  using the feature request template.
- **Contribute code** — see below.

## Before you open a pull request

- For a small, obvious fix (typo, small bug), just open a PR.
- For anything non-trivial — a new feature, a behavior change, a new
  camera/device integration — please open an issue or discussion first so
  the approach can be agreed on before you put in the work. New non-trivial
  features go through spec-driven development; see
  [`specs/README.md`](../specs/README.md) for how that works and how to add
  one.

## Development setup

See the main [README](../README.md#requirements) and
[Building and running](../README.md#building-and-running) sections for
toolchain requirements and `make` targets. In short:

```
make build   # build into ./build
make test    # run the unit tests and UI tests
make run     # build and launch skyformac.app
```

CI (`.github/workflows/ci.yml`) runs `make build`/`make test` on every
push/PR — make sure both pass locally before opening a PR.

## Pull requests

- Keep PRs focused — one change per PR is easier to review than a bundle of
  unrelated fixes.
- Update relevant docs (`README.md`, `docs/`, `CHANGELOG.md`'s
  `[Unreleased]` section) alongside code changes where it applies.
- Explain the *why* in the PR description, not just the *what* — the diff
  already shows what changed.

## Project documentation

Technical details — project layout, rendering/threading architecture, and
the non-obvious design decisions behind them — live in
[`docs/`](../docs/):

- [`docs/architecture.md`](../docs/architecture.md) — what's in each part of
  the codebase.
- [`docs/design-notes.md`](../docs/design-notes.md) — decisions and gotchas
  worth knowing before changing the capture/rendering pipeline.
- [`docs/features.md`](../docs/features.md) — the current feature set in
  detail.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you're expected to uphold it.

## License

By contributing, you agree that your contributions will be licensed under
the project's [GPLv3 license](../LICENSE.md).
