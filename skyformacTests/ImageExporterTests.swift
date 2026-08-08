import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct ImageExporterTests {
    private func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    private func makeTestImage() -> CGImage {
        let width = 16, height = 16
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<(width * height) { base[i] = UInt8(i % 256) }
        }
        let frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: data)
        return CGImageRenderer.makeDisplayImage(
            from: frame,
            isColorCamera: false,
            bayerPattern: ASI_BAYER_RG,
            stretch: .identity
        )!
    }

    @Test func writesValidPNGFile() throws {
        let url = tempURL(ext: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter.writePNG(makeTestImage(), to: url)

        let data = try Data(contentsOf: url)
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Array(data.prefix(8)) == pngMagic)
    }

    @Test func writesValidTIFFFile() throws {
        let url = tempURL(ext: "tiff")
        defer { try? FileManager.default.removeItem(at: url) }

        try ImageExporter.writeTIFF(makeTestImage(), to: url)

        let data = try Data(contentsOf: url)
        // TIFF starts with "II*\0" (little-endian) or "MM\0*" (big-endian).
        let prefix = Array(data.prefix(4))
        let isLittleEndianTIFF = prefix == [0x49, 0x49, 0x2A, 0x00]
        let isBigEndianTIFF = prefix == [0x4D, 0x4D, 0x00, 0x2A]
        #expect(isLittleEndianTIFF || isBigEndianTIFF)
    }
}
