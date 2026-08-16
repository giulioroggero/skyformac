import Foundation
import Testing
@testable import skyformac

struct SirilElaborationTests {
    // MARK: - Recipe resolution (pure function, no Siril process involved)

    @Test func singleFITSAlwaysResolvesToSingleImageRegardlessOfTarget() {
        let url = URL(fileURLWithPath: "/tmp/a.fits")
        #expect(SirilElaborationService.resolveRecipe(for: .singleFITS(url), target: nil) == .singleImage)
        #expect(SirilElaborationService.resolveRecipe(for: .singleFITS(url), target: .planetary(.saturn)) == .singleImage)
        #expect(SirilElaborationService.resolveRecipe(for: .singleFITS(url), target: .deepSky(.m13)) == .singleImage)
    }

    @Test func resolvedTargetWinsOverSourceKindDefault() {
        let serURL = URL(fileURLWithPath: "/tmp/a.ser")
        // A .ser video defaults to planetary, but an explicitly-resolved deep-sky target
        // (unusual, but possible) should still win.
        #expect(SirilElaborationService.resolveRecipe(for: .serVideo(serURL), target: .deepSky(.m13)) == .deepSky)
        let framesURLs = [URL(fileURLWithPath: "/tmp/frame_000000.fits")]
        // A FITS-frames burst defaults to deep-sky, but a resolved planetary target should win.
        #expect(SirilElaborationService.resolveRecipe(for: .fitsFrames(framesURLs), target: .planetary(.saturn)) == .planetary)
    }

    @Test func unresolvedTargetFallsBackToSourceKindDefault() {
        let serURL = URL(fileURLWithPath: "/tmp/a.ser")
        #expect(SirilElaborationService.resolveRecipe(for: .serVideo(serURL), target: nil) == .planetary)
        let framesURLs = [URL(fileURLWithPath: "/tmp/frame_000000.fits")]
        #expect(SirilElaborationService.resolveRecipe(for: .fitsFrames(framesURLs), target: nil) == .deepSky)
    }

    // MARK: - CLI path resolution

    @Test func defaultCLIPathIsUnderStandardSirilInstall() {
        #expect(SirilElaborationService.defaultCLIPath().path == "/Applications/Siril.app/Contents/MacOS/siril-cli")
    }

    // MARK: - ProjectStore: elaborated images

    private func makeStore() -> (store: ProjectStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (ProjectStore(rootDirectory: root), root)
    }

    @Test func addElaboratedImageAppendsAndPersists() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Saturn")
        try store.save(project)
        let sessionID = UUID()

        let added = try store.addElaboratedImage(
            fileName: "Elaborated-1.tif", sourceSessionIDs: [sessionID], sourceCaptureID: nil,
            recipe: .planetary, to: &project
        )
        #expect(project.elaboratedImages.count == 1)
        #expect(project.elaboratedImages.first?.id == added.id)

        let reloaded = store.loadAllProjects().first { $0.id == project.id }
        #expect(reloaded?.elaboratedImages.count == 1)
        #expect(reloaded?.elaboratedImages.first?.fileName == "Elaborated-1.tif")
        #expect(reloaded?.elaboratedImages.first?.recipe == .planetary)
        #expect(reloaded?.elaboratedImages.first?.sourceSessionIDs == [sessionID])
    }

    @Test func deleteElaboratedImageRemovesFileAndCatalogEntry() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Saturn")
        try store.save(project)

        let folder = store.elaboratedImagesFolderURL(for: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("Elaborated-1.tif")
        try Data("fake tiff bytes".utf8).write(to: fileURL)

        let added = try store.addElaboratedImage(
            fileName: "Elaborated-1.tif", sourceSessionIDs: [], sourceCaptureID: nil, recipe: .deepSky, to: &project
        )
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try store.deleteElaboratedImage(added.id, in: &project)
        #expect(project.elaboratedImages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func projectDiskUsageIncludesElaboratedImagesFolder() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var project = Project.newProject(name: "Saturn")
        try store.save(project)

        let usageBefore = store.diskUsage(for: project)

        let folder = store.elaboratedImagesFolderURL(for: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: folder.appendingPathComponent("Elaborated-1.tif"))

        let usageAfter = store.diskUsage(for: project)
        #expect(usageAfter >= usageBefore + 1000)
    }

    // MARK: - Back-compat decoding

    @Test func decodingAnOlderProjectJSONWithoutElaboratedImagesDefaultsToEmpty() throws {
        // Simulates a `project.json` written before this feature existed.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old Project","goal":"","createdDate":\(Date().timeIntervalSinceReferenceDate),
         "tags":[],"notes":[],"sessions":[],"isArchived":false,"folderName":"old-project"}
        """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(decoded.elaboratedImages.isEmpty)
    }

    @Test func elaboratedImagesRoundTripThroughJSON() throws {
        var project = Project.newProject(name: "P")
        let sessionID = UUID()
        let captureID = UUID()
        project.elaboratedImages = [
            ElaboratedImage(date: Date(), fileName: "a.tif", sourceSessionIDs: [sessionID], sourceCaptureID: captureID, recipe: .singleImage)
        ]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded.elaboratedImages.count == 1)
        #expect(decoded.elaboratedImages.first?.fileName == "a.tif")
        #expect(decoded.elaboratedImages.first?.sourceSessionIDs == [sessionID])
        #expect(decoded.elaboratedImages.first?.sourceCaptureID == captureID)
        #expect(decoded.elaboratedImages.first?.recipe == .singleImage)
    }
}
