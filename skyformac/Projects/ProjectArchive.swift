import Foundation

/// Packages a whole project folder (its `project.json`, every session subfolder, every capture
/// file and thumbnail) into one `.zip` file — and unpacks one back — so a project can be handed to
/// another user or machine as a single file instead of "zip this folder yourself and hope the
/// receiving end reconstructs the layout correctly." Shells out to `/usr/bin/ditto` (macOS's own
/// archive utility, already the standard tool for zipping a whole directory tree on this platform)
/// rather than pulling in a third-party archiving dependency for the one feature that needs it.
enum ProjectArchive {
    enum ArchiveError: Error, LocalizedError {
        case dittoFailed(status: Int32)
        case noProjectFound
        case invalidProjectFile

        var errorDescription: String? {
            switch self {
            case .dittoFailed(let status): "Couldn't read/write the project archive (ditto exited with status \(status))."
            case .noProjectFound: "The archive doesn't contain a recognizable project folder."
            case .invalidProjectFile: "The project.json inside the archive couldn't be read."
            }
        }
    }

    /// Zips `projectFolder` to `destinationZipURL`, overwriting any existing file there.
    /// `--keepParent` preserves the folder's own name inside the archive, so
    /// `importProject(from:into:)` can find it as the one top-level entry once extracted.
    static func archive(projectFolder: URL, to destinationZipURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
            try FileManager.default.removeItem(at: destinationZipURL)
        }
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", projectFolder.path, destinationZipURL.path])
    }

    /// Unpacks `zipURL` into a fresh, uniquely-named project folder under `projectsRoot`, assigning
    /// the imported project a brand-new `id`/`folderName` — never the ones the exporting machine
    /// used. Without this, re-importing the same export twice, or two different people's exports
    /// that happened to trace back to the same original project, would silently collide with (or
    /// overwrite) whatever's already in this library sharing that `id`.
    static func importProject(from zipURL: URL, into projectsRoot: URL) throws -> Project {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        try runDitto(["-x", "-k", zipURL.path, tempDirectory.path])

        let contents = try fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        guard let extractedFolder = try contents.first(where: { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true })
        else {
            throw ArchiveError.noProjectFound
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: extractedFolder.appendingPathComponent("project.json")),
              var project = try? decoder.decode(Project.self, from: data)
        else {
            throw ArchiveError.invalidProjectFile
        }

        project.id = UUID()
        project.folderName = Project.makeFolderName(name: project.name, id: project.id)

        try fileManager.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let destinationFolder = projectsRoot.appendingPathComponent(project.folderName, isDirectory: true)
        try fileManager.moveItem(at: extractedFolder, to: destinationFolder)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedData = try encoder.encode(project)
        try updatedData.write(to: destinationFolder.appendingPathComponent("project.json"), options: .atomic)

        return project
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiveError.dittoFailed(status: process.terminationStatus)
        }
    }
}
