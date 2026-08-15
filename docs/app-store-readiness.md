# Mac App Store readiness

Tracks what's actually done, what's been verified, and what's still genuinely open toward
submitting Skyformac to the Mac App Store. Not a checklist to rubber-stamp — several items below
are real open risks, not just remaining paperwork.

## Done and verified in this codebase

- **`NSLocationWhenInUseUsageDescription`** added to `Info.plist` — `CoreLocationProvider` calls
  `CLLocationManager.requestWhenInUseAuthorization()`/`requestLocation()`, which requires this key
  regardless of sandboxing; it was missing before.
- **`PrivacyInfo.xcprivacy`** added, declaring the two "required reason" API categories the app
  actually calls: `NSPrivacyAccessedAPICategoryUserDefaults` (`AppSettings`, own-app-only, reason
  `1C8F.1`) and `NSPrivacyAccessedAPICategoryDiskSpace` (`DiskSpaceChecker`, reason `E174.1`).
  **Re-check both reason codes against Apple's current published list before submitting** —
  Apple revises/adds reasons periodically and this wasn't cross-checked against a live account.
- **`com.apple.security.network.client`** and **`com.apple.security.files.user-selected.read-write`**
  added to the entitlements file. Both are inert while App Sandbox is off (see below) — added now
  so they're already in place the moment sandboxing is turned on, rather than a change that has to
  be remembered later.
- Verified the app still builds, launches, and the full unit test suite (528 tests) passes with
  the new entitlements/Info.plist/privacy manifest in place.

## Not done — App Sandbox is deliberately still OFF

`com.apple.security.app-sandbox` stays `false`. Turning it on isn't a small toggle here; two real
problems need solving first, not just verifying:

1. **Existing users' data would appear to vanish.** `ProjectStore`/`EquipmentLibrary`/
   `AstronomyKnowledgeBase`/`AIChatLibrary` all default to `FileManager.default.urls(for:
   .documentDirectory, ...)`. Under App Sandbox that call returns the app's own private container
   Documents folder, not the real `~/Documents` — so anyone who already has
   `~/Documents/Skyformac Projects` from a pre-sandbox version would find it empty the first time
   they launch a sandboxed build, not just need to re-grant access to it. This needs an actual
   one-time migration (detect the old location, prompt, copy or bookmark it) before sandboxing can
   ship, not just security-scoped bookmarks for the Settings-chosen custom folders.
2. **The ZWO ASI SDK's sandbox compatibility is unverified.** `libASICamera2`'s raw USB access
   needs `com.apple.security.device.usb` (already present) plus
   `com.apple.security.cs.disable-library-validation` (already present, since the dylib isn't
   signed with this app's own certificate) to even load. Whether a real ASI camera actually still
   connects and streams under a sandboxed, hardened-runtime build is untested — there's no ZWO
   camera in this environment to test against. `disable-library-validation` alongside App Sandbox
   is also a plausible App Review friction point on its own; it may draw extra scrutiny or a
   rejection requiring justification, independent of whether it technically works.

**Recommended next step, if this is still wanted**: build the Documents-folder migration first
(testable without any camera), ship a build with sandboxing on to a TestFlight-style internal
build, and separately test camera connectivity on real hardware before committing to a submission
date.

## Open questions that aren't code problems

- **GPLv3 and the App Store's terms.** Skyformac is GPLv3-licensed (`LICENSE`,
  `THIRD_PARTY_NOTICES.md`). Apple's own Store terms have historically been read by some
  GPL-licensed projects as incompatible with GPLv3 §6 (restrictions the Store's DRM/usage terms
  arguably impose) — this has caused real apps to be pulled or never submitted in the past. Worth
  resolving (talk to a lawyer, or the FSF's own guidance, or relicense the specific distributed
  binary) before any submission, not after.
- **Apple Developer Program enrollment.** Distribution requires an active paid membership
  ($99/year) tied to a real Apple ID — something only the account owner can do.
- **App Store Connect setup.** Listing metadata, screenshots, age rating, pricing — administrative
  work in App Store Connect, not this repo.
- **Code signing for distribution.** The project currently signs "to run locally"
  (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`). Distribution needs a real Team ID and an
  App Store distribution certificate/provisioning profile, set up once Developer Program
  enrollment above exists.
