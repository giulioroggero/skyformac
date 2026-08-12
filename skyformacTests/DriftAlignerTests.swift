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
}
