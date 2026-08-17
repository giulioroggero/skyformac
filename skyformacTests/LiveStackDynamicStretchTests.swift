import Foundation
import Testing
@testable import skyformac

/// Pure-math coverage for `LiveStackDynamicStretch` — the actual fix behind
/// `specs/live-stackig-fix-spec.md` ("stacking doesn't visibly brighten"): a dynamic, non-linear
/// stretch re-derived from the stack's own histogram as it grows, instead of a fixed black/white
/// point. No GPU/Metal needed — this is plain histogram arithmetic, unlike
/// `GPULiveStackAccumulationTests`'s kernel-level coverage.
struct LiveStackDynamicStretchTests {
    /// A 256-bucket histogram with `count` samples concentrated at `peakBucket` (the background)
    /// and `highlightCount` samples at bucket 255 (a bright star/highlight), so `compute` has both
    /// a clear peak to find and a clear white point to protect.
    private func makeHistogram(peakBucket: Int, peakCount: Int, highlightCount: Int) -> [Int] {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[peakBucket] = peakCount
        histogram[255] = highlightCount
        return histogram
    }

    @Test func emptyHistogramReturnsNil() {
        let histogram = [Int](repeating: 0, count: 256)
        #expect(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .medium, blackPointOffset: 0) == nil)
    }

    @Test func blackPointTracksTheHistogramsPeakNotTheLowPercentile() {
        // Peak at bucket 40 (background), a small highlight at 255 (a star) — the pre-existing
        // linear `DisplayStretch.autoStretch`'s 1st-percentile approach would track close to the
        // very bottom of the range instead, which barely moves as a stack's own noise floor
        // narrows around its real peak. This is the specific behavior change the spec's step 5
        // ("find the peak of the histogram... set the Black Point just to the left of the peak")
        // asks for.
        let histogram = makeHistogram(peakBucket: 40, peakCount: 10000, highlightCount: 20)
        let result = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .medium, blackPointOffset: 0))
        let expectedPeak = Float(40) / Float(255)
        #expect(abs(result.blackPoint - expectedPeak) < 0.01)
    }

    @Test func blackPointOffsetShiftsTheComputedBlackPoint() {
        let histogram = makeHistogram(peakBucket: 40, peakCount: 10000, highlightCount: 20)
        let unshifted = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .medium, blackPointOffset: 0))
        let shifted = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .medium, blackPointOffset: 0.05))
        #expect(abs(shifted.blackPoint - unshifted.blackPoint - 0.05) < 0.001)
    }

    @Test func higherAggressivenessProducesAHigherStretchIntensity() {
        let histogram = makeHistogram(peakBucket: 40, peakCount: 10000, highlightCount: 20)
        let low = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .low, blackPointOffset: 0))
        let medium = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .medium, blackPointOffset: 0))
        let high = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .high, blackPointOffset: 0))
        #expect(low.stretchIntensity < medium.stretchIntensity)
        #expect(medium.stretchIntensity < high.stretchIntensity)
    }

    @Test func stretchIntensityIsAlwaysClampedToTheValidRange() {
        // An extremely narrow dynamic range (peak and highlight almost coincide) would otherwise
        // blow the naive `50 / range` computation far past what `arcsinhStretch` accepts.
        let histogram = makeHistogram(peakBucket: 250, peakCount: 10000, highlightCount: 20)
        let result = try! #require(LiveStackDynamicStretch.compute(histogram: histogram, aggressiveness: .high, blackPointOffset: 0))
        #expect(result.stretchIntensity >= 1.0 && result.stretchIntensity <= 200.0)
        #expect(result.whitePoint > result.blackPoint)
    }

    @Test func standardDeviationOfAConstantHistogramIsZero() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[100] = 5000
        #expect(LiveStackDynamicStretch.standardDeviation(histogram: histogram) == 0)
    }

    @Test func standardDeviationIsZeroForAnEmptyHistogram() {
        #expect(LiveStackDynamicStretch.standardDeviation(histogram: [Int](repeating: 0, count: 256)) == 0)
    }

    @Test func standardDeviationGrowsWithWiderSpread() {
        var narrow = [Int](repeating: 0, count: 256)
        narrow[100] = 500
        narrow[110] = 500
        var wide = [Int](repeating: 0, count: 256)
        wide[50] = 500
        wide[200] = 500
        #expect(LiveStackDynamicStretch.standardDeviation(histogram: wide) > LiveStackDynamicStretch.standardDeviation(histogram: narrow))
    }
}
