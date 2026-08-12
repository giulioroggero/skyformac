import Testing
import simd
@testable import skyformac

struct DriftAlignerTests {
    @Test func centroidComputesWeightedPosition() {
        // A single unit-intensity "pixel" at (10, 20): sumI=1, sumIx=10, sumIy=20.
        let centroid = DriftAligner.centroid(sumI: 1, sumIx: 10, sumIy: 20)
        #expect(centroid == SIMD2<Float>(10, 20))
    }

    @Test func centroidAveragesMultipleContributions() throws {
        // Two unit-intensity pixels at (0, 0) and (10, 0): centroid should sit at their midpoint.
        let centroid = try #require(DriftAligner.centroid(sumI: 2, sumIx: 10, sumIy: 0))
        #expect(centroid.x == 5)
        #expect(centroid.y == 0)
    }

    @Test func centroidReturnsNilForNegligibleSignal() {
        #expect(DriftAligner.centroid(sumI: 0, sumIx: 0, sumIy: 0) == nil)
        #expect(DriftAligner.centroid(sumI: 0.0001, sumIx: 5, sumIy: 5) == nil)
    }

    @Test func shiftIsCurrentMinusReference() {
        let reference = SIMD2<Float>(100, 200)
        let current = SIMD2<Float>(103, 197)
        let shift = DriftAligner.shift(current: current, reference: reference)
        #expect(shift == SIMD2<Float>(3, -3))
    }

    @Test func shiftIsZeroWhenUndrifted() {
        let point = SIMD2<Float>(50, 50)
        #expect(DriftAligner.shift(current: point, reference: point) == SIMD2<Float>(0, 0))
    }

    @Test func brightestPointPicksTheHighestValuePartial() throws {
        let partials = [
            SIMD3<Float>(0.2, 5, 5),
            SIMD3<Float>(0.9, 40, 60),
            SIMD3<Float>(0.5, 10, 10),
        ]
        let point = try #require(DriftAligner.brightestPoint(partials: partials))
        #expect(point == SIMD2<Float>(40, 60))
    }

    @Test func brightestPointReturnsNilWhenNoPartialHasPositiveSignal() {
        let partials = [SIMD3<Float>(-1, 0, 0), SIMD3<Float>(-1, 100, 200)]
        #expect(DriftAligner.brightestPoint(partials: partials) == nil)
    }

    @Test func brightestPointReturnsNilForEmptyPartials() {
        #expect(DriftAligner.brightestPoint(partials: []) == nil)
    }

    @Test func backgroundThresholdComputesMeanAndSigmaClippedThreshold() throws {
        // Uniform background at 0.1 (zero variance): threshold collapses to exactly the mean,
        // so any pixel strictly brighter than 0.1 (e.g. a star) clears it, but the flat
        // background itself never does.
        let result = try #require(DriftAligner.backgroundThreshold(sum: 100, sumOfSquares: 10, count: 1000))
        #expect(abs(result.background - 0.1) < 0.0001)
        #expect(abs(result.threshold - 0.1) < 0.0001)
    }

    @Test func backgroundThresholdRisesAboveMeanWithRealVariance() throws {
        // Two-population region: 980 background pixels at 0.05, 20 star pixels at 0.9 — a
        // realistic ROI-to-star-footprint ratio. Mean is well below the star's own value, and
        // the threshold (mean + 3*stddev) must land somewhere above the background but below the
        // star, so `centroidPartial` keeps the star's pixels and excludes the background's.
        let count: Float = 1000
        let sum: Float = 980 * 0.05 + 20 * 0.9
        let sumSq: Float = 980 * 0.05 * 0.05 + 20 * 0.9 * 0.9
        let result = try #require(DriftAligner.backgroundThreshold(sum: sum, sumOfSquares: sumSq, count: count))
        #expect(result.threshold > result.background)
        #expect(result.threshold < 0.9)
        #expect(result.background < 0.9)
    }

    @Test func backgroundThresholdReturnsNilForEmptyRegion() {
        #expect(DriftAligner.backgroundThreshold(sum: 0, sumOfSquares: 0, count: 0) == nil)
    }

    @Test func isLikelyPointSourceAcceptsARealStarsFootprint() {
        // A 64x64 (4096px) ROI with ~20 surviving pixels — a plausible bloated-star footprint,
        // nowhere close to the 15% ceiling.
        #expect(DriftAligner.isLikelyPointSource(survivingPixelCount: 20, roiArea: 4096))
    }

    @Test func isLikelyPointSourceRejectsAHugeOverexposedBlob() {
        // Over a third of the ROI cleared the threshold — a blown-out window, not a star.
        #expect(!DriftAligner.isLikelyPointSource(survivingPixelCount: 1500, roiArea: 4096))
    }

    @Test func isLikelyPointSourceRejectsNoSignalAtAll() {
        #expect(!DriftAligner.isLikelyPointSource(survivingPixelCount: 0, roiArea: 4096))
    }

    @Test func isLikelyPointSourceRespectsCustomFraction() {
        // Exactly at a custom, tighter ceiling should still pass; just over it should fail.
        #expect(DriftAligner.isLikelyPointSource(survivingPixelCount: 40, roiArea: 4096, maxFraction: 0.01))
        #expect(!DriftAligner.isLikelyPointSource(survivingPixelCount: 42, roiArea: 4096, maxFraction: 0.01))
    }
}
