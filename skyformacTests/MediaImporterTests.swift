import CoreGraphics
import Foundation
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
}
