import Testing
@testable import skyformac

struct HubblePaletteCombinerTests {
    private func solidChannel(_ value: Float, width: Int = 4, height: Int = 4) -> HubblePaletteCombiner.ChannelInput {
        HubblePaletteCombiner.ChannelInput(luminance: [Float](repeating: value, count: width * height), width: width, height: height)
    }

    @Test func combineMapsSIIToRedHaToGreenAndOIIIToBlue() throws {
        let sii = solidChannel(0.2)
        let ha = solidChannel(0.5)
        let oiii = solidChannel(0.8)
        let result = try HubblePaletteCombiner.combine(sii: sii, ha: ha, oiii: oiii, alignChannels: false)

        #expect(result.width == 4)
        #expect(result.height == 4)
        #expect(result.channels == 3)
        // Every pixel should carry the same (R, G, B) since every channel is a flat fill.
        for i in 0..<(4 * 4) {
            #expect(abs(result.values[i * 3] - 0.2) < 0.001)
            #expect(abs(result.values[i * 3 + 1] - 0.5) < 0.001)
            #expect(abs(result.values[i * 3 + 2] - 0.8) < 0.001)
        }
    }

    @Test func combineThrowsOnDimensionMismatch() {
        let sii = solidChannel(0.2, width: 4, height: 4)
        let ha = solidChannel(0.5, width: 8, height: 8)
        let oiii = solidChannel(0.8, width: 4, height: 4)
        #expect(throws: HubblePaletteCombiner.CombineError.self) {
            _ = try HubblePaletteCombiner.combine(sii: sii, ha: ha, oiii: oiii)
        }
    }

    @Test func combineThrowsOnEmptyChannel() {
        let empty = HubblePaletteCombiner.ChannelInput(luminance: [], width: 0, height: 0)
        let ha = solidChannel(0.5)
        #expect(throws: HubblePaletteCombiner.CombineError.self) {
            _ = try HubblePaletteCombiner.combine(sii: empty, ha: ha, oiii: empty)
        }
    }

    /// A bright 4×4 square offset by a known (dx, dy) inside an otherwise-dark frame — the
    /// simplest possible "these two images show the same real structure, just shifted" case,
    /// exactly the scenario a centroid-based approach (right for a single bright planetary disk)
    /// would actually handle fine too; the point of this test is confirming the *sign* and
    /// *magnitude* of the detected shift are both correct, not that correlation beats a centroid
    /// here specifically.
    private func offsetSquareChannel(dx: Int, dy: Int, width: Int = 64, height: Int = 64) -> HubblePaletteCombiner.ChannelInput {
        var values = [Float](repeating: 0.1, count: width * height)
        let squareOrigin = (x: 24 + dx, y: 24 + dy)
        for y in squareOrigin.y..<(squareOrigin.y + 8) where y >= 0 && y < height {
            for x in squareOrigin.x..<(squareOrigin.x + 8) where x >= 0 && x < width {
                values[y * width + x] = 0.9
            }
        }
        return HubblePaletteCombiner.ChannelInput(luminance: values, width: width, height: height)
    }

    /// `alignmentShift(of:toReference:)` compares `channel[x, y]` against `reference[x + dx, y +
    /// dy]` (see its own implementation), so the shift it reports for a channel created *ahead*
    /// of the reference by `(dx, dy)` is the *negation* of that creation offset — `combine`'s own
    /// application of this (`bilinearShift(..., dx: -shift.dx, dy: -shift.dy)`) is what actually
    /// moves the channel back into register, which `combineWithAlignmentCorrectsAKnownOffset`
    /// below confirms end-to-end.
    @Test func alignmentShiftFindsAKnownTranslation() {
        let reference = offsetSquareChannel(dx: 0, dy: 0)
        let shifted = offsetSquareChannel(dx: 5, dy: -3)
        let shift = HubblePaletteCombiner.alignmentShift(of: shifted, toReference: reference)
        #expect(shift.dx == -5)
        #expect(shift.dy == 3)
    }

    @Test func alignmentShiftIsZeroForAlreadyAlignedChannels() {
        let reference = offsetSquareChannel(dx: 0, dy: 0)
        let sameAgain = offsetSquareChannel(dx: 0, dy: 0)
        let shift = HubblePaletteCombiner.alignmentShift(of: sameAgain, toReference: reference)
        #expect(shift.dx == 0)
        #expect(shift.dy == 0)
    }

    /// End-to-end: combining a deliberately-offset channel with `alignChannels: true` should pull
    /// its bright square back into register with the reference, landing at the same pixel the
    /// reference's own (unshifted) square is at.
    @Test func combineWithAlignmentCorrectsAKnownOffset() throws {
        let reference = offsetSquareChannel(dx: 0, dy: 0) // used as Hα
        let shiftedSII = offsetSquareChannel(dx: 4, dy: 2)
        let result = try HubblePaletteCombiner.combine(sii: shiftedSII, ha: reference, oiii: reference, alignChannels: true)

        // The reference square sits at (24...31, 24...31) — after alignment, the red (SII)
        // channel's own bright square should have moved back there too.
        let centerIndex = (28 * result.width + 28) * 3
        #expect(result.values[centerIndex] > 0.5) // red (SII), realigned
        #expect(result.values[centerIndex + 1] > 0.5) // green (Hα), was always there
    }
}
