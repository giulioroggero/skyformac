import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerFirstRunTests {
    @Test func freshRootAutoOpensTheProjectsBrowserOnAnEmptyProject() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CameraManager(projectStore: ProjectStore(rootDirectory: root))

        #expect(manager.isProjectsBrowserPresented)
        #expect(manager.projectsLibrary.projects.count == 1)
        #expect(manager.projectsLibrary.projects.first?.name == "")
    }

    @Test func existingProjectsDoNotAutoOpenTheBrowser() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(rootDirectory: root)
        try store.save(Project.newProject(name: "Existing Project"))

        let manager = CameraManager(projectStore: store)

        #expect(!manager.isProjectsBrowserPresented)
        #expect(manager.projectsLibrary.projects.count == 1)
        #expect(manager.projectsLibrary.projects.first?.name == "Existing Project")
    }
}
