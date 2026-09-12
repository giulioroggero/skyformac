# Skyformac Remote — iOS Companion App Spec

## 1. Objective

A new iOS app, built as a second target inside the existing `skyformac.xcodeproj`, that lets you
step away from the Mac during a session and still (a) browse Projects/Sessions/Gallery, (b) see
live session/connection status, (c) watch a streamed live-view preview of whatever the Mac's
camera is currently showing, and (d) remotely start/stop capture — all over the local network.
The Mac keeps doing all the real work: the ZWO/webcam capture pipeline, stacking, and storage all
stay exactly where they are today. The iOS app is a thin remote window onto `CameraManager` and
`ProjectsLibrary`, not a second capture implementation.

Deliberately **not** in scope for v1: the iPhone's own camera as a capture source (that's the
existing, unrelated "iPhone Companion" Continuity Camera feature in `AllSkyMonitorView.swift`'s
`AddiPhoneCompanionSheet` — this spec avoids the word "Companion" in its own naming to prevent
confusion with that), remote exposure/gain/target configuration, APNs push notifications, and any
access from outside the local network.

## 2. Architecture

### 2.1 Why no third-party dependency

The rest of this app is deliberately dependency-free (see `CloudAITransports.swift`'s own doc
comment on why cloud AI calls are plain `URLSession` instead of pulling in a library). Local
device-to-device networking follows the same discipline: `Network.framework`
(`NWListener`/`NWBrowser`/`NWConnection`), which ships with the OS, instead of a bundled
HTTP/WebSocket server library.

### 2.2 Transport

- **Discovery**: Mac advertises via Bonjour (`NWListener` with a `.tcp` service of type
  `_skyformac-remote._tcp`, named after the Mac's computer name). iOS discovers via `NWBrowser`
  scanning that same service type.
- **Framing**: a single persistent `NWConnection` per paired phone, carrying length-prefixed JSON
  messages (4-byte big-endian length, then the UTF-8 JSON payload) — the simplest framing that
  needs no HTTP/WebSocket handshake machinery.
- **Pairing**: first connection shows a 6-digit code in the Mac app's own UI (AirPlay/Handoff-style)
  that the user types once into the iOS app. The Mac persists a small approved-device list (device
  UUID) so reconnects skip the prompt.
- **Security limitation (explicit, deliberate for v1)**: local network only, no TLS, no APNs/public
  internet exposure. The pairing code is the only access control. This is acceptable for a
  same-Wi-Fi remote control and should be called out again if this ever grows beyond that.

### 2.3 Shared model code

`skyformac/Projects/ObservationModels.swift` (`Session`, `ElaboratedImage`, `Project`,
`CaptureRecord`, `Annotation`, `GeoLocation`) is already `Foundation`-only, `Codable`, `Sendable` —
confirmed to have zero AppKit dependency. Add the new iOS target to this file's target membership
directly rather than introducing a new local Swift Package — this project has no existing SPM
modularization (`Vendor/ZWO` is a vendored binary framework, not a local package), and one file
gaining a second target is simpler than standing up a package for a single shared file. Revisit
only if the shared surface grows meaningfully beyond this.

**As actually built** (milestone 2): the naive "just add the target membership" approach didn't
compile as-is — `ObservationModels.swift` transitively reached into several Mac-only files through
nested types and one static function:
- `ElaboratedImage.planetarySettings: PlanetaryPostProcessor.SettingsSnapshot?` needed
  `PlanetaryPostProcessor`'s nested `SettingsSnapshot`/`StackMethod`/`WaveletLayer`,
  `SirilElaborationService`'s nested `PixelRect` (that file uses `Process`, unavailable on iOS
  entirely), and `ImageEditor`'s nested `Adjustments`.
- `CaptureRecord.preset: AcquisitionPreset?` needed `AcquisitionMode`/`AcquisitionPreset`, both
  originally in `AcquisitionTarget.swift` alongside `AcquisitionTarget`/`DeepSkyObject`, which
  reference `PlanetaryPreset` (defined inside the giant Mac-only `CameraManager.swift`).
- Two of `ObservationModels.swift`'s own methods called `ProjectStore.sanitizeForFilename` — a
  pure string function on an otherwise 500+-line real Mac-only filesystem-persistence type.

Fixed by extracting each of these into small top-level (non-nested) declarations in
`skyformac/Projects/PlanetaryElaborationSnapshot.swift` (`ROIPixelRect`, `PlanetaryStackMethod`,
`PlanetaryWaveletLayer`, `ImageAdjustments`, `PlanetarySettingsSnapshot`, `FilenameSanitizer`) and
`skyformac/CameraManagement/AcquisitionPreset.swift` (`AcquisitionMode`, `AcquisitionPreset`,
moved out of `AcquisitionTarget.swift` entirely), with the original locations left as
`typealias`es (or, for `sanitizeForFilename`, a one-line delegating call) so every existing call
site kept compiling unchanged. `ObservationModels.swift` itself was updated to reference the
extracted top-level names directly (e.g. `PlanetarySettingsSnapshot?`, not
`PlanetaryPostProcessor.SettingsSnapshot?`) since it can't reach through a namespace whose base
declaration isn't in the iOS target at all. `AstronomyFilter.swift` (`FilterSelection`,
`AstronomyFilterType`) turned out to already be fully self-contained and was shared as a whole
file, no extraction needed. Verified: both targets build, full Mac suite (895 tests) still passes.

