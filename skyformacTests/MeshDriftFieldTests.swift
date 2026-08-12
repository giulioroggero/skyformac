import Foundation
import Testing
@testable import skyformac

struct MeshDriftFieldTests {
    @Test func vertexPositionsAreCellCentersRowMajor() {
        let positions = MeshDriftField.vertexPositions(gridSize: 2, width: 100, height: 200)
        #expect(positions.count == 4)
        #expect(positions[0] == SIMD2<Float>(25, 50))   // row 0, col 0
        #expect(positions[1] == SIMD2<Float>(75, 50))   // row 0, col 1
        #expect(positions[2] == SIMD2<Float>(25, 150))  // row 1, col 0
        #expect(positions[3] == SIMD2<Float>(75, 150))  // row 1, col 1
    }

    @Test func roiHalfSizeGrowsWithOverlap() {
        let noOverlap = MeshDriftField.roiHalfSize(gridSize: 4, width: 400, height: 400, overlap: 0)
        let withOverlap = MeshDriftField.roiHalfSize(gridSize: 4, width: 400, height: 400, overlap: 1)
        #expect(noOverlap.x == 50) // cellWidth 100, half = 50
        #expect(withOverlap.x == 100) // factor 2x
    }

    @Test func interpolatedDisplacementMatchesVertexExactlyAtItsCenter() {
        let gridSize = 2
        let width = 100, height = 100
        let displacements: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(2, 0),
            SIMD2(0, 1), SIMD2(0, 2),
        ]
        let vertices = MeshDriftField.vertexPositions(gridSize: gridSize, width: width, height: height)
        for (index, vertex) in vertices.enumerated() {
            let result = MeshDriftField.interpolatedDisplacement(
                at: vertex, gridSize: gridSize, width: width, height: height, vertexDisplacements: displacements
            )
            #expect(abs(result.x - displacements[index].x) < 0.001)
            #expect(abs(result.y - displacements[index].y) < 0.001)
        }
    }

    /// A quad cell is split into 2 triangles along the `v10`-`v01` diagonal — this and the
    /// following two tests exercise each triangle plus the shared boundary, replacing what used
    /// to be a bilinear "average of all four corners" expectation. A triangulated mesh has no
    /// such point: every location is influenced by exactly the 3 vertices of whichever triangle
    /// contains it, never all 4 — even at the cell's exact center.
    @Test func interpolatedDisplacementWithinFirstTriangle() {
        let gridSize = 2
        let width = 100, height = 100
        // v00, v10, v01, v11 in that row-major order.
        let displacements: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(0, 4), SIMD2(4, 4)]
        // fx = fy = 0.25 (well inside the fx + fy <= 1 triangle): pixel = cell origin (25, 25) +
        // 0.25 * cellSize (50, 50) = (37.5, 37.5).
        let pixel = SIMD2<Float>(37.5, 37.5)
        let result = MeshDriftField.interpolatedDisplacement(
            at: pixel, gridSize: gridSize, width: width, height: height, vertexDisplacements: displacements
        )
        // w00 = 0.5, w10 = 0.25, w01 = 0.25 -> 0.25*(4,0) + 0.25*(0,4) = (1, 1).
        #expect(abs(result.x - 1.0) < 0.01)
        #expect(abs(result.y - 1.0) < 0.01)
    }

    @Test func interpolatedDisplacementWithinSecondTriangle() {
        let gridSize = 2
        let width = 100, height = 100
        let displacements: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(0, 4), SIMD2(4, 4)]
        // fx = fy = 0.75 (well inside the fx + fy > 1 triangle): pixel = (25, 25) + 0.75*(50, 50)
        // = (62.5, 62.5).
        let pixel = SIMD2<Float>(62.5, 62.5)
        let result = MeshDriftField.interpolatedDisplacement(
            at: pixel, gridSize: gridSize, width: width, height: height, vertexDisplacements: displacements
        )
        // w11 = 0.5, w10 = 0.25, w01 = 0.25 -> 0.5*(4,4) + 0.25*(4,0) + 0.25*(0,4) = (3, 3).
        #expect(abs(result.x - 3.0) < 0.01)
        #expect(abs(result.y - 3.0) < 0.01)
    }

    @Test func interpolatedDisplacementIsContinuousAcrossTheTriangleDiagonal() {
        let gridSize = 2
        let width = 100, height = 100
        let displacements: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(0, 4), SIMD2(4, 4)]
        // Exactly on the fx + fy == 1 boundary: both triangles' formulas must agree here, so
        // there's no visible seam at the split — the diagonal's midpoint is (50, 50).
        let pixel = SIMD2<Float>(50, 50)
        let result = MeshDriftField.interpolatedDisplacement(
            at: pixel, gridSize: gridSize, width: width, height: height, vertexDisplacements: displacements
        )
        // w00 = 0, w10 = 0.5, w01 = 0.5 -> 0.5*(4,0) + 0.5*(0,4) = (2, 2).
        #expect(abs(result.x - 2.0) < 0.01)
        #expect(abs(result.y - 2.0) < 0.01)
    }

    @Test func interpolatedDisplacementReturnsZeroForMismatchedVertexCount() {
        let result = MeshDriftField.interpolatedDisplacement(
            at: SIMD2(10, 10), gridSize: 3, width: 100, height: 100, vertexDisplacements: [SIMD2(1, 1)]
        )
        #expect(result == .zero)
    }

    @Test func blendAtFullSensitivityJumpsToMeasured() {
        let result = MeshDriftField.blend(previous: SIMD2(0, 0), measured: SIMD2(10, -5), sensitivity: 1)
        #expect(result == SIMD2<Float>(10, -5))
    }

    @Test func blendAtZeroSensitivityNeverMoves() {
        let result = MeshDriftField.blend(previous: SIMD2(3, 3), measured: SIMD2(10, -5), sensitivity: 0)
        #expect(result == SIMD2<Float>(3, 3))
    }

    @Test func blendAtHalfSensitivityIsTheMidpoint() {
        let result = MeshDriftField.blend(previous: SIMD2(0, 0), measured: SIMD2(10, 10), sensitivity: 0.5)
        #expect(abs(result.x - 5) < 0.001)
        #expect(abs(result.y - 5) < 0.001)
    }

    @Test func measuredCentroidsLocateABrightSpotWithinEachCell() {
        // 4x4 luminance grid, 2x2 mesh: bright spot in each quadrant at a distinct offset from
        // its own cell center, to confirm each vertex measures its OWN cell rather than the
        // whole frame.
        let gridWidth = 4, gridHeight = 4
        var luminance = [Double](repeating: 10, count: gridWidth * gridHeight)
        luminance[0 * gridWidth + 0] = 200 // top-left cell, near its own top-left corner
        luminance[1 * gridWidth + 3] = 200 // top-right cell, near its own top-right corner
        luminance[2 * gridWidth + 0] = 200 // bottom-left cell
        luminance[3 * gridWidth + 3] = 200 // bottom-right cell

        let centroids = MeshDriftField.measuredCentroids(
            luminance: luminance, gridWidth: gridWidth, gridHeight: gridHeight,
            gridSize: 2, overlap: 0, originalWidth: 4, originalHeight: 4
        )
        #expect(centroids.count == 4)
        for centroid in centroids {
            #expect(centroid != nil)
        }
    }

    @Test func measuredCentroidsReturnsNilForAFlatCellWithNoSignal() {
        let gridWidth = 4, gridHeight = 4
        let luminance = [Double](repeating: 50, count: gridWidth * gridHeight) // perfectly flat — no centroid to find
        let centroids = MeshDriftField.measuredCentroids(
            luminance: luminance, gridWidth: gridWidth, gridHeight: gridHeight,
            gridSize: 2, overlap: 0, originalWidth: 4, originalHeight: 4
        )
        #expect(centroids.allSatisfy { $0 == nil })
    }

    @Test func measuredCentroidsHandlesMismatchedInputGracefully() {
        let centroids = MeshDriftField.measuredCentroids(
            luminance: [1, 2, 3], gridWidth: 4, gridHeight: 4,
            gridSize: 2, overlap: 0, originalWidth: 4, originalHeight: 4
        )
        #expect(centroids.count == 4)
        #expect(centroids.allSatisfy { $0 == nil })
    }

    @Test func cheapLuminanceGridSamplesRAW8DirectlyWithoutDebayering() throws {
        // 2x2, no downsampling needed (well under the 512px cap) — every raw byte should appear
        // verbatim, confirming this does NOT debayer (a debayer would blend neighboring Bayer
        // samples together, so a lone bright RAW8 value wouldn't survive unchanged like this).
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([10, 20, 30, 200]))
        let grid = try #require(MeshDriftField.cheapLuminanceGrid(for: frame))
        #expect(grid.width == 2)
        #expect(grid.height == 2)
        #expect(grid.values == [10, 20, 30, 200])
    }

    @Test func cheapLuminanceGridSamplesRAW16Directly() throws {
        var data = Data(count: 8)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 100; p[1] = 200; p[2] = 300; p[3] = 40000
        }
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW16, data: data)
        let grid = try #require(MeshDriftField.cheapLuminanceGrid(for: frame))
        #expect(grid.values == [100, 200, 300, 40000])
    }

    @Test func cheapLuminanceGridReturnsNilForRGB24() {
        // Mesh drift correction only ever runs on the mono GPU accumulator (RGB24/webcam sources
        // never reach it) — this just documents that this function agrees, rather than silently
        // misreading packed RGB triplets as if they were single-channel samples.
        let frame = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RGB24, data: Data([10, 20, 30]))
        #expect(MeshDriftField.cheapLuminanceGrid(for: frame) == nil)
    }

    @Test func cheapLuminanceGridDownsamplesALargeFrameByStride() throws {
        let width = 1200, height = 800
        let frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(repeating: 5, count: width * height))
        let grid = try #require(MeshDriftField.cheapLuminanceGrid(for: frame))
        // stride = max(1200, 800) / 512 = 2 -> downsampled dimensions shrink accordingly.
        #expect(grid.width < width)
        #expect(grid.height < height)
    }
}
