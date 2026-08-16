import Foundation

/// Filesystem persistence for `Project`/`Session` — one folder per project under
/// `rootDirectory` (`~/Documents/Skyformac Projects` by default; injectable, mainly for
/// testing against a temp directory instead of the user's real Documents folder), each
/// containing its own `project.json` plus one subfolder per session (each with its own
/// `session.json`, the session's actual capture files, and a `Thumbnails/` subfolder).
///
/// Deliberately not a database — the realistic number of projects/sessions for one person's
/// observing history is small enough that "read every project.json on launch" is plenty fast,
/// and plain JSON files are trivially inspectable/backupable/sync-able (iCloud Drive, Time
/// Machine, a manual copy to another machine) without this app needing to know anything about
/// that, the same "one file per preset" philosophy `AcquisitionPreset` already uses, just at
/// the folder-per-project/session level instead of one flat file per item.
final class ProjectStore {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL = ProjectStore.defaultRootDirectory(), fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// A user-chosen folder (`AppSettings.customProjectsRootDirectoryPath`, set via Settings)
    /// takes priority over `~/Documents/Skyformac Projects` when one's actually been set.
    static func defaultRootDirectory() -> URL {
        AppSettings.resolveRootDirectory(customPath: AppSettings.customProjectsRootDirectoryPath, defaultFolderName: "Skyformac Projects")
    }

    // MARK: - Paths

    func projectFolderURL(for project: Project) -> URL {
        rootDirectory.appendingPathComponent(project.folderName, isDirectory: true)
    }

    func sessionFolderURL(for session: Session, in project: Project) -> URL {
        projectFolderURL(for: project).appendingPathComponent(session.folderName, isDirectory: true)
    }

    func thumbnailsFolderURL(for session: Session, in project: Project) -> URL {
        sessionFolderURL(for: session, in: project).appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// The thumbnail belonging to `project`'s single most recent capture (across every session)
    /// that actually has one — `nil` for a project with no captures yet, or where every capture so
    /// far failed to generate a thumbnail. What the Home page's grid card shows as the project's
    /// own "cover image," the same way a photo album shows its most recent photo.
    func mostRecentThumbnailURL(for project: Project) -> URL? {
        var best: (session: Session, capture: CaptureRecord)?
        for session in project.sessions {
            for capture in session.captures where capture.thumbnailFileName != nil {
                if best == nil || capture.date > best!.capture.date {
                    best = (session, capture)
                }
            }
        }
        guard let best, let name = best.capture.thumbnailFileName else { return nil }
        return thumbnailsFolderURL(for: best.session, in: project).appendingPathComponent(name)
    }

    /// Same idea as `mostRecentThumbnailURL(for:)`, scoped to one `session` — what a session card
    /// on the Project Detail page shows as its own cover image.
    func mostRecentThumbnailURL(for session: Session, in project: Project) -> URL? {
        guard let best = session.captures.filter({ $0.thumbnailFileName != nil }).max(by: { $0.date < $1.date }),
              let name = best.thumbnailFileName
        else { return nil }
        return thumbnailsFolderURL(for: session, in: project).appendingPathComponent(name)
    }

    private func projectMetadataURL(for project: Project) -> URL {
        projectFolderURL(for: project).appendingPathComponent("project.json")
    }

    private func sessionMetadataURL(for session: Session, in project: Project) -> URL {
        sessionFolderURL(for: session, in: project).appendingPathComponent("session.json")
    }

    // MARK: - Load

    /// Every project this store knows about — every immediate subdirectory of `rootDirectory`
    /// containing a readable `project.json`. Skips (rather than throws for) a subdirectory that
    /// isn't a valid project folder at all, or whose `project.json` fails to decode (a hand-
    /// edited file, a future version's now-incompatible format) — one bad folder shouldn't make
    /// every other project fail to load.
    func loadAllProjects() -> [Project] {
        guard let contents = try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.compactMap { url -> Project? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let metadataURL = url.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: metadataURL) else { return nil }
            return try? decoder.decode(Project.self, from: data)
        }
    }

    // MARK: - Save

