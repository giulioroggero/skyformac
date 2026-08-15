import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerSessionLifecycleTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
    }

    private func makeProjectWithSessions(_ count: Int) -> Project {
        var project = Project.newProject(name: "Multi Session Project")
        project.sessions = (0..<count).map { Session.newSession(name: "Night \($0 + 1)") }
        return project
    }

    @Test func endActiveSessionClearsSessionButKeepsProjectAndRemembersIt() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(1)
        let session = project.sessions[0]
        manager.setActive(project: project, session: session)

        manager.endActiveSession()

        #expect(manager.activeSession == nil)
        #expect(manager.activeProject?.id == project.id)
        #expect(manager.lastEndedSessionID == session.id)
    }

    @Test func hasNextSessionIsTrueWhenAnotherSessionFollows() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(2)
        manager.setActive(project: project, session: project.sessions[0])

        #expect(manager.hasNextSession)
    }

    @Test func hasNextSessionIsFalseOnTheLastSession() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(2)
        manager.setActive(project: project, session: project.sessions[1])

        #expect(!manager.hasNextSession)
    }

    @Test func openNextSessionMovesToTheFollowingSession() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(2)
        manager.setActive(project: project, session: project.sessions[0])

        manager.openNextSession()

        #expect(manager.activeSession?.id == project.sessions[1].id)
    }

    @Test func openNextSessionIsANoOpOnTheLastSession() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(2)
        manager.setActive(project: project, session: project.sessions[1])

        manager.openNextSession()

        #expect(manager.activeSession?.id == project.sessions[1].id)
    }

    @Test func createSessionInActiveProjectAddsItAndPersists() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project.newProject(name: "Named Project")
        try manager.projectsLibrary.save(project)
        manager.setActive(project: project, session: nil)

        let created = try #require(manager.createSessionInActiveProject())

        #expect(manager.activeProject?.sessions.contains { $0.id == created.id } == true)
        #expect(manager.projectStore.loadAllProjects().first?.sessions.count == 1)
    }

    @Test func createSessionInActiveProjectDoesNothingWithNoActiveProject() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(manager.createSessionInActiveProject() == nil)
    }

    @Test func deleteActiveSessionRemovesItAndClearsActiveSession() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(1)
        try manager.projectsLibrary.save(project)
        manager.setActive(project: project, session: project.sessions[0])

        manager.deleteActiveSession()

        #expect(manager.activeSession == nil)
        #expect(manager.activeProject?.sessions.isEmpty == true)
        #expect(manager.projectStore.loadAllProjects().first?.sessions.isEmpty == true)
    }

    @Test func showProjectDetailClearsOnlyTheSessionNotTheProject() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(1)
        manager.setActive(project: project, session: project.sessions[0])

        manager.showProjectDetail()

        #expect(manager.activeSession == nil)
        #expect(manager.activeProject?.id == project.id)
        // Unlike endActiveSession(), this doesn't remember the session — it's the "go up to the
        // project page" action, not "come back to this session's history."
        #expect(manager.lastEndedSessionID == nil)
    }

    @Test func showAllProjectsClearsTheSessionAndSetsTheFlag() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(1)
        manager.setActive(project: project, session: project.sessions[0])

        manager.showAllProjects()

        #expect(manager.activeSession == nil)
        #expect(manager.isShowingAllProjectsRequested)
    }

    @Test func showEquipmentListClearsTheSessionAndSetsTheFlag() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(1)
        manager.setActive(project: project, session: project.sessions[0])

        manager.showEquipmentList()

        #expect(manager.activeSession == nil)
        #expect(manager.isShowingEquipmentRequested)
        #expect(!manager.isAddingNewEquipmentRequested)
    }

    @Test func showAddNewEquipmentClearsTheSessionAndSetsItsOwnFlag() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = makeProjectWithSessions(1)
        manager.setActive(project: project, session: project.sessions[0])

        manager.showAddNewEquipment()

        #expect(manager.activeSession == nil)
        #expect(manager.isAddingNewEquipmentRequested)
        #expect(!manager.isShowingEquipmentRequested)
    }

    @Test func requestQuickStartClearsActiveStateAndSetsTheFlag() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.setActive(project: makeProjectWithSessions(1), session: nil)

        manager.requestQuickStart()

        #expect(manager.activeProject == nil)
        #expect(manager.activeSession == nil)
        #expect(manager.isQuickStartRequested)
    }

    @Test func quickStartCreatesAProjectAndSessionNamedAfterTheTargetAndOpensIt() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = manager.quickStart(with: .planetary(.saturn))

        #expect(session.name == "Saturn")
        #expect(session.plannedObjects == ["Saturn"])
        #expect(manager.activeSession?.id == session.id)
        #expect(manager.activeProject?.name == "Saturn")

        let reloaded = manager.projectStore.loadAllProjects().first
        #expect(reloaded?.name == "Saturn")
        #expect(reloaded?.sessions.first?.name == "Saturn")
    }

    @Test func quickStartDefersItsPresetWithNoCameraConnected() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(manager.connectedCamera == nil)

        _ = manager.quickStart(with: .deepSky(.m13))

        #expect(manager.pendingAcquisitionPreset != nil)
        #expect(manager.pendingAcquisitionPreset?.targetID == AcquisitionTarget.deepSky(.m13).id)
    }

    // MARK: - Disconnect-path session cleanup (handleCameraRemoved/handleWebcamDisconnected)

    /// A ZWO camera being unplugged mid-session used to leave a stale Lucky Imaging burst and a
    /// live-view-paused flag behind — reconnecting could then resume into what looked like an
    /// already-running burst from before, rather than a clean slate. `handleCameraRemoved()` now
    /// shares the same session-reset logic `disconnect()` always used.
    @Test func handleCameraRemovedClearsTheLuckyImagingSessionAndResetsLiveView() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.startLuckyImagingBurst(frameCount: 20)
        #expect(manager.luckyImagingSession != nil)

        manager.handleCameraRemoved()

        #expect(manager.luckyImagingSession == nil)
        #expect(manager.isLiveViewActive)
        #expect(manager.currentFrame == nil)
    }

    @Test func handleCameraRemovedClearsSmartLiveStackState() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isSmartLiveStackEnabled = true

        manager.handleCameraRemoved()

        #expect(!manager.isSmartLiveStackEnabled)
    }
}
