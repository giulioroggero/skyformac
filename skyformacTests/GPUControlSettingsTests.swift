import Testing
@testable import skyformac

struct GPUControlSettingsTests {
    @Test func whitePointNeverDropsWithin005OfBlackPoint() {
        let gpu = GPUControlSettings()
        gpu.blackPoint = 0.2
        gpu.whitePoint = 0.21 // within 0.05 of blackPoint
        #expect(gpu.whitePoint >= gpu.blackPoint + 0.05)
    }

    @Test func raisingBlackPointPushesWhitePointUpIfNeeded() {
        let gpu = GPUControlSettings()
        gpu.whitePoint = 0.20 // set first, since blackPoint's own didSet checks against it
        gpu.blackPoint = 0.30 // now within 0.05 of whitePoint — whitePoint must move up
        #expect(gpu.whitePoint >= gpu.blackPoint + 0.05)
        #expect(abs(gpu.whitePoint - 0.35) < 0.001)
    }

    @Test func loweringWhitePointPullsBlackPointDownIfNeeded() {
        let gpu = GPUControlSettings()
        gpu.blackPoint = 0.3
        gpu.whitePoint = 0.32 // forces blackPoint down to stay >= 0.05 below
        #expect(gpu.blackPoint <= gpu.whitePoint - 0.05)
    }

    @Test func whitePointNeverDropsBelow010() {
        let gpu = GPUControlSettings()
        gpu.blackPoint = 0.0
        gpu.whitePoint = 0.02
        #expect(gpu.whitePoint >= 0.10)
    }

    @Test func blackPointClampedToDocumentedRange() {
        let gpu = GPUControlSettings()
        gpu.blackPoint = -1.0
        #expect(gpu.blackPoint == 0.0)
        gpu.blackPoint = 10.0
        #expect(gpu.blackPoint == 0.4)
    }

    @Test func numericSlidersClampToDocumentedRanges() {
        let gpu = GPUControlSettings()
        gpu.temporalAlpha = 5.0
        #expect(gpu.temporalAlpha == 1.0)
        gpu.temporalAlpha = -1.0
        #expect(gpu.temporalAlpha == 0.01)

        gpu.spatialSigma = 50.0
        #expect(gpu.spatialSigma == 10.0)
        gpu.spatialSigma = 0.0
        #expect(gpu.spatialSigma == 1.0)

        gpu.rangeSigma = 5.0
        #expect(gpu.rangeSigma == 0.50)
        gpu.rangeSigma = 0.0
        #expect(gpu.rangeSigma == 0.01)

        gpu.stretchIntensity = 500.0
        #expect(gpu.stretchIntensity == 200.0)
        gpu.stretchIntensity = 0.0
        #expect(gpu.stretchIntensity == 1.0)
    }

    @Test func autoStretchIsNoOpOnEmptyHistogram() {
        let gpu = GPUControlSettings()
        gpu.blackPoint = 0.15
        gpu.whitePoint = 0.75
        gpu.autoStretch(histogram: Array(repeating: 0, count: 256))
        #expect(gpu.blackPoint == 0.15)
        #expect(gpu.whitePoint == 0.75)
    }

    @Test func autoStretchFindsPercentilesOfANarrowDistribution() {
        let gpu = GPUControlSettings()
        // All pixel weight sits in buckets 100...150 (a narrow, low-contrast frame) — auto-stretch
        // should pull blackPoint/whitePoint in to roughly that range instead of the full 0...1.
        var histogram = Array(repeating: 0, count: 256)
        for bucket in 100...150 { histogram[bucket] = 1000 }

        gpu.autoStretch(histogram: histogram)

        #expect(gpu.blackPoint > 0.3 && gpu.blackPoint < 0.45)
        #expect(gpu.whitePoint > 0.45 && gpu.whitePoint < 0.65)
        #expect(gpu.whitePoint >= gpu.blackPoint + 0.05)
        #expect(gpu.stretchIntensity >= 1.0 && gpu.stretchIntensity <= 200.0)
    }

    @Test func autoStretchOnFullRangeHistogramStaysWide() {
        let gpu = GPUControlSettings()
        // Uniform histogram across the whole range: 1st/99th percentile should sit near the
        // extremes, unlike the narrow-distribution case above.
        let histogram = Array(repeating: 100, count: 256)

        gpu.autoStretch(histogram: histogram)

        #expect(gpu.blackPoint < 0.1)
        #expect(gpu.whitePoint > 0.9)
    }

    @Test func snapshotReflectsCurrentValues() {
        let gpu = GPUControlSettings()
        gpu.isEnabled = true
        gpu.temporalAlpha = 0.5
        let snapshot = gpu.snapshot
        #expect(snapshot.isEnabled == true)
        #expect(snapshot.temporalAlpha == 0.5)
        #expect(snapshot.spatialSigma == gpu.spatialSigma)
        #expect(snapshot.blackPoint == gpu.blackPoint)
        #expect(snapshot.whitePoint == gpu.whitePoint)
    }
}
