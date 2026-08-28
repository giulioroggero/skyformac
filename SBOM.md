# Software Bill of Materials

What "Sky for Mac" is actually built from and ships with — source dependencies, vendored
binaries, and bundled AI model weights. Kept up to date alongside the code: any commit that adds,
upgrades, or removes something on this list updates this file in the same push. See
[`LICENSE.md`](LICENSE.md) for the full license text of everything with its own license below,
and [`docs/architecture.md`](docs/architecture.md) for how each of these actually fits into the
app.

## First-party

| Component | Description |
| --- | --- |
| Sky for Mac (this repository) | GPLv3, © Giulio Roggero — every `.swift` file under `skyformac/` not listed as vendored/third-party below. |

## Build toolchain (not distributed with the app)

| Tool | Used for |
| --- | --- |
| Xcode / Swift 6 | Building the app itself. |
| Python 3, PyTorch, coremltools | One-time, offline conversion of third-party model weights (PyTorch → Core ML) — see `scripts/models/`. Never bundled with or required by the shipped app; a user running the app needs none of this. |

## Vendored binaries

| Component | Version/commit | License | How it's used |
| --- | --- | --- | --- |
| ZWO ASI Camera SDK (`libASICamera2.dylib`, `Vendor/ZWO/`) | Vendored as provided by ZWO Co., Ltd. | Proprietary (ZWO) — see `LICENSE.md`'s own special exception permitting this | Camera control (`skyformac/Bridging/ZWOSDK`) — no source, closed-source binary only. |

## Bundled AI models

| Model | Source | License | Format/size | Purpose |
| --- | --- | --- | --- | --- |
| Cosmic-ray/hot-pixel mask (`DeepCRCosmicRayMask.mlpackage`) | [profjsb/deepCR](https://github.com/profjsb/deepCR), commit `2943485` (2024-04-18), `learned_models/mask/ACS-WFC.pth` | BSD-3-Clause (full text in `LICENSE.md`) | Core ML `mlprogram`, ~220KB, flexible 64–4096px grayscale input | Edit Image / Planetary Post-Processing's "AI" section → "Remove Cosmic Rays". `UNet2Sigmoid` (2-level U-Net, Conv-BatchNorm-ReLU blocks), converted via `scripts/models/convert_deepcr.py`; validated against the original PyTorch checkpoint (max per-pixel output difference ≈ 4×10⁻⁵). Weight file SHA-256: `e7cb7dd5be21f8e6d82ae02ed3267e01b90e377368f1d00a16fad3ae2132a956`. |

### Researched, not bundled

Three more models were evaluated for the same "AI" section and are **not** included in this
build — listed here for transparency and so a future contributor doesn't re-research the same
ground from scratch:

| Model | License | Why it isn't bundled |
| --- | --- | --- |
| [astrodeepnet/diffusion4astro](https://github.com/astrodeepnet/diffusion4astro) (Bayesian deconvolution via a diffusion model) | MIT | No pretrained weights are published by the authors anywhere (repo, releases, or linked storage) — only training code. Converting/bundling this would require training a model from scratch, which is outside what this app's own build process does. |
| [megvii-research/NAFNet](https://github.com/megvii-research/NAFNet) (CNN-based image restoration) | MIT (own code) + Apache-2.0 (BasicSR-derived portions) | Pretrained weights are hosted on Google Drive/Baidu Netdisk only, both of which block the kind of scripted/headless download this project's build process would need. Architecture itself (plain convs, no attention) is otherwise straightforward to convert. |
| [JingyunLiang/SwinIR](https://github.com/JingyunLiang/SwinIR) (Swin Transformer-based image restoration) | Apache-2.0 | Weights are fetchable (GitHub Releases), but the architecture's windowed self-attention (shifted windows, relative position bias, attention masks) is a substantially harder coremltools conversion than the other candidates — attempting it without dedicated validation time risked shipping a silently-incorrect conversion, which is worse than not shipping it at all. |

`AlessandroGhiotto/deconvolution-Tikhonov` (classical Tikhonov-regularized deconvolution, not a
neural network) is **not** in this table because nothing from that repository was used — its
LICENSE file is absent (all rights reserved, no reuse permission granted), so
`TikhonovDeconvolver.swift` is an original Swift/Accelerate implementation of the well-known
Tikhonov/Landweber regularization technique itself, not a port of that repo's code.

## AI features that call out to a service, not a bundled model

No weights ship for these — they need the user's own local Ollama install or their own API key.

| Feature | Provider(s) | Where |
| --- | --- | --- |
| Session/project planning, sidebar assistant, tag suggestions, descriptions | Ollama (local), Anthropic Claude, Google Gemini — user-selected in Settings | `skyformac/Projects/OllamaPlanner.swift` and its Anthropic/Gemini counterparts |

## Keeping this file current

Update this file in the same commit whenever you:
- Add, upgrade, or remove a vendored binary or bundled model.
- Add a new external service integration (even one with no bundled weights, like an LLM API).
- Convert and bundle one of the "researched, not bundled" models above — move its row up into
  "Bundled AI models" with the same detail level (source commit, license, size, SHA-256, purpose).
