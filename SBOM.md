# Software Bill of Materials

Every third-party binary, model, script, data file, and distributable artifact "Sky for Mac"
ships or is built with — each with its version/commit, license, and a checksum where one applies.
Kept up to date alongside the code: any commit that adds, upgrades, or removes something on this
list updates this file in the same push. See [`LICENSE.md`](LICENSE.md) and
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for full license text, and
[`docs/architecture.md`](docs/architecture.md) for how each of these fits into the app.

## First-party

| Component | Version | License |
| --- | --- | --- |
| Sky for Mac (this repository) | 0.6.0 (`MARKETING_VERSION`, `skyformac.xcodeproj`) | GPLv3 (+ the ZWO SDK linking exception, see `LICENSE.md`) |

## Build toolchain

Used to build the app and, separately, to convert third-party model weights offline — none of
this ships inside the app itself; a user running Sky for Mac needs none of it.

| Tool | Version (as last built/verified) | Used for |
| --- | --- | --- |
| Xcode | 26.6 (build 17F113) | Building the app. |
| Swift | 6.0 (main target; `SWIFT_VERSION` in `skyformac.xcodeproj/project.pbxproj`) | Language/toolchain. |
| macOS deployment target | 14.0 (`MACOSX_DEPLOYMENT_TARGET`) | Minimum supported OS. |
| Python | 3.x (via `pyenv`) | Running the one-time model-conversion/catalog-build scripts below. |
| PyTorch | 2.6.0 | Loading `deepCR`'s checkpoint for conversion (`scripts/models/convert_deepcr.py`). |
| coremltools | 9.0 | PyTorch → Core ML conversion. |
| Pillow (PIL) | latest available at conversion time | Validating the converted model's output against the original in `convert_deepcr.py`. |

## Vendored binaries

| Component | Version/identity | License | Checksum | How it's used |
| --- | --- | --- | --- | --- |
| ZWO ASI Camera SDK (`libASICamera2.dylib`, universal x86_64+arm64, `Vendor/ZWO/lib/`) | Not embedded as a version string in the binary itself (call `ASIGetSDKVersion()` at runtime for the exact string, e.g. `"1, 13, 0503"`-shaped) — vendored 2026-08-08 | Proprietary (ZWO Co., Ltd.) — see `LICENSE.md`'s linking exception | SHA-256 `ed667802a10f6da9b841f58ef71e5cf578ab68998ebcd537b0cc2fbaf67af39f` | Camera control (`skyformac/Bridging/ZWOSDK`) — closed-source binary only, no source. |
| `Vendor/ZWO/include/ASICamera2.h` | Matching header, vendored alongside the dylib above | Proprietary (ZWO Co., Ltd.) | — | C API declarations for the Swift bridge. |

## Bundled AI models

