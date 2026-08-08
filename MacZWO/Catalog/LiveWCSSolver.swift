import CoreGraphics
import Foundation

/// Solves an approximate `WCSFrame` (pointing/rotation/plate scale) from real pixel<->sky
/// correspondences — e.g. `StarPatternRecognizer.correspondences`'s output — so `SkyHUDView` can
/// show catalog overlays on an actual live camera frame instead of only ever a demo target.
///
/// - Important: Not a full astrometric plate solver. It's a small-angle, least-squares fit of the
///   2D similarity transform (rotation + uniform scale + translation) that `WCSFrame.projectToPixel`
///   already defines, given `correspondences` it trusts as correct — no distortion model, no
///   robust outlier rejection beyond `Correspondence.confidence` filtering upstream, and accuracy
///   degrades away from the small-angle assumption on very wide fields. Same "real geometry,
///   honestly scoped" spirit as `PolarAlignmentSolver`'s rotation-center solve.
enum LiveWCSSolver {
    /// Fits `centerRADeg`/`centerDecDeg`/`radiansPerPixel`/`rotationRadians` to best explain
    /// `correspondences` under `WCSFrame.projectToPixel`'s exact forward-projection formula
    /// (inverted analytically below), via ordinary least squares. Needs >= 2 correspondences
    /// (4 unknowns, 2 equations per point); more are averaged for robustness against detection
    /// noise. Returns `nil` if the points are degenerate (e.g. all coincident).
    static func solve(
        correspondences: [StarPatternRecognizer.Correspondence],
        imageWidth: Int,
        imageHeight: Int
    ) -> WCSFrame? {
        guard correspondences.count >= 2 else { return nil }
        let n = Double(correspondences.count)

        // Provisional small-angle tangent-plane reference: the correspondences' own mean RA/Dec.
        // Doesn't need to be the true field center — the fit below solves for the (small) offset
        // between this reference and the true center along with rotation/scale, in one pass.
        let meanRA = correspondences.map(\.object.raDegrees).reduce(0, +) / n
        let meanDec = correspondences.map(\.object.decDegrees).reduce(0, +) / n
        let deg2rad = Double.pi / 180
        let cosMeanDec = cos(meanDec * deg2rad)

        let halfWidth = Double(imageWidth) / 2
        let halfHeight = Double(imageHeight) / 2

        // (xi, eta): small-angle sky tangent-plane offset from the provisional reference, radians.
        // (dx, dy): pixel offset from the image's true center.
        let points = correspondences.map { c -> (xi: Double, eta: Double, dx: Double, dy: Double) in
            let xi = (c.object.raDegrees - meanRA) * cosMeanDec * deg2rad
            let eta = (c.object.decDegrees - meanDec) * deg2rad
            return (xi, eta, Double(c.pixel.x) - halfWidth, Double(c.pixel.y) - halfHeight)
        }

        let xiMean = points.map(\.xi).reduce(0, +) / n
        let etaMean = points.map(\.eta).reduce(0, +) / n
        let dxMean = points.map(\.dx).reduce(0, +) / n
        let dyMean = points.map(\.dy).reduce(0, +) / n

        // Least-squares fit of `dx = A*xi + B*eta + Cx`, `dy = B*xi - A*eta + Cy` — the linear
        // (in A, B) form of `projectToPixel`'s `(-cosθ, sinθ; sinθ, cosθ)/radiansPerPixel` matrix
        // once its constant additive offset (Cx, Cy) is centered out. Standard OLS normal-equation
        // solution for this specific 2x2-rotation-like structure (derived by hand to match
        // `projectToPixel` exactly, not a generic similarity-transform formula).
        var sumDenominator = 0.0
        var sumA = 0.0
        var sumB = 0.0
        for p in points {
            let cxi = p.xi - xiMean
            let ceta = p.eta - etaMean
            let cdx = p.dx - dxMean
            let cdy = p.dy - dyMean
            sumDenominator += cxi * cxi + ceta * ceta
            sumA += cxi * cdx - ceta * cdy
            sumB += ceta * cdx + cxi * cdy
        }
        guard sumDenominator > 1e-20 else { return nil }
        let a = sumA / sumDenominator
        let b = sumB / sumDenominator

        let scaleSquared = a * a + b * b
        guard scaleSquared > 1e-20 else { return nil }
        let radiansPerPixel = 1 / scaleSquared.squareRoot()
        let rotationRadians = atan2(b, -a)

        // Offset (in tangent-plane radians) between the provisional reference and the true field
        // center, recovered from the fit's constant term: `Cx = -A*xi0 - B*eta0`,
        // `Cy = -B*xi0 + A*eta0`, solved for (xi0, eta0).
        let cx = dxMean - a * xiMean - b * etaMean
        let cy = dyMean - b * xiMean + a * etaMean
        let xi0 = -(a * cx + b * cy) / scaleSquared
        let eta0 = (a * cy - b * cx) / scaleSquared

        let centerDecDeg = meanDec + eta0 / deg2rad
        let centerRADeg = meanRA + xi0 / (cosMeanDec * deg2rad)

        return WCSFrame(
            centerRADeg: centerRADeg, centerDecDeg: centerDecDeg,
            radiansPerPixel: radiansPerPixel, rotationRadians: rotationRadians,
            imageWidth: imageWidth, imageHeight: imageHeight
        )
    }
}
