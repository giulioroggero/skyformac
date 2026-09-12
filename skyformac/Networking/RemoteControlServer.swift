import Foundation
import Network

/// The Mac side of "Skyformac Remote" (see `specs/skyformac_Mobile_Remote_Spec.md`) — advertises
/// itself over Bonjour, accepts a connection from the paired iPhone, and answers
/// `RemoteProtocol.ClientMessage`s by calling into the real `CameraManager`/`ProjectsLibrary`
/// (never duplicating their logic). `@MainActor`, since `CameraManager`/`ProjectsLibrary` both are
/// — this app's whole point here is a single low-frequency remote-control connection, not a
/// high-throughput data pipe, so hopping to the main actor per message is a non-issue. Every
/// `Network.framework` callback below runs on the main dispatch queue (`.start(queue: .main)`),
/// but Swift's strict concurrency checking doesn't treat "runs on the main queue" as proof of
/// running on the main *actor* — each callback explicitly re-enters via `Task { @MainActor in }`
/// rather than assuming isolation the compiler can't verify.
@MainActor
@Observable
final class RemoteControlServer {
    enum ServerError: Error, LocalizedError {
        case alreadyRunning
        case listenerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "The remote control server is already running."
            case .listenerFailed(let reason): return "Couldn't start the remote control server: \(reason)."
            }
        }
    }

    private(set) var isRunning = false
    /// Set while waiting for the phone to type in the code shown here — `nil` once pairing
    /// succeeds (or if no connection has attempted pairing yet). A real `NWConnection` only ever
    /// has one pairing attempt in flight at a time in this v1 (single-client) scope.
    private(set) var pendingPairingCode: String?
    private(set) var connectionDescription: String?
    /// The actual TCP port `NWListener` bound to — only meaningful once `isRunning`. Not needed
    /// for normal Bonjour-discovered connections (the port travels with the service record), but
    /// lets a test (or a manual "connect by IP" fallback) reach this server directly.
    private(set) var port: UInt16?

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var isActiveConnectionPaired = false
    private weak var cameraManager: CameraManager?
    private weak var projectsLibrary: ProjectsLibrary?
    private let userDefaults: UserDefaults

    /// Device IDs (the iOS app's own `UIDevice.identifierForVendor`, sent once as part of
    /// `.pair`) that have already completed pairing — persisted so a reconnect from the same
    /// phone skips the on-screen code. Not a secret store: a stolen/spoofed device ID would still
    /// need to be on the same local network to matter at all, which is this whole feature's
    /// already-accepted v1 security scope (see the spec's own "Security limitation" note).
    private var trustedDeviceIDs: Set<String> {
        get { Set(userDefaults.stringArray(forKey: "remoteControlTrustedDeviceIDs") ?? []) }
        set { userDefaults.set(Array(newValue), forKey: "remoteControlTrustedDeviceIDs") }
    }

    /// `userDefaults` defaults to `.standard` for real use — injectable so tests don't leak
    /// pairing state into the real app's actual preferences (the same isolation
    /// `ProjectStore(rootDirectory:)` already gives tests for on-disk state).
    init(cameraManager: CameraManager?, projectsLibrary: ProjectsLibrary, userDefaults: UserDefaults = .standard) {
        self.cameraManager = cameraManager
        self.projectsLibrary = projectsLibrary
        self.userDefaults = userDefaults
    }

    /// `CameraManager.init` can't pass `self` while still inside its own
    /// `self.remoteControlServer = RemoteControlServer(...)` assignment (Swift's two-phase init:
    /// `self` isn't usable as a value until that very assignment completes) — it constructs this
    /// with `cameraManager: nil` instead, then calls this immediately after.
    func attach(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
    }

    func start() throws {
        guard !isRunning else { throw ServerError.alreadyRunning }
        // No TLS in v1 — see the spec's own explicit, deliberate "local network only" limitation.
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            throw ServerError.listenerFailed(error.localizedDescription)
        }
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Skyformac", type: RemoteProtocol.bonjourServiceType)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue
                Task { @MainActor in self?.port = port }
            case .failed:
                Task { @MainActor in self?.stop() }
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        isRunning = true
    }

    func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        isActiveConnectionPaired = false
        pendingPairingCode = nil
        connectionDescription = nil
        listener?.cancel()
        listener = nil
        port = nil
        isRunning = false
    }

    /// Only one phone at a time in v1 — a second incoming connection while one is already active
    /// is rejected outright rather than silently displacing the first (a confusing "why did my
    /// phone just disconnect" surprise for whoever's already paired).
    private func accept(_ connection: NWConnection) {
        guard activeConnection == nil else {
            connection.cancel()
            return
        }
        activeConnection = connection
        isActiveConnectionPaired = false
        pendingPairingCode = Self.generatePairingCode()
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleConnectionState(state, for: connection) }
        }
        connection.start(queue: .main)
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .ready:
            connectionDescription = connection.endpoint.debugDescription
            receiveNextMessage(on: connection)
        case .failed, .cancelled:
            guard activeConnection === connection else { return }
            activeConnection = nil
            isActiveConnectionPaired = false
            pendingPairingCode = nil
            connectionDescription = nil
        default:
            break
        }
    }

    private static func generatePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    // MARK: - Framing

    /// 4-byte big-endian length prefix, then the UTF-8 JSON payload — see `RemoteProtocol.swift`'s
    /// own doc comment for why this instead of a full HTTP/WebSocket stack.
    private func send<M: Codable & Sendable>(_ message: M, on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(RemoteEnvelope(message: message)) else { return }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func receiveNextMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor in self?.handleLengthPrefix(data, isComplete: isComplete, error: error, on: connection) }
        }
    }

    private func handleLengthPrefix(_ data: Data?, isComplete: Bool, error: NWError?, on connection: NWConnection) {
        guard let data, data.count == 4, error == nil else {
            if isComplete || error != nil { connection.cancel() }
            return
        }
        let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
        guard length > 0, length < 64 * 1024 * 1024 else { connection.cancel(); return }
        receivePayload(length: length, on: connection)
    }

    private func receivePayload(length: Int, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            Task { @MainActor in self?.handlePayload(data, length: length, isComplete: isComplete, error: error, on: connection) }
        }
    }

    private func handlePayload(_ data: Data?, length: Int, isComplete: Bool, error: NWError?, on connection: NWConnection) {
        guard let data, data.count == length, error == nil else {
            if isComplete || error != nil { connection.cancel() }
            return
        }
        if let envelope = try? JSONDecoder().decode(RemoteEnvelope<RemoteProtocol.ClientMessage>.self, from: data) {
            handle(envelope.message, on: connection)
        }
        // Keep listening regardless of whether this particular payload decoded — a single
        // malformed message shouldn't tear down an otherwise-good connection.
        receiveNextMessage(on: connection)
    }

    // MARK: - Message handling

    private func handle(_ message: RemoteProtocol.ClientMessage, on connection: NWConnection) {
        if case .pair(let deviceID, let code) = message {
            handlePairing(deviceID: deviceID, code: code, on: connection)
            return
        }
        guard isActiveConnectionPaired else { return }
        switch message {
        case .pair:
            break // handled above
        case .listProjects:
            send(RemoteProtocol.ServerMessage.projects(projectsLibrary?.activeProjects ?? []), on: connection)
        case .listSessions(let projectID):
            guard let project = projectsLibrary?.activeProjects.first(where: { $0.id == projectID }) else {
                send(RemoteProtocol.ServerMessage.error(message: "Unknown project."), on: connection)
                return
            }
            send(RemoteProtocol.ServerMessage.sessions(project.sessions), on: connection)
        case .listGalleryImages(let projectID):
            guard let project = projectsLibrary?.activeProjects.first(where: { $0.id == projectID }) else {
                send(RemoteProtocol.ServerMessage.error(message: "Unknown project."), on: connection)
                return
            }
            send(RemoteProtocol.ServerMessage.galleryImages(project.elaboratedImages), on: connection)
        case .fetchImageData(let projectID, let fileName):
            guard let project = projectsLibrary?.activeProjects.first(where: { $0.id == projectID }) else {
                send(RemoteProtocol.ServerMessage.error(message: "Unknown project."), on: connection)
                return
            }
            let url = projectsLibrary?.store.elaboratedImagesFolderURL(for: project).appendingPathComponent(fileName)
            guard let url, let data = try? Data(contentsOf: url) else {
                send(RemoteProtocol.ServerMessage.error(message: "Couldn't read that image."), on: connection)
                return
            }
            send(RemoteProtocol.ServerMessage.imageData(projectID: projectID, fileName: fileName, data: data), on: connection)
        case .subscribeLiveView, .unsubscribeLiveView, .subscribeSessionStatus, .startCapture, .stopCapture:
            // Wired up in a later milestone — see specs/skyformac_Mobile_Remote_Spec.md.
            break
        }
    }

    private func handlePairing(deviceID: String, code: String, on connection: NWConnection) {
        if trustedDeviceIDs.contains(deviceID) {
            isActiveConnectionPaired = true
            pendingPairingCode = nil
            send(RemoteProtocol.ServerMessage.paired(success: true), on: connection)
            return
        }
        guard let expected = pendingPairingCode, code == expected else {
            send(RemoteProtocol.ServerMessage.paired(success: false), on: connection)
            return
        }
        isActiveConnectionPaired = true
        pendingPairingCode = nil
        trustedDeviceIDs.insert(deviceID)
        send(RemoteProtocol.ServerMessage.paired(success: true), on: connection)
    }
}
