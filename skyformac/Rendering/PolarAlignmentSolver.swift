import CoreGraphics
import Foundation

/// Solves for a mount's mechanical RA-axis position in the image (the classic "drift"/
/// "plate-solved" polar alignment workflow: capture near the pole, rotate RA by a known amount,
/// capture again — the axis the field visibly pivoted around in pixel space is exactly the
/// mount's actual mechanical polar axis).
///
/// - Important, what this is **not**: a blind plate solver. It has no absolute WCS (no RA/Dec,
///   orientation, or plate scale), so it cannot report the true celestial pole's position or
///   convert pixel offsets into real alt/az degrees. What it *can* do correctly, with real
///   geometry, is find the rotation center from star correspondences between the two frames —
///   which is the actual hard part of this technique. Turning that into precise knob-turning
///   instructions in a shipped product would need a real plate solver on top of this.
enum PolarAlignmentSolver {
    struct StarCorrespondence {
        let before: CGPoint
        let after: CGPoint
    }

    /// Matches stars between two detections of the same field before/after a pure rotation,
    /// using each star's sorted distances to every other star in its own frame as a signature.
    /// Pairwise distances between points are exactly preserved under rotation (an isometry), so
    /// two stars with near-identical distance signatures across the two frames are very likely
    /// the same physical star — no absolute position, brightness, or ordering assumptions needed.
    static func matchStars(before: [CGPoint], after: [CGPoint], maxSignatureDifference: Double = 5.0) -> [StarCorrespondence] {
        guard before.count >= 2, after.count >= 2 else { return [] }

        func signature(_ points: [CGPoint], index: Int) -> [Double] {
            points.enumerated()
                .filter { $0.offset != index }
                .map { hypot(points[index].x - $0.element.x, points[index].y - $0.element.y) }
                .sorted()
        }

        func signatureDifference(_ a: [Double], _ b: [Double]) -> Double {
            let n = min(a.count, b.count)
            guard n > 0 else { return .greatestFiniteMagnitude }
            return (0..<n).reduce(0.0) { $0 + abs(a[$1] - b[$1]) } / Double(n)
        }

        var correspondences: [StarCorrespondence] = []
        for (i, beforePoint) in before.enumerated() {
            let beforeSignature = signature(before, index: i)
            var bestIndex: Int?
            var bestDifference = Double.greatestFiniteMagnitude
            for (j, _) in after.enumerated() {
                let difference = signatureDifference(beforeSignature, signature(after, index: j))
                if difference < bestDifference {
                    bestDifference = difference
                    bestIndex = j
                }
            }
            if let bestIndex, bestDifference < maxSignatureDifference {
                correspondences.append(StarCorrespondence(before: beforePoint, after: after[bestIndex]))
            }
        }
        return correspondences
    }

    /// Least-squares rotation center from >= 2 correspondences: for a pure rotation about center
    /// `C`, `|C - before| = |C - after|` for every matched star, so `C` lies on the perpendicular
    /// bisector of `(before, after)`. Each correspondence contributes one linear equation in
    /// `C = (Cx, Cy)`; with >= 2 non-parallel bisectors this is solved exactly, and with more
    /// than 2 it's solved via least squares (normal equations), improving robustness to detection
    /// noise the more stars are matched.
    static func solveRotationCenter(from correspondences: [StarCorrespondence]) -> CGPoint? {
        guard correspondences.count >= 2 else { return nil }

        var sumDxDx = 0.0, sumDxDy = 0.0, sumDyDy = 0.0
        var sumDxRhs = 0.0, sumDyRhs = 0.0

        for correspondence in correspondences {
            let dx = correspondence.after.x - correspondence.before.x
            let dy = correspondence.after.y - correspondence.before.y
            let rhs = (
                correspondence.after.x * correspondence.after.x + correspondence.after.y * correspondence.after.y
                    - correspondence.before.x * correspondence.before.x - correspondence.before.y * correspondence.before.y
            ) / 2
            sumDxDx += dx * dx
            sumDxDy += dx * dy
            sumDyDy += dy * dy
            sumDxRhs += dx * rhs
            sumDyRhs += dy * rhs
        }

        let determinant = sumDxDx * sumDyDy - sumDxDy * sumDxDy
        guard abs(determinant) > 1e-9 else { return nil } // bisectors parallel/coincident — degenerate

        let centerX = (sumDxRhs * sumDyDy - sumDxDy * sumDyRhs) / determinant
        let centerY = (sumDxDx * sumDyRhs - sumDxRhs * sumDxDy) / determinant
        return CGPoint(x: centerX, y: centerY)
    }
}
