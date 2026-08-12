import Foundation

/// User-configurable "Experimental" mesh-based drift correction settings.
///
/// The existing single-star-lock drift reduction (`DriftAligner`, `MetalFrameRenderer
/// .computeDriftShift`) tracks exactly one star and applies one rigid `(dx, dy)` shift to the
/// whole frame — it can't correct for field rotation or differential drift across a wide field
/// (alt-az mounts without a rotator, imperfect polar alignment, mirror flop). This tracks an
/// NxN grid of points across the frame instead, each drifting independently, and blends their
/// displacements with bilinear interpolation — the same "vertex skinning" technique used to
/// blend bone transforms smoothly across a mesh in real-time rendering/games — to build a smooth,
/// spatially-varying correction instead of one global shift.
///
/// Marked "Experimental" in the UI on purpose: unlike the single-star lock (which has a
/// background-subtracted two-pass measurement per frame), each mesh vertex here measures its own
/// small ROI with a simpler one-pass weighted centroid (see `MeshDriftField.measuredDisplacements`
/// for why) — good enough to validate the technique's payoff on a real rig, not a fully
/// production-hardened replacement for the single-star lock.
struct MeshDriftConfig: Equatable, Sendable {
    /// NxN grid of tracked vertices. Kept small deliberately (`gridSizeRange`) — measurement
    /// cost scales with `gridSize * gridSize`, and a denser mesh needs correspondingly more
    /// overlap for each vertex to reliably contain a star at all.
    var gridSize: Int
    /// 0...1 — how far each vertex's own search/measurement window extends beyond its "home"
    /// cell into its neighbors'. 0 is exactly its own cell; higher values give a vertex a better
    /// chance of actually containing a trackable star (useful for a sparse field), at the cost of
    /// neighboring vertices' measurements overlapping more (drifting less independently).
    var overlap: Double
    /// 0...1 — how much of a newly-measured displacement blends into each vertex's smoothed
    /// value per frame (`MeshDriftField.blend`). Low values are heavily smoothed (resistant to a
    /// single noisy/wrong measurement, slower to react to real drift); high values react
    /// immediately (faster, but noisier).
    var sensitivity: Double

    static let gridSizeRange = 2...8

    static let `default` = MeshDriftConfig(gridSize: 3, overlap: 0.5, sensitivity: 0.5)
}

