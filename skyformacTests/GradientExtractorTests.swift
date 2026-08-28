import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct GradientExtractorTests {
    /// A flat gray image with a linear left-to-right brightness ramp across all three channels —
    /// exactly what a light-pollution/vignetting gradient looks like in miniature, with no star or
    /// nebulosity involved at all (keeping these tests independent of Vision's own star-detection
    /// behavior, which `detectBackgroundSamples` alone exercises separately).
    private func makeLinearGradientImage(width: Int, height: Int, baseValue: Double = 40, span: Double = 150) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(min(255, baseValue + span * Double(x) / Double(width - 1)))
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// A simple, deterministic 4x4 grid of sample points spread across the image — standing in
    /// for whatever `detectBackgroundSamples` would have picked, without depending on it.
    private func gridSamplePoints(width: Int, height: Int, count: Int = 4) -> [CGPoint] {
        var points: [CGPoint] = []
        for row in 0..<count {
            for col in 0..<count {
                let fx = (Double(col) + 0.5) / Double(count)
                let fy = (Double(row) + 0.5) / Double(count)
                points.append(CGPoint(x: fx * Double(width), y: fy * Double(height)))
            }
        }
        return points
    }

    private func pixel(at x: Int, _ y: Int, in image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    @Test func detectBackgroundSamplesThrowsForATinyImage() {
        let image = makeLinearGradientImage(width: 3, height: 3)
        #expect(throws: GradientExtractor.ExtractionError.self) {
            try GradientExtractor.detectBackgroundSamples(in: image)
        }
    }

    @Test func removeGradientThrowsTooFewSamplesWithFewerThanSixPoints() {
        let image = makeLinearGradientImage(width: 100, height: 100)
        let fewPoints = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 90)]
        #expect(throws: GradientExtractor.ExtractionError.self) {
            try GradientExtractor.removeGradient(from: image, samplePoints: fewPoints)
        }
    }

    /// The core claim: given real background samples, the fitted-and-subtracted gradient should
    /// leave far less left-to-right brightness spread than the original ramp had, while keeping
    /// the image's own overall brightness roughly where it was (not just darkening everything).
    @Test func removeGradientFlattensALinearRampWithExplicitSamplePoints() throws {
        let image = makeLinearGradientImage(width: 100, height: 100, baseValue: 40, span: 150)
        let points = gridSamplePoints(width: 100, height: 100)

        let before = pixel(at: 5, 50, in: image)
        let beforeFar = pixel(at: 94, 50, in: image)
        let originalSpread = Int(beforeFar.red) - Int(before.red)
        #expect(originalSpread > 100) // sanity: the synthetic ramp really is steep

        let corrected = try GradientExtractor.removeGradient(from: image, samplePoints: points)
        #expect(corrected.width == 100)
        #expect(corrected.height == 100)

        let after = pixel(at: 5, 50, in: corrected)
        let afterFar = pixel(at: 94, 50, in: corrected)
        let correctedSpread = abs(Int(afterFar.red) - Int(after.red))
        #expect(correctedSpread < originalSpread / 4)

        // Brightness preservation: the corrected image's midpoint shouldn't have drifted far from
        // the original ramp's own midpoint value.
        let originalMid = pixel(at: 50, 50, in: image)
        let correctedMid = pixel(at: 50, 50, in: corrected)
        #expect(abs(Int(correctedMid.red) - Int(originalMid.red)) < 20)
    }
}
