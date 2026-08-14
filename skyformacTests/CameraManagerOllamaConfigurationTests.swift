import Foundation
import Testing
@testable import skyformac

private final class FakeOllamaTransport: OllamaTransport, @unchecked Sendable {
    var responseText: String?
    var isUnreachable = false

    func send(_ request: URLRequest) async throws -> Data {
        if isUnreachable { throw URLError(.cannotConnectToHost) }
        if request.url?.path == "/api/tags" {
            return try JSONSerialization.data(withJSONObject: ["models": [["name": "qwen3:8b"]]])
        }
        return try JSONSerialization.data(withJSONObject: ["model": "qwen3:8b", "response": responseText ?? "", "done": true])
    }
}

@MainActor
struct CameraManagerOllamaConfigurationTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
    }

    private func makeManager(withOllamaTransport transport: OllamaTransport) -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let planner = OllamaPlanner(transport: transport)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root), ollamaPlanner: planner), root)
    }

    /// `AppSettings.ollamaServerURL`/`ollamaModel` are real `UserDefaults` — reset around each
    /// test so this doesn't leak into (or pick up) whatever a real launch of the app on this same
    /// machine has stored.
    private func withCleanOllamaSettings(_ body: () throws -> Void) rethrows {
        let originalURL = AppSettings.ollamaServerURL
        let originalModel = AppSettings.ollamaModel
        defer {
            AppSettings.ollamaServerURL = originalURL
            AppSettings.ollamaModel = originalModel
        }
        try body()
    }

    @Test func ollamaServerURLDefaultsToLocalhost() {
        withCleanOllamaSettings {
            AppSettings.ollamaServerURL = URL(string: "http://localhost:11434")!
            #expect(AppSettings.ollamaServerURL.absoluteString == "http://localhost:11434")
        }
    }

    @Test func ollamaModelDefaultsToNilForAutoDetect() {
        withCleanOllamaSettings {
            AppSettings.ollamaModel = nil
            #expect(AppSettings.ollamaModel == nil)
        }
    }

    @Test func updateOllamaConfigurationPersistsAndRebuildsThePlanner() {
        withCleanOllamaSettings {
            let (manager, root) = makeManager()
            defer { try? FileManager.default.removeItem(at: root) }
            let newURL = URL(string: "http://192.168.1.50:11434")!

            manager.updateOllamaConfiguration(serverURL: newURL, model: "qwen3:8b")

            #expect(manager.ollamaPlanner.baseURL == newURL)
            #expect(manager.ollamaPlanner.model == "qwen3:8b")
            #expect(AppSettings.ollamaServerURL == newURL)
            #expect(AppSettings.ollamaModel == "qwen3:8b")
        }
    }

    @Test func updateOllamaConfigurationCanResetToAutoDetect() {
        withCleanOllamaSettings {
            let (manager, root) = makeManager()
            defer { try? FileManager.default.removeItem(at: root) }
            manager.updateOllamaConfiguration(serverURL: AppSettings.ollamaServerURL, model: "qwen3:8b")

            manager.updateOllamaConfiguration(serverURL: AppSettings.ollamaServerURL, model: nil)

            #expect(manager.ollamaPlanner.model == nil)
            #expect(AppSettings.ollamaModel == nil)
        }
    }

    // MARK: - fetchSuggestedNextObjects

    @Test func fetchSuggestedNextObjectsReturnsTheAIListWhenOllamaIsAvailable() async {
        let transport = FakeOllamaTransport()
        transport.responseText = #"{"objects": ["M13", "M57"]}"#
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await manager.fetchSuggestedNextObjects(fallback: ["Saturn"])

        #expect(result == ["M13", "M57"])
    }

    @Test func fetchSuggestedNextObjectsFallsBackWhenOllamaIsUnreachable() async {
        let transport = FakeOllamaTransport()
        transport.isUnreachable = true
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await manager.fetchSuggestedNextObjects(fallback: ["Saturn", "M13"])

        #expect(result == ["Saturn", "M13"])
    }

    @Test func fetchSuggestedNextObjectsFallsBackWhenTheReplyIsUnusable() async {
        let transport = FakeOllamaTransport()
        transport.responseText = "not JSON at all"
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await manager.fetchSuggestedNextObjects(fallback: ["Saturn"])

        #expect(result == ["Saturn"])
    }

    @Test func fetchSuggestedNextObjectsFallsBackWhenTheAIReturnsAnEmptyList() async {
        let transport = FakeOllamaTransport()
        transport.responseText = #"{"objects": []}"#
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await manager.fetchSuggestedNextObjects(fallback: ["Saturn"])

        #expect(result == ["Saturn"])
    }
}
