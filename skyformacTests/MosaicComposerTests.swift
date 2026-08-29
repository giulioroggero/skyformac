import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct SimilarityTransformFitterTests {
    @Test func fitRecoversAKnownPureTranslation() throws {
        let known = Similarity2DTransform(a: 1, b: 0, tx: 12, ty: -7)
        let source = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 20), CGPoint(x: 30, y: 60)]
        let target = source.map(known.apply)

        let fitted = try #require(SimilarityTransformFitter.fit(source: source, target: target))
        #expect(abs(fitted.a - known.a) < 1e-6)
        #expect(abs(fitted.b - known.b) < 1e-6)
        #expect(abs(fitted.tx - known.tx) < 1e-6)
        #expect(abs(fitted.ty - known.ty) < 1e-6)
    }

    @Test func fitRecoversAKnownRotationScaleAndTranslation() throws {
        // scale 1.4, rotation ~25.8°, real translation — everything a mosaic tile offset by
        // capture drift/rotation actually looks like, not just a clean pan.
        let angle = 0.45
        let scale = 1.4
        let known = Similarity2DTransform(a: scale * cos(angle), b: scale * sin(angle), tx: 40, ty: -15)
        let source = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 80), CGPoint(x: 60, y: 45)]
        let target = source.map(known.apply)

        let fitted = try #require(SimilarityTransformFitter.fit(source: source, target: target))
        #expect(abs(fitted.a - known.a) < 1e-6)
        #expect(abs(fitted.b - known.b) < 1e-6)
        #expect(abs(fitted.tx - known.tx) < 1e-4)
        #expect(abs(fitted.ty - known.ty) < 1e-4)

        // Round-trips through every source point, and `cgAffineTransform` agrees with `apply`.
        for (s, t) in zip(source, target) {
            let applied = fitted.apply(s)
            #expect(abs(applied.x - t.x) < 1e-3)
            #expect(abs(applied.y - t.y) < 1e-3)
            let viaCGAffineTransform = s.applying(fitted.cgAffineTransform)
            #expect(abs(viaCGAffineTransform.x - t.x) < 1e-3)
            #expect(abs(viaCGAffineTransform.y - t.y) < 1e-3)
        }
    }

    @Test func fitReturnsNilForTooFewOrDegeneratePoints() {
        #expect(SimilarityTransformFitter.fit(source: [CGPoint(x: 0, y: 0)], target: [CGPoint(x: 1, y: 1)]) == nil)
        // Every source point coincident — no shape at all to fit a rotation/scale from.
        let coincident = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]
        #expect(SimilarityTransformFitter.fit(source: coincident, target: coincident) == nil)
    }

    @Test func concatenatingComposesTwoTransformsInApplicationOrder() {
        let first = Similarity2DTransform(a: 1, b: 0, tx: 10, ty: 0) // +10 on x
        let second = Similarity2DTransform(a: 0, b: 1, tx: 0, ty: 0) // rotate 90°
        // second.concatenating(first): apply `first`, then `second` — (0,0) -> (10,0) -> (0,10).
        let combined = second.concatenating(first)
        let result = combined.apply(CGPoint(x: 0, y: 0))
        #expect(abs(result.x - 0) < 1e-9)
        #expect(abs(result.y - 10) < 1e-9)
    }
}

