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

    @Test func permanentlyDeleteRemovesFromMemoryAndDiskWhenNamed() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "To Delete")
        try library.save(project)
        #expect(library.store.loadAllProjects().count == 1)

        try library.permanentlyDelete(project)
        #expect(library.projects.isEmpty)
        #expect(library.store.loadAllProjects().isEmpty)
    }

    @Test func permanentlyDeleteAnUnsavedUnnamedProjectDoesNotTouchDisk() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject()
        try library.permanentlyDelete(project)
        #expect(library.projects.isEmpty)
    }

    @Test func softDeleteKeepsTheProjectOnDiskButMarksItDeleted() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Soft Delete Me")
        try library.save(project)

        try library.softDelete(project)

        #expect(library.activeProjects.isEmpty)
        #expect(library.deletedProjects.count == 1)
        #expect(library.store.loadAllProjects().first?.deletedAt != nil)
    }

    @Test func softDeleteOfAnUnnamedProjectJustRemovesItFromMemory() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject()
        try library.softDelete(project)

        #expect(library.projects.isEmpty)
    }

    @Test func restoreClearsTheDeletedFlag() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Restore Me")
        try library.save(project)
        try library.softDelete(project)
        let deleted = try #require(library.deletedProjects.first)

        try library.restore(deleted)

        #expect(library.deletedProjects.isEmpty)
        #expect(library.activeProjects.count == 1)
        #expect(library.store.loadAllProjects().first?.deletedAt == nil)
    }

    @Test func permanentlyDeleteAllDeletedRemovesEveryDeletedProjectButNotActiveOnes() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let kept = library.createProject(name: "Kept")
        try library.save(kept)
        let deletedA = library.createProject(name: "Deleted A")
        try library.save(deletedA)
        try library.softDelete(deletedA)
        let deletedB = library.createProject(name: "Deleted B")
        try library.save(deletedB)
        try library.softDelete(deletedB)

        library.permanentlyDeleteAllDeleted()

        #expect(library.deletedProjects.isEmpty)
        #expect(library.activeProjects.map(\.name) == ["Kept"])
        #expect(library.store.loadAllProjects().count == 1)
    }

    @Test func purgeExpiredSoftDeletesRemovesOnlyProjectsPastTheGracePeriod() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var expired = library.createProject(name: "Expired")
        try library.save(expired)
        expired.deletedAt = Calendar.current.date(byAdding: .day, value: -31, to: Date())
        try library.store.save(expired)
        library.reload()

        var stillGraced = library.createProject(name: "Still Graced")
        try library.save(stillGraced)
        stillGraced.deletedAt = Date()
        try library.store.save(stillGraced)
        library.reload()

        library.purgeExpiredSoftDeletes()

        let remainingNames = library.projects.map(\.name)
        #expect(!remainingNames.contains("Expired"))
        #expect(remainingNames.contains("Still Graced"))
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
