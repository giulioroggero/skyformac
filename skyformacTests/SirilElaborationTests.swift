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

    // MARK: - SER round-trip (SERWriter -> SERReader)

    /// Not a uniform fill — `SERWriter.write`'s own blank-frame guard rejects an all-identical-byte
    /// frame outright (see that method's doc comment), so every test frame needs at least one
    /// differing byte to actually get written.
    private func makeFrame(width: Int, height: Int, fill: UInt8) -> CapturedFrame {
        var bytes = [UInt8](repeating: fill, count: width * height)
        bytes[bytes.count - 1] = fill &+ 1
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(bytes))
    }

    @Test func serReaderRoundTripsEveryWrittenFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ser")
        defer { try? FileManager.default.removeItem(at: root) }

        let frame1 = makeFrame(width: 8, height: 6, fill: 10)
        let writer = try SERWriter(firstFrame: frame1, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "test", url: root)
        try writer.write(frame1)
        // Distinct fill values (not all-identical bytes) so `SERWriter.write`'s own
        // blank-frame guard doesn't reject them.
        var frame2Bytes = [UInt8](repeating: 20, count: 8 * 6)
        frame2Bytes[0] = 21
        try writer.write(CapturedFrame(width: 8, height: 6, imageType: ASI_IMG_RAW8, data: Data(frame2Bytes)))
        try writer.close()

        let parsed = try SERReader.read(from: root)
        #expect(parsed.width == 8)
        #expect(parsed.height == 6)
        #expect(parsed.imageType.rawValue == ASI_IMG_RAW8.rawValue)
        #expect(parsed.isColorCamera == false)
        #expect(parsed.frames.count == 2)
        #expect(parsed.frames[0].data == frame1.data)
        #expect(parsed.frames[1].data == Data(frame2Bytes))
    }

    @Test func serReaderReadsFirstFrameWithoutLoadingTheRest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ser")
        defer { try? FileManager.default.removeItem(at: root) }

        let frame1 = makeFrame(width: 4, height: 4, fill: 5)
        let writer = try SERWriter(firstFrame: frame1, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "test", url: root)
        try writer.write(frame1)
        try writer.close()

        let (frame, isColorCamera, _) = try SERReader.readFirstFrame(from: root)
        #expect(frame.width == 4)
        #expect(frame.height == 4)
        #expect(frame.data == frame1.data)
        #expect(isColorCamera == false)
    }

    @Test func croppedFrameWrittenAndReadBackMatchesFrameCropperDirectly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ser")
        defer { try? FileManager.default.removeItem(at: root) }

        var bytes = [UInt8](repeating: 0, count: 10 * 10)
        for i in bytes.indices { bytes[i] = UInt8(i % 250) } // varied, non-blank
        let fullFrame = CapturedFrame(width: 10, height: 10, imageType: ASI_IMG_RAW8, data: Data(bytes))
        let expectedCrop = try #require(FrameCropper.crop(fullFrame, toPixelRect: (x: 2, y: 3, width: 4, height: 5)))

        let writer = try SERWriter(firstFrame: fullFrame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "test", url: root)
        try writer.write(fullFrame)
        try writer.close()

        let parsed = try SERReader.read(from: root)
        let croppedFromReader = try #require(FrameCropper.crop(parsed.frames[0], toPixelRect: (x: 2, y: 3, width: 4, height: 5)))
        #expect(croppedFromReader.data == expectedCrop.data)
        #expect(croppedFromReader.width == 4)
        #expect(croppedFromReader.height == 5)
    }

    // MARK: - Configurable rejection parameters (default preserved)

    @Test func elaborationParametersDefaultMatchesThePreviouslyHardcodedSigmaValues() {
        #expect(SirilElaborationService.ElaborationParameters.default.rejectionSigmaLow == 3.0)
        #expect(SirilElaborationService.ElaborationParameters.default.rejectionSigmaHigh == 3.0)
        #expect(SirilElaborationService.ElaborationParameters.default.cropRect == nil)
    }
}

/// Pure coordinate-math coverage for `CropRectangleSelector` — the view-space <-> pixel-space
/// conversions behind "drag a box over the planet to crop." No SwiftUI rendering involved, so
/// this is testable the same way `DriftAligner`'s own pure math is.
struct CropRectangleSelectorTests {
    private let pixelSize = (width: 1000, height: 500)
    // A container exactly matching the image's own 2:1 aspect ratio, so `imageRect` fills it with
    // no letterboxing — the common case once `ElaborateSheet`'s own `.aspectRatio(...)` modifier
    // is applied, and simplest to reason about here.
    private let imageRect = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test func viewSelectionMapsToExpectedPixelRect() {
        // Half the container, starting a quarter of the way in on both axes.
        let viewRect = CGRect(x: 100, y: 50, width: 200, height: 100)
        let pixelRect = CropRectangleSelector.pixelRect(forViewRect: viewRect, imageRect: imageRect, pixelSize: pixelSize)
        let expected = SirilElaborationService.PixelRect(x: 250, y: 125, width: 500, height: 250)
        #expect(pixelRect == expected)
    }

    @Test func pixelRectAndViewRectAreInverses() {
        let original = SirilElaborationService.PixelRect(x: 100, y: 50, width: 300, height: 150)
        let viewRect = CropRectangleSelector.viewRect(for: original, imageRect: imageRect, pixelSize: pixelSize)
        let roundTripped = CropRectangleSelector.pixelRect(forViewRect: viewRect, imageRect: imageRect, pixelSize: pixelSize)
        #expect(roundTripped == original)
    }

    @Test func tinyDragIsRejectedAsDegenerate() {
        let viewRect = CGRect(x: 100, y: 50, width: 1, height: 1)
        #expect(CropRectangleSelector.pixelRect(forViewRect: viewRect, imageRect: imageRect, pixelSize: pixelSize) == nil)
    }

    @Test func selectionIsClampedToTheImageBounds() {
        // Starts inside the image but drags well past its right/bottom edge.
        let viewRect = CGRect(x: 300, y: 150, width: 300, height: 300)
        let pixelRect = try! #require(CropRectangleSelector.pixelRect(forViewRect: viewRect, imageRect: imageRect, pixelSize: pixelSize))
        #expect(pixelRect.x + pixelRect.width <= pixelSize.width)
        #expect(pixelRect.y + pixelRect.height <= pixelSize.height)
    }

    @Test func selectionEntirelyOutsideTheImageIsNil() {
        let viewRect = CGRect(x: 500, y: 300, width: 50, height: 50) // past the 400x200 imageRect
        #expect(CropRectangleSelector.pixelRect(forViewRect: viewRect, imageRect: imageRect, pixelSize: pixelSize) == nil)
    }

    @Test func fittedImageRectLetterboxesAWiderImageInATallerContainer() {
        // A 2:1 image in a square container should letterbox top/bottom, filling width exactly.
        let rect = CropRectangleSelector.fittedImageRect(containerSize: CGSize(width: 400, height: 400), pixelSize: pixelSize)
        #expect(rect.width == 400)
        #expect(rect.height == 200)
        #expect(rect.minY == 100) // centered vertically
    }
}
