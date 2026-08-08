import Testing
@testable import MacZWO

struct DisplayStretchTests {
    @Test func identityStretchIsLinear() {
        let lut = DisplayStretch.identity.lookupTable(maxValue: 255)
        #expect(lut.count == 256)
        #expect(lut[0] == 0)
        #expect(lut[255] == 255)
        #expect(abs(Int(lut[128]) - 128) <= 1) // floating-point rounding in the LUT math
    }

    @Test func blackPointClipsBelowThreshold() {
        let stretch = DisplayStretch(blackPoint: 0.5, whitePoint: 1.0)
        let lut = stretch.lookupTable(maxValue: 255)
        #expect(lut[0] == 0)
        #expect(lut[127] == 0) // below the black point (127.5) clips to 0
        #expect(lut[255] == 255)
    }

    @Test func whitePointClipsAboveThreshold() {
        let stretch = DisplayStretch(blackPoint: 0.0, whitePoint: 0.5)
        let lut = stretch.lookupTable(maxValue: 255)
        #expect(lut[255] == 255) // above the white point (127.5) clips to 255
        #expect(lut[0] == 0)
    }

    @Test func degenerateRangeDoesNotDivideByZero() {
        // blackPoint == whitePoint would divide by zero without the `white > black` guard;
        // it instead produces a very narrow (1 raw-unit) transition band rather than crashing.
        let stretch = DisplayStretch(blackPoint: 0.5, whitePoint: 0.5)
        let lut = stretch.lookupTable(maxValue: 255)
        #expect(lut.count == 256)
        #expect(lut[0] == 0)
        #expect(lut[255] == 255)
    }
}
