import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct LiveWCSSolverTests {
    private func catalogObject(id: String, ra: Double, dec: Double) -> SkyCatalogObject {
        SkyCatalogObject(id: id, commonName: nil, objectType: "Star", raDegrees: ra, decDegrees: dec, magnitude: 1)
    }

    /// Round-trip test: project a handful of real catalog stars through a known `WCSFrame` (the
    /// exact forward projection `LiveWCSSolver` has to invert), feed the solver those pixel<->star
    /// correspondences, and check it recovers the same center/rotation/scale — the way a genuine
    /// astrometric fit's correctness gets verified without needing real telescope data.
    @Test func recoversKnownWCSFromProjectedStars() throws {
        let truth = WCSFrame(
            centerRADeg: 83.8, centerDecDeg: -5.4,
            radiansPerPixel: (2.0 * .pi / 180) / 1000, // ~2 degree FOV over 1000px
            rotationRadians: 0.4, imageWidth: 1000, imageHeight: 1000
        )
        let catalog = [
            catalogObject(id: "A", ra: 83.8, dec: -5.4),
            catalogObject(id: "B", ra: 84.5, dec: -5.0),
            catalogObject(id: "C", ra: 83.2, dec: -5.9),
            catalogObject(id: "D", ra: 84.0, dec: -6.1),
        ]
        let correspondences = try catalog.map { object -> StarPatternRecognizer.Correspondence in
            let pixel = try #require(truth.projectToPixel(raDeg: object.raDegrees, decDeg: object.decDegrees))
            return StarPatternRecognizer.Correspondence(pixel: pixel, object: object, confidence: 5)
        }

        let solved = try #require(LiveWCSSolver.solve(
            correspondences: correspondences, imageWidth: truth.imageWidth, imageHeight: truth.imageHeight
        ))

        #expect(abs(solved.centerRADeg - truth.centerRADeg) < 0.01)
        #expect(abs(solved.centerDecDeg - truth.centerDecDeg) < 0.01)
        #expect(abs(solved.radiansPerPixel - truth.radiansPerPixel) / truth.radiansPerPixel < 0.01)
        #expect(abs(solved.rotationRadians - truth.rotationRadians) < 0.01)

        // The fit should also agree with ground truth on where each star actually lands, not
        // just on the abstract parameters — the practically-meaningful check for `SkyHUDView`.
        for object in catalog {
            let truePixel = try #require(truth.projectToPixel(raDeg: object.raDegrees, decDeg: object.decDegrees))
            let solvedPixel = try #require(solved.projectToPixel(raDeg: object.raDegrees, decDeg: object.decDegrees))
            #expect(abs(truePixel.x - solvedPixel.x) < 1.0)
            #expect(abs(truePixel.y - solvedPixel.y) < 1.0)
        }
    }

    @Test func tooFewCorrespondencesReturnsNil() {
        let object = catalogObject(id: "A", ra: 0, dec: 0)
        let solved = LiveWCSSolver.solve(
            correspondences: [StarPatternRecognizer.Correspondence(pixel: CGPoint(x: 500, y: 500), object: object, confidence: 5)],
            imageWidth: 1000, imageHeight: 1000
        )
        #expect(solved == nil)
    }

    @Test func coincidentPointsReturnNilInsteadOfCrashing() {
        let a = catalogObject(id: "A", ra: 10, dec: 10)
        let b = catalogObject(id: "B", ra: 10, dec: 10)
        let solved = LiveWCSSolver.solve(
            correspondences: [
                StarPatternRecognizer.Correspondence(pixel: CGPoint(x: 500, y: 500), object: a, confidence: 5),
                StarPatternRecognizer.Correspondence(pixel: CGPoint(x: 500, y: 500), object: b, confidence: 5),
            ],
            imageWidth: 1000, imageHeight: 1000
        )
        #expect(solved == nil)
    }
}
