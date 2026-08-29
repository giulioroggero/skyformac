import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision
import simd

/// A 2D similarity transform (uniform scale + rotation + translation) — the same 4-degrees-of-
/// freedom shape `LiveWCSSolver.solve` fits for pixel<->sky, just for plain pixel<->pixel here.
/// Stored as `a`/`b` (the rotation+scale matrix's own two independent values — `a = scale*cosθ`,
/// `b = scale*sinθ`) rather than scale/rotation separately, since that's both what the closed-form
/// fit below naturally produces and what composing two transforms needs directly.
struct Similarity2DTransform: Sendable {
    var a: Double
    var b: Double
    var tx: Double
    var ty: Double

    static let identity = Similarity2DTransform(a: 1, b: 0, tx: 0, ty: 0)

    func apply(_ point: CGPoint) -> CGPoint {
        CGPoint(x: a * point.x - b * point.y + tx, y: b * point.x + a * point.y + ty)
    }

    var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// `self` after `other` — `self.concatenating(other).apply(p) == self.apply(other.apply(p))`.
    /// What chains a tile's own transform ("tile *i* onto tile *i-1*") into the mosaic's shared
    /// reference frame ("tile *i-1* onto tile 0") across a sequential registration chain.
    func concatenating(_ other: Similarity2DTransform) -> Similarity2DTransform {
        Similarity2DTransform(
            a: a * other.a - b * other.b, b: b * other.a + a * other.b,
            tx: a * other.tx - b * other.ty + tx, ty: b * other.tx + a * other.ty + ty
        )
    }
}

/// Fits a `Similarity2DTransform` from point correspondences via ordinary least squares — the
/// same "real geometry, closed-form OLS" spirit as `LiveWCSSolver.solve`, but derived fresh here
/// for a plain pixel<->pixel fit (that solver's own derivation is specific to its small-angle
/// tangent-plane sky projection, not something a second unrelated fit target can reuse directly).
/// The closed form itself is the standard "least-squares similarity transform between two point
/// sets" result, viewing each point as a complex number `x + iy`: fitting `target ≈ s·source + t`
/// for complex `s` (which encodes rotation *and* scale together) and `t` (translation) reduces to
/// `s = Σ(a·conj(b)) / Σ|b|²`, `t = mean(target) - s·mean(source)`, where `a`/`b` are the
/// source/target points centered on their own means.
enum SimilarityTransformFitter {
    /// Needs >= 2 correspondences (4 unknowns: scale, rotation, tx, ty); more are averaged for
    /// robustness the same way `LiveWCSSolver` treats extra correspondences. `nil` if the source
    /// points are degenerate (e.g. all coincident).
    static func fit(source: [CGPoint], target: [CGPoint]) -> Similarity2DTransform? {
        guard source.count == target.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let meanSource = CGPoint(x: source.map(\.x).reduce(0, +) / n, y: source.map(\.y).reduce(0, +) / n)
        let meanTarget = CGPoint(x: target.map(\.x).reduce(0, +) / n, y: target.map(\.y).reduce(0, +) / n)

        var sumRealPart = 0.0
        var sumImaginaryPart = 0.0
        var sumSourceMagnitudeSquared = 0.0
        for i in 0..<source.count {
            let bx = source[i].x - meanSource.x
            let by = source[i].y - meanSource.y
            let ax = target[i].x - meanTarget.x
            let ay = target[i].y - meanTarget.y
            // a * conj(b) = (ax + i·ay)(bx - i·by) = (ax·bx + ay·by) + i(ay·bx - ax·by)
            sumRealPart += ax * bx + ay * by
            sumImaginaryPart += ay * bx - ax * by
            sumSourceMagnitudeSquared += bx * bx + by * by
        }
        guard sumSourceMagnitudeSquared > 1e-9 else { return nil }
        let a = sumRealPart / sumSourceMagnitudeSquared
        let b = sumImaginaryPart / sumSourceMagnitudeSquared
        guard a * a + b * b > 1e-9 else { return nil }

        let tx = meanTarget.x - (a * meanSource.x - b * meanSource.y)
        let ty = meanTarget.y - (b * meanSource.x + a * meanSource.y)
        return Similarity2DTransform(a: a, b: b, tx: tx, ty: ty)
    }
}

/// Resolves point-to-point correspondence between two *anonymous* detected-star sets via triangle
/// (asterism) similarity — the same shape-matching technique
/// `StarPatternRecognizer.correspondences` already uses to pin detected pixels to *named* catalog
/// stars, adapted here for two plain pixel sets instead (a mosaic tile has no catalog to match
/// against, just its neighboring tile's own detected stars) — trying all 6 vertex-labelings of
/// each candidate triangle pair is what recovers *which* point is which, not just "these two
/// triangles are the same shape."
enum MosaicStarMatcher {
    struct Match {
        let indexA: Int
        let indexB: Int
    }

