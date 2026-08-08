import CoreGraphics
import Foundation
import Testing
@testable import MacZWO

struct PlanetDetectorTests {
    /// Regression test for the union-of-contours approach: verified during development that
    /// picking a single "largest contour" fails on a banded planet like Jupiter, since its
    /// bands each produce their own long-thin contour rather than one clean disk outline.
    @Test func detectsJupiterDiskRoughlyCentered() throws {
        let frame = DemoTargetGenerator.generate(.jupiter, width: 640, height: 480)
        let image = try #require(CGImageRenderer.makeDisplayImage(
            from: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, stretch: .identity
        ))
        let box = try #require(try PlanetDetector.detectDisk(in: image))

        // The demo planet is drawn dead-center; the detected box should be centered too, and
        // cover a meaningful fraction of the frame (not a stray tiny noise contour).
        #expect(abs(box.midX - 0.5) < 0.15)
        #expect(abs(box.midY - 0.5) < 0.15)
        #expect(box.width > 0.1)
        #expect(box.height > 0.1)
    }

    @Test func emptyFieldFindsNoDisk() throws {
        // A flat, empty field has no contours at all.
        let frame = CapturedFrame(width: 64, height: 64, imageType: ASI_IMG_RAW8, data: Data(repeating: 5, count: 64 * 64))
        let image = try #require(CGImageRenderer.makeDisplayImage(
            from: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, stretch: .identity
        ))
        let box = try PlanetDetector.detectDisk(in: image)
        #expect(box == nil)
    }
}
