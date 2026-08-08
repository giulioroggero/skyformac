import CoreGraphics
import Foundation

/// A solved astrometric calibration for a single frame: field center, pixel scale, and field
/// rotation. Per spec/skyformac_Catalog_HUD_Spec.md section 4, this is what `SkyHUDView` needs to
/// map any catalog object's (RA, Dec) onto the pixel it falls on in that specific frame.
///
/// - Important: `LiveWCSSolver` fits this from `StarPatternRecognizer.correspondences` — a small-
///   angle least-squares similarity-transform fit, not a full blind plate solver (no distortion
///   model, accuracy narrows to the star match's own confidence). See its doc comment.
struct WCSFrame: Sendable, Equatable {
    let centerRADeg: Double
    let centerDecDeg: Double
    /// Pixel scale, in radians of sky per pixel.
    let radiansPerPixel: Double
    /// Field rotation, in radians (spec section 4, step 2's θ).
    let rotationRadians: Double
    let imageWidth: Int
    let imageHeight: Int

    /// The frame's angular width/height, in degrees — used for both the catalog bounding-box
    /// query and the dynamic level-of-detail magnitude cutoff (spec section 6.2).
    var fieldOfViewDegrees: (width: Double, height: Double) {
        let degPerPixel = radiansPerPixel * 180 / .pi
        return (degPerPixel * Double(imageWidth), degPerPixel * Double(imageHeight))
    }

    /// Gnomonic (tangent-plane) projection of a celestial coordinate onto this frame's pixel
    /// space (spec section 4, steps 1-2). Returns `nil` for coordinates on or behind the tangent
    /// plane (more than ~90° from the field center) — undefined/infinite in this projection.
    func projectToPixel(raDeg: Double, decDeg: Double) -> CGPoint? {
        let deg2rad = Double.pi / 180
        let dAlpha = (raDeg - centerRADeg) * deg2rad
        let delta0 = centerDecDeg * deg2rad
        let delta = decDeg * deg2rad

        let d = sin(delta0) * sin(delta) + cos(delta0) * cos(delta) * cos(dAlpha)
        guard d > 0.01 else { return nil }

        let xi = cos(delta) * sin(dAlpha) / d
        let eta = (cos(delta0) * sin(delta) - sin(delta0) * cos(delta) * cos(dAlpha)) / d

        let cosT = cos(rotationRadians)
        let sinT = sin(rotationRadians)
        let xPixel = Double(imageWidth) / 2 + (-cosT * xi + sinT * eta) / radiansPerPixel
        let yPixel = Double(imageHeight) / 2 + (sinT * xi + cosT * eta) / radiansPerPixel
        return CGPoint(x: xPixel, y: yPixel)
    }

    /// Celestial bounding box to query the catalog with (spec section 3.1), padded so objects
    /// near the frame's diagonal corners — where the true FOV circle's AABB extends past the
    /// rectangular frame in a rotated field — still get fetched.
    func boundingBox(paddingFactor: Double = 1.3) -> BoundingBox {
        let fov = fieldOfViewDegrees
        let wDeg = fov.width * paddingFactor
        let hDeg = fov.height * paddingFactor

        let decMin = max(-90, centerDecDeg - hDeg / 2)
        let decMax = min(90, centerDecDeg + hDeg / 2)
        let limitDecDeg = max(abs(decMin), abs(decMax))
        let cosLimit = max(cos(limitDecDeg * .pi / 180), 0.01) // guards the near-pole singularity
        let deltaAlpha = wDeg / 2 / cosLimit

        // Near the pole (or for a very wide FOV), the RA half-width can exceed 180° — the whole
        // point of the cosδ correction is that a fixed sky-angle spans more and more RA the
        // closer the field gets to a pole. Naively wrapping a >180° half-width back into
        // [0, 360) folds it into a bogus *narrow* slice (e.g. 1625° wraps to a 10°-wide range)
        // instead of "cover the whole RA axis", which is what it actually means here.
        guard deltaAlpha < 180 else {
            return BoundingBox(raMinDeg: 0, raMaxDeg: 360, decMinDeg: decMin, decMaxDeg: decMax)
        }

        func wrap(_ degrees: Double) -> Double {
            let wrapped = degrees.truncatingRemainder(dividingBy: 360)
            return wrapped < 0 ? wrapped + 360 : wrapped
        }

        return BoundingBox(
            raMinDeg: wrap(centerRADeg - deltaAlpha),
            raMaxDeg: wrap(centerRADeg + deltaAlpha),
            decMinDeg: decMin,
            decMaxDeg: decMax
        )
    }
}

/// A celestial bounding box in RA/Dec, per spec section 3.1.
struct BoundingBox: Sendable {
    let raMinDeg: Double
    let raMaxDeg: Double
    let decMinDeg: Double
    let decMaxDeg: Double

    /// `true` when the RA range wraps past the 0°/360° seam (e.g. a field centered near RA
    /// 359°) — the SQL query needs an OR'd range instead of a single BETWEEN in that case.
    var wrapsAround: Bool { raMinDeg > raMaxDeg }
}