    /// Capped triangle enumeration (see `StarPatternRecognizer.recognize`'s own doc comment for
    /// the identical reasoning) — `maxPoints` keeps the O(n³) × O(m³) triangle-pair comparison
    /// bounded on a busy field.
    static func match(
        _ pointsA: [CGPoint], _ pointsB: [CGPoint],
        toleranceFraction: Double = 0.06, minimumVotes: Int = 2, maxPoints: Int = 12
    ) -> [Match] {
        guard pointsA.count >= 3, pointsB.count >= 3 else { return [] }
        let a = Array(pointsA.prefix(maxPoints))
        let b = Array(pointsB.prefix(maxPoints))

        var votes: [Int: [Int: Int]] = [:] // index in a -> index in b -> vote count
        for i in 0..<a.count {
            for j in (i + 1)..<a.count {
                for k in (j + 1)..<a.count {
                    let sideIJ = hypot(a[i].x - a[j].x, a[i].y - a[j].y)
                    guard sideIJ > 0 else { continue }
                    let ratio1 = hypot(a[j].x - a[k].x, a[j].y - a[k].y) / sideIJ
                    let ratio2 = hypot(a[i].x - a[k].x, a[i].y - a[k].y) / sideIJ

                    for p in 0..<b.count {
                        for q in (p + 1)..<b.count {
                            for r in (q + 1)..<b.count {
                                for (x, y, z) in labelings(p, q, r) {
                                    let sideXY = hypot(b[x].x - b[y].x, b[x].y - b[y].y)
                                    guard sideXY > 0 else { continue }
                                    let bRatio1 = hypot(b[y].x - b[z].x, b[y].y - b[z].y) / sideXY
                                    let bRatio2 = hypot(b[x].x - b[z].x, b[x].y - b[z].y) / sideXY
                                    guard abs(ratio1 - bRatio1) < toleranceFraction, abs(ratio2 - bRatio2) < toleranceFraction
                                    else { continue }
                                    votes[i, default: [:]][x, default: 0] += 1
                                    votes[j, default: [:]][y, default: 0] += 1
                                    votes[k, default: [:]][z, default: 0] += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        return votes.compactMap { indexA, tally -> Match? in
            guard let best = tally.max(by: { $0.value < $1.value }), best.value >= minimumVotes else { return nil }
            return Match(indexA: indexA, indexB: best.key)
        }
    }

    private static func labelings(_ p: Int, _ q: Int, _ r: Int) -> [(Int, Int, Int)] {
        [(p, q, r), (p, r, q), (q, p, r), (q, r, p), (r, p, q), (r, q, p)]
    }
}

/// Registers one tile against its neighbor using Vision's own general-purpose homographic image
/// registration — unlike `MosaicStarMatcher` below (which needs an anonymous *point* source, i.e.
/// stars specifically), this locks onto whatever local structure the content actually offers:
/// lunar craters/terminator detail, terrestrial edges and texture, building silhouettes — anything
/// with enough contrast for Vision's own internal keypoint detector to find and match, not just
/// star fields. `MosaicComposer.compose` reaches for this only when `MosaicStarMatcher` can't find
/// enough point-source matches — exactly the Moon/terrestrial case, where there are no stars to
/// match at all. Star matching stays authoritative for real star fields: it's a precise fit tuned
/// for that exact shape (anonymous point sources), and a synthetic or sparse starfield can give
/// Vision's own generic keypoint detector too little real texture to lock onto reliably.
enum GenericImageRegistrar {
    /// Approximates Vision's fitted homography as a similarity transform (rotation + uniform scale
    /// + translation) so it can share `MosaicComposer`'s existing `CGAffineTransform`-based canvas
    /// placement — any genuine perspective component Vision found is folded into this least-squares
    /// fit rather than applied exactly (a true projective warp would need the compositor itself
    /// rewritten around `CIFilter.perspectiveTransform`; for the pan-style sweep a mosaic actually
    /// is, the residual is negligible). `nil` if Vision couldn't register the pair at all, or if
    /// what it found looks degenerate (near-zero or wildly implausible scale) rather than a real
    /// two-tile overlap.
    static func similarityTransform(reference: CGImage, floating: CGImage) -> Similarity2DTransform? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: floating, options: [:])
        guard (try? VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])) != nil,
              let observation = request.results?.first as? VNImageHomographicAlignmentObservation
        else { return nil }

        let floatingSize = CGSize(width: floating.width, height: floating.height)
        let referenceSize = CGSize(width: reference.width, height: reference.height)
        // Corners plus the center — a handful of samples spread across the tile, not just its
        // corners, so the similarity fit below tracks the true homography well even where Vision
        // found real (if modest) perspective distortion, not only a clean rotate/scale/pan.
        let samplePoints = [
            CGPoint(x: 0, y: 0), CGPoint(x: floatingSize.width, y: 0),
            CGPoint(x: 0, y: floatingSize.height), CGPoint(x: floatingSize.width, y: floatingSize.height),
            CGPoint(x: floatingSize.width / 2, y: floatingSize.height / 2),
        ]
        let targetPoints = samplePoints.map {
            referencePixelPoint(forFloatingPixel: $0, floatingSize: floatingSize, referenceSize: referenceSize, warpTransform: observation.warpTransform)
        }
        guard let fitted = SimilarityTransformFitter.fit(source: samplePoints, target: targetPoints) else { return nil }
        // Reject an implausible fit rather than trust a registration Vision itself found
        // ambiguous — same spirit as `MosaicStarMatcher.match`'s own `minimumVotes` threshold.
        let scaleSquared = fitted.a * fitted.a + fitted.b * fitted.b
        guard scaleSquared > 0.04, scaleSquared < 25 else { return nil }
        return fitted
    }

    /// `warpTransform` operates in Vision's own resolution-independent, bottom-left-origin,
    /// normalized `[0,1]x[0,1]` coordinate space for *both* images — converts a floating-tile pixel
    /// point (this app's usual top-left-origin, y-down convention) through that normalized
    /// homography and back into the reference tile's own pixel space, doing the homogeneous divide
    /// explicitly rather than assuming the third row is trivial (it generally isn't, for a real
    /// perspective fit).
    private static func referencePixelPoint(
        forFloatingPixel point: CGPoint, floatingSize: CGSize, referenceSize: CGSize, warpTransform matrix: simd_float3x3
    ) -> CGPoint {
        let normalizedFloating = simd_float3(
            Float(point.x / floatingSize.width), Float(1 - point.y / floatingSize.height), 1
        )
        let transformed = matrix * normalizedFloating
        let normalizedReferenceX = CGFloat(transformed.x / transformed.z)
        let normalizedReferenceY = CGFloat(transformed.y / transformed.z)
        return CGPoint(
            x: normalizedReferenceX * referenceSize.width,
            y: (1 - normalizedReferenceY) * referenceSize.height
        )
    }
}

/// Composes several overlapping-but-offset captures (different tiles of the Moon, adjacent fields
/// of a wide object like Andromeda, or any other overlapping photo set) into one larger image.
/// `MosaicStarMatcher`'s star-pattern triangle matching handles real star fields; when it can't
/// find enough point-source matches (no stars at all — lunar craters, a plain terrestrial photo),
/// `GenericImageRegistrar`'s Vision-based generic feature registration takes over, so this works on
/// any overlapping photo set, not just starfields.
/// Unlike `PlanetaryPostProcessor`'s own registration/stacking, which assumes every frame shares
/// the *same* field of view and only corrects small sub-pixel jitter between them (its own
/// `alignRGBChannels` explicitly discards a large offset as noise — exactly what a real tile
/// boundary looks like to it), this expects tiles to be substantially offset from one another.
enum MosaicComposer {
    enum ComposeError: Error {
        case tooFewTiles
        /// Not enough matched stars between tile `tileIndex` and the tile before it — the two
        /// don't overlap enough (or at all) for this to register them, unlike a real plate solver
        /// this isn't trying to be.
        case insufficientOverlap(tileIndex: Int)
        case renderFailed
    }

    /// `tileIndex`/`totalTiles` — reported once per tile as its star detection finishes, then
    /// again once per tile as it's composited onto the canvas (`totalTiles*2` calls total).
    static func compose(tiles: [CGImage], progress: ((Int, Int) -> Void)? = nil) throws -> CGImage {
        guard tiles.count >= 2 else { throw ComposeError.tooFewTiles }

        var starPointsPerTile: [[CGPoint]] = []
        for (index, tile) in tiles.enumerated() {
            let detected = try StarDetector.detectStars(in: tile)
            starPointsPerTile.append(pixelPoints(from: detected.stars, width: tile.width, height: tile.height))
            progress?(index, tiles.count)
        }

        // Sequential registration — each tile matched against the one right before it (the
        // natural capture order for a swept mosaic, where adjacent tiles overlap but tile 0 and
        // tile 4 likely don't), then chained into tile 0's own coordinate system via
        // `concatenating`. Star-pattern matching is tried first (precise, when there are real stars
        // to match); a tile pair with no detectable stars at all (lunar craters, a terrestrial
        // photo) falls back to `GenericImageRegistrar`'s Vision-based generic feature registration.
        var transforms: [Similarity2DTransform] = [.identity]
        for i in 1..<tiles.count {
            let matches = MosaicStarMatcher.match(starPointsPerTile[i - 1], starPointsPerTile[i])
            let starFit: Similarity2DTransform? = matches.count >= 2
                ? SimilarityTransformFitter.fit(
                    source: matches.map { starPointsPerTile[i][$0.indexB] },
                    target: matches.map { starPointsPerTile[i - 1][$0.indexA] }
                )
                : nil
            // Star-pattern matching stays authoritative when it finds enough points — a real
            // asterism gives a precise fit Vision's generic keypoints can't necessarily beat.
            // Vision only takes over when there simply aren't enough point sources to match,
            // exactly the case a lunar or terrestrial tile pair hits (no stars at all).
            guard let tileToPrevious = starFit
                ?? GenericImageRegistrar.similarityTransform(reference: tiles[i - 1], floating: tiles[i])
            else { throw ComposeError.insufficientOverlap(tileIndex: i) }
            transforms.append(transforms[i - 1].concatenating(tileToPrevious))
        }

        guard let canvasRect = unionRect(tiles: tiles, transforms: transforms) else { throw ComposeError.tooFewTiles }
        let canvasWidth = Int(canvasRect.width.rounded(.up))
        let canvasHeight = Int(canvasRect.height.rounded(.up))
        guard canvasWidth > 0, canvasHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvasContext = CGContext(
                  data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ComposeError.renderFailed }

        // Flip to this app's own top-left-origin, y-down pixel convention (the standard
        // translate+scale(-1) trick) — every coordinate above (star positions, fitted transforms,
        // `canvasRect`) was computed in that same convention, so drawing here without this flip
        // would composite every tile upside down and offset.
        canvasContext.translateBy(x: 0, y: CGFloat(canvasHeight))
        canvasContext.scaleBy(x: 1, y: -1)

        for (index, tile) in tiles.enumerated() {
            guard let feathered = featheredCGImage(for: tile) else { continue }
            var placement = transforms[index]
            placement.tx -= canvasRect.minX
            placement.ty -= canvasRect.minY
            canvasContext.saveGState()
            canvasContext.concatenate(placement.cgAffineTransform)
            canvasContext.draw(feathered, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
            canvasContext.restoreGState()
            progress?(index, tiles.count)
        }

        guard let composed = canvasContext.makeImage() else { throw ComposeError.renderFailed }
        return composed
    }

    /// `DetectedStar.boundingBoxNormalized` is Vision's own normalized (0...1), bottom-left-origin
    /// convention (see `StarDetector`'s own doc comment) — converted here to this app's usual
    /// top-left-origin pixel space, the same conversion `StarPatternRecognizer` already applies.
    private static func pixelPoints(from stars: [DetectedStar], width: Int, height: Int) -> [CGPoint] {
        stars.map { star in
            let box = star.boundingBoxNormalized
            return CGPoint(x: box.midX * CGFloat(width), y: (1 - box.midY) * CGFloat(height))
        }
    }

    private static func unionRect(tiles: [CGImage], transforms: [Similarity2DTransform]) -> CGRect? {
        var union: CGRect?
        for (tile, transform) in zip(tiles, transforms) {
            let corners = [
                CGPoint(x: 0, y: 0), CGPoint(x: tile.width, y: 0),
                CGPoint(x: 0, y: tile.height), CGPoint(x: tile.width, y: tile.height),
            ].map(transform.apply)
            guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
                  let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max()
            else { continue }
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            union = union?.union(rect) ?? rect
        }
        return union
    }

    private nonisolated(unsafe) static let context = CIContext()

    /// `tile` with its alpha soft-feathered toward every edge (opaque in the interior, fading to
    /// fully transparent over `marginFraction` of the tile's shorter side) — the standard "simple
    /// panorama blend" trick: drawing each tile's own feathered copy over the ones before it lets
    /// a seam's two overlapping tiles blend smoothly into each other near the boundary instead of
    /// showing a hard cut, with no separate weighted-accumulation buffer needed.
    private static func featheredCGImage(for tile: CGImage, marginFraction: Double = 0.12) -> CGImage? {
        let ciImage = CIImage(cgImage: tile)
        let extent = ciImage.extent
        let margin = CGFloat(marginFraction) * min(extent.width, extent.height)
        guard margin > 0 else { return tile }

        // Opaque white inside an edge-inset rect, genuinely transparent beyond it (an *unclamped*
        // blur reads true transparent-black past the color's own extent) — blurring that inset
        // edge is what produces the fade, rather than a hard-edged mask.
        let insetRect = extent.insetBy(dx: margin, dy: margin)
        guard insetRect.width > 0, insetRect.height > 0 else { return tile }
        let maskBase = CIImage(color: .white).cropped(to: insetRect)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = maskBase
        blur.radius = Float(margin / 2)
        guard let mask = blur.outputImage?.cropped(to: extent) else { return tile }

        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = ciImage
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = mask
        guard let output = blend.outputImage else { return tile }
        return context.createCGImage(output, from: extent)
    }
}
