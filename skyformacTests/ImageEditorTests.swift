import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct ImageEditorTests {
    /// A flat mid-gray `width`×`height` RGB image — enough for `ImageEditor`'s adjustments to
    /// have something to operate on without needing a real capture on disk.
    private func makeImage(width: Int, height: Int, red: CGFloat = 0.5, green: CGFloat = 0.5, blue: CGFloat = 0.5) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Reads back the top-left pixel's RGB (0...255) — enough to check a color-level effect
    /// (like SCNR's green cap) actually happened, on a known-flat test image.
    private func topLeftPixel(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return (pixels[0], pixels[1], pixels[2])
    }

    @Test func renderWithIdentityAdjustmentsPreservesDimensions() throws {
        let image = makeImage(width: 40, height: 30)
        let rendered = try #require(ImageEditor.render(image, with: .identity))
        #expect(rendered.width == 40)
        #expect(rendered.height == 30)
    }

    @Test func renderWithACropRectShrinksTheOutput() throws {
        let image = makeImage(width: 100, height: 100)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 50)
        #expect(rendered.height == 50)
    }

    @Test func renderWithA90DegreeRotationSwapsDimensions() throws {
        let image = makeImage(width: 80, height: 40)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.rotationDegrees = 90
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 40)
        #expect(rendered.height == 80)
    }

    @Test func autoFixedReturnsAnImageOfTheSameSize() throws {
        let image = makeImage(width: 60, height: 60)
        let fixed = try #require(ImageEditor.autoFixed(image))
        #expect(fixed.width == 60)
        #expect(fixed.height == 60)
    }

    @Test func renderWithDenoisePreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.denoiseAmount = 0.5
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithHotPixelRemovalPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.removesHotPixels = true
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithStarSizeReductionPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.starSizeReduction = 2
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithShadowAndHighlightAdjustmentsPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.shadowLift = 0.5
        adjustments.highlightRecovery = 0.5
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithStrongerSharpenRangePreservesDimensions() throws {
        // The sharpen range was widened from 0...2 to 0...5 ("increase sharp strength") — confirm
        // the top of the new range still renders without degenerating.
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.sharpenIntensity = 5
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithGreenCastRemovalCapsGreenAtTheRedBlueAverage() throws {
        // A green-dominant pixel (0, 255, 0) — full removal should cap green at the red/blue
        // average (0), leaving essentially no green cast.
        let image = makeImage(width: 4, height: 4, red: 0, green: 1, blue: 0)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.greenCastRemoval = 1
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        let pixel = topLeftPixel(of: rendered)
        #expect(pixel.green < 10)
    }

    @Test func renderWithNoGreenCastRemovalLeavesGreenUntouched() throws {
        let image = makeImage(width: 4, height: 4, red: 0, green: 1, blue: 0)
        let rendered = try #require(ImageEditor.render(image, with: .identity))
        let pixel = topLeftPixel(of: rendered)
        #expect(pixel.green > 200)
    }
}
