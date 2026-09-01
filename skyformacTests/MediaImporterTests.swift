import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import skyformac

struct MediaImporterTests {
    @Test func kindForRecognizesEveryStillImageExtensionAsPNGKind() {
        for ext in ["png", "PNG", "jpg", "jpeg", "heic"] {
            #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.\(ext)")) == .png)
        }
    }

    @Test func kindForRecognizesTIFFAndFITSDistinctly() {
        #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.tiff")) == .tiff)
        #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.tif")) == .tiff)
        #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.fits")) == .fits)
        #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.fit")) == .fits)
    }

    @Test func kindForRecognizesVideoExtensionsAsVideoKind() {
        for ext in ["mov", "MOV", "mp4", "m4v"] {
            #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.\(ext)")) == .video)
        }
    }

    @Test func kindForReturnsNilForAnUnsupportedExtension() {
        #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file.txt")) == nil)
        #expect(MediaImporter.kind(for: URL(fileURLWithPath: "/tmp/file")) == nil)
    }

    @Test func fileExtensionForUsesTheUTTypesOwnPreferredExtension() {
        #expect(MediaImporter.fileExtension(for: .png) == "png")
        #expect(MediaImporter.fileExtension(for: .quickTimeMovie) == "mov")
        #expect(MediaImporter.fileExtension(for: nil) == "dat")
    }

    private func writeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    /// A folder someone picked ("import this whole folder") should flatten to its own supported
    /// files, skip unsupported ones, and NOT recurse into a subfolder.
    @Test func expandFlattensAFolderToItsSupportedFilesOnlyNonRecursively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try writeFile(named: "a.png", in: root)
        let mov = try writeFile(named: "b.mov", in: root)
        _ = try writeFile(named: "c.txt", in: root)
        let subfolder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        _ = try writeFile(named: "d.png", in: subfolder)

        // `/var` vs. `/private/var` — `FileManager.contentsOfDirectory` resolves the temp
        // directory's own symlink alias, so comparing raw URLs would spuriously fail regardless
        // of `expand`'s own correctness; standardizing both sides is what actually isolates that.
        let expanded = Set(MediaImporter.expand([root]).map { $0.resolvingSymlinksInPath() })
        #expect(expanded == Set([png, mov].map { $0.resolvingSymlinksInPath() }))
    }

    @Test func expandPassesThroughAnAlreadySupportedFileDirectly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try writeFile(named: "a.png", in: root)

        #expect(MediaImporter.expand([png]) == [png])
    }

    @Test func expandDropsAnUnsupportedFileURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let txt = try writeFile(named: "a.txt", in: root)

        #expect(MediaImporter.expand([txt]).isEmpty)
    }

    /// Writes a real 1×1 PNG with an EXIF `DateTimeOriginal` embedded — the same kind of file a
    /// real camera/Photos export carries, standing in for "an old astrophoto imported today should
    /// still sort at when it was actually taken."
    private func writePNG(withExifDateTimeOriginal dateString: String, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            struct DestinationCreationFailed: Error {}
            throw DestinationCreationFailed()
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: dateString] as [CFString: Any]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            struct FinalizeFailed: Error {}
            throw FinalizeFailed()
        }
    }

    @Test func captureDateReadsEmbeddedExifDateTimeOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.png")
        try writePNG(withExifDateTimeOriginal: "2020:06:15 22:30:00", to: url)

        let date = await MediaImporter.captureDate(for: url, kind: .png)

        let calendar = Calendar(identifier: .gregorian)
        var expected = DateComponents()
        expected.year = 2020; expected.month = 6; expected.day = 15
        expected.hour = 22; expected.minute = 30; expected.second = 0
        expected.timeZone = TimeZone.current
        let expectedDate = calendar.date(from: expected)!
        #expect(abs(date.timeIntervalSince(expectedDate)) < 1)
    }

    @Test func captureDateFallsBackToFilesystemDateWhenNoMetadataIsPresent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeFile(named: "a.fits", in: root)

        let date = await MediaImporter.captureDate(for: url, kind: .fits)

        // No embedded date at all for this app's own FITS files (see `MediaImporter.captureDate`'s
        // own doc comment) — the fallback should still be "close to now" (the file's own just-now
        // filesystem date), not some arbitrary unrelated value.
        #expect(abs(date.timeIntervalSinceNow) < 30)
    }
}
