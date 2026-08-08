import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct PlanetDetectorTests {
    /// A dead-center banded disk (bright limb-darkened circle with sinusoidal brightness bands,
    /// like Jupiter's cloud bands) — enough to reproduce the union-of-contours regression below
    /// without depending on the app's (removed) demo-target generator.
    private func bandedDiskFrame(width: Int, height: Int) -> CapturedFrame {
        var pixels = [UInt8](repeating: 8, count: width * height)
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        let radius = Double(min(width, height)) * 0.22
        let oblateness = 0.93
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = (Double(y) - cy) / oblateness
                let r = (dx * dx + dy * dy).squareRoot()
                guard r <= radius else { continue }
                let band = 1.0 + 0.35 * sin(dy * 0.9)
                let limbDarkening = 1.0 - 0.3 * (r / radius)
                pixels[y * width + x] = UInt8(clamping: Int(150.0 * band * limbDarkening))
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    /// Regression test for the union-of-contours approach: verified during development that
    /// picking a single "largest contour" fails on a banded planet like Jupiter, since its
    /// bands each produce their own long-thin contour rather than one clean disk outline.
    @Test func detectsJupiterDiskRoughlyCentered() throws {
        let frame = bandedDiskFrame(width: 640, height: 480)
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
