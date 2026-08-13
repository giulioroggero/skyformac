import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerFirstRunTests {
    @Test func freshRootStartsWithNoActiveProjectRegardlessOfExistingProjects() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))

        #expect(manager.activeProject == nil)
        #expect(manager.projectsLibrary.projects.isEmpty)
    }

    @Test func existingProjectsAreListedButNoneIsActiveOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootDirectory: root)
        try store.save(Project.newProject(name: "Existing Project"))

        let manager = CameraManager(projectStore: store)

        #expect(manager.activeProject == nil)
        #expect(manager.projectsLibrary.projects.count == 1)
        #expect(manager.projectsLibrary.projects.first?.name == "Existing Project")
    }

    @Test func newProjectRequestsTheCreationSheetAndClosesAnyOpenProject() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))
        manager.setActive(project: Project.newProject(name: "Currently Open"), session: nil)
        #expect(manager.activeProject != nil)

        manager.newProject()

        #expect(manager.activeProject == nil)
        #expect(manager.activeSession == nil)
        #expect(manager.isCreatingNewProjectRequested)
    }

    @Test func switchingProjectClearsTheActiveProjectAndSession() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))
        var project = Project.newProject(name: "Currently Open")
        let session = Session.newSession(name: "Night 1")
        project.sessions = [session]
        manager.setActive(project: project, session: session)

        manager.setActive(project: nil, session: nil)

        #expect(manager.activeProject == nil)
        #expect(manager.activeSession == nil)
    }
}