    /// Writes `project.json` (metadata only — a project's sessions/notes/tags, not any capture
    /// file bytes, which already live wherever `recordCapture` put them) into the project's own
    /// folder, creating it (and every session subfolder underneath it) first if this is the
    /// first save. Safe to call on every edit — it's a small JSON file, not a bulk file copy.
    func save(_ project: Project) throws {
        let folder = projectFolderURL(for: project)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for session in project.sessions {
            try fileManager.createDirectory(at: sessionFolderURL(for: session, in: project), withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: projectMetadataURL(for: project), options: .atomic)
    }

    // MARK: - Archive / delete

    /// Archiving is a flag, not a move — an archived project's folder stays exactly where it is
    /// (still fully browsable in Finder, still backed up by whatever already backs up
    /// `rootDirectory`), it just stops showing in the main Projects browser by default.
    func setArchived(_ isArchived: Bool, for project: inout Project) throws {
        project.isArchived = isArchived
        try save(project)
    }

    func setArchived(_ isArchived: Bool, forSessionID sessionID: UUID, in project: inout Project) throws {
        guard let index = project.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        project.sessions[index].isArchived = isArchived
        try save(project)
    }

    /// Deletes the project's entire folder — every session, every capture, every thumbnail
    /// underneath it, gone. Real data loss, not a flag flip like `setArchived` — callers are
    /// expected to confirm with the user first (see `ProjectsBrowserView`'s delete confirmation).
    func delete(_ project: Project) throws {
        try fileManager.removeItem(at: projectFolderURL(for: project))
    }

    /// Deletes one session's folder (and everything captured in it) from `project`, then
    /// re-saves the project's own metadata without that session listed. Same real-data-loss
    /// caveat as `delete(_:)` above. The folder removal is a real `try`, not `try?` — a failure
    /// there (permissions, a file still open) now aborts before the session is stripped from
    /// `project.sessions`, rather than proceeding to make the session vanish from the UI while its
    /// files are silently orphaned on disk.
    func deleteSession(_ sessionID: UUID, in project: inout Project) throws {
        guard let session = project.sessions.first(where: { $0.id == sessionID }) else { return }
        let folder = sessionFolderURL(for: session, in: project)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        project.sessions.removeAll { $0.id == sessionID }
        try save(project)
    }

    enum MoveSessionError: Error, LocalizedError {
        /// Extremely unlikely given `Session.folderName` embeds a UUID prefix, but refused
        /// outright rather than risking silently overwriting whatever's already there.
        case destinationFolderAlreadyExists

        var errorDescription: String? {
            switch self {
            case .destinationFolderAlreadyExists:
                return "A folder for this session already exists in the destination project."
            }
        }
    }

    /// Moves `sessionID` from `source` to `destination` — a real on-disk folder move (not
    /// delete-then-recreate, so a failure partway through can't lose any captures), then updates
    /// both projects' in-memory `sessions` arrays and re-saves both `project.json`s. `source`/
    /// `destination` are updated in place so the caller doesn't need to re-derive which project is
    /// which afterward. A no-op if `sessionID` isn't actually in `source`.
    func moveSession(_ sessionID: UUID, from source: inout Project, to destination: inout Project) throws {
        guard let index = source.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = source.sessions[index]
        let sourceFolder = sessionFolderURL(for: session, in: source)
        let destinationFolder = sessionFolderURL(for: session, in: destination)
        guard !fileManager.fileExists(atPath: destinationFolder.path) else {
            throw MoveSessionError.destinationFolderAlreadyExists
        }

        try fileManager.createDirectory(at: projectFolderURL(for: destination), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: sourceFolder.path) {
            try fileManager.moveItem(at: sourceFolder, to: destinationFolder)
        }

        source.sessions.remove(at: index)
        destination.sessions.insert(session, at: 0)
        try save(source)
        try save(destination)
    }

    // MARK: - Captures

    /// Copies `sourceURL` (wherever the actual export/recording was just written) into the
    /// session's own folder, generates a thumbnail for it (best-effort — a failed thumbnail
    /// still lets the capture itself get recorded, just without one), and appends a
    /// `CaptureRecord` to `session.captures` before re-saving the project. This is the one path
    /// that actually populates a session's timeline with real captures — see
    /// `CameraManager.recordActiveSessionCapture` for where it's called from.
    @discardableResult
    func recordCapture(
        movingFileAt sourceURL: URL, kind: CaptureRecord.Kind, thumbnail: Data?, note: String? = nil,
        object: String? = nil, location: GeoLocation? = nil, equipmentSystemID: UUID? = nil,
        preset: AcquisitionPreset? = nil, into session: Session, project: inout Project
    ) throws -> CaptureRecord {
        try recordCapture(
            at: sourceURL, kind: kind, thumbnail: thumbnail, note: note, object: object, location: location,
            equipmentSystemID: equipmentSystemID, preset: preset, into: session, project: &project,
            transfer: fileManager.moveItem
        )
    }

    /// Same as `recordCapture(movingFileAt:...)`, except `sourceURL` is left untouched — used for
    /// capture paths (single-frame export, SER recording) where the original file already lives
    /// wherever the user chose to save it (an `NSSavePanel` destination) and that location must
    /// keep working afterwards; the session folder gets its own curated copy for the timeline
    /// instead of stealing the user's file out from under them.
    @discardableResult
    func recordCapture(
        copyingFileAt sourceURL: URL, kind: CaptureRecord.Kind, thumbnail: Data?, note: String? = nil,
        object: String? = nil, location: GeoLocation? = nil, equipmentSystemID: UUID? = nil,
        preset: AcquisitionPreset? = nil, into session: Session, project: inout Project
    ) throws -> CaptureRecord {
        try recordCapture(
            at: sourceURL, kind: kind, thumbnail: thumbnail, note: note, object: object, location: location,
            equipmentSystemID: equipmentSystemID, preset: preset, into: session, project: &project,
            transfer: fileManager.copyItem
        )
    }

    private func recordCapture(
        at sourceURL: URL, kind: CaptureRecord.Kind, thumbnail: Data?, note: String?,
        object: String?, location: GeoLocation?, equipmentSystemID: UUID?, preset: AcquisitionPreset?,
        into session: Session, project: inout Project, transfer: (URL, URL) throws -> Void
    ) throws -> CaptureRecord {
        let sessionFolder = sessionFolderURL(for: session, in: project)
        try fileManager.createDirectory(at: sessionFolder, withIntermediateDirectories: true)
        let destinationURL = sessionFolder.appendingPathComponent(sourceURL.lastPathComponent)
        // A caller that already wrote directly into the session's own folder (no separate
        // NSSavePanel step — see `CameraManager.exportCurrentFrame`) passes a `sourceURL` that's
        // already exactly `destinationURL`. Without this check, the "remove whatever's already
        // at the destination" step just below would delete that same file out from under itself
        // before `transfer` ever ran, leaving a `CaptureRecord` pointing at nothing.
        if sourceURL.path != destinationURL.path {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            try transfer(sourceURL, destinationURL)
        }

        var thumbnailFileName: String?
        if let thumbnail {
            let thumbnailsFolder = thumbnailsFolderURL(for: session, in: project)
            try fileManager.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true)
            let name = destinationURL.deletingPathExtension().lastPathComponent + ".jpg"
            try thumbnail.write(to: thumbnailsFolder.appendingPathComponent(name))
            thumbnailFileName = name
        }

        let record = CaptureRecord(
            date: Date(), fileName: destinationURL.lastPathComponent, thumbnailFileName: thumbnailFileName, kind: kind,
            note: note, object: object, location: location, equipmentSystemID: equipmentSystemID, preset: preset
        )
        guard let sessionIndex = project.sessions.firstIndex(where: { $0.id == session.id }) else { return record }
        project.sessions[sessionIndex].captures.append(record)
        try save(project)
        return record
    }