struct MosaicStarMatcherTests {
    @Test func matchFindsCorrespondencesUnderATranslation() {
        let a = [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 15), CGPoint(x: 30, y: 90), CGPoint(x: 120, y: 60)]
        let offset = CGVector(dx: 25, dy: -8)
        let b = a.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }

        let matches = MosaicStarMatcher.match(a, b)
        #expect(!matches.isEmpty)
        // Every match found should be the *correct* index pairing (a[i] really does correspond to
        // b[i] here, since `b` was built as a straight positional offset of `a`).
        for match in matches {
            #expect(match.indexA == match.indexB)
        }
    }

    @Test func matchFindsCorrespondencesUnderARotationAndScale() {
        let transform = Similarity2DTransform(a: 1.2 * cos(0.3), b: 1.2 * sin(0.3), tx: 50, ty: 20)
        let a = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 10), CGPoint(x: 20, y: 100), CGPoint(x: 90, y: 90)]
        let b = a.map(transform.apply)

        let matches = MosaicStarMatcher.match(a, b)
        #expect(matches.count >= 2)
        for match in matches {
            #expect(match.indexA == match.indexB)
        }
    }

    @Test func matchReturnsEmptyForFewerThanThreePoints() {
        let matches = MosaicStarMatcher.match([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        #expect(matches.isEmpty)
    }
}

struct MosaicComposerTests {
    /// Several small bright square "stars" on an otherwise-black background, top-left-origin —
    /// same synthetic-blob-image convention `ImageEditorTests.makeBlobImage` already uses, just
    /// with several dots instead of one so `StarDetector`'s contour detection has a real asterism
    /// to find. `positions` are each blob's own top-left corner.
    private func makeStarFieldImage(width: Int, height: Int, positions: [(x: Int, y: Int)], blobSize: Int = 10) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for position in positions where position.x < width && position.y < height {
            for y in position.y..<min(position.y + blobSize, height) where y >= 0 {
                for x in position.x..<min(position.x + blobSize, width) where x >= 0 {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 255
                    pixels[offset + 1] = 255
                    pixels[offset + 2] = 255
                }
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test func composeThrowsWithFewerThanTwoTiles() {
        let tile = makeStarFieldImage(width: 200, height: 200, positions: [(20, 20), (100, 40), (60, 150)])
        #expect(throws: MosaicComposer.ComposeError.self) {
            try MosaicComposer.compose(tiles: [tile])
        }
    }

    /// Two tiles sharing the same asterism, the second shifted by a known translation (as if the
    /// second tile were captured after panning the mount) — a real, if minimal, end-to-end
    /// exercise of star detection (`StarDetector`, Vision-backed) → matching → transform fitting
    /// → canvas compositing, not just the pure-geometry pieces above. The composed canvas should
    /// be wider than either tile alone (the two only partially overlap), never smaller.
    @Test func composeProducesACanvasLargerThanEitherTileAlone() throws {
        let positions: [(x: Int, y: Int)] = [(30, 30), (150, 40), (90, 160), (200, 100)]
        let tileA = makeStarFieldImage(width: 340, height: 300, positions: positions, blobSize: 14)
        let shiftedPositions = positions.map { (x: $0.x + 60, y: $0.y) }
        let tileB = makeStarFieldImage(width: 340, height: 300, positions: shiftedPositions, blobSize: 14)

        let composed = try MosaicComposer.compose(tiles: [tileA, tileB])
        #expect(composed.width > 340)
        #expect(composed.height >= 300)
    }

    /// A deterministic noise texture — real per-pixel structure (unlike `makeStarFieldImage`'s
    /// point sources on a flat black background), the same kind of content a Moon crater field or
    /// a terrestrial photo actually offers `StarDetector` nothing to find in. A tiny seeded LCG
    /// (not `Int.random`, for a reproducible test) fills every pixel independently, giving Vision's
    /// own generic keypoint detector plenty of local contrast to lock onto.
    private func makeNoiseTextureImage(width: Int, height: Int, seed: UInt64 = 1) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state = seed
        func nextByte() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 56) & 0xFF)
        }
        for i in 0..<(width * height) {
            let value = nextByte()
            pixels[i * 4] = value
            pixels[i * 4 + 1] = value
            pixels[i * 4 + 2] = value
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// A crop of a shared noise texture, top-left origin — mirrors
    /// `composeProducesACanvasLargerThanEitherTileAlone`'s "two tiles, one translated" shape, just
    /// with real overlapping image content instead of a matched pair of star positions.
    private func crop(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: x, y: y, width: width, height: height))!
    }

    /// The exact scenario this composer previously couldn't handle at all — no stars, no
    /// point-source content of any kind, just two overlapping crops of an ordinary photo (what a
    /// Moon mosaic's crater detail, or a plain terrestrial panorama, actually looks like).
    /// `MosaicStarMatcher` finds nothing to match here; `GenericImageRegistrar`'s Vision-based
    /// generic feature registration is what makes this succeed instead of throwing
    /// `insufficientOverlap`.
    @Test func composeRegistersOverlappingTilesWithNoDetectableStars() throws {
        let master = makeNoiseTextureImage(width: 460, height: 340)
        let tileA = crop(master, x: 0, y: 0, width: 340, height: 300)
        let tileB = crop(master, x: 60, y: 0, width: 340, height: 300)

        let composed = try MosaicComposer.compose(tiles: [tileA, tileB])
        #expect(composed.width > 340)
        #expect(composed.height >= 300)
    }
}
