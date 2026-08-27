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

    /// Where `SirilElaborationService` results land — a project-level folder (not nested under
    /// any one session's), since an elaboration is shown project-wide regardless of which
    /// session/capture triggered it. See `ElaboratedImage`'s doc comment.
    func elaboratedImagesFolderURL(for project: Project) -> URL {
        projectFolderURL(for: project).appendingPathComponent("Elaborated", isDirectory: true)
    }

    /// The thumbnail belonging to `project`'s single most recent capture (across every session)
    /// that actually has one — `nil` for a project with no captures yet, or where every capture so
    /// far failed to generate a thumbnail. What the Home page's grid card shows as the project's
    /// own "cover image," the same way a photo album shows its most recent photo. A user-chosen
    /// `customThumbnailURL(for:)` always wins over this automatic fallback when one's set.
    func mostRecentThumbnailURL(for project: Project) -> URL? {
        if let custom = customThumbnailURL(for: project) { return custom }
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
    /// on the Project Detail page shows as its own cover image. Its own `customThumbnailURL(for:in:)`
    /// wins over the automatic fallback the same way the project-level one does.
    func mostRecentThumbnailURL(for session: Session, in project: Project) -> URL? {
        if let custom = customThumbnailURL(for: session, in: project) { return custom }
        guard let best = session.captures.filter({ $0.thumbnailFileName != nil }).max(by: { $0.date < $1.date }),
              let name = best.thumbnailFileName
        else { return nil }
        return thumbnailsFolderURL(for: session, in: project).appendingPathComponent(name)
    }

    /// `project.customThumbnailFileName`'s actual file, living directly in the project's own
    /// folder — `nil` when no custom thumbnail is set. Kept as a stored filename (not a fixed name
    /// like "cover.png") so the original extension survives whatever image format was picked.
    func customThumbnailURL(for project: Project) -> URL? {
        guard let name = project.customThumbnailFileName else { return nil }
        return projectFolderURL(for: project).appendingPathComponent(name)
    }

    func customThumbnailURL(for session: Session, in project: Project) -> URL? {
        guard let name = session.customThumbnailFileName else { return nil }
        return sessionFolderURL(for: session, in: project).appendingPathComponent(name)
    }

    /// Copies `sourceURL` into `project`'s own folder as its new custom thumbnail, replacing any
    /// previous one — the caller (`ProjectsLibrary`) is responsible for saving the returned
    /// filename onto `project.customThumbnailFileName` afterward.
    func importCustomThumbnail(from sourceURL: URL, for project: Project) throws -> String {
        let name = "cover.\(sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension)"
        let destination = projectFolderURL(for: project).appendingPathComponent(name)
        try fileManager.createDirectory(at: projectFolderURL(for: project), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return name
    }

    /// Same idea as `importCustomThumbnail(from:for:)`, scoped to one session's own folder.
    func importCustomThumbnail(from sourceURL: URL, for session: Session, in project: Project) throws -> String {
        let name = "cover.\(sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension)"
        let destination = sessionFolderURL(for: session, in: project).appendingPathComponent(name)
        try fileManager.createDirectory(at: sessionFolderURL(for: session, in: project), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return name
    }

    /// Deletes `project`'s custom thumbnail file from disk, if it has one — the caller still needs
    /// to separately clear `project.customThumbnailFileName` and save, the same division of
    /// responsibility `importCustomThumbnail(from:for:)` uses.
    func removeCustomThumbnail(for project: Project) {
        guard let url = customThumbnailURL(for: project) else { return }
        try? fileManager.removeItem(at: url)
    }

    func removeCustomThumbnail(for session: Session, in project: Project) {
        guard let url = customThumbnailURL(for: session, in: project) else { return }
        try? fileManager.removeItem(at: url)
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

    enum MoveCaptureError: Error, LocalizedError {
        /// As unlikely as `MoveSessionError.destinationFolderAlreadyExists` (capture file names
        /// already embed a timestamp), but refused outright for the same reason — never silently
        /// overwrite whatever's already there.
        case destinationFileAlreadyExists

        var errorDescription: String? {
            switch self {
            case .destinationFileAlreadyExists:
                return "A file with this name already exists in the destination session."
            }
        }
    }

    /// Moves one capture (its file, thumbnail, and `CaptureRecord`) from `sourceSessionID` to
    /// `destinationSessionID` within the SAME project — a real on-disk file move, not delete-
    /// then-recreate, then updates `project.sessions` in place and re-saves once. A no-op if
    /// either session or the capture itself isn't found.
    func moveCapture(
        _ captureID: UUID, fromSessionID sourceSessionID: UUID, toSessionID destinationSessionID: UUID,
        in project: inout Project
    ) throws {
        guard let sourceIndex = project.sessions.firstIndex(where: { $0.id == sourceSessionID }),
              let destinationIndex = project.sessions.firstIndex(where: { $0.id == destinationSessionID }),
              let captureIndex = project.sessions[sourceIndex].captures.firstIndex(where: { $0.id == captureID })
        else { return }
        let capture = project.sessions[sourceIndex].captures[captureIndex]
        try moveCaptureFiles(
            capture, from: project.sessions[sourceIndex], in: project,
            to: project.sessions[destinationIndex], in: project
        )

        project.sessions[sourceIndex].captures.remove(at: captureIndex)
        // Re-located by ID, not the `destinationIndex` captured above — removing from
        // `sourceIndex` shifts every later index down by one, and `destinationIndex` could be
        // either side of `sourceIndex`.
        guard let refreshedDestinationIndex = project.sessions.firstIndex(where: { $0.id == destinationSessionID })
        else { return }
        project.sessions[refreshedDestinationIndex].captures.insert(capture, at: 0)
        try save(project)
    }

    /// Cross-project variant of the above — `source`/`destination` are two different projects
    /// (their own session, in each), so both in-memory copies are updated and both `project.json`s
    /// re-saved, the same "update both in place" shape as `moveSession`.
    func moveCapture(
        _ captureID: UUID, fromSessionID sourceSessionID: UUID, in source: inout Project,
        toSessionID destinationSessionID: UUID, in destination: inout Project
    ) throws {
        guard let sourceIndex = source.sessions.firstIndex(where: { $0.id == sourceSessionID }),
              let destinationIndex = destination.sessions.firstIndex(where: { $0.id == destinationSessionID }),
              let captureIndex = source.sessions[sourceIndex].captures.firstIndex(where: { $0.id == captureID })
        else { return }
        let capture = source.sessions[sourceIndex].captures[captureIndex]
        try moveCaptureFiles(
            capture, from: source.sessions[sourceIndex], in: source,
            to: destination.sessions[destinationIndex], in: destination
        )

        source.sessions[sourceIndex].captures.remove(at: captureIndex)
        destination.sessions[destinationIndex].captures.insert(capture, at: 0)
        try save(source)
        try save(destination)
    }

    /// The actual on-disk relocation shared by both `moveCapture` overloads above — moves
    /// `capture`'s file, and its thumbnail if it has one, out of `sourceSession`'s folder and
    /// into `destinationSession`'s. Thumbnail move failures are tolerated (`try?`, matching
    /// `deleteCapture`'s own leniency there) since a missing thumbnail is regenerable and far
    /// less costly to lose than the capture file itself.
    private func moveCaptureFiles(
        _ capture: CaptureRecord, from sourceSession: Session, in sourceProject: Project,
        to destinationSession: Session, in destinationProject: Project
    ) throws {
        let sourceFileURL = sessionFolderURL(for: sourceSession, in: sourceProject).appendingPathComponent(capture.fileName)
        let destinationFolder = sessionFolderURL(for: destinationSession, in: destinationProject)
        let destinationFileURL = destinationFolder.appendingPathComponent(capture.fileName)
        guard !fileManager.fileExists(atPath: destinationFileURL.path) else {
            throw MoveCaptureError.destinationFileAlreadyExists
        }

        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: sourceFileURL.path) {
            try fileManager.moveItem(at: sourceFileURL, to: destinationFileURL)
        }

        if let thumbnailName = capture.thumbnailFileName {
            let sourceThumbnailURL = thumbnailsFolderURL(for: sourceSession, in: sourceProject).appendingPathComponent(thumbnailName)
            if fileManager.fileExists(atPath: sourceThumbnailURL.path) {
                let destinationThumbnailFolder = thumbnailsFolderURL(for: destinationSession, in: destinationProject)
                try fileManager.createDirectory(at: destinationThumbnailFolder, withIntermediateDirectories: true)
                try? fileManager.moveItem(at: sourceThumbnailURL, to: destinationThumbnailFolder.appendingPathComponent(thumbnailName))
            }
        }
    }

    // MARK: - Elaborated images (Siril)

    /// Records a `SirilElaborationService` result that's already been written to
    /// `elaboratedImagesFolderURL(for:)` — this just appends the catalog entry and re-saves.
    @discardableResult
    func addElaboratedImage(
        fileName: String, sourceSessionIDs: [UUID], sourceCaptureID: UUID?, recipe: ElaborationRecipe? = nil,
        toolLabel: String? = nil, title: String? = nil, notes: String? = nil,
        planetarySettings: PlanetaryPostProcessor.SettingsSnapshot? = nil, to project: inout Project
    ) throws -> ElaboratedImage {
        let image = ElaboratedImage(
            date: Date(), fileName: fileName, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: sourceCaptureID, recipe: recipe, toolLabel: toolLabel,
            title: title, notes: notes, planetarySettings: planetarySettings
        )
        project.elaboratedImages.append(image)
        try save(project)
        return image
    }

    /// Updates an *existing* elaborated image's catalog entry in place — same `id`, same
    /// `fileName` (the caller has already overwritten that file's bytes with the new render
    /// before calling this; this only ever touches metadata), `date` bumped to now. The
    /// "Overwrite" half of `PlanetaryPostProcessingView`'s save flow — "New Version" instead
    /// calls `addElaboratedImage` and leaves this entry untouched.
    @discardableResult
    func updateElaboratedImage(
        _ imageID: UUID, title: String?, notes: String?,
        planetarySettings: PlanetaryPostProcessor.SettingsSnapshot?, in project: inout Project
    ) throws -> ElaboratedImage {
        guard let index = project.elaboratedImages.firstIndex(where: { $0.id == imageID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        project.elaboratedImages[index].date = Date()
        project.elaboratedImages[index].title = title
        project.elaboratedImages[index].notes = notes
        project.elaboratedImages[index].planetarySettings = planetarySettings
        try save(project)
        return project.elaboratedImages[index]
    }

    /// Deletes one elaborated image's file and its catalog entry — same real-data-loss caveat as
    /// `deleteCapture(_:fromSessionID:in:)` above.
    func deleteElaboratedImage(_ imageID: UUID, in project: inout Project) throws {
        guard let image = project.elaboratedImages.first(where: { $0.id == imageID }) else { return }
        let fileURL = elaboratedImagesFolderURL(for: project).appendingPathComponent(image.fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        project.elaboratedImages.removeAll { $0.id == imageID }
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
