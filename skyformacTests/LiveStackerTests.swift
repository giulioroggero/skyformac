import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct LiveStackerTests {
    @Test func averagesMultipleRAW8Frames() throws {
        let stacker = LiveStacker()
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([10, 100])))
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([20, 200])))
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([30, 254])))

        #expect(stacker.frameCount == 3)
        let result = try #require(stacker.currentAverage())
        #expect(Array(result.data) == [20, 184])
    }

    @Test func emptyStackerReturnsNil() {
        let stacker = LiveStacker()
        #expect(stacker.currentAverage() == nil)
        #expect(stacker.frameCount == 0)
    }

    @Test func resetClearsAccumulatedFrames() {
        let stacker = LiveStacker()
        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([200])))
        #expect(stacker.frameCount == 1)
        stacker.reset()
        #expect(stacker.frameCount == 0)
        #expect(stacker.currentAverage() == nil)
    }

    @Test func changingFrameDimensionsImplicitlyResets() throws {
        let stacker = LiveStacker()
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([100, 100])))
        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([50])))
        #expect(stacker.frameCount == 1) // the dimension change reset the accumulator
        let result = try #require(stacker.currentAverage())
        #expect(Array(result.data) == [50])
    }

    @Test func averagesRAW16Frames() throws {
        let stacker = LiveStacker()
        func frame16(_ values: [UInt16]) -> CapturedFrame {
            var data = Data(count: values.count * 2)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let p = raw.bindMemory(to: UInt16.self)
                for (i, v) in values.enumerated() { p[i] = v }
            }
            return CapturedFrame(width: values.count, height: 1, imageType: ASI_IMG_RAW16, data: data)
        }
        stacker.add(frame16([1000, 2000]))
        stacker.add(frame16([3000, 4000]))
        let result = try #require(stacker.currentAverage())
        result.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            #expect(p[0] == 2000)
            #expect(p[1] == 3000)
        }
    }

    // MARK: - Streak masking (specs/skyformac_AI_Features_Pipeline_Spec.md Feature 3)

    @Test func maskedPixelIsExcludedFromThatFramesContribution() throws {
        let stacker = LiveStacker()
        // A 1-streak, single detection spanning normalized x in [0, 0.5) of a 2x1 frame — masks
        // out pixel 0 only (see `StreakMask`'s bottom-left-origin-to-top-left-pixel-space flip;
        // full-height box here makes the y flip irrelevant).
        let streak = DetectedStreak(boundingBoxNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let mask = StreakMask(width: 2, height: 1, streaks: [streak], paddingFraction: 0)

        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([255, 10])), mask: mask)
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([255, 20])), mask: mask)
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([255, 30])), mask: mask)

        let result = try #require(stacker.currentAverage())
        // Pixel 0 (masked every frame) falls back to 0 rather than averaging in the streak's own
        // bright value; pixel 1 (never masked) averages normally.
        #expect(Array(result.data) == [0, 20])
    }

    @Test func nilMaskBehavesExactlyLikeNoMasking() throws {
        let unmasked = LiveStacker()
        let masked = LiveStacker()
        for value in [UInt8(10), 20, 30] {
            unmasked.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([value])))
            masked.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([value])), mask: nil)
        }
        #expect(try #require(unmasked.currentAverage()).data == (try #require(masked.currentAverage())).data)
    }

    @Test func partiallyMaskedPixelsAverageOverFewerContributingFrames() throws {
        let stacker = LiveStacker()
        let streak = DetectedStreak(boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1))
        let fullMask = StreakMask(width: 1, height: 1, streaks: [streak], paddingFraction: 0)

        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([100])), mask: nil)
        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([255])), mask: fullMask) // masked out
        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([200])), mask: nil)

        // Averages only the two unmasked contributions (100, 200), not all three.
        let result = try #require(stacker.currentAverage())
        #expect(Array(result.data) == [150])
    }
}