| Model | Source commit | License | Format/size | Checksum | Purpose |
| --- | --- | --- | --- | --- | --- |
| Cosmic-ray/hot-pixel mask (`skyformac/Resources/Models/DeepCRCosmicRayMask.mlpackage`) | [profjsb/deepCR](https://github.com/profjsb/deepCR) commit `2943485` (2024-04-18), `learned_models/mask/ACS-WFC.pth` | BSD-3-Clause (full text in `LICENSE.md`) | Core ML `mlprogram`, 220KB, flexible 64–4096px grayscale input | Weight file (`weights/weight.bin`) SHA-256 `e7cb7dd5be21f8e6d82ae02ed3267e01b90e377368f1d00a16fad3ae2132a956` | Edit Image / Planetary Post-Processing's "AI" section → "Remove Cosmic Rays". Converted via `scripts/models/convert_deepcr.py`, validated against the original PyTorch checkpoint (max per-pixel output difference ≈ 4×10⁻⁵). |

## Bundled data

| File | Size | Source | License | Checksum (SHA-256) |
| --- | --- | --- | --- | --- |
| `skyformac/Resources/SkyCatalog/messier.json` | 23,854 B | Extracted from Stellarium's bundled DSO catalog | GPLv2 (per `THIRD_PARTY_NOTICES.md`)¹ | `05e640fe8dc5e6e20beb8b1a6d5066fb69429be41659a63d1c31580ccc975655` |
| `skyformac/Resources/SkyCatalog/caldwell.json` | 24,584 B | Extracted from Stellarium's bundled DSO catalog | GPLv2 (per `THIRD_PARTY_NOTICES.md`)¹ | `93dc33fa7ea52889262b5b469b67e77114852c876d0e5aa608f5079377a53490` |
| `skyformac/Resources/SkyCatalog/ngc.json` | 50,597 B | Extracted from Stellarium's bundled DSO catalog | GPLv2 (per `THIRD_PARTY_NOTICES.md`)¹ | `42d3cc61ddb96dbfb7bd8153418b693eee1e342685115f240adacbbf27523dc3` |
| `skyformac/Resources/SkyCatalog/bright_stars.json` | 1,881 B | Hand-curated by this project (~14 stars) | Sky for Mac's own GPLv3 | `1c3fbf8b2bf7c8541a4c014dc036fb00ffce8edebe1280ede1fa8f9e896c6fac` |
| `skyformac/Resources/AstroCatalog/astro_catalog.sqlite` | 327,680 B | Built by `scripts/build_astro_catalog.py` from Stellarium's DSO catalog + the `bright_stars.json` above | GPLv2 (per `THIRD_PARTY_NOTICES.md`)¹ | `353daf63024573835c56fbe7a9fba911302cce5458778d3af5da58aa257218f9` |

¹ `scripts/build_astro_catalog.py`'s own header comment cites the Stellarium data specifically as
CC-BY-SA-4.0, while `THIRD_PARTY_NOTICES.md` characterizes the whole Stellarium project as GPLv2 —
these haven't been reconciled against Stellarium's actual per-file licensing; treat this row's
license as provisional until that's checked.

## Scripts

| Script | Lines | Checksum (SHA-256) | Purpose |
| --- | --- | --- | --- |
| `scripts/release.sh` | 106 | `5543909d859ef672af689fd185722ee04db20cde552405bf403adba786dca787` | Builds/signs/notarizes a distributable `.dmg` via a real Developer ID certificate (not used for any release published so far — see `docs/distribution.md`'s "Ad-hoc manual releases" section for what's actually used instead). |
| `scripts/models/convert_deepcr.py` | 135 | `cca4e777db5681f730159124ee24bc0a5ce308c34ae7cccb668d36932dac5871` | One-time PyTorch → Core ML conversion for the bundled cosmic-ray model (see above). |
| `scripts/build_astro_catalog.py` | 179 | `9093b8396096f68a3e7aeb0106c2bd4a0b2d7c7dcc60874c1ff725622de96042` | One-time build of `astro_catalog.sqlite` (see above). |
| `scripts/Fix Gatekeeper Warning.command` | 67 | `a18e984f892af01bc1a37a7d34644140fbb40f4f2e850630a0929761f3badd7e` | Ships *inside* the `.dmg`/`.zip` release assets (not run at build time) — clears the quarantine flag on an ad-hoc-signed, non-notarized build so Gatekeeper allows it to launch. |

## Distributed release artifacts

The latest tagged release's actual built/published assets — rebuilt (and this table updated)
for every new tag.

| Artifact | Tag | Size | Checksum (SHA-256) |
| --- | --- | --- | --- |
| `skyformac-v0.6.0-macOS.dmg` | [v0.6.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.6.0) | 12,275,218 B | `26b5a4aa43b5e280d0b592971f9f6fcfa1c43a4cb6df098bb42ada33df3c89cc` |
| `skyformac-v0.6.0-macOS.zip` | [v0.6.0](https://github.com/giulioroggero/skyformac/releases/tag/v0.6.0) | 10,484,776 B | `c266a499b0955aaf1b7ad9093d5110cb0b9b546e7434c61946f41f31cd51cb21` |

Both built via the "Ad-hoc manual releases" process in `docs/distribution.md` (ad-hoc codesigning,
not a notarized Developer ID build); `Casks/skyformac.rb`'s own `sha256` is kept in sync with the
`.dmg` row above.

## AI features that call out to a service, not a bundled model

No weights ship for these — they need the user's own local Ollama install, or their own API key
for a cloud provider selected in Settings.

| Feature | Provider(s) | Where |
| --- | --- | --- |
| Session/project planning, sidebar assistant, tag suggestions, descriptions | Ollama (local, any installed model — no fixed version dependency), Anthropic Claude (`claude-3-5-haiku-latest` default), Google Gemini (`gemini-2.0-flash` default) | `skyformac/Projects/OllamaPlanner.swift`, `skyformac/Projects/CloudAITransports.swift` |

## Keeping this file current

Update this file in the same commit whenever you:
- Add, upgrade, or remove a vendored binary, bundled model, bundled data file, or script.
- Cut a new release — update the "Distributed release artifacts" table with the new tag's real
  asset sizes/checksums (`shasum -a 256`).
- Add a new external service integration (even one with no bundled weights, like an LLM API).
- Bump the ZWO SDK, Xcode/Swift version, or any conversion-toolchain version listed above.
