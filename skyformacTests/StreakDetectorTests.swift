import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct StreakDetectorTests {
    /// A long, thin, bright horizontal line spanning most of the frame — a stand-in for a
    /// satellite/aircraft/meteor trail, the same "draw the real geometry by hand instead of
    /// depending on a removed demo generator" approach `PlanetDetectorTests` already uses.
    private func streakFrame(width: Int, height: Int) -> CapturedFrame {
        var pixels = [UInt8](repeating: 5, count: width * height)
        let centerY = height / 2
        let thickness = max(1, height / 100)
        let startX = Int(Double(width) * 0.1)
        let endX = Int(Double(width) * 0.9)
        for y in max(0, centerY - thickness)...min(height - 1, centerY + thickness) {
            for x in startX...endX {
                pixels[y * width + x] = 220
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    /// A small, round, bright blob — a star, which must *not* be flagged as a streak.
    private func roundBlobFrame(width: Int, height: Int) -> CapturedFrame {
        var pixels = [UInt8](repeating: 5, count: width * height)
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        let radius = Double(min(width, height)) * 0.05
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                if (dx * dx + dy * dy).squareRoot() <= radius { pixels[y * width + x] = 220 }
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    private func image(for frame: CapturedFrame) throws -> CGImage {
        try #require(CGImageRenderer.makeDisplayImage(
            from: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, stretch: .identity
        ))
    }

    @Test func detectsALongThinBrightStreak() throws {
        let streaks = try StreakDetector.detectStreaks(in: image(for: streakFrame(width: 640, height: 480)))
        let streak = try #require(streaks.first)
        let box = streak.boundingBoxNormalized
        let longSide = max(box.width, box.height)
        let shortSide = max(min(box.width, box.height), 0.001)
        #expect(longSide > 0.15)
        #expect(longSide / shortSide > 6)
    }

    @Test func roundBlobIsNotFlaggedAsAStreak() throws {
        let streaks = try StreakDetector.detectStreaks(in: image(for: roundBlobFrame(width: 640, height: 480)))
        #expect(streaks.isEmpty)
    }

    @Test func emptyFieldFindsNoStreaks() throws {
        let frame = CapturedFrame(width: 64, height: 64, imageType: ASI_IMG_RAW8, data: Data(repeating: 5, count: 64 * 64))
        let streaks = try StreakDetector.detectStreaks(in: image(for: frame))
        #expect(streaks.isEmpty)
    }
}

struct StreakMaskTests {
    @Test func pixelsInsideAStreaksBoxAreMaskedOut() {
        let streak = DetectedStreak(boundingBoxNormalized: CGRect(x: 0.0, y: 0.4, width: 1.0, height: 0.2))
        let mask = StreakMask(width: 10, height: 10, streaks: [streak], paddingFraction: 0)

        // y in [0.4, 0.6) normalized, bottom-left origin -> flipped to top-left pixel rows
        // [4, 6) roughly (allowing for the ceil/floor rounding `StreakMask` applies).
        #expect(mask.isKept(flatIndex: 0 * 10 + 5) == true) // row 0: outside the streak band
        #expect(mask.isKept(flatIndex: 5 * 10 + 5) == false) // row 5: inside the streak band
        #expect(mask.isKept(flatIndex: 9 * 10 + 5) == true) // row 9: outside the streak band
    }

    @Test func noStreaksKeepsEveryPixel() {
        let mask = StreakMask(width: 4, height: 4, streaks: [])
        #expect(mask.maskedFraction == 0)
        for i in 0..<16 { #expect(mask.isKept(flatIndex: i)) }
    }

    @Test func maskedFractionReflectsStreakCoverage() {
        // A full-width, half-height streak should mask roughly half the frame.
        let streak = DetectedStreak(boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        let mask = StreakMask(width: 100, height: 100, streaks: [streak], paddingFraction: 0)
        #expect(abs(mask.maskedFraction - 0.5) < 0.05)
    }

    @Test func outOfBoundsFlatIndexDefaultsToKept() {
        let mask = StreakMask(width: 2, height: 2, streaks: [])
        #expect(mask.isKept(flatIndex: -1))
        #expect(mask.isKept(flatIndex: 999))
    }
}
