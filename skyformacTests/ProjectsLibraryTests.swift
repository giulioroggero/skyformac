import Foundation
import Testing
@testable import skyformac

@MainActor
struct ProjectsLibraryTests {
    private func makeLibrary() -> (library: ProjectsLibrary, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ProjectsLibrary(store: ProjectStore(rootDirectory: root)), root)
    }

    @Test func savingAnUnnamedProjectNeverTouchesDisk() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject()
        try library.save(project)

        #expect(library.store.loadAllProjects().isEmpty)
        #expect(library.projects.count == 1)
    }

    @Test func namingAPreviouslyUnnamedProjectPersistsItOnTheNextSave() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = library.createProject()
        project.name = "Messier Marathon"
        try library.save(project)

        #expect(library.store.loadAllProjects().count == 1)
        #expect(library.store.loadAllProjects().first?.name == "Messier Marathon")
    }

    @Test func addSessionInsertsAndPersists() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Named Project")
        try library.save(project)

        let session = Session.newSession(name: "Night 1")
        let updated = try library.addSession(session, to: project)

        #expect(updated.sessions.count == 1)
        #expect(library.projects.first?.sessions.count == 1)
        #expect(library.store.loadAllProjects().first?.sessions.count == 1)
    }

    @Test func deleteRemovesFromMemoryAndDiskWhenNamed() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "To Delete")
        try library.save(project)
        #expect(library.store.loadAllProjects().count == 1)

        try library.delete(project)
        #expect(library.projects.isEmpty)
        #expect(library.store.loadAllProjects().isEmpty)
    }

    @Test func deleteAnUnsavedUnnamedProjectDoesNotTouchDisk() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject()
        try library.delete(project)
        #expect(library.projects.isEmpty)
    }

    @Test func setArchivedPersistsAndUpdatesInMemory() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Archive Me")
        try library.save(project)

        try library.setArchived(true, for: project)
        #expect(library.projects.first?.isArchived == true)
        #expect(library.store.loadAllProjects().first?.isArchived == true)
    }

    @Test func deleteSessionRemovesItFromTheProject() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Has Sessions")
        try library.save(project)
        let session = Session.newSession(name: "Night 1")
        let updated = try library.addSession(session, to: project)

        try library.deleteSession(session.id, in: updated)
        #expect(library.projects.first?.sessions.isEmpty == true)
    }
}
