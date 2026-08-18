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

    @Test func moveSessionRelocatesItBetweenProjectsInMemoryToo() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = library.createProject(name: "Source")
        try library.save(source)
        let destination = library.createProject(name: "Destination")
        try library.save(destination)
        let session = Session.newSession(name: "Night 1")
        let updatedSource = try library.addSession(session, to: source)

        try library.moveSession(session.id, from: updatedSource, to: destination)

        let reloadedSource = library.projects.first { $0.id == source.id }
        let reloadedDestination = library.projects.first { $0.id == destination.id }
        #expect(reloadedSource?.sessions.isEmpty == true)
        #expect(reloadedDestination?.sessions.first?.id == session.id)
    }

    @Test func moveCaptureWithinTheSameProjectUpdatesInMemoryToo() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Project")
        try library.save(project)
        let source = Session.newSession(name: "Session A")
        let destination = Session.newSession(name: "Session B")
        var updated = try library.addSession(source, to: project)
        updated = try library.addSession(destination, to: updated)
        let capture = CaptureRecord(date: Date(), fileName: "a.fits", thumbnailFileName: nil, kind: .fits)
        try FileManager.default.createDirectory(
            at: library.store.sessionFolderURL(for: source, in: updated), withIntermediateDirectories: true
        )
        try Data("frame".utf8).write(
            to: library.store.sessionFolderURL(for: source, in: updated).appendingPathComponent("a.fits")
        )
        var sourceWithCapture = source
        sourceWithCapture.captures = [capture]
        guard let sourceIndex = updated.sessions.firstIndex(where: { $0.id == source.id }) else {
            Issue.record("source session missing")
            return
        }
        updated.sessions[sourceIndex] = sourceWithCapture
        try library.save(updated)

        try library.moveCapture(
            capture.id, fromSessionID: source.id, toSessionID: destination.id, from: updated, to: updated
        )

        let reloaded = library.projects.first { $0.id == project.id }
        #expect(reloaded?.sessions.first { $0.id == source.id }?.captures.isEmpty == true)
        #expect(reloaded?.sessions.first { $0.id == destination.id }?.captures.first?.id == capture.id)
    }

    @Test func moveCaptureAcrossProjectsUpdatesBothInMemory() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceProject = library.createProject(name: "Source")
        try library.save(sourceProject)
        let destinationProject = library.createProject(name: "Destination")
        try library.save(destinationProject)
        let sourceSession = Session.newSession(name: "Session A")
        let destinationSession = Session.newSession(name: "Session B")
        let updatedSource = try library.addSession(sourceSession, to: sourceProject)
        let updatedDestination = try library.addSession(destinationSession, to: destinationProject)

        let capture = CaptureRecord(date: Date(), fileName: "a.png", thumbnailFileName: nil, kind: .png)
        try FileManager.default.createDirectory(
            at: library.store.sessionFolderURL(for: sourceSession, in: updatedSource), withIntermediateDirectories: true
        )
        try Data("frame".utf8).write(
            to: library.store.sessionFolderURL(for: sourceSession, in: updatedSource).appendingPathComponent("a.png")
        )
        var sourceWithCapture = updatedSource
        guard let sessionIndex = sourceWithCapture.sessions.firstIndex(where: { $0.id == sourceSession.id }) else {
            Issue.record("source session missing")
            return
        }
        sourceWithCapture.sessions[sessionIndex].captures = [capture]
        try library.save(sourceWithCapture)

        try library.moveCapture(
            capture.id, fromSessionID: sourceSession.id, toSessionID: destinationSession.id,
            from: sourceWithCapture, to: updatedDestination
        )

        let reloadedSource = library.projects.first { $0.id == sourceProject.id }
        let reloadedDestination = library.projects.first { $0.id == destinationProject.id }
        #expect(reloadedSource?.sessions.first?.captures.isEmpty == true)
        #expect(reloadedDestination?.sessions.first?.captures.first?.id == capture.id)
    }

    @Test func splitSessionMovesTheCaptureAndEverythingAfterItIntoANewSession() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Project")
        try library.save(project)
        var session = Session.newSession(name: "Original Session", goal: "Widefield", plannedObjects: ["M31"])
        let early = Date(timeIntervalSince1970: 1000)
        let splitPoint = Date(timeIntervalSince1970: 2000)
        let after = Date(timeIntervalSince1970: 3000)
        let earlyCapture = CaptureRecord(date: early, fileName: "a.fits", thumbnailFileName: nil, kind: .fits)
        let splitCapture = CaptureRecord(date: splitPoint, fileName: "b.fits", thumbnailFileName: nil, kind: .fits)
        let laterCapture = CaptureRecord(date: after, fileName: "c.fits", thumbnailFileName: nil, kind: .fits)
        session.captures = [earlyCapture, splitCapture, laterCapture]
        let updated = try library.addSession(session, to: project)

        let sessionFolder = library.store.sessionFolderURL(for: session, in: updated)
        try FileManager.default.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        for name in ["a.fits", "b.fits", "c.fits"] {
            try Data("frame".utf8).write(to: sessionFolder.appendingPathComponent(name))
        }

        let newSession = try library.splitSession(
            session, atCaptureID: splitCapture.id, newSessionName: "New Target", in: updated
        )

        let reloaded = library.projects.first { $0.id == project.id }
        let originalReloaded = reloaded?.sessions.first { $0.id == session.id }
        let newReloaded = reloaded?.sessions.first { $0.id == newSession.id }

        #expect(originalReloaded?.captures.map(\.id) == [earlyCapture.id])
        #expect(newReloaded?.captures.map(\.id).sorted() == [splitCapture.id, laterCapture.id].sorted())
        #expect(newReloaded?.name == "New Target")
        #expect(newReloaded?.goal == "Widefield")
        #expect(newReloaded?.plannedObjects == ["M31"])
    }

    @Test func splitSessionThrowsWhenTheCaptureIsntFound() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = library.createProject(name: "Project")
        try library.save(project)
        let session = Session.newSession(name: "Original Session")
        let updated = try library.addSession(session, to: project)

        #expect(throws: ProjectsLibrary.SplitSessionError.self) {
            try library.splitSession(session, atCaptureID: UUID(), newSessionName: "New Target", in: updated)
        }
    }
}
