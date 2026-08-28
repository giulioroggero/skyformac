import CoreGraphics
import Foundation

/// Aligns and averages several *same-field-of-view* captures into one image — the "just combine
/// these stills for a better SNR" counterpart to `MosaicComposer` (which instead stitches
/// deliberately *offset* tiles side by side into a wider frame). Reuses `MosaicComposer`'s own
/// star-pattern registration primitives (`StarDetector`, `MosaicStarMatcher`,
/// `SimilarityTransformFitter`) to correct the small drift/rotation between otherwise-overlapping
/// captures (an untracked mount, slightly different framing between two sessions of the same
/// target) before combining them — unlike `PlanetaryPostProcessor`'s own stacking, which operates
/// on raw sensor `.ser` frames, not already-debayered/stretched stills like a saved PNG/TIFF/FITS
/// capture. Shares `MosaicComposer.ComposeError` rather than a parallel error type, since the same
/// three failure shapes (too few usable inputs, one doesn't line up, rendering failed) apply here
/// unchanged.
enum StillImageStacker {
    /// `tileIndex`/`totalTiles` reported once per tile as its star detection finishes, then again
    /// as it's added to the running average — the same shape `MosaicComposer.compose`'s own
    /// progress callback uses, so `MosaicComposerView` can share one progress sink for both modes.
    static func stack(tiles: [CGImage], progress: ((Int, Int) -> Void)? = nil) throws -> CGImage {
        guard tiles.count >= 2 else { throw MosaicComposer.ComposeError.tooFewTiles }
        let reference = tiles[0]
        let width = reference.width
        let height = reference.height

        var pointsPerTile: [[CGPoint]] = []
        for (index, tile) in tiles.enumerated() {
            let detected = try StarDetector.detectStars(in: tile)
            pointsPerTile.append(pixelPoints(from: detected.stars, width: tile.width, height: tile.height))
            progress?(index, tiles.count)
        }

        var accumulator = ChannelAccumulator(width: width, height: height)
        accumulator.add(rasterize(reference, transform: .identity, width: width, height: height))
        progress?(0, tiles.count)

        // Every tile is matched directly against tile 0 (the reference), not chained
        // tile-to-previous the way `MosaicComposer` does — these are meant to already share
        // (almost) the same field of view, so registering each one straight against a single
        // fixed reference avoids compounding drift across a long sequence the way a chain would.
        for index in 1..<tiles.count {
            let matches = MosaicStarMatcher.match(pointsPerTile[index], pointsPerTile[0])
            guard matches.count >= 2 else { throw MosaicComposer.ComposeError.insufficientOverlap(tileIndex: index) }
            let sourcePoints = matches.map { pointsPerTile[index][$0.indexA] }
            let targetPoints = matches.map { pointsPerTile[0][$0.indexB] }
            guard let transform = SimilarityTransformFitter.fit(source: sourcePoints, target: targetPoints)
            else { throw MosaicComposer.ComposeError.insufficientOverlap(tileIndex: index) }
            guard let raster = rasterize(tiles[index], transform: transform, width: width, height: height)
            else { throw MosaicComposer.ComposeError.renderFailed }
            accumulator.add(raster)
            progress?(index, tiles.count)
        }

        guard let image = accumulator.makeImage() else { throw MosaicComposer.ComposeError.renderFailed }
        return image
    }

    /// Same Vision-normalized-to-pixel conversion as `MosaicComposer.pixelPoints` — duplicated
    /// rather than shared since that one's `private` to its own enum and this is a two-line helper.
    private static func pixelPoints(from stars: [DetectedStar], width: Int, height: Int) -> [CGPoint] {
        stars.map { star in
            let box = star.boundingBoxNormalized
            return CGPoint(x: box.midX * CGFloat(width), y: (1 - box.midY) * CGFloat(height))
        }
    }

    /// Draws `tile` transformed into `width`x`height` canvas space, returning its raw RGBA8
    /// pixels. A pixel the transform left outside the tile's own bounds (a rotated/shifted edge)
    /// comes back with alpha `0`, so `ChannelAccumulator` can exclude it from that pixel's average
    /// instead of blending in transparent black.
    private static func rasterize(
        _ tile: CGImage, transform: Similarity2DTransform, width: Int, height: Int
    ) -> [UInt8]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(transform.cgAffineTransform)
        context.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        let count = width * height * 4
        return Array(UnsafeRawBufferPointer(start: data, count: count))
    }
}

/// Per-pixel running sum/count for RGB — the still-image counterpart to `LiveStacker`'s own
/// masked-average accumulator, operating on already-rendered RGBA8 buffers (`rasterize`'s output)
/// instead of raw sensor data, and excluding a pixel entirely from a tile's contribution wherever
/// that tile's own alpha is `0` there (outside its rotated/shifted bounds) rather than averaging
/// in transparent black.
private struct ChannelAccumulator {
    let width: Int
    let height: Int
    private var sums: [UInt32]
    private var counts: [UInt16]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        sums = [UInt32](repeating: 0, count: width * height * 3)
        counts = [UInt16](repeating: 0, count: width * height)
    }

    mutating func add(_ rgba: [UInt8]?) {
        guard let rgba, rgba.count == width * height * 4 else { return }
        for i in 0..<(width * height) {
            let o = i * 4
            guard rgba[o + 3] > 0 else { continue }
            let s = i * 3
            sums[s] += UInt32(rgba[o])
            sums[s + 1] += UInt32(rgba[o + 1])
            sums[s + 2] += UInt32(rgba[o + 2])
            counts[i] += 1
        }
    }

    func makeImage() -> CGImage? {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let count = UInt32(counts[i])
            guard count > 0 else { continue }
            let o = i * 4
            let s = i * 3
            output[o] = UInt8(clamping: sums[s] / count)
            output[o + 1] = UInt8(clamping: sums[s + 1] / count)
            output[o + 2] = UInt8(clamping: sums[s + 2] / count)
            output[o + 3] = 255
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return output.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
