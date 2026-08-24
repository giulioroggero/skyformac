# Distribution: Developer ID + notarization (not the Mac App Store)

Skyformac is distributed as a signed, notarized `.dmg` via GitHub Releases and a Homebrew Cask —
**not** through the Mac App Store. That decision (made explicitly, not by default) sidesteps the
two hardest blockers a Store submission would have required: App Sandbox (would need a Documents-
folder migration for existing users, and the ZWO camera SDK's behavior under sandboxing is
untested) and any question of GPLv3's compatibility with the Store's own terms. See
`docs/app-store-readiness.md` for that earlier investigation — kept for reference, not being
pursued.

License stays **GPLv3** throughout; direct distribution outside the Store has no license-
compatibility concern the way Store distribution might.

## One-time setup (do this once, not per release)

1. **Enroll in the Apple Developer Program** ($99/year) at
   [developer.apple.com](https://developer.apple.com/programs/) if not already enrolled.
2. **Create a "Developer ID Application" certificate** — Xcode → Settings → Accounts → your Apple
   ID → Manage Certificates → "+" → "Developer ID Application". This installs the certificate (and
   its private key) into your login keychain; `scripts/release.sh` signs with whatever certificate
   of this type it finds there.
3. **Find your Team ID** — developer.apple.com → Account → Membership Details. You'll pass this as
   `SKYFORMAC_TEAM_ID` every time you run a release build (see below); it's not committed anywhere
   in the repo.
4. **Store notarytool credentials once**, so `scripts/release.sh` doesn't need them passed in every
   time:
   ```
   xcrun notarytool store-credentials "skyformac-notarize" \
     --apple-id "your-apple-id@example.com" \
     --team-id "YOUR_TEAM_ID" \
     --password "an-app-specific-password"
   ```
   The password is an **app-specific password** (appleid.apple.com → Sign-In and Security →
   App-Specific Passwords), not your real Apple ID password. This stores credentials under the
   keychain profile name `skyformac-notarize`, which the script uses by default (override with
   `SKYFORMAC_NOTARY_PROFILE` if you name it differently).

## Cutting a release

1. Bump `MARKETING_VERSION` in the Xcode project (skyformac target's Build Settings, both Debug
   and Release configurations) to the new version number.
2. Update `CHANGELOG.md` — move the `[Unreleased]` content under a new dated version heading.
3. Build, sign, and notarize:
   ```
   export SKYFORMAC_TEAM_ID=YOUR_TEAM_ID
   make release
   ```
   This runs `scripts/release.sh`, which:
   - Archives a Release build (`xcodebuild archive`)
   - Exports it signed with your Developer ID Application certificate
   - Verifies the signature (`codesign --verify`, `spctl --assess`)
   - Packages it as `build/release/Skyformac-<version>.dmg` (the `.app` plus an `/Applications`
     symlink for drag-install)
   - Submits it to Apple for notarization and waits for the result (`notarytool submit --wait`)
   - Staples the notarization ticket to the `.dmg` (`stapler staple`) so Gatekeeper can verify it
     offline, without a network round-trip to Apple at first launch
   - Runs a final Gatekeeper check (`spctl -a -t open`)
4. Tag the release and push:
   ```
   git tag v<version>
   git push origin v<version>
   ```
5. Create the GitHub Release for that tag (`gh release create v<version> build/release/Skyformac-<version>.dmg --title "..." --notes-file ...`, or via the web UI) and attach the `.dmg` as a release asset.
6. Update the Homebrew Cask (`Casks/skyformac.rb`) with the new `version` and the `.dmg`'s real
   SHA-256 (`shasum -a 256 build/release/Skyformac-<version>.dmg`), then copy that same file into
   the tap repo (see below) and push it there too.

## Homebrew Cask

`Casks/skyformac.rb` in this repo is kept in sync with the live formula, not read by Homebrew
directly — the actual tap Homebrew installs from is
[giulioroggero/homebrew-skyformac](https://github.com/giulioroggero/homebrew-skyformac). After
updating the version/SHA-256 here, copy the same file to that repo's own `Casks/skyformac.rb` and
push it there; `brew tap giulioroggero/skyformac` / `brew install --cask skyformac` won't see a
new version until that copy lands.

## What `scripts/release.sh` deliberately does NOT do

Signing/notarization credentials never leave your machine — there's no GitHub Actions automation
for this (a deliberate choice: storing a code-signing certificate and notarization password as CI
secrets is a real security tradeoff, and this project has a comfortable "release when ready, on
the maintainer's own machine" cadence that doesn't need it). CI (`.github/workflows/ci.yml`) only
ever builds a debug, ad-hoc-signed build for running the test suite — it has nothing to do with
producing a real release artifact.
