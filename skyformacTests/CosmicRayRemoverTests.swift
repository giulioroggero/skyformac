import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct CosmicRayRemoverTests {
    /// A smooth gray field with one small, extremely bright, sharp-edged spike near the corner —
    /// a stand-in for a cosmic-ray hit (a single/few-pixel, unnaturally bright, isolated blob),
    /// distinct from a broad soft "star" the model is meant to leave alone.
    private func makeImageWithSpike(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let offset = i * 4
            pixels[offset] = 60
            pixels[offset + 1] = 60
            pixels[offset + 2] = 60
        }
        for y in 20..<22 {
            for x in 20..<22 {
                let offset = (y * width + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test func modelIsBundledAndAvailable() {
        // If this fails, the .mlpackage didn't compile into the test bundle — check the Xcode
        // project's Resources build phase, not the Swift code itself.
        #expect(CosmicRayRemover.isAvailable)
    }

    @Test func cleanPreservesImageDimensions() throws {
        try #require(CosmicRayRemover.isAvailable)
        let image = makeImageWithSpike(width: 64, height: 64)
        let cleaned = try CosmicRayRemover.clean(image)
        #expect(cleaned.width == 64)
        #expect(cleaned.height == 64)
    }

    @Test func cleanReturnsAValidImageForAFlatField() throws {
        try #require(CosmicRayRemover.isAvailable)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 80, count: 64 * 64 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i + 3] = 255 }
        let context = CGContext(
            data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!
        let cleaned = try CosmicRayRemover.clean(image)
        #expect(cleaned.width == 64)
        #expect(cleaned.height == 64)
    }
}
