import Foundation
import Testing
@testable import skyformac

/// `ProjectArchive.archive(projectFolder:to:)`/`importProject(from:into:)` shell out to the real
/// `/usr/bin/ditto` — deliberately not faked, since the one thing worth verifying here is that a
/// real project folder survives a real zip/unzip round trip intact, with the identity guarantees
/// `importProject` is supposed to provide (a fresh id/folderName, never colliding with the
/// original).
@MainActor
struct ProjectArchiveTests {
    private func makeProjectFolder(in root: URL) throws -> (project: Project, store: ProjectStore) {
        let store = ProjectStore(rootDirectory: root)
        var project = Project.newProject(name: "Messier Marathon", goal: "See them all")
        let session = Session.newSession(name: "Night One", goal: "M13 and M57", plannedObjects: ["M13", "M57"])
        project.sessions = [session]
        try store.save(project)
        return (project, store)
    }

    @Test func archiveThenImportRoundTripsTheProjectContent() throws {
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destinationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
            try? FileManager.default.removeItem(at: zipURL)
        }
        let (project, store) = try makeProjectFolder(in: sourceRoot)

        try ProjectArchive.archive(projectFolder: store.projectFolderURL(for: project), to: zipURL)
        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        let imported = try ProjectArchive.importProject(from: zipURL, into: destinationRoot)

        #expect(imported.name == project.name)
        #expect(imported.goal == project.goal)
        #expect(imported.sessions.map(\.name) == project.sessions.map(\.name))
        #expect(imported.sessions.first?.plannedObjects == ["M13", "M57"])
    }

    @Test func importAssignsAFreshIdentityRatherThanReusingTheOriginal() throws {
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destinationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
            try? FileManager.default.removeItem(at: zipURL)
        }
        let (project, store) = try makeProjectFolder(in: sourceRoot)
        try ProjectArchive.archive(projectFolder: store.projectFolderURL(for: project), to: zipURL)

        let imported = try ProjectArchive.importProject(from: zipURL, into: destinationRoot)

        #expect(imported.id != project.id)
        #expect(imported.folderName != project.folderName)
        #expect(imported.folderName.contains(imported.id.uuidString.prefix(8)))
    }

    @Test func importingTheSameArchiveTwiceProducesTwoIndependentProjects() throws {
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destinationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: destinationRoot)
            try? FileManager.default.removeItem(at: zipURL)
        }
        let (project, store) = try makeProjectFolder(in: sourceRoot)
        try ProjectArchive.archive(projectFolder: store.projectFolderURL(for: project), to: zipURL)

        let first = try ProjectArchive.importProject(from: zipURL, into: destinationRoot)
        let second = try ProjectArchive.importProject(from: zipURL, into: destinationRoot)

        #expect(first.id != second.id)
        #expect(first.folderName != second.folderName)
        let destinationStore = ProjectStore(rootDirectory: destinationRoot)
        #expect(destinationStore.loadAllProjects().count == 2)
    }

    @Test func importThrowsInvalidProjectFileForAZipWithNoProjectJSON() throws {
        let junkFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destinationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: junkFolder)
            try? FileManager.default.removeItem(at: destinationRoot)
            try? FileManager.default.removeItem(at: zipURL)
        }
        try FileManager.default.createDirectory(at: junkFolder, withIntermediateDirectories: true)
        try Data("not a project".utf8).write(to: junkFolder.appendingPathComponent("notes.txt"))
        try ProjectArchive.archive(projectFolder: junkFolder, to: zipURL)

        #expect(throws: ProjectArchive.ArchiveError.self) {
            try ProjectArchive.importProject(from: zipURL, into: destinationRoot)
        }
    }
}
