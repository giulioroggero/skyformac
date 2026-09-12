import Foundation

/// The wire format between the Mac's `RemoteControlServer` and the "Skyformac Remote" iOS app —
/// see `specs/skyformac_Mobile_Remote_Spec.md` for the overall design. Plain `Codable`/`Sendable`
/// value types only, shared verbatim by both targets (no AppKit/UIKit, no networking types here —
/// this file just describes what can be said, not how it's sent). Each message is wrapped in
/// `RemoteEnvelope` and framed by the transport as length-prefixed JSON (4-byte big-endian length,
/// then the UTF-8 JSON payload) — see `RemoteControlServer`'s own doc comment for the transport
/// side once that lands.
enum RemoteProtocol {
    /// Bonjour service type both `RemoteControlServer` (advertising) and `RemoteClient`
    /// (browsing) use — lives here, not on either of those Mac-only/iOS-only types, since it's
    /// exactly the kind of thing both sides need to agree on and this file is the one already
    /// shared between them. Must also match the `NSBonjourServices` entry in both targets'
    /// `Info.plist`.
    static let bonjourServiceType = "_skyformac-remote._tcp"

    /// Sent by the iOS app.
    enum ClientMessage: Codable, Sendable, Equatable {
        /// `deviceID` is the iOS app's own stable per-install identifier (`UIDevice
        /// .identifierForVendor`) — sent on every connection, first-time or not, so the Mac can
        /// recognize an already-trusted phone and skip asking for `code` again. `code` is only
        /// actually checked the first time a given `deviceID` connects; a reconnecting trusted
        /// device can send any value there (empty string is fine) since the Mac never looks at it.
        case pair(deviceID: String, code: String)
        case listProjects
        case listSessions(projectID: UUID)
        case listGalleryImages(projectID: UUID)
        /// `fileName` matches `ElaboratedImage.fileName` — resolved against that project's own
        /// `elaboratedImagesFolderURL` on the Mac side, the same way `ProjectDetailPane` does.
        case fetchImageData(projectID: UUID, fileName: String)
        case subscribeLiveView
        case unsubscribeLiveView
        case subscribeSessionStatus
        /// Scoped to whatever capture kind is already configured on the Mac — see the spec's own
        /// v1 constraint (no remote target/exposure/gain selection).
        case startCapture
        case stopCapture
    }

    /// Sent by the Mac.
    enum ServerMessage: Codable, Sendable, Equatable {
        /// `false` (with no further reply to whatever prompted pairing) means the code was wrong —
        /// the client should let the user retry rather than treating this as a fatal error.
        case paired(success: Bool)
        case projects([Project])
        case sessions([Session])
        case galleryImages([ElaboratedImage])
        case imageData(projectID: UUID, fileName: String, data: Data)
        /// `timestamp` lets the client discard a late-arriving frame behind one it already
        /// rendered, instead of visibly flickering backwards on a slow/jittery connection.
        case liveViewFrame(jpeg: Data, timestamp: Date)
        case sessionStatus(RemoteSessionStatus)
        case captureStarted
        case captureStopped
        case error(message: String)
    }
}

/// A snapshot of the Mac's own capture state, just enough for the phone to show something
/// meaningful without needing `CameraManager`'s own full `CameraConnectionState`/`currentFrame`
/// machinery (which isn't `Codable` and isn't meant to be — this is a deliberately thin summary,
/// not a mirror of Mac-side state).
struct RemoteSessionStatus: Codable, Sendable, Equatable {
    enum Connection: String, Codable, Sendable {
        case disconnected, connecting, connected, streaming, error
    }

    var connection: Connection
    /// Set only when `connection == .error` — `RemoteControlServer` derives this from
    /// `CameraManager.connectionState`'s own associated message.
    var errorMessage: String?
    var isRecording: Bool
    var activeSessionID: UUID?
    var activeSessionName: String?
}

/// One full message on the wire — a message plus which target it's about, where relevant messages
/// need one (a bare `.listProjects` doesn't; `.imageData` does, via its own `projectID` field, so
/// this envelope only adds framing concerns, not routing ones already carried by the message
/// itself). Kept minimal on purpose: no request/response correlation ID in v1 — the connection
/// carries exactly one client, so replies are matched by message *type* alone (one outstanding
/// request per type at a time), not by ID. Revisit if that ever stops being true (e.g. concurrent
/// requests of the same type).
struct RemoteEnvelope<Message: Codable & Sendable>: Codable, Sendable {
    var message: Message
}