A new shared file, `skyformac/Networking/RemoteProtocol.swift`, defines the wire message types
(plain `Codable`/`Sendable` enums/structs — client→server: `.listProjects`, `.listSessions(projectID:)`,
`.listGalleryImages(projectID:)`, `.fetchImageData(fileRef:)`, `.subscribeLiveView`,
`.unsubscribeLiveView`, `.subscribeSessionStatus`, `.startCapture`, `.stopCapture`; server→client:
`.projects([Project])`, `.sessions([Session])`, `.galleryImages([ElaboratedImage])`,
`.imageData(fileRef:, data: Data)`, `.liveViewFrame(jpeg: Data, timestamp: Date)`,
`.sessionStatus(...)`, `.captureStarted`, `.captureStopped`, `.error(message: String)`). Shared by
both targets the same way as `ObservationModels.swift`.

### 2.4 Mac side: `RemoteControlServer`

New file `skyformac/Networking/RemoteControlServer.swift`. Owns the `NWListener`, tracks connected
`NWConnection`s, decodes incoming `RemoteProtocol` messages, and answers them by calling into the
real `CameraManager`/`ProjectsLibrary`/`ProjectStore` — it never duplicates capture or storage
logic, only relays.

Two integration points worth flagging up front:

- **Live view relay**: re-encodes `CameraManager.currentImage` (`CGImage`) to JPEG at a throttled
  rate (4–8 fps is plenty for a remote monitor, not a smooth video feed) using the same
  `AIVisionImageEncoder.jpegData`-style helper already used elsewhere in this codebase, rather than
  writing a new encoder.
- **Change notification**: `CameraManager` is `@Observable`, which has no built-in
  external-subscriber mechanism outside SwiftUI's own view-body tracking. `RemoteControlServer`
  needs an explicit push hook — e.g. a `NotificationCenter` post (or an `AsyncStream` the server
  subscribes to) fired from the same sites that already mutate `currentFrame`/`connectionState`/
  session state, not a polling timer. Solve this properly during implementation rather than
  papering over it with a poll loop.

Remote capture control goes through one new small wrapper, not the existing per-mode methods
directly: `func remoteStartCapture() async` / `func remoteStopCapture()` on `CameraManager`, scoped
in v1 to whatever capture kind the user already has set up on the Mac (plain recording via
`startRecording(to:)`/`stopRecording()`). Remote selection of capture kind, target, exposure, or
gain is out of scope for v1.

### 2.5 iOS target: "Skyformac Remote"

New SwiftUI iOS app target (iOS 17+, matching the modern SwiftUI surface already used on the Mac
side), sharing `ObservationModels.swift` and `RemoteProtocol.swift` as described above, but with
its own fresh SwiftUI views — none of the Mac's AppKit-flavored views are reused:

- **Discovery/pairing screen**: `NWBrowser` scan results list, pairing-code entry, persists the
  trusted server.
- **Projects → Sessions → Gallery** browser (read-only), fetching real data over the connection.
- **Live View screen**: renders the streamed JPEG frames, shows connection/session status.
- **Capture control**: a single start/stop button reflecting real Mac-side state, per the v1 scope
  above.

`Info.plist` additions required on the iOS target: `NSLocalNetworkUsageDescription` (privacy
string shown on first local-network access) and `NSBonjourServices` declaring
`_skyformac-remote._tcp`. No entitlement changes needed on the Mac side for opening the listening
socket — `skyformac.entitlements` already has `com.apple.security.app-sandbox = false`, so there's
no sandbox restriction to work around there (unlike a hypothetical Mac App Store build, which this
app doesn't target — see `docs/distribution.md`).

## 3. Milestones

- [x] Add the iOS app target to `skyformac.xcodeproj`; a minimal SwiftUI "Hello World" builds and
  runs in Simulator.
- [x] Extend `ObservationModels.swift`'s target membership to the iOS target; confirm (or fix)
  `ElaboratedImage.planetarySettings`'s type is safe to compile there too.
- [x] Add `RemoteProtocol.swift` (message types), shared by both targets.
- [ ] Mac: `RemoteControlServer` — Bonjour advertise + `NWListener`, answers `.listProjects`/
  `.listSessions`/`.listGalleryImages` from real data.
- [ ] iOS: discovery screen (`NWBrowser` scan) + pairing-code entry + persisted trusted server.
- [ ] iOS: Projects → Sessions → Gallery browsing screens, backed by real data over the connection.
- [ ] Mac: live-view frame relay (throttled JPEG stream) wired to `CameraManager.currentImage`,
  with a real change-notification hook (not a polling timer).
- [ ] iOS: Live View screen rendering the streamed frames.
- [ ] Mac: `remoteStartCapture`/`remoteStopCapture` wrapper + session-status push.
- [ ] iOS: start/stop capture control + status indicator, reflecting real Mac-side state.
- [ ] Manual end-to-end test: Mac and iPhone on the same Wi-Fi, a real session running, phone shows
  live view and can start/stop it.

## 4. Directives / constraints

- Local network only; no TLS, no APNs, no internet-facing server — an explicit, deliberate v1
  limitation, not an oversight. Revisit if this ever needs to work over the internet.
- Exactly one remote capture kind in v1 (plain recording, whatever's already configured on the
  Mac). No remote target/exposure/gain configuration.
- Share code via multi-target file membership (as `ObservationModels.swift`/`RemoteProtocol.swift`
  do), not a new local Swift Package, unless the shared surface grows enough to justify one.
- `CameraManager` remains the single source of truth and the only thing that talks to the camera;
  `RemoteControlServer` is a thin protocol adapter, never a parallel capture implementation.
- Don't call this feature "Companion" anywhere in code or UI — that name is already taken by the
  unrelated Continuity-Camera-as-webcam feature (`AddiPhoneCompanionSheet` in
  `AllSkyMonitorView.swift`). Use "Skyformac Remote."
