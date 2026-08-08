import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct HFDCalculatorTests {
    private func gaussianStarFrame(width: Int, height: Int, cx: Int, cy: Int, sigma: Double, peak: Double = 200) -> CapturedFrame {
        var pixels = [UInt8](repeating: 5, count: width * height) // flat background
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x - cx)
                let dy = Double(y - cy)
                let value = peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                let index = y * width + x
                pixels[index] = UInt8(clamping: Int(pixels[index]) + Int(value))
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    private func detectedStar(atPixelX x: Int, y: Int, imageWidth: Int, imageHeight: Int) -> DetectedStar {
        let midX = Double(x) / Double(imageWidth)
        let midY = 1 - (Double(y) / Double(imageHeight))
        return DetectedStar(boundingBoxNormalized: CGRect(x: midX - 0.01, y: midY - 0.01, width: 0.02, height: 0.02))
    }

    @Test func tighterStarHasSmallerHFDThanBroaderStar() throws {
        let width = 64, height = 64
        let sharpFrame = gaussianStarFrame(width: width, height: height, cx: 32, cy: 32, sigma: 1.2)
        let blurryFrame = gaussianStarFrame(width: width, height: height, cx: 32, cy: 32, sigma: 4.0)
        let star = detectedStar(atPixelX: 32, y: 32, imageWidth: width, imageHeight: height)

        let sharpHFD = try #require(HFDCalculator.hfd(for: star, in: sharpFrame, cropRadius: 15))
        let blurryHFD = try #require(HFDCalculator.hfd(for: star, in: blurryFrame, cropRadius: 15))

        #expect(sharpHFD < blurryHFD)
    }

    @Test func medianHFDAcrossMultipleStars() throws {
        let width = 128, height = 64
        var frame = gaussianStarFrame(width: width, height: height, cx: 30, cy: 32, sigma: 1.5)
        // Add a second star into the same frame by blending in another blob.
        var pixels = Array(frame.data)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x - 90), dy = Double(y - 32)
                let value = 180.0 * exp(-(dx * dx + dy * dy) / (2 * 1.5 * 1.5))
                let index = y * width + x
                pixels[index] = UInt8(clamping: Int(pixels[index]) + Int(value))
            }
        }
        frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))

        let stars = [
            detectedStar(atPixelX: 30, y: 32, imageWidth: width, imageHeight: height),
            detectedStar(atPixelX: 90, y: 32, imageWidth: width, imageHeight: height),
        ]
        let median = try #require(HFDCalculator.medianHFD(frame: frame, stars: stars, cropRadius: 12))
        #expect(median > 0)
    }

    @Test func noStarsReturnsNil() {
        let frame = gaussianStarFrame(width: 32, height: 32, cx: 16, cy: 16, sigma: 2)
        #expect(HFDCalculator.medianHFD(frame: frame, stars: []) == nil)
    }
}
