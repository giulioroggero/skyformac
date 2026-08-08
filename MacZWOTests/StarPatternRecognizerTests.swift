import CoreGraphics
import Foundation
import Testing
@testable import MacZWO

struct StarPatternRecognizerTests {
    private func catalogObject(id: String, ra: Double, dec: Double) -> SkyCatalogObject {
        SkyCatalogObject(id: id, commonName: nil, objectType: "Star", raDegrees: ra, decDegrees: dec, magnitude: 1)
    }

    private func detectedStar(pixelX: Double, pixelY: Double, imageSize: Double) -> DetectedStar {
        // Recognizer flips Vision's bottom-left-origin normalized Y back to plain pixel space
        // via `(1 - midY) * height`; invert that here to place a star at a known pixel position.
        let midX = pixelX / imageSize
        let midY = 1 - (pixelY / imageSize)
        let box = CGRect(x: midX - 0.005, y: midY - 0.005, width: 0.01, height: 0.01)
        return DetectedStar(boundingBoxNormalized: box)
    }

    @Test func recognizesARotatedAndScaledTriangleMatch() {
        // A right-triangle asterism in RA/Dec: A=(0,0), B=(1,0), C=(0,1) degrees -> sides 1,1,~1.414.
        let catalog = [
            catalogObject(id: "A", ra: 0, dec: 0),
            catalogObject(id: "B", ra: 1, dec: 0),
            catalogObject(id: "C", ra: 0, dec: 1),
        ]

        // The same shape, scaled 100x and rotated 30 degrees, translated into a 500x500 frame —
        // triangle similarity should recognize this regardless of the unknown scale/rotation.
        let theta = 30.0 * .pi / 180
        let scale = 100.0
        let translate = (x: 250.0, y: 250.0)
        func project(_ dx: Double, _ dy: Double) -> (Double, Double) {
            let x = translate.x + scale * (dx * cos(theta) - dy * sin(theta))
            let y = translate.y + scale * (dx * sin(theta) + dy * cos(theta))
            return (x, y)
        }
        let (ax, ay) = project(0, 0)
        let (bx, by) = project(1, 0)
        let (cx, cy) = project(0, 1)

        let detected = [
            detectedStar(pixelX: ax, pixelY: ay, imageSize: 500),
            detectedStar(pixelX: bx, pixelY: by, imageSize: 500),
            detectedStar(pixelX: cx, pixelY: cy, imageSize: 500),
        ]

        let matches = StarPatternRecognizer.recognize(
            detectedStars: detected, imageWidth: 500, imageHeight: 500, catalog: catalog
        )

        let matchedIDs = Set(matches.map { $0.object.id })
        #expect(matchedIDs == Set(["A", "B", "C"]))
    }

    @Test func unrelatedShapeDoesNotMatch() {
        let catalog = [
            catalogObject(id: "A", ra: 0, dec: 0),
            catalogObject(id: "B", ra: 1, dec: 0),
            catalogObject(id: "C", ra: 0, dec: 1),
        ]
        // An equilateral-ish triangle has very different side ratios (~1,1,1) than the catalog's
        // right triangle (~0.707, 0.707, 1) — should not vote for any catalog star.
        let detected = [
            detectedStar(pixelX: 100, pixelY: 100, imageSize: 500),
            detectedStar(pixelX: 200, pixelY: 100, imageSize: 500),
            detectedStar(pixelX: 150, pixelY: 186.6, imageSize: 500),
        ]
        let matches = StarPatternRecognizer.recognize(
            detectedStars: detected, imageWidth: 500, imageHeight: 500, catalog: catalog
        )
        #expect(matches.isEmpty)
    }

    @Test func tooFewStarsReturnsEmpty() {
        let detected = [detectedStar(pixelX: 10, pixelY: 10, imageSize: 100)]
        let matches = StarPatternRecognizer.recognize(detectedStars: detected, imageWidth: 100, imageHeight: 100)
        #expect(matches.isEmpty)
    }
}
