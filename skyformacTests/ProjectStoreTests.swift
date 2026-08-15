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

    @Test func moveSessionRelocatesItsFolderAndUpdatesBothProjects() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var source = Project.newProject(name: "Source Project")
        var destination = Project.newProject(name: "Destination Project")
        let session = Session.newSession(name: "Night One")
        source.sessions = [session]
        try store.save(source)
        try store.save(destination)

        let oldSessionFolder = store.sessionFolderURL(for: session, in: source)
        try Data("capture bytes".utf8).write(to: oldSessionFolder.appendingPathComponent("capture.fits"))

        try store.moveSession(session.id, from: &source, to: &destination)

        #expect(source.sessions.isEmpty)
        #expect(destination.sessions.count == 1)
        #expect(destination.sessions.first?.id == session.id)

        let newSessionFolder = store.sessionFolderURL(for: session, in: destination)
        #expect(!FileManager.default.fileExists(atPath: oldSessionFolder.path))
        #expect(FileManager.default.fileExists(atPath: newSessionFolder.appendingPathComponent("capture.fits").path))

        let reloaded = store.loadAllProjects()
        #expect(reloaded.first { $0.id == source.id }?.sessions.isEmpty == true)
        #expect(reloaded.first { $0.id == destination.id }?.sessions.count == 1)
    }

    @Test func moveSessionIsANoOpWhenTheSessionIsntInTheSourceProject() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var source = Project.newProject(name: "Source Project")
        var destination = Project.newProject(name: "Destination Project")
        try store.save(source)
        try store.save(destination)

        try store.moveSession(UUID(), from: &source, to: &destination)

        #expect(source.sessions.isEmpty)
        #expect(destination.sessions.isEmpty)
    }

    @Test func moveSessionThrowsWhenTheDestinationFolderAlreadyExists() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var source = Project.newProject(name: "Source Project")
        var destination = Project.newProject(name: "Destination Project")
        let session = Session.newSession(name: "Night One")
        source.sessions = [session]
        try store.save(source)
        try store.save(destination)
        // Pre-create a folder collision at the exact destination path the move would target.
        try FileManager.default.createDirectory(at: store.sessionFolderURL(for: session, in: destination), withIntermediateDirectories: true)

        #expect(throws: ProjectStore.MoveSessionError.self) {
            try store.moveSession(session.id, from: &source, to: &destination)
        }
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

    @Test func recordCaptureCopyingLeavesTheSourceFileInPlace() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Copy Project")
        let session = Session.newSession(name: "Copy Session")
        project.sessions = [session]
        try store.save(project)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ser")
        try Data([1, 2, 3]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let record = try store.recordCapture(
            copyingFileAt: sourceURL, kind: .serVideo, thumbnail: nil, into: session, project: &project
        )

        #expect(FileManager.default.fileExists(atPath: sourceURL.path)) // left in place, not moved
        let destination = store.sessionFolderURL(for: session, in: project).appendingPathComponent(record.fileName)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(project.sessions.first?.captures.first?.kind == .serVideo)
    }

    @Test func recordCaptureStoresObjectLocationEquipmentAndPreset() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Detailed Project")
        let session = Session.newSession(name: "Detailed Session")
        project.sessions = [session]
        try store.save(project)

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
        try Data([1, 2, 3]).write(to: sourceURL)

        let location = GeoLocation(latitude: 45, longitude: 9, name: "Backyard", source: .manual)
        let equipmentID = UUID()
        let preset = AcquisitionPreset(name: "Test", targetID: "", mode: .liveStack, gain: 100, isDriftReductionEnabled: false, isSmartLiveStackEnabled: false)

        let record = try store.recordCapture(
            movingFileAt: sourceURL, kind: .fits, thumbnail: nil, object: "Saturn", location: location,
            equipmentSystemID: equipmentID, preset: preset, into: session, project: &project
        )

        #expect(record.object == "Saturn")
        #expect(record.location == location)
        #expect(record.equipmentSystemID == equipmentID)
        #expect(record.preset == preset)
        #expect(project.sessions.first?.captures.first?.object == "Saturn")
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

    @Test func totalCaptureCountSumsAcrossEverySession() {
        var project = Project.newProject(name: "Count Test")
        var sessionA = Session.newSession(name: "A")
        sessionA.captures = [
            CaptureRecord(date: Date(), fileName: "a.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: Date(), fileName: "b.png", thumbnailFileName: nil, kind: .png),
        ]
        var sessionB = Session.newSession(name: "B")
        sessionB.captures = [CaptureRecord(date: Date(), fileName: "c.fits", thumbnailFileName: nil, kind: .fits)]
        project.sessions = [sessionA, sessionB]

        #expect(project.totalCaptureCount == 3)
    }

    @Test func lastActivityDateIsTheMostRecentCaptureDate() {
        var project = Project.newProject(name: "Activity Test")
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        var session = Session.newSession(name: "A")
        session.captures = [
            CaptureRecord(date: older, fileName: "a.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: newer, fileName: "b.png", thumbnailFileName: nil, kind: .png),
        ]
        project.sessions = [session]

        #expect(project.lastActivityDate == newer)
    }

    @Test func lastActivityDateFallsBackToCreatedDateWithNoCaptures() {
        let project = Project.newProject(name: "No Captures Yet")
        #expect(project.lastActivityDate == project.createdDate)
    }

    @Test func mostRecentThumbnailURLIsNilWithNoCaptures() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project.newProject(name: "No Captures")
        #expect(store.mostRecentThumbnailURL(for: project) == nil)
    }

    @Test func mostRecentThumbnailURLPicksTheNewestCaptureAcrossSessions() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Multi Session Thumbnails")
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        var sessionA = Session.newSession(name: "A")
        sessionA.captures = [CaptureRecord(date: older, fileName: "a.png", thumbnailFileName: "a.jpg", kind: .png)]
        var sessionB = Session.newSession(name: "B")
        sessionB.captures = [CaptureRecord(date: newer, fileName: "b.png", thumbnailFileName: "b.jpg", kind: .png)]
        project.sessions = [sessionA, sessionB]

        let url = store.mostRecentThumbnailURL(for: project)
        #expect(url?.lastPathComponent == "b.jpg")
        #expect(url?.deletingLastPathComponent() == store.thumbnailsFolderURL(for: sessionB, in: project))
    }

    @Test func mostRecentThumbnailURLSkipsCapturesWithNoThumbnail() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Mixed Thumbnails")
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        var session = Session.newSession(name: "A")
        session.captures = [
            CaptureRecord(date: older, fileName: "a.png", thumbnailFileName: "a.jpg", kind: .png),
            CaptureRecord(date: newer, fileName: "b.fits", thumbnailFileName: nil, kind: .fits),
        ]
        project.sessions = [session]

        #expect(store.mostRecentThumbnailURL(for: project)?.lastPathComponent == "a.jpg")
    }

    @Test func mostRecentThumbnailURLForOneSessionIgnoresOtherSessions() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Two Sessions")
        var sessionA = Session.newSession(name: "A")
        sessionA.captures = [CaptureRecord(date: Date(timeIntervalSince1970: 1000), fileName: "a.png", thumbnailFileName: "a.jpg", kind: .png)]
        var sessionB = Session.newSession(name: "B")
        sessionB.captures = [CaptureRecord(date: Date(timeIntervalSince1970: 2000), fileName: "b.png", thumbnailFileName: "b.jpg", kind: .png)]
        project.sessions = [sessionA, sessionB]

        #expect(store.mostRecentThumbnailURL(for: sessionA, in: project)?.lastPathComponent == "a.jpg")
        #expect(store.mostRecentThumbnailURL(for: sessionB, in: project)?.lastPathComponent == "b.jpg")
    }

    @Test func sessionFirstAndLastCaptureDatesAndDuration() {
        var session = Session.newSession(name: "A")
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 4600)
        session.captures = [
            CaptureRecord(date: start, fileName: "a.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: end, fileName: "b.png", thumbnailFileName: nil, kind: .png),
        ]

        #expect(session.firstCaptureDate == start)
        #expect(session.lastCaptureDate == end)
        #expect(session.duration == 3600)
    }

    @Test func sessionWithFewerThanTwoCapturesHasNoDuration() {
        var session = Session.newSession(name: "A")
        #expect(session.duration == nil)
        session.captures = [CaptureRecord(date: Date(), fileName: "a.png", thumbnailFileName: nil, kind: .png)]
        #expect(session.duration == nil)
    }

    @Test func sessionCaptureCountByKindGroupsCorrectly() {
        var session = Session.newSession(name: "A")
        session.captures = [
            CaptureRecord(date: Date(), fileName: "a.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: Date(), fileName: "b.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: Date(), fileName: "c.fits", thumbnailFileName: nil, kind: .fits),
        ]
        #expect(session.captureCountByKind == [.png: 2, .fits: 1])
    }

    @Test func projectCaptureCountByKindAggregatesAcrossSessions() {
        var project = Project.newProject(name: "Kinds")
        var sessionA = Session.newSession(name: "A")
        sessionA.captures = [CaptureRecord(date: Date(), fileName: "a.png", thumbnailFileName: nil, kind: .png)]
        var sessionB = Session.newSession(name: "B")
        sessionB.captures = [
            CaptureRecord(date: Date(), fileName: "b.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: Date(), fileName: "c.fits", thumbnailFileName: nil, kind: .fits),
        ]
        project.sessions = [sessionA, sessionB]

        #expect(project.captureCountByKind == [.png: 2, .fits: 1])
    }

    @Test func projectFirstActivityDateIsTheEarliestCapture() {
        var project = Project.newProject(name: "Activity")
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        var session = Session.newSession(name: "A")
        session.captures = [
            CaptureRecord(date: newer, fileName: "a.png", thumbnailFileName: nil, kind: .png),
            CaptureRecord(date: older, fileName: "b.png", thumbnailFileName: nil, kind: .png),
        ]
        project.sessions = [session]

        #expect(project.firstActivityDate == older)
    }

    @Test func projectFirstActivityDateIsNilWithNoCaptures() {
        let project = Project.newProject(name: "No Activity")
        #expect(project.firstActivityDate == nil)
    }

    @Test func projectActiveAndArchivedSessionCounts() {
        var project = Project.newProject(name: "Counts")
        var archived = Session.newSession(name: "Archived")
        archived.isArchived = true
        project.sessions = [Session.newSession(name: "Active 1"), Session.newSession(name: "Active 2"), archived]

        #expect(project.activeSessionsCount == 2)
        #expect(project.archivedSessionsCount == 1)
    }
}
