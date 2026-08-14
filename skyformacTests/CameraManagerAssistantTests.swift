import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerAssistantTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
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
}
