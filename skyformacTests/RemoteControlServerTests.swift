import Foundation
import Network
import Testing
@testable import skyformac

/// End-to-end over a real loopback socket, not just compiling the message types — connects with a
/// plain `NWConnection` speaking the exact same length-prefixed-JSON framing
/// `RemoteControlServer` itself uses, so a break in the actual wire format (not just the Swift
/// types) would be caught here.
@MainActor
struct RemoteControlServerTests {
    /// A minimal stand-in for the iOS app's own connection code — just enough framing to drive
    /// `RemoteControlServer` from a test. Deliberately not shared production code: duplicating a
    /// dozen lines of framing here is cheaper than adding a test-only escape hatch to the real
    /// client this doesn't have yet.
    final class TestClient: @unchecked Sendable {
        private let connection: NWConnection

        init(port: UInt16) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }

        func connect() async {
            await withCheckedContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        continuation.resume()
                    }
                }
                connection.start(queue: .main)
            }
        }

        func send(_ message: RemoteProtocol.ClientMessage) {
            guard let payload = try? JSONEncoder().encode(RemoteEnvelope(message: message)) else { return }
            var length = UInt32(payload.count).bigEndian
            var framed = Data(bytes: &length, count: 4)
            framed.append(payload)
            connection.send(content: framed, completion: .contentProcessed { _ in })
        }

        func receiveOneMessage() async -> RemoteProtocol.ServerMessage? {
            guard let lengthData = await receive(exactly: 4), lengthData.count == 4 else { return nil }
            let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
            guard let payload = await receive(exactly: length) else { return nil }
            return try? JSONDecoder().decode(RemoteEnvelope<RemoteProtocol.ServerMessage>.self, from: payload).message
        }

        private func receive(exactly length: Int) async -> Data? {
            await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        func cancel() { connection.cancel() }
    }

    private func makeServer() -> (server: RemoteControlServer, manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))
        // A throwaway suite, not `.standard` — otherwise every test run would permanently trust
        // "test-device-1"/"test-device-2" in the real app's actual preferences.
        let defaults = UserDefaults(suiteName: "RemoteControlServerTests-\(UUID().uuidString)")!
        let server = RemoteControlServer(cameraManager: manager, projectsLibrary: manager.projectsLibrary, userDefaults: defaults)
        return (server, manager, root)
    }

    /// Polls `server.port` briefly — `NWListener` binds asynchronously, so it isn't set the
    /// instant `start()` returns.
    private func waitForPort(_ server: RemoteControlServer) async -> UInt16? {
        for _ in 0..<50 {
            if let port = server.port { return port }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    @Test func startedServerAcceptsAConnectionAndRejectsAWrongPairingCode() async throws {
        let (server, _, root) = makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try server.start()

        let port = await waitForPort(server)
        #expect(port != nil)
        let client = TestClient(port: port!)
        await client.connect()
        defer { client.cancel() }

        client.send(.pair(deviceID: "test-device-1", code: "000000"))
        // Astronomically unlikely to collide with the real random code, and even if it did, the
        // assertion below would just be checking the wrong thing rather than flaking — accepted
        // for a test this cheap to run many times over.
        let reply = await client.receiveOneMessage()
        #expect(reply == .paired(success: false))
    }

    @Test func pairingWithTheRealCodeThenListingProjectsReturnsWhatWasSaved() async throws {
        let (server, manager, root) = makeServer()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let project = Project.newProject(name: "Remote Test Project")
        try manager.projectsLibrary.save(project)
        try server.start()

        let port = await waitForPort(server)
        #expect(port != nil)
        let client = TestClient(port: port!)
        await client.connect()
        defer { client.cancel() }

        // `server.pendingPairingCode` is set inside `accept(_:)`, which fires when the server's
        // own `NWListener` processes the new connection — not guaranteed to have happened yet
        // just because the *client* side of that same connection already reached `.ready`.
        var code: String?
        for _ in 0..<50 {
            if let pending = server.pendingPairingCode { code = pending; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let code else {
            Issue.record("Server never generated a pairing code")
            return
        }
        client.send(.pair(deviceID: "test-device-2", code: code))
        let pairedReply = await client.receiveOneMessage()
        #expect(pairedReply == .paired(success: true))

        client.send(.listProjects)
        let projectsReply = await client.receiveOneMessage()
        guard case .projects(let projects) = projectsReply else {
            Issue.record("Expected .projects, got \(String(describing: projectsReply))")
            return
        }
        #expect(projects.contains { $0.name == "Remote Test Project" })
    }
}