enum MeshDriftField {
    /// Pixel-space center of each of the `gridSize x gridSize` cells, row-major
    /// (`index == row * gridSize + col`).
    static func vertexPositions(gridSize: Int, width: Int, height: Int) -> [SIMD2<Float>] {
        guard gridSize > 0, width > 0, height > 0 else { return [] }
        let cellWidth = Float(width) / Float(gridSize)
        let cellHeight = Float(height) / Float(gridSize)
        var positions: [SIMD2<Float>] = []
        positions.reserveCapacity(gridSize * gridSize)
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                positions.append(SIMD2<Float>(
                    (Float(col) + 0.5) * cellWidth,
                    (Float(row) + 0.5) * cellHeight
                ))
            }
        }
        return positions
    }

    /// Half-width/half-height (pixels) of each vertex's own search window, given `overlap`.
    static func roiHalfSize(gridSize: Int, width: Int, height: Int, overlap: Double) -> SIMD2<Float> {
        guard gridSize > 0, width > 0, height > 0 else { return SIMD2<Float>(Float(width) / 2, Float(height) / 2) }
        let cellWidth = Float(width) / Float(gridSize)
        let cellHeight = Float(height) / Float(gridSize)
        let factor = Float(1 + max(0, overlap))
        return SIMD2<Float>(cellWidth * factor / 2, cellHeight * factor / 2)
    }

    /// Bilinear blend of the (up to) 4 nearest vertices' displacement vectors at an arbitrary
    /// pixel position — the same interpolation real-time rendering uses to blend control-point
    /// transforms smoothly across a mesh, rather than each cell having a hard edge at its
    /// boundary (a visible seam in the accumulated stack otherwise).
    static func interpolatedDisplacement(
        at pixel: SIMD2<Float>, gridSize: Int, width: Int, height: Int, vertexDisplacements: [SIMD2<Float>]
    ) -> SIMD2<Float> {
        guard gridSize > 0, width > 0, height > 0, vertexDisplacements.count == gridSize * gridSize else {
            return .zero
        }
        if gridSize == 1 { return vertexDisplacements[0] }

        let cellWidth = Float(width) / Float(gridSize)
        let cellHeight = Float(height) / Float(gridSize)
        // Vertex (col, row) sits at the CENTER of its cell, so a pixel's fractional grid position
        // is offset by half a cell before mapping into the [0, gridSize - 1] vertex index space.
        let gx = min(max(pixel.x / cellWidth - 0.5, 0), Float(gridSize - 1))
        let gy = min(max(pixel.y / cellHeight - 0.5, 0), Float(gridSize - 1))
        let col0 = Int(gx)
        let row0 = Int(gy)
        let col1 = min(col0 + 1, gridSize - 1)
        let row1 = min(row0 + 1, gridSize - 1)
        let fx = gx - Float(col0)
        let fy = gy - Float(row0)

        let v00 = vertexDisplacements[row0 * gridSize + col0]
        let v10 = vertexDisplacements[row0 * gridSize + col1]
        let v01 = vertexDisplacements[row1 * gridSize + col0]
        let v11 = vertexDisplacements[row1 * gridSize + col1]

        let top = v00 * (1 - fx) + v10 * fx
        let bottom = v01 * (1 - fx) + v11 * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Exponential (single-pole) smoothing toward a newly measured value — `sensitivity == 1`
    /// jumps straight to `measured`; `sensitivity == 0` never moves at all.
    static func blend(previous: SIMD2<Float>, measured: SIMD2<Float>, sensitivity: Double) -> SIMD2<Float> {
        let t = Float(min(max(sensitivity, 0), 1))
        return previous * (1 - t) + measured * t
    }

    /// Per-vertex intensity centroid (in ORIGINAL frame pixel coordinates), measured from an
    /// already-downsampled luminance grid (`SharpnessScorer.luminanceGrid`) rather than the raw
    /// frame — the same bounded-resolution reasoning that fixed `GPUSharpnessScorer`'s hang
    /// applies here just as directly: measuring `gridSize * gridSize` windows against the *full*
    /// native resolution every live-stack frame would scale with sensor size, not with the mesh
    /// itself. `nil` per vertex whose window has no signal clearly above its own local background
    /// (an empty/cloudy patch of sky) — a vertex with no real star to lock onto shouldn't report
    /// a meaningless centroid on background noise.
    ///
    /// Deliberately a single-pass weighted centroid (weight by how far above the ROI's own mean
    /// a sample is, not the two-pass background+threshold `DriftAligner`/`computeCentroid` uses
    /// for the single-star lock) — simpler, and good enough at the resolution this already runs
    /// at post-downsample; see `MeshDriftConfig`'s own doc comment for why this is the
    /// "Experimental" tier's tradeoff, not the single-star lock's.
    static func measuredCentroids(
        luminance: [Double], gridWidth: Int, gridHeight: Int,
        gridSize: Int, overlap: Double, originalWidth: Int, originalHeight: Int
    ) -> [SIMD2<Float>?] {
        let vertexCount = gridSize * gridSize
        guard gridSize > 0, gridWidth > 0, gridHeight > 0, originalWidth > 0, originalHeight > 0,
              luminance.count == gridWidth * gridHeight
        else {
            return Array(repeating: nil, count: max(vertexCount, 0))
        }

        let scaleX = Float(gridWidth) / Float(originalWidth)
        let scaleY = Float(gridHeight) / Float(originalHeight)
        let vertices = vertexPositions(gridSize: gridSize, width: originalWidth, height: originalHeight)
        let roiHalf = roiHalfSize(gridSize: gridSize, width: originalWidth, height: originalHeight, overlap: overlap)

        return vertices.map { vertex in
            let centerX = vertex.x * scaleX
            let centerY = vertex.y * scaleY
            let halfX = max(1, roiHalf.x * scaleX)
            let halfY = max(1, roiHalf.y * scaleY)
            let minX = max(0, Int((centerX - halfX).rounded(.down)))
            let maxX = min(gridWidth - 1, Int((centerX + halfX).rounded(.up)))
            let minY = max(0, Int((centerY - halfY).rounded(.down)))
            let maxY = min(gridHeight - 1, Int((centerY + halfY).rounded(.up)))
            guard maxX > minX, maxY > minY else { return nil }

            var sum = 0.0
            var count = 0.0
            for y in minY...maxY {
                for x in minX...maxX {
                    sum += luminance[y * gridWidth + x]
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            let mean = sum / count

            var sumWeight = 0.0
            var sumWeightX = 0.0
            var sumWeightY = 0.0
            for y in minY...maxY {
                for x in minX...maxX {
                    let value = luminance[y * gridWidth + x]
                    guard value > mean else { continue }
                    let weight = value - mean
                    sumWeight += weight
                    sumWeightX += weight * Double(x)
                    sumWeightY += weight * Double(y)
                }
            }
            guard sumWeight > 0 else { return nil }

            let gridCentroidX = Float(sumWeightX / sumWeight)
            let gridCentroidY = Float(sumWeightY / sumWeight)
            return SIMD2<Float>(gridCentroidX / scaleX, gridCentroidY / scaleY)
        }
    }
}
