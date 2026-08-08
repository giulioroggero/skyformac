import CoreGraphics
import Foundation

/// Identifies which catalog stars are likely present in a detected star field, using triangle
/// (asterism) similarity — a simplified relative of the technique real blind plate-solvers like
/// astrometry.net use, scaled down to work over `SkyCatalog.brightStars`' small hand-curated
/// list rather than a full star catalog.
///
/// - Important: This is **not** a plate solver. It doesn't compute a WCS (pointing/rotation/
///   scale), doesn't establish exact point-to-point correspondence, and can't tell you where the
///   frame's center or edges point. It only answers "which of these ~14 named bright stars does
///   this pattern of dots plausibly contain" by voting: for every 3-detected-star triangle whose
///   side-length ratios match a 3-catalog-star triangle's ratios (computed from real RA/Dec via
///   small-angle separations) within tolerance, all three catalog stars get a vote. Triangle
///   side ratios are similarity-invariant (unaffected by the field's unknown rotation, scale, or
///   translation), which is what makes this comparison meaningful without knowing the FOV/pointing.
enum StarPatternRecognizer {
    struct Match {
        let object: SkyCatalogObject
        let confidence: Int
    }

    /// `detectedStars` should come from `StarDetector`. Only usable with >= 3 stars and a
    /// catalog of >= 3 objects; returns matches sorted by descending vote count.
    static func recognize(
        detectedStars: [DetectedStar],
        imageWidth: Int,
        imageHeight: Int,
        catalog: [SkyCatalogObject] = SkyCatalog.brightStars,
        toleranceFraction: Double = 0.08
    ) -> [Match] {
        guard imageWidth > 0, imageHeight > 0, detectedStars.count >= 3, catalog.count >= 3 else { return [] }

        let points = detectedStars.map { star -> CGPoint in
            let box = star.boundingBoxNormalized
            // Vision's normalized coords are bottom-left origin, y-up; flip to a plain pixel space.
            return CGPoint(x: box.midX * CGFloat(imageWidth), y: (1 - box.midY) * CGFloat(imageHeight))
        }

        // Cap star count to keep the O(n^3) triangle enumeration bounded on a busy frame.
        let cappedPoints = Array(points.prefix(12))
        let catalogTriangles = makeCatalogTriangles(catalog)
        let detectedRatios = makePixelTriangleRatios(cappedPoints)

        var votes: [String: Int] = [:]
        for detectedRatio in detectedRatios {
            for triangle in catalogTriangles where ratiosMatch(detectedRatio, triangle.ratios, tolerance: toleranceFraction) {
                votes[triangle.a.id, default: 0] += 1
                votes[triangle.b.id, default: 0] += 1
                votes[triangle.c.id, default: 0] += 1
            }
        }

        return votes
            .sorted { $0.value > $1.value }
            .compactMap { id, count in catalog.first { $0.id == id }.map { Match(object: $0, confidence: count) } }
    }

    // MARK: - Geometry

    private struct CatalogTriangle {
        let a: SkyCatalogObject
        let b: SkyCatalogObject
        let c: SkyCatalogObject
        let ratios: (Double, Double)
    }

    /// Small-angle angular separation between two catalog objects, in degrees. Adequate for
    /// comparative triangle-shape purposes at the field-of-view scales this is used for.
    private static func angularSeparation(_ s1: SkyCatalogObject, _ s2: SkyCatalogObject) -> Double {
        let meanDecRad = (s1.decDegrees + s2.decDegrees) / 2 * .pi / 180
        let dRA = (s1.raDegrees - s2.raDegrees) * cos(meanDecRad)
        let dDec = s1.decDegrees - s2.decDegrees
        return (dRA * dRA + dDec * dDec).squareRoot()
    }

    /// Sorted-ascending side lengths reduced to two scale-invariant ratios: (shortest/longest,
    /// middle/longest). Two similar triangles (same shape, any scale/rotation/reflection) share
    /// these ratios.
    private static func sideRatios(_ d1: Double, _ d2: Double, _ d3: Double) -> (Double, Double) {
        let sorted = [d1, d2, d3].sorted()
        guard sorted[2] > 0 else { return (0, 0) }
        return (sorted[0] / sorted[2], sorted[1] / sorted[2])
    }

    private static func ratiosMatch(_ a: (Double, Double), _ b: (Double, Double), tolerance: Double) -> Bool {
        abs(a.0 - b.0) < tolerance && abs(a.1 - b.1) < tolerance
    }

    private static func makeCatalogTriangles(_ stars: [SkyCatalogObject]) -> [CatalogTriangle] {
        var result: [CatalogTriangle] = []
        for i in 0..<stars.count {
            for j in (i + 1)..<stars.count {
                for k in (j + 1)..<stars.count {
                    let d1 = angularSeparation(stars[i], stars[j])
                    let d2 = angularSeparation(stars[j], stars[k])
                    let d3 = angularSeparation(stars[i], stars[k])
                    result.append(CatalogTriangle(a: stars[i], b: stars[j], c: stars[k], ratios: sideRatios(d1, d2, d3)))
                }
            }
        }
        return result
    }

    private static func makePixelTriangleRatios(_ points: [CGPoint]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                for k in (j + 1)..<points.count {
                    let d1 = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                    let d2 = hypot(points[j].x - points[k].x, points[j].y - points[k].y)
                    let d3 = hypot(points[i].x - points[k].x, points[i].y - points[k].y)
                    result.append(sideRatios(Double(d1), Double(d2), Double(d3)))
                }
            }
        }
        return result
    }
}
