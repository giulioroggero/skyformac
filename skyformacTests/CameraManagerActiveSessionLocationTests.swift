import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerActiveSessionLocationTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))
        return (manager, root)
    }

    @Test func setManualLocationRejectsOutOfRangeCoordinates() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project.newProject(name: "Test Project")
        #expect(!manager.setManualLocation(for: project, session: nil, latitude: 200, longitude: 7, name: nil))
    }

    @Test func setManualLocationOnAProjectWithNoSessionSetsTheProjectLocation() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project.newProject(name: "Test Project")
        #expect(manager.setManualLocation(for: project, session: nil, latitude: 45.07, longitude: 7.68, name: "Backyard"))

        let reloaded = manager.projectStore.loadAllProjects().first
        #expect(reloaded?.location?.displayName == "Backyard")
    }

    @Test func setManualLocationWithASessionSetsTheSessionLocationNotTheProjectLocation() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Test Project")
        let session = Session.newSession(name: "Night 1")
        project.sessions = [session]

        #expect(manager.setManualLocation(for: project, session: session, latitude: 45.07, longitude: 7.68, name: "Dark Sky Site"))

        let reloaded = manager.projectStore.loadAllProjects().first
        #expect(reloaded?.location == nil)
        #expect(reloaded?.sessions.first?.location?.displayName == "Dark Sky Site")
    }

    @Test func setManualLocationMirrorsIntoActiveProjectWhenThatProjectIsOpen() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project.newProject(name: "Open Project")
        manager.setActive(project: project, session: nil)

        #expect(manager.setManualLocation(for: project, session: nil, latitude: 45.07, longitude: 7.68, name: "Backyard"))

        #expect(manager.activeProject?.location?.displayName == "Backyard")
    }

    @Test func setManualLocationDoesNotOpenAnUnrelatedProject() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project.newProject(name: "Not Open")
        #expect(manager.activeProject == nil)

        #expect(manager.setManualLocation(for: project, session: nil, latitude: 45.07, longitude: 7.68, name: "Backyard"))

        #expect(manager.activeProject == nil)
    }
}
