import CoreGraphics
import ImageIO
import Testing
@testable import skyformac

struct AIVisionImageEncoderTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func jpegDataProducesAValidJPEGAtOrUnderTheImagesOwnSize() throws {
        let image = makeImage(width: 200, height: 150)
        let data = try #require(AIVisionImageEncoder.jpegData(from: image))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 200)
        #expect(decoded.height == 150)
    }

    /// A capture-sized image should come back downscaled to `maxDimension`'s longest edge, aspect
    /// ratio preserved — this is what keeps a real multi-megapixel FITS/PNG capture from blowing
    /// past a vision API's own payload limits.
    @Test func jpegDataDownscalesAnOversizedImageToMaxDimension() throws {
        let image = makeImage(width: 4000, height: 2000)
        let data = try #require(AIVisionImageEncoder.jpegData(from: image))

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == AIVisionImageEncoder.maxDimension)
        #expect(decoded.height == AIVisionImageEncoder.maxDimension / 2)
    }
}
