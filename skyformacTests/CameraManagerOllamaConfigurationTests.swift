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

    // MARK: - fetchSuggestedNextSession / acceptSuggestedSession

    @Test func fetchSuggestedNextSessionReturnsThePlanWhenOllamaIsAvailable() async {
        let transport = FakeOllamaTransport()
        transport.responseText = #"{"projectName": "Messier Marathon", "name": "M13 Night", "goal": "See M13", "plannedObjects": ["M13"]}"#
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = await manager.fetchSuggestedNextSession()

        #expect(plan == OllamaPlanner.SuggestedSessionPlan(
            projectName: "Messier Marathon", name: "M13 Night", goal: "See M13", plannedObjects: ["M13"]
        ))
    }

    @Test func fetchSuggestedNextSessionReturnsNilWhenOllamaIsUnreachable() async {
        let transport = FakeOllamaTransport()
        transport.isUnreachable = true
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = await manager.fetchSuggestedNextSession()

        #expect(plan == nil)
    }

    @Test func fetchSuggestedNextSessionReturnsNilWhenTheReplyIsUnusable() async {
        let transport = FakeOllamaTransport()
        transport.responseText = "not JSON at all"
        let (manager, root) = makeManager(withOllamaTransport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = await manager.fetchSuggestedNextSession()

        #expect(plan == nil)
    }

    @Test func acceptSuggestedSessionCreatesANewProjectWhenNoneMatches() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = OllamaPlanner.SuggestedSessionPlan(
            projectName: "Brand New Project", name: "First Night", goal: "See M13", plannedObjects: ["M13"]
        )

        manager.acceptSuggestedSession(plan)

        let project = try #require(manager.projectsLibrary.projects.first { $0.name == "Brand New Project" })
        let session = try #require(project.sessions.first { $0.name == "First Night" })
        #expect(session.goal == "See M13")
        #expect(session.plannedObjects == ["M13"])
    }

    @Test func acceptSuggestedSessionAttachesToAnExistingProjectCaseInsensitively() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try manager.projectsLibrary.save(Project.newProject(name: "existing project", goal: "Deep sky"))
        let plan = OllamaPlanner.SuggestedSessionPlan(
            projectName: "Existing Project", name: "Second Night", goal: "See M57", plannedObjects: ["M57"]
        )

        manager.acceptSuggestedSession(plan)

        #expect(manager.projectsLibrary.projects.count == 1)
        let project = try #require(manager.projectsLibrary.projects.first)
        #expect(project.sessions.contains { $0.name == "Second Night" })
    }

    @Test func acceptSuggestedSessionSurfacesAnErrorWhenItsRootFolderCannotBeWrittenTo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))
        let plan = OllamaPlanner.SuggestedSessionPlan(
            projectName: "Locked Out", name: "First Night", goal: "See M13", plannedObjects: ["M13"]
        )

        manager.acceptSuggestedSession(plan)

        #expect(manager.projectsLibrary.projects.isEmpty)
        #expect(manager.lastErrorMessage != nil)
    }
}
