import Testing
@testable import skyformac

struct StackSNREstimatorTests {
    @Test func doublingFrameCountAlwaysGivesTheSameRelativeGain() throws {
        // sqrt(2N)/sqrt(N) - 1 = sqrt(2) - 1 ≈ 41.4%, regardless of N.
        let small = try #require(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 10, additionalFrames: 10))
        let large = try #require(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 200, additionalFrames: 200))
        #expect(abs(small - 41.42) < 0.1)
        #expect(abs(large - 41.42) < 0.1)
    }

    @Test func aFixedAdditionalCountGivesDiminishingGainAsSessionGrows() throws {
        // The same "10 more frames" helps far less once the session already has many more frames.
        let earlyGain = try #require(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 10, additionalFrames: 10))
        let lateGain = try #require(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 500, additionalFrames: 10))
        #expect(earlyGain > lateGain)
    }

    @Test func zeroAdditionalFramesIsZeroGain() throws {
        let gain = try #require(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 50, additionalFrames: 0))
        #expect(abs(gain) < 0.0001)
    }

    @Test func returnsNilWithoutAnExistingBaseline() {
        #expect(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 0, additionalFrames: 10) == nil)
    }

    @Test func returnsNilForNegativeAdditionalFrames() {
        #expect(StackSNREstimator.relativeSNRGainPercent(currentFrameCount: 10, additionalFrames: -1) == nil)
    }
}
