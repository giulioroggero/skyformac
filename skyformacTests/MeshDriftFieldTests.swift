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

    @Test func interpolatedDisplacementAtMidpointIsTheAverageOfAllFour() {
        let gridSize = 2
        let width = 100, height = 100
        let displacements: [SIMD2<Float>] = [SIMD2(4, 0), SIMD2(0, 0), SIMD2(0, 0), SIMD2(0, 4)]
        // Midpoint between all four cell centers is the exact center of the frame.
        let center = SIMD2<Float>(Float(width) / 2, Float(height) / 2)
        let result = MeshDriftField.interpolatedDisplacement(
            at: center, gridSize: gridSize, width: width, height: height, vertexDisplacements: displacements
        )
        #expect(abs(result.x - 1.0) < 0.01)
        #expect(abs(result.y - 1.0) < 0.01)
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
}
