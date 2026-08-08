import Foundation
import Testing
@testable import skyformac

struct AllSkyAnalyzerTests {
    @Test func averageBrightnessOfUniformSamples() {
        #expect(AllSkyAnalyzer.averageBrightness([100, 100, 100]) == 100)
    }

    @Test func averageBrightnessOfEmptyIsZero() {
        #expect(AllSkyAnalyzer.averageBrightness([]) == 0)
    }

    @Test func motionScoreZeroForIdenticalFrames() {
        let frame: [UInt8] = [50, 60, 70, 80]
        #expect(AllSkyAnalyzer.motionScore(current: frame, previous: frame) == 0)
    }

    @Test func motionScoreDetectsLargeChange() {
        let before: [UInt8] = [50, 50, 50, 50]
        let after: [UInt8] = [200, 200, 200, 200]
        #expect(AllSkyAnalyzer.motionScore(current: after, previous: before) == 150)
    }

    @Test func mismatchedSizesReturnZeroScore() {
        #expect(AllSkyAnalyzer.motionScore(current: [1, 2], previous: [1]) == 0)
    }

    @Test func cloudAlertTriggersOnSuddenDimming() {
        // Baseline 100, current 30 -> ratio 0.3 < 0.5 threshold.
        #expect(AllSkyAnalyzer.isCloudOrLightAlert(currentBrightness: 30, baseline: 100))
    }

    @Test func cloudAlertTriggersOnSuddenBrightening() {
        // Baseline 50, current 150 -> ratio 3.0 > 1/0.5 = 2.0 threshold.
        #expect(AllSkyAnalyzer.isCloudOrLightAlert(currentBrightness: 150, baseline: 50))
    }

    @Test func noCloudAlertForStableBrightness() {
        #expect(!AllSkyAnalyzer.isCloudOrLightAlert(currentBrightness: 102, baseline: 100))
    }

    @Test func noCloudAlertForDegenerateBaseline() {
        #expect(!AllSkyAnalyzer.isCloudOrLightAlert(currentBrightness: 200, baseline: 0))
    }

    @Test func motionAlertRespectsThreshold() {
        #expect(AllSkyAnalyzer.isMotionAlert(score: 20, threshold: 15))
        #expect(!AllSkyAnalyzer.isMotionAlert(score: 10, threshold: 15))
    }
}