    /// Removes one capture's file (and its thumbnail, if any) from `session`'s folder, then
    /// re-saves the project's own metadata without that `CaptureRecord` listed. Same real-data-
    /// loss caveat as `deleteSession(_:in:)` — callers confirm with the user first. A no-op if
    /// `captureID` isn't actually in `session`'s captures (already deleted, wrong ID).
    func deleteCapture(_ captureID: UUID, fromSessionID sessionID: UUID, in project: inout Project) throws {
        guard let sessionIndex = project.sessions.firstIndex(where: { $0.id == sessionID }),
              let capture = project.sessions[sessionIndex].captures.first(where: { $0.id == captureID })
        else { return }
        let session = project.sessions[sessionIndex]
        let fileURL = sessionFolderURL(for: session, in: project).appendingPathComponent(capture.fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if let thumbnailName = capture.thumbnailFileName {
            let thumbnailURL = thumbnailsFolderURL(for: session, in: project).appendingPathComponent(thumbnailName)
            try? fileManager.removeItem(at: thumbnailURL)
        }
        project.sessions[sessionIndex].captures.removeAll { $0.id == captureID }
        try save(project)
    }

    // MARK: - Disk usage

    /// The actual bytes one capture occupies on disk — its main file plus its thumbnail, if any.
    /// Reads real file sizes rather than trusting any cached figure, so this stays correct even
    /// for a capture recorded by an older version of the app that never tracked a size at all.
    func diskUsage(for capture: CaptureRecord, in session: Session, project: Project) -> Int64 {
        var total = fileSize(at: sessionFolderURL(for: session, in: project).appendingPathComponent(capture.fileName))
        if let thumbnailName = capture.thumbnailFileName {
            total += fileSize(at: thumbnailsFolderURL(for: session, in: project).appendingPathComponent(thumbnailName))
        }
        return total
    }

    /// A session's total footprint — the recursive size of its entire on-disk folder (every
    /// capture, every thumbnail, `session.json` itself), not just the sum of its `captures` array,
    /// so a stray/orphaned file left behind by some other bug still counts toward what's actually
    /// using disk space.
    func diskUsage(for session: Session, in project: Project) -> Int64 {
        folderSize(at: sessionFolderURL(for: session, in: project))
    }

    /// A project's total footprint — the recursive size of its entire on-disk folder, all
    /// sessions included. Same "trust the real folder, not the in-memory model" reasoning as
    /// `diskUsage(for:in:)` above.
    func diskUsage(for project: Project) -> Int64 {
        folderSize(at: projectFolderURL(for: project))
    }

    /// Every project's total footprint combined — what the Settings storage tab shows as the
    /// grand total across `rootDirectory`.
    func totalDiskUsage(for projects: [Project]) -> Int64 {
        projects.reduce(0) { $0 + diskUsage(for: $1) }
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func folderSize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Filename sanitizing

    /// Strips everything that isn't safe (or at least pleasant) in a filesystem path component —
    /// used for both `Project.folderName`/`Session.folderName` and `recordCapture`'s destination
    /// name. Collapses to a single placeholder rather than an empty string if nothing survives
    /// (an all-emoji or all-punctuation name, say), since an empty path component is invalid.
    static func sanitizeForFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
    }
}
