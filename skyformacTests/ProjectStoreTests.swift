import Foundation
import Testing
@testable import skyformac

struct ProjectStoreTests {
    private func makeStore() -> (store: ProjectStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ProjectStore(rootDirectory: root), root)
    }

    @Test func loadAllProjectsIsEmptyForAFreshRoot() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.loadAllProjects().isEmpty)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Messier Marathon", goal: "See as many Messier objects as possible")
        project.tags = ["marathon", "deep-sky"]
        project.sessions = [Session.newSession(name: "Night 1", goal: "M13, M57", plannedObjects: ["M13", "M57"])]

        try store.save(project)
        let loaded = store.loadAllProjects()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Messier Marathon")
        #expect(loaded.first?.sessions.first?.name == "Night 1")
        #expect(loaded.first?.sessions.first?.plannedObjects == ["M13", "M57"])
    }

    @Test func saveCreatesAFolderPerProjectAndPerSession() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Saturn Project")
        let session = Session.newSession(name: "First Light")
        project.sessions = [session]
        try store.save(project)

        var isDirectory: ObjCBool = false
        let projectFolder = store.projectFolderURL(for: project)
        #expect(FileManager.default.fileExists(atPath: projectFolder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)

        let sessionFolder = store.sessionFolderURL(for: session, in: project)
        #expect(FileManager.default.fileExists(atPath: sessionFolder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func renamingDoesNotChangeTheFolderName() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Original Name")
        let originalFolderName = project.folderName
        try store.save(project)

        project.name = "Renamed Project"
        try store.save(project)
        #expect(project.folderName == originalFolderName)

        let loaded = store.loadAllProjects().first
        #expect(loaded?.name == "Renamed Project")
        #expect(loaded?.folderName == originalFolderName)
    }

    @Test func deleteRemovesTheProjectFolder() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project.newProject(name: "To Delete")
        try store.save(project)
        #expect(store.loadAllProjects().count == 1)

        try store.delete(project)
        #expect(store.loadAllProjects().isEmpty)
    }

    @Test func deleteSessionRemovesItFromTheProjectAndFromDisk() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Multi Session Project")
        let keep = Session.newSession(name: "Keep Me")
        let remove = Session.newSession(name: "Remove Me")
        project.sessions = [keep, remove]
        try store.save(project)

        let sessionFolder = store.sessionFolderURL(for: remove, in: project)
        #expect(FileManager.default.fileExists(atPath: sessionFolder.path))

        try store.deleteSession(remove.id, in: &project)
        #expect(project.sessions.count == 1)
        #expect(project.sessions.first?.id == keep.id)
        #expect(!FileManager.default.fileExists(atPath: sessionFolder.path))

        let reloaded = store.loadAllProjects().first
        #expect(reloaded?.sessions.count == 1)
    }

    @Test func setArchivedPersists() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Archive Me")
        try store.save(project)
        try store.setArchived(true, for: &project)
        #expect(project.isArchived)

        let reloaded = store.loadAllProjects().first
        #expect(reloaded?.isArchived == true)
    }

    @Test func setArchivedForSessionPersists() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Has A Session")
        let session = Session.newSession(name: "Archive This One")
        project.sessions = [session]
        try store.save(project)

        try store.setArchived(true, forSessionID: session.id, in: &project)
        #expect(project.sessions.first?.isArchived == true)

        let reloaded = store.loadAllProjects().first
        #expect(reloaded?.sessions.first?.isArchived == true)
    }

    @Test func recordCaptureMovesFileAndAppendsARecord() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Capture Project")
        let session = Session.newSession(name: "Capture Session")
        project.sessions = [session]
        try store.save(project)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([1, 2, 3]).write(to: sourceURL)

        let record = try store.recordCapture(
            movingFileAt: sourceURL, kind: .png, thumbnail: Data([9, 9, 9]), into: session, project: &project
        )

        #expect(!FileManager.default.fileExists(atPath: sourceURL.path)) // moved, not copied
        let destination = store.sessionFolderURL(for: session, in: project).appendingPathComponent(record.fileName)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(project.sessions.first?.captures.count == 1)
        #expect(project.sessions.first?.captures.first?.kind == .png)
        #expect(record.thumbnailFileName != nil)

        let thumbnailURL = store.thumbnailsFolderURL(for: session, in: project).appendingPathComponent(record.thumbnailFileName!)
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    }

    @Test func recordCaptureWithoutAThumbnailStillRecords() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "No Thumbnail Project")
        let session = Session.newSession(name: "Session")
        project.sessions = [session]
        try store.save(project)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
        try Data([1, 2, 3]).write(to: sourceURL)

        let record = try store.recordCapture(movingFileAt: sourceURL, kind: .fits, thumbnail: nil, into: session, project: &project)
        #expect(record.thumbnailFileName == nil)
    }

    @Test func sanitizeForFilenameStripsInvalidCharacters() {
        let sanitized = ProjectStore.sanitizeForFilename("M13 / M57: Night?")
        // Every character invalid in a path component (/, :, ?) is gone; nothing else is touched.
        #expect(!sanitized.contains("/"))
        #expect(!sanitized.contains(":"))
        #expect(!sanitized.contains("?"))
        #expect(sanitized.contains("M13"))
        #expect(sanitized.contains("M57"))
        #expect(sanitized.contains("Night"))
    }

    @Test func folderNameIsNeverEmptyEvenForAnAllInvalidName() {
        let folderName = Project.makeFolderName(name: "///???", id: UUID())
        #expect(!folderName.isEmpty)
    }

    @Test func projectAllPlannedObjectsIsDeduplicatedAndSorted() {
        var project = Project.newProject(name: "Dedup Test")
        project.sessions = [
            Session.newSession(name: "A", plannedObjects: ["M13", "Saturn"]),
            Session.newSession(name: "B", plannedObjects: ["Saturn", "M57"]),
        ]
        #expect(project.allPlannedObjects == ["M13", "M57", "Saturn"])
    }
}
