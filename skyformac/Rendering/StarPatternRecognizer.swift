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
        let catalogTriangles = catalogTriangles(for: catalog)
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

    /// One detected pixel position resolved to a specific catalog star — unlike `recognize`'s
    /// aggregate per-star votes, this is exact point-to-point correspondence, e.g. for
    /// `LiveWCSSolver` to fit a real `WCSFrame` from.
    struct Correspondence {
        let pixel: CGPoint
        let object: SkyCatalogObject
        let confidence: Int
    }

    /// Resolves real pixel<->catalog-star correspondences, not just "which stars are plausibly
    /// present" (see `recognize`'s doc comment on why sorted-side-ratio triangle shape matching
    /// alone can't do this: it discards which vertex is which). This tries all 6 vertex-label
    /// orderings of each candidate catalog triangle against each detected triple's *fixed* order,
    /// so a shape match also pins down which detected point is which catalog star. Only keeps a
    /// detected point's best-voted catalog star once it has `minimumVotes` independent triangle
    /// matches agreeing on it, as a simple confidence/outlier filter.
    static func correspondences(
        detectedStars: [DetectedStar],
        imageWidth: Int,
        imageHeight: Int,
        catalog: [SkyCatalogObject] = SkyCatalog.brightStars,
        toleranceFraction: Double = 0.08,
        minimumVotes: Int = 2
    ) -> [Correspondence] {
        guard imageWidth > 0, imageHeight > 0, detectedStars.count >= 3, catalog.count >= 3 else { return [] }

        let points = detectedStars.map { star -> CGPoint in
            let box = star.boundingBoxNormalized
            return CGPoint(x: box.midX * CGFloat(imageWidth), y: (1 - box.midY) * CGFloat(imageHeight))
        }
        let cappedPoints = Array(points.prefix(12))

        var votes: [Int: [String: Int]] = [:] // detected-point index -> catalog object id -> votes

        for i in 0..<cappedPoints.count {
            for j in (i + 1)..<cappedPoints.count {
                for k in (j + 1)..<cappedPoints.count {
                    let s12 = Double(hypot(cappedPoints[i].x - cappedPoints[j].x, cappedPoints[i].y - cappedPoints[j].y))
                    guard s12 > 0 else { continue }
                    let s23 = Double(hypot(cappedPoints[j].x - cappedPoints[k].x, cappedPoints[j].y - cappedPoints[k].y))
                    let s13 = Double(hypot(cappedPoints[i].x - cappedPoints[k].x, cappedPoints[i].y - cappedPoints[k].y))
                    let pixelR1 = s23 / s12
                    let pixelR2 = s13 / s12

                    for a in 0..<catalog.count {
                        for b in (a + 1)..<catalog.count {
                            for c in (b + 1)..<catalog.count {
                                for (p1, p2, p3) in labelings(catalog[a], catalog[b], catalog[c]) {
                                    let cs12 = angularSeparation(p1, p2)
                                    guard cs12 > 0 else { continue }
                                    let r1 = angularSeparation(p2, p3) / cs12
                                    let r2 = angularSeparation(p1, p3) / cs12
                                    guard abs(r1 - pixelR1) < toleranceFraction, abs(r2 - pixelR2) < toleranceFraction
                                    else { continue }
                                    votes[i, default: [:]][p1.id, default: 0] += 1
                                    votes[j, default: [:]][p2.id, default: 0] += 1
                                    votes[k, default: [:]][p3.id, default: 0] += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        var results: [Correspondence] = []
        for (pixelIndex, tally) in votes {
            guard let best = tally.max(by: { $0.value < $1.value }), best.value >= minimumVotes,
                  let object = catalog.first(where: { $0.id == best.key })
            else { continue }
            results.append(Correspondence(pixel: cappedPoints[pixelIndex], object: object, confidence: best.value))
        }
        return results.sorted { $0.confidence > $1.confidence }
    }

    /// All 6 orderings of a triangle's 3 vertices — trying each against a detected triple's fixed
    /// order is what lets `correspondences` recover which vertex is which (see its doc comment).
    private static func labelings(
        _ a: SkyCatalogObject, _ b: SkyCatalogObject, _ c: SkyCatalogObject
    ) -> [(SkyCatalogObject, SkyCatalogObject, SkyCatalogObject)] {
        [(a, b, c), (a, c, b), (b, a, c), (b, c, a), (c, a, b), (c, b, a)]
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

    /// `makeCatalogTriangles(_:)`'s own result for the default catalog, built once — `recognize`
    /// runs on a timer (`CameraManager.scheduleFocusAssistIfNeeded`, every ~400ms while Focus
    /// Assist/star recognition is on) and `SkyCatalog.brightStars` never changes at runtime, so
    /// rebuilding its fixed ~14-star triangle-ratio table from scratch on every tick was pure
    /// repeated work over a value that was always going to come out the same.
    private static let defaultCatalogTriangles: [CatalogTriangle] = makeCatalogTriangles(SkyCatalog.brightStars)

    /// Only the default catalog is served from `defaultCatalogTriangles` — a caller passing a
    /// different one (tests, mainly) always recomputes fresh, since there's no way to know in
    /// advance a non-default catalog will be reused across calls.
    private static func catalogTriangles(for catalog: [SkyCatalogObject]) -> [CatalogTriangle] {
        catalog == SkyCatalog.brightStars ? defaultCatalogTriangles : makeCatalogTriangles(catalog)
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
