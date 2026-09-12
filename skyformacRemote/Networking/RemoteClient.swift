import Foundation
import Network

/// The iOS side of "Skyformac Remote" (see `specs/skyformac_Mobile_Remote_Spec.md`) — discovers a
/// Mac's `RemoteControlServer` over Bonjour, connects, pairs, and speaks the same
/// length-prefixed-JSON framing that side uses. `@MainActor @Observable`, same reasoning as
/// `RemoteControlServer` itself: a single low-frequency connection, and every `Network.framework`
/// callback re-enters via `Task { @MainActor in }` rather than assuming "runs on `.main`" proves
/// actor isolation.
@MainActor
@Observable
final class RemoteClient {
    enum Phase: Equatable {
        case idle
        case browsing
        case connecting(name: String)
        /// The Mac is showing a pairing code and waiting for the user to type it in here — not
        /// reached at all for an already-trusted device, which pairs silently on connect.
        case awaitingPairingCode(name: String)
        case connected(name: String)
        case failed(String)
    }

    struct DiscoveredServer: Identifiable, Equatable {
        var id: String { name }
        var name: String
        fileprivate var endpoint: NWEndpoint
    }

    private(set) var phase: Phase = .idle
    private(set) var discoveredServers: [DiscoveredServer] = []

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connectingServerName: String?
    /// One handler for whatever's currently on screen — this app only ever has one active
    /// "waiting for a reply" consumer at a time (the current screen), so there's no need for a
    /// per-request-type or per-request-ID dispatch table yet. Revisit if two screens ever need to
    /// listen concurrently.
    var onMessage: ((RemoteProtocol.ServerMessage) -> Void)?

    /// This install's own stable identifier, sent with every `.pair` so the Mac can recognize a
    /// reconnect — a plain generated/persisted UUID rather than `UIDevice.identifierForVendor`,
    /// so this type has no UIKit dependency and is trivially testable without a real device/
    /// simulator identity. Resolved once in `init()`, not a `lazy var` — `@Observable`'s macro
    /// expansion doesn't support `lazy` (it needs a plain stored property to generate init
    /// accessors for), and there's no benefit to deferring this past construction anyway.
    let deviceID: String

    init() {
        let key = "remoteClientDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: key)
            deviceID = generated
        }
    }

    func startBrowsing() {
        stopBrowsing()
        phase = .browsing
        discoveredServers = []
        let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.bonjourServiceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let servers = results.compactMap { result -> DiscoveredServer? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredServer(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.discoveredServers = servers }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    /// Connects to `server` and immediately attempts pairing — silent (no code needed) if this
    /// device is already trusted, otherwise `phase` becomes `.awaitingPairingCode` and the caller
    /// should prompt for one, then call `submitPairingCode(_:)`.
    func connect(to server: DiscoveredServer) {
        stopBrowsing()
        phase = .connecting(name: server.name)
        connectingServerName = server.name
        let connection = NWConnection(to: server.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleConnectionState(state) }
        }
        connection.start(queue: .main)
        self.connection = connection
    }

    func submitPairingCode(_ code: String) {
        send(.pair(deviceID: deviceID, code: code))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connectingServerName = nil
        phase = .idle
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receiveNextMessage()
            // Attempt pairing right away — an already-trusted device's `code` is ignored
            // server-side, so sending an empty one here is exactly the "silent reconnect" case;
            // `.paired(success:)`'s handler below moves to `.connected` or `.awaitingPairingCode`.
            send(.pair(deviceID: deviceID, code: ""))
        case .failed(let error):
            phase = .failed(error.localizedDescription)
            connection = nil
        case .cancelled:
            // Reached both for an explicit `disconnect()` (which already set `.idle` itself) and
            // an unexpected drop while connected/pairing — either way, `.idle` is the right
            // resting state; the user reconnects via `startBrowsing()` again.
            phase = .idle
        default:
            break
        }
    }

    // MARK: - Framing (mirrors `RemoteControlServer`'s own — see its doc comment)

    /// Not `private` — a screen that needs to ask something beyond what `RemoteClient` itself
    /// tracks (Projects/Sessions/Gallery listing, live view, capture control) calls this directly
    /// rather than this type growing a method per message type.
    func send(_ message: RemoteProtocol.ClientMessage) {
        guard let connection, let payload = try? JSONEncoder().encode(RemoteEnvelope(message: message)) else { return }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func receiveNextMessage() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor in self?.handleLengthPrefix(data, isComplete: isComplete, error: error) }
        }
    }

    private func handleLengthPrefix(_ data: Data?, isComplete: Bool, error: NWError?) {
        guard let connection else { return }
        guard let data, data.count == 4, error == nil else {
            if isComplete || error != nil { self.connection = nil; phase = .idle }
            return
        }
        let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
        guard length > 0, length < 64 * 1024 * 1024 else { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            Task { @MainActor in self?.handlePayload(data, length: length, isComplete: isComplete, error: error) }
        }
    }

    private func handlePayload(_ data: Data?, length: Int, isComplete: Bool, error: NWError?) {
        guard let data, data.count == length, error == nil else {
            if isComplete || error != nil { connection = nil; phase = .idle }
            return
        }
        if let envelope = try? JSONDecoder().decode(RemoteEnvelope<RemoteProtocol.ServerMessage>.self, from: data) {
            handle(envelope.message)
        }
        receiveNextMessage()
    }

    private func handle(_ message: RemoteProtocol.ServerMessage) {
        if case .paired(let success) = message {
            if success, let name = connectingServerName {
                phase = .connected(name: name)
            } else if !success, let name = connectingServerName {
                phase = .awaitingPairingCode(name: name)
            }
            return
        }
        onMessage?(message)
    }
}
