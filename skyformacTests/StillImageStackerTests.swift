import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct StillImageStackerTests {
    /// Same synthetic-blob-image convention as `MosaicComposerTests.makeStarFieldImage` —
    /// duplicated locally since that one's `private` to its own test type.
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

    @Test func stackThrowsWithFewerThanTwoTiles() {
        let tile = makeStarFieldImage(width: 200, height: 200, positions: [(20, 20), (100, 40), (60, 150)])
        #expect(throws: MosaicComposer.ComposeError.self) {
            try StillImageStacker.stack(tiles: [tile])
        }
    }

    /// Two tiles of the exact same field (no shift at all — the common case this is actually
    /// for: two same-framing captures of the same target) — the stacked result should keep the
    /// reference's own dimensions, unlike `MosaicComposer.compose` which grows the canvas to fit
    /// offset tiles.
    @Test func stackOfIdenticalTilesKeepsTheReferencesOwnDimensions() throws {
        let positions: [(x: Int, y: Int)] = [(30, 30), (150, 40), (90, 160), (200, 100)]
        let tile = makeStarFieldImage(width: 340, height: 300, positions: positions, blobSize: 14)

        let stacked = try StillImageStacker.stack(tiles: [tile, tile])
        #expect(stacked.width == 340)
        #expect(stacked.height == 300)
    }

    /// A small real-world drift between two otherwise-matching captures (an untracked mount) —
    /// end-to-end through star detection → matching → transform fitting → alignment → averaging,
    /// same spirit as `MosaicComposerTests.composeProducesACanvasLargerThanEitherTileAlone` but
    /// exercising the fixed-canvas/averaging path instead of the grow-and-composite one.
    @Test func stackAlignsASmallShiftWithoutThrowing() throws {
        let positions: [(x: Int, y: Int)] = [(30, 30), (150, 40), (90, 160), (200, 100)]
        let tileA = makeStarFieldImage(width: 340, height: 300, positions: positions, blobSize: 14)
        let shiftedPositions = positions.map { (x: $0.x + 6, y: $0.y + 3) }
        let tileB = makeStarFieldImage(width: 340, height: 300, positions: shiftedPositions, blobSize: 14)

        let stacked = try StillImageStacker.stack(tiles: [tileA, tileB])
        #expect(stacked.width == 340)
        #expect(stacked.height == 300)
    }

    @Test func stackThrowsInsufficientOverlapWhenTilesShareNoStars() {
        let tileA = makeStarFieldImage(width: 200, height: 200, positions: [(20, 20), (100, 40), (60, 150)])
        let tileB = makeStarFieldImage(width: 200, height: 200, positions: [])

        #expect(throws: MosaicComposer.ComposeError.self) {
            try StillImageStacker.stack(tiles: [tileA, tileB])
        }
    }
}
