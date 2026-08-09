import Testing
@testable import skyformac

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

    @Test func autoStretchIsNilOnEmptyHistogram() {
        #expect(DisplayStretch.autoStretch(histogram: Array(repeating: 0, count: 256)) == nil)
    }

    @Test func autoStretchFindsPercentilesOfANarrowDistribution() throws {
        // All pixel weight sits in buckets 100...150 — a real ASI sensor's actual signal
        // typically occupies a narrow slice of the full digital range like this, which is exactly
        // why `.identity` (0...1 of the *full* range) renders that signal as solid black.
        var histogram = Array(repeating: 0, count: 256)
        for bucket in 100...150 { histogram[bucket] = 1000 }

        let stretch = try #require(DisplayStretch.autoStretch(histogram: histogram))

        #expect(stretch.blackPoint > 0.3 && stretch.blackPoint < 0.45)
        #expect(stretch.whitePoint > 0.45 && stretch.whitePoint < 0.65)
        #expect(stretch.whitePoint >= stretch.blackPoint + 0.05)
    }

    @Test func autoStretchOnFullRangeHistogramStaysWide() throws {
        // Uniform histogram across the whole range: 1st/99th percentile should sit near the
        // extremes, unlike the narrow-distribution case above.
        let histogram = Array(repeating: 100, count: 256)
        let stretch = try #require(DisplayStretch.autoStretch(histogram: histogram))
        #expect(stretch.blackPoint < 0.1)
        #expect(stretch.whitePoint > 0.9)
    }
}
