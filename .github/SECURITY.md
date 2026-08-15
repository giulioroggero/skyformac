# Security Policy

## Supported Versions

Skyformac is pre-1.0 and distributed as a single rolling line of releases —
only the [latest release](https://github.com/giulioroggero/skyformac/releases/latest)
is supported. There is no long-term-support branch.

## Reporting a Vulnerability

Please **do not** open a public issue for a security vulnerability.

Instead, report it privately using
[GitHub's private vulnerability reporting](https://github.com/giulioroggero/skyformac/security/advisories/new),
or by emailing giulio.roggero@gmail.com with details and reproduction steps.

You should get an acknowledgment within a few days. Since this is a small,
maintainer-run project without a dedicated security team, response and fix
timelines are best-effort rather than SLA-backed — but reports are taken
seriously and will be addressed as promptly as possible, with credit given
to the reporter unless anonymity is requested.

## Scope notes

Skyformac is a native macOS app distributed as an ad-hoc-signed, unnotarized
build (see [`docs/distribution.md`](../docs/distribution.md)) — Gatekeeper
warnings on first launch are expected, not a vulnerability report on their
own. Genuine concerns in scope include things like: unsafe handling of
project/session files, unsafe network requests (e.g. the local Ollama AI
integration), or anything that could let a malicious project file or
downloaded asset execute code beyond its expected sandboxed use.
