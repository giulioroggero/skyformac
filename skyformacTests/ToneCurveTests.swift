import Foundation
import Testing
@testable import skyformac

struct ToneCurveTests {
    @Test func identityCurveIsAnIdentityLUT() {
        let lut = ToneCurve.identity.lookupTable()
        #expect(lut.count == 256)
        for i in 0..<256 {
            #expect(Int(lut[i]) == i)
        }
    }

    @Test func degenerateSinglePointFallsBackToIdentity() {
        let curve = ToneCurve(points: [CurvePoint(x: 0.5, y: 0.5)])
        let lut = curve.lookupTable()
        for i in 0..<256 {
            #expect(Int(lut[i]) == i)
        }
    }

    @Test func liftsMidtonesTowardAnInteriorControlPoint() {
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.75), CurvePoint(x: 1, y: 1)
        ])
        let lut = curve.lookupTable()
        #expect(Int(lut[0]) == 0)
        #expect(Int(lut[255]) == 255)
        #expect(abs(Int(lut[128]) - 191) <= 3) // 0.75 * 255 ≈ 191
        // Every sample should sit above the plain diagonal (i.e. above `i`) given this curve
        // lifts everything below the midpoint and pulls the top half back down to meet (1,1) —
        // check the specific lifted region rather than the whole range for that reason.
        #expect(Int(lut[64]) > 64)
    }

    @Test func outputIsMonotonicNonDecreasing() {
        let configurations: [ToneCurve] = [
            .identity,
            ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.1), CurvePoint(x: 0.7, y: 0.9), CurvePoint(x: 1, y: 1)]),
            ToneCurve(points: [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0.8)]),
        ]
        for curve in configurations {
            let lut = curve.lookupTable()
            for i in 1..<256 {
                #expect(lut[i] >= lut[i - 1])
            }
        }
    }

    @Test func duplicateXCoordinatesAreDeduplicatedRatherThanDividingByZero() {
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.2), CurvePoint(x: 0.5, y: 0.8), CurvePoint(x: 1, y: 1)
        ])
        let lut = curve.lookupTable()
        #expect(lut.count == 256)
        for i in 1..<256 {
            #expect(lut[i] >= lut[i - 1])
        }
    }
}

struct ChannelToneCurvesTests {
    @Test func allIdentityCurvesComposeToAnIdentityLUT() {
        let curves = ChannelToneCurves.identity
        for lut in [curves.effectiveRedLUT, curves.effectiveGreenLUT, curves.effectiveBlueLUT] {
            for i in 0..<256 {
                #expect(Int(lut[i]) == i)
            }
        }
    }

    @Test func perChannelCurveComposesOnTopOfMasterCurve() {
        var curves = ChannelToneCurves.identity
        curves.master = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 0.5)])
        curves.red = ToneCurve(points: [CurvePoint(x: 0, y: 0.5), CurvePoint(x: 1, y: 1)])

        let redLUT = curves.effectiveRedLUT
        let greenLUT = curves.effectiveGreenLUT

        // Green only goes through the master curve (identity red/green/blue channel curves),
        // so it should match the master curve's own LUT exactly.
        #expect(greenLUT == curves.master.lookupTable())

        // Red goes through both master (halves the range) and its own curve (maps 0...1 to
        // 0.5...1) — composing "halve" then "compress into the top half" should land back near
        // the original values, not at either intermediate stage.
        #expect(Int(redLUT[255]) > Int(greenLUT[255]))
    }
}
