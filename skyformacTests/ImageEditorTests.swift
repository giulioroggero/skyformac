import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct ImageEditorTests {
    /// A flat mid-gray `width`×`height` RGB image — enough for `ImageEditor`'s adjustments to
    /// have something to operate on without needing a real capture on disk.
    private func makeImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
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
}
