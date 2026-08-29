import CoreGraphics
import Testing
@testable import skyformac

struct AIWatermarkTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func applyPreservesTheImagesOwnDimensions() throws {
        let image = makeImage(width: 400, height: 300)
        let watermarked = try #require(AIWatermark.apply(to: image))
        #expect(watermarked.width == 400)
        #expect(watermarked.height == 300)
    }

    /// The whole point of a watermark is that it actually changes pixels near where it's drawn —
    /// this doesn't check the exact shape, just that the bottom-right corner (where the label is
    /// placed) isn't bit-identical to the plain dark background `makeImage` fills the whole frame
    /// with.
    @Test func applyActuallyChangesPixelsNearTheBottomRightCorner() throws {
        let image = makeImage(width: 400, height: 300)
        let watermarked = try #require(AIWatermark.apply(to: image))

        guard let originalData = image.dataProvider?.data, let watermarkedData = watermarked.dataProvider?.data else {
            Issue.record("Couldn't read back raw pixel data")
            return
        }
        let originalPointer = CFDataGetBytePtr(originalData)!
        let watermarkedPointer = CFDataGetBytePtr(watermarkedData)!
        let bytesPerRow = watermarked.bytesPerRow
        // A whole region near the bottom-right corner, not one exact row/column — the label's
        // precise box size depends on font metrics this test shouldn't need to reproduce, so scan
        // broadly enough to catch it regardless of its exact placement within that corner.
        var differs = false
        for y in stride(from: watermarked.height - 50, to: watermarked.height, by: 2) {
            for x in stride(from: watermarked.width - 150, to: watermarked.width, by: 2) {
                let offset = y * bytesPerRow + x * 4
                if originalPointer[offset] != watermarkedPointer[offset]
                    || originalPointer[offset + 1] != watermarkedPointer[offset + 1]
                    || originalPointer[offset + 2] != watermarkedPointer[offset + 2] {
                    differs = true
                }
            }
        }
        #expect(differs)
    }
}
