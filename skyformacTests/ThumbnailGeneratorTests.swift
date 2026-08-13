import CoreGraphics
import ImageIO
import Testing
@testable import skyformac

struct ThumbnailGeneratorTests {
    private func testImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    @Test func makesAJPEGForANormalImage() throws {
        let image = try #require(testImage(width: 800, height: 600))
        let data = try #require(ThumbnailGenerator.makeThumbnail(from: image))
        #expect(!data.isEmpty)
        // JPEG magic bytes.
        #expect(data.starts(with: [0xFF, 0xD8]))
    }

    @Test func downscalesToAtMostMaxDimension() throws {
        let image = try #require(testImage(width: 4000, height: 2000))
        let data = try #require(ThumbnailGenerator.makeThumbnail(from: image))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            Issue.record("Could not read back thumbnail dimensions")
            return
        }
        #expect(max(width, height) <= ThumbnailGenerator.maxDimension)
        // 2:1 aspect ratio preserved.
        #expect(abs(Double(width) / Double(height) - 2.0) < 0.05)
    }

    @Test func neverUpscalesASmallerImage() throws {
        let image = try #require(testImage(width: 40, height: 30))
        let data = try #require(ThumbnailGenerator.makeThumbnail(from: image))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int
        else {
            Issue.record("Could not read back thumbnail dimensions")
            return
        }
        #expect(width == 40)
    }
}
