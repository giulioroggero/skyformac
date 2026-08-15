import Foundation
import Testing
@testable import skyformac

/// Always fails fast (`.cannotConnectToHost`) rather than making a real network call — the
/// multi-session chat-history tests below only care that a user's own message gets appended and
/// persisted immediately, not what (if anything) Ollama replies with.
private final class UnreachableOllamaTransport: OllamaTransport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> Data {
        throw URLError(.cannotConnectToHost)
    }
}

@MainActor
struct CameraManagerAssistantTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chatsRoot = root.appendingPathComponent("AIChats")
        return (
            CameraManager(
                projectStore: ProjectStore(rootDirectory: root),
                ollamaPlanner: OllamaPlanner(transport: UnreachableOllamaTransport()),
                aiChatLibrary: AIChatLibrary(rootDirectory: chatsRoot)
            ),
            root
        )
    }

    @Test func confirmingCreateProjectSavesANewProject() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.assistantPendingAction = AssistantPendingAction(
            action: .createProject(name: "Messier Marathon", goal: "See many objects"), message: "Create it?"
        )

        manager.confirmAssistantAction()

        #expect(manager.assistantPendingAction == nil)
        let saved = manager.projectsLibrary.projects.first { $0.name == "Messier Marathon" }
        #expect(saved?.goal == "See many objects")
    }

    @Test func confirmingCreateSessionAddsToAnExistingProjectByNameCaseInsensitively() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project.newProject(name: "Messier Marathon")
        try? manager.projectsLibrary.save(project)

        manager.assistantPendingAction = AssistantPendingAction(
            action: .createSession(projectName: "messier marathon", sessionName: "Night 1", goal: "Clusters", plannedObjects: ["M13"]),
            message: "Add it?"
        )
        manager.confirmAssistantAction()

        let updated = manager.projectsLibrary.projects.first { $0.id == project.id }
        #expect(updated?.sessions.count == 1)
        #expect(updated?.sessions.first?.name == "Night 1")
        #expect(updated?.sessions.first?.plannedObjects == ["M13"])
    }

    @Test func confirmingCreateSessionCreatesTheProjectWhenNoneMatches() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        manager.assistantPendingAction = AssistantPendingAction(
            action: .createSession(projectName: "Brand New Project", sessionName: "Night 1", goal: "", plannedObjects: []),
            message: "Add it?"
        )
        manager.confirmAssistantAction()

        let created = manager.projectsLibrary.projects.first { $0.name == "Brand New Project" }
        #expect(created?.sessions.count == 1)
    }

    @Test func confirmingApplyCameraSettingsWithNoCameraConnectedReportsItInstead() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.assistantPendingAction = AssistantPendingAction(
            action: .applyCameraSettings(gain: 100, exposureSeconds: nil, mode: nil), message: "Apply?"
        )

        manager.confirmAssistantAction()

        #expect(manager.assistantPendingAction == nil)
        #expect(manager.assistantMessages.last?.text.contains("No camera is connected") == true)
    }

    @Test func rejectingClearsThePendingActionAndRecordsIt() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.assistantPendingAction = AssistantPendingAction(action: .createProject(name: "P", goal: ""), message: "Create it?")

        manager.rejectAssistantAction()

        #expect(manager.assistantPendingAction == nil)
        #expect(manager.assistantMessages.last?.text == "Okay, I won't do that.")
        // Rejecting doesn't actually create anything.
        #expect(manager.projectsLibrary.projects.isEmpty)
    }

    @Test func rejectingWithNoPendingActionIsANoOp() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        manager.rejectAssistantAction()

        #expect(manager.assistantMessages.isEmpty)
    }

    // MARK: - Camera-mode dock state

    private func makeProjectWithSession() -> (project: Project, session: Session) {
        var project = Project.newProject(name: "P")
        let session = Session.newSession(name: "S")
        project.sessions = [session]
        return (project, session)
    }

    @Test func enteringCameraModeDetachesADockedPanel() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isAssistantPanelVisible = true
        manager.isAssistantDetached = false
        let (project, session) = makeProjectWithSession()

        manager.setActive(project: project, session: session)

        #expect(manager.isAssistantDetached)
    }

    @Test func leavingCameraModeRedocksAPanelThatWasDockedBefore() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isAssistantPanelVisible = true
        manager.isAssistantDetached = false
        let (project, session) = makeProjectWithSession()
        manager.setActive(project: project, session: session)
        #expect(manager.isAssistantDetached) // sanity: entered camera mode detached

        manager.endActiveSession()

        #expect(!manager.isAssistantDetached)
    }

    @Test func leavingCameraModeDoesNotRedockAPanelThatWasAlreadyDetachedBeforehand() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isAssistantPanelVisible = true
        manager.isAssistantDetached = true // already detached by the user's own choice
        let (project, session) = makeProjectWithSession()
        manager.setActive(project: project, session: session)

        manager.endActiveSession()

        // Stays detached — it wasn't docked before camera mode, so there's nothing to restore.
        #expect(manager.isAssistantDetached)
    }

    @Test func closingThePanelDuringCameraModeWinsOverRedocking() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isAssistantPanelVisible = true
        manager.isAssistantDetached = false
        let (project, session) = makeProjectWithSession()
        manager.setActive(project: project, session: session)

        manager.isAssistantPanelVisible = false // user closes it while in camera mode
        manager.endActiveSession()

        #expect(!manager.isAssistantPanelVisible)
    }

    @Test func reopeningThePanelWhileStillInCameraModeShowsItDetachedAgain() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isAssistantPanelVisible = true
        manager.isAssistantDetached = false
        let (project, session) = makeProjectWithSession()
        manager.setActive(project: project, session: session)
        #expect(manager.isAssistantDetached) // sanity: entered camera mode detached

        // The detached panel's own Close button sets isAssistantPanelVisible = false and (via its
        // floating window's own close callback) isAssistantDetached = false too — simulated here
        // directly since that second part happens through AssistantChatPanelController/RootView,
        // not CameraManager itself.
        manager.isAssistantPanelVisible = false
        manager.isAssistantDetached = false

        // Reopening from the menu bar's "AI" toggle, still in camera mode — this used to leave
        // isAssistantDetached false, matching neither RootView's embedded-sidebar condition (which
        // requires activeSession == nil) nor its detached-panel condition (which requires
        // isAssistantDetached), so the panel silently never reappeared at all.
        manager.isAssistantPanelVisible = true

        #expect(manager.isAssistantDetached)
    }

    // MARK: - Multi-session chat history

    @Test func sendingAMessagePersistsANewChatSessionAutoTitledFromIt() async {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        await manager.sendAssistantMessage("What can I see tonight from home?")

        #expect(manager.chatSessions.count == 1)
        #expect(manager.chatSessions.first?.title == "What can I see tonight from home?")
        #expect(manager.currentChatSessionID == manager.chatSessions.first?.id)
    }

    @Test func startingANewChatSessionClearsMessagesButKeepsThePreviousOneSaved() async {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.sendAssistantMessage("First conversation")

        manager.startNewChatSession()

        #expect(manager.assistantMessages.isEmpty)
        #expect(manager.currentChatSessionID == nil)
        #expect(manager.chatSessions.count == 1)
        #expect(manager.chatSessions.first?.messages.isEmpty == false)
    }

    @Test func switchingToAPastChatSessionRestoresItsMessages() async {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.sendAssistantMessage("First conversation")
        let firstID = try! #require(manager.currentChatSessionID)
        manager.startNewChatSession()
        await manager.sendAssistantMessage("Second conversation")

        manager.switchToChatSession(firstID)

        #expect(manager.currentChatSessionID == firstID)
        #expect(manager.assistantMessages.first?.text == "First conversation")
    }

    @Test func deletingTheCurrentlyOpenChatSessionStartsAFreshBlankOne() async {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.sendAssistantMessage("Only conversation")
        let id = try! #require(manager.currentChatSessionID)

        manager.deleteChatSession(id)

        #expect(manager.chatSessions.isEmpty)
        #expect(manager.currentChatSessionID == nil)
        #expect(manager.assistantMessages.isEmpty)
    }

    @Test func renamingAChatSessionUpdatesItsTitleWithoutTouchingItsMessages() async {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        await manager.sendAssistantMessage("Original text")
        let id = try! #require(manager.currentChatSessionID)

        manager.renameChatSession(id, to: "My Renamed Chat")

        #expect(manager.chatSessions.first?.title == "My Renamed Chat")
        #expect(manager.chatSessions.first?.messages.first?.text == "Original text")
    }
}
