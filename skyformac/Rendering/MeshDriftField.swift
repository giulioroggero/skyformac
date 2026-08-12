import Foundation

/// User-configurable "Experimental" mesh-based drift correction settings.
///
/// The existing single-star-lock drift reduction (`DriftAligner`, `MetalFrameRenderer
/// .computeDriftShift`) tracks exactly one star and applies one rigid `(dx, dy)` shift to the
/// whole frame — it can't correct for field rotation or differential drift across a wide field
/// (alt-az mounts without a rotator, imperfect polar alignment, mirror flop). This tracks an
/// NxN grid of points across the frame instead, each drifting independently, and blends their
/// displacements with triangulated (barycentric) interpolation — the same mesh-deformation
/// primitive real-time rendering/games use to blend control-point transforms smoothly across a
/// surface — to build a smooth, spatially-varying correction instead of one global shift.
///
/// Not a 3D reconstruction of anything, despite the "mesh" name inviting that comparison to e.g.
/// a face-tracking mesh: there's no depth/parallax information to recover from a single 2D
/// camera pointed at the night sky in the first place (every star is, for this purpose, at
/// infinite distance — a flat 2D field, not a 3D surface with real curvature the way a face is).
/// The mesh here is purely a 2D image-plane deformation field for motion compensation; triangles
/// are used because they're the standard, unambiguous interpolation primitive for that (see
/// `interpolatedDisplacement`'s own doc comment), not because there's 3D shape being fitted.
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

    /// Barycentric blend of the 3 vertices of whichever triangle a pixel position falls in —
    /// each of the mesh's quad cells is split into 2 triangles (along the `v10`-`v01` diagonal,
    /// the standard top-right/bottom-left split), the same primitive real-time rendering actually
    /// rasterizes (a GPU has no native "quad" — every rasterized surface, including a deformed
    /// mesh's, is triangles under the hood). Unlike a quad's bilinear blend (which is a smooth
    /// but not-quite-flat function across the whole cell), barycentric interpolation across a
    /// triangle is exactly affine — a single flat plane fit through its 3 corner values — so each
    /// half of the cell blends as one flat plane instead of two overlapping curved ones. The two
    /// triangles still agree exactly along their shared diagonal (both formulas below evaluate
    /// identically there), so there's no seam introduced at that split.
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

        // Triangle (v00, v10, v01) covers fx + fy <= 1; triangle (v10, v11, v01) covers the rest.
        if fx + fy <= 1 {
            let w00 = 1 - fx - fy
            return v00 * w00 + v10 * fx + v01 * fy
        } else {
            let w11 = fx + fy - 1
            return v11 * w11 + v10 * (1 - fy) + v01 * (1 - fx)
        }
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

    /// Maximum grid dimension for `cheapLuminanceGrid` — same bounded-cost idea as
    /// `SharpnessScorer`'s own `maxDimension`, just enforced *before* touching most of the
    /// frame's bytes instead of after, see that function's doc comment for why the difference
    /// matters here specifically.
    private static let maxLuminanceDimension = 512

    /// A cheap, stride-sampled approximate brightness grid built directly from raw sensor
    /// bytes — deliberately *not* `SharpnessScorer.luminanceGrid`, which debayers the entire
    /// native-resolution frame (a real interpolating demosaic over every pixel) *before* its own
    /// downsample. That's the right tradeoff for `SharpnessScorer`'s own use (a perceptually
    /// accurate sharpness metric needs real debayered luminance), but it means calling it once
    /// per live-stack frame — continuously, for as long as mesh drift correction is on — runs a
    /// full-resolution CPU debayer every single frame, unconditionally, regardless of the
    /// downstream downsample. That's exactly what was making the UI stutter while this feature is
    /// on despite the accumulate step itself being pure GPU work: the *measurement* stage was
    /// still doing full-native-resolution CPU work first.
    ///
    /// Mesh-drift measurement doesn't need perceptually accurate demosaiced luminance in the
    /// first place — it only needs an approximate brightness map to locate bright stars, and a
    /// real star saturates every Bayer channel similarly, so a raw single-channel sample is a
    /// perfectly good brightness proxy for that purpose. Sampling at a stride *before* touching
    /// most of the frame's bytes (rather than after debayering all of them) is the same lesson
    /// `GPUSharpnessScorer`'s own hang fix already applied to its Metal kernel, just needed again
    /// here on the CPU side.
    static func cheapLuminanceGrid(for frame: CapturedFrame) -> (values: [Double], width: Int, height: Int)? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let stride = max(1, max(frame.width, frame.height) / maxLuminanceDimension)
        let newWidth = (frame.width + stride - 1) / stride
        let newHeight = (frame.height + stride - 1) / stride
        guard newWidth > 0, newHeight > 0 else { return nil }

        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            guard frame.data.count >= frame.width * frame.height else { return nil }
            return frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (values: [Double], width: Int, height: Int)? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var output = [Double](repeating: 0, count: newWidth * newHeight)
                for y in Swift.stride(from: 0, to: frame.height, by: stride) {
                    for x in Swift.stride(from: 0, to: frame.width, by: stride) {
                        output[(y / stride) * newWidth + (x / stride)] = Double(base[y * frame.width + x])
                    }
                }
                return (output, newWidth, newHeight)
            }
        case ASI_IMG_RAW16:
            guard frame.data.count >= frame.width * frame.height * 2 else { return nil }
            return frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (values: [Double], width: Int, height: Int)? in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return nil }
                var output = [Double](repeating: 0, count: newWidth * newHeight)
                for y in Swift.stride(from: 0, to: frame.height, by: stride) {
                    for x in Swift.stride(from: 0, to: frame.width, by: stride) {
                        output[(y / stride) * newWidth + (x / stride)] = Double(base[y * frame.width + x])
                    }
                }
                return (output, newWidth, newHeight)
            }
        default:
            return nil
        }
    }
}
