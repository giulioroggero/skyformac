import AppKit
import Foundation
import Testing
@testable import skyformac

struct ThumbnailCacheTests {
    private func writeTestPNG(to url: URL, sizePoint: NSSize = NSSize(width: 4, height: 4)) throws {
        let image = NSImage(size: sizePoint)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: sizePoint).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    @Test func loadsAndDecodesARealImageFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("thumb.png")
        try writeTestPNG(to: url)

        let image = ThumbnailCache.image(at: url)

        #expect(image != nil)
    }

    @Test func returnsNilForAMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")

        #expect(ThumbnailCache.image(at: url) == nil)
    }

    @Test func aSecondLoadOfTheSameUnchangedFileReturnsAnImageToo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("thumb.png")
        try writeTestPNG(to: url)

        let first = ThumbnailCache.image(at: url)
        let second = ThumbnailCache.image(at: url)

        #expect(first != nil)
        #expect(second != nil)
    }

    @Test func picksUpAChangedFileAfterItsModificationDateChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("thumb.png")
        try writeTestPNG(to: url, sizePoint: NSSize(width: 4, height: 4))
        let firstImage = try #require(ThumbnailCache.image(at: url))

        // Overwrite with a different-sized image and force the modification date forward — the
        // cache key includes modification date specifically so this doesn't just serve the first,
        // now-stale image forever.
        try writeTestPNG(to: url, sizePoint: NSSize(width: 8, height: 8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let secondImage = try #require(ThumbnailCache.image(at: url))

        #expect(firstImage.size != secondImage.size)
    }
}
