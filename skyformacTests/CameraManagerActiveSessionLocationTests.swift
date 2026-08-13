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

    @Test func setManualLocationDoesNothingWithNoActiveProject() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!manager.setManualLocationForActiveSession(latitude: 45, longitude: 7, name: "Backyard"))
    }

    @Test func setManualLocationRejectsOutOfRangeCoordinates() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        manager.activeProject = Project.newProject(name: "Test Project")
        #expect(!manager.setManualLocationForActiveSession(latitude: 200, longitude: 7, name: nil))
    }

    @Test func setManualLocationOnAProjectWithNoActiveSessionSetsTheProjectLocation() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        manager.activeProject = Project.newProject(name: "Test Project")
        #expect(manager.setManualLocationForActiveSession(latitude: 45.07, longitude: 7.68, name: "Backyard"))

        let location = try #require(manager.activeProject?.location)
        #expect(location.source == .manual)
        #expect(location.displayName == "Backyard")

        let reloaded = manager.projectStore.loadAllProjects().first
        #expect(reloaded?.location?.displayName == "Backyard")
    }

    @Test func setManualLocationWithAnActiveSessionSetsTheSessionLocationNotTheProjectLocation() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Test Project")
        let session = Session.newSession(name: "Night 1")
        project.sessions = [session]
        manager.activeProject = project
        manager.activeSession = session

        #expect(manager.setManualLocationForActiveSession(latitude: 45.07, longitude: 7.68, name: "Dark Sky Site"))

        #expect(manager.activeProject?.location == nil)
        let sessionLocation = try #require(manager.activeSession?.location)
        #expect(sessionLocation.displayName == "Dark Sky Site")

        let reloaded = manager.projectStore.loadAllProjects().first
        #expect(reloaded?.sessions.first?.location?.displayName == "Dark Sky Site")
    }
}
