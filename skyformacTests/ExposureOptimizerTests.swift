import Foundation
import Testing
@testable import skyformac

struct ExposureOptimizerTests {
    @Test func readNoiseFromKnownStandardDeviation() throws {
        // Alternating 8/12 around a mean of 10 has variance 4, so stddev = 2.
        var bytes = [UInt8]()
        for i in 0..<100 { bytes.append(i % 2 == 0 ? 8 : 12) }
        let frame = CapturedFrame(width: 10, height: 10, imageType: ASI_IMG_RAW8, data: Data(bytes))

        let readNoise = try #require(ExposureOptimizer.readNoiseElectrons(biasFrame: frame, electronsPerADU: 2.5))
        #expect(abs(readNoise - 5.0) < 0.001) // 2.0 ADU stddev * 2.5 e-/ADU
    }

    @Test func skyBackgroundRateFromMedianIgnoringOutliers() throws {
        var bytes = [UInt8](repeating: 50, count: 100)
        bytes[0] = 255 // a "star" shouldn't move the median background estimate
        bytes[1] = 254
        let frame = CapturedFrame(width: 10, height: 10, imageType: ASI_IMG_RAW8, data: Data(bytes))

        let rate = try #require(ExposureOptimizer.skyBackgroundRate(testFrame: frame, exposureSeconds: 2.0, electronsPerADU: 2.5))
        #expect(abs(rate - 62.5) < 0.001) // median 50 ADU * 2.5 e-/ADU / 2s
    }

    @Test func optimalSubExposureMatchesClassicFormula() {
        let t = ExposureOptimizer.optimalSubExposureSeconds(
            readNoiseElectrons: 5.0, skyRateElectronsPerSecond: 62.5, targetRatio: 10.0
        )
        #expect(t != nil)
        #expect(abs(t! - 4.0) < 0.001) // 10 * 5^2 / 62.5 = 4.0
    }

    @Test func zeroSkyRateReturnsNil() {
        #expect(ExposureOptimizer.optimalSubExposureSeconds(readNoiseElectrons: 5.0, skyRateElectronsPerSecond: 0) == nil)
    }

    @Test func higherReadNoiseRecommendsLongerExposure() {
        let lowNoise = ExposureOptimizer.optimalSubExposureSeconds(readNoiseElectrons: 2.0, skyRateElectronsPerSecond: 50)!
        let highNoise = ExposureOptimizer.optimalSubExposureSeconds(readNoiseElectrons: 8.0, skyRateElectronsPerSecond: 50)!
        #expect(highNoise > lowNoise)
    }

    @Test func brighterSkyRecommendsShorterExposure() {
        let darkSky = ExposureOptimizer.optimalSubExposureSeconds(readNoiseElectrons: 5.0, skyRateElectronsPerSecond: 20)!
        let brightSky = ExposureOptimizer.optimalSubExposureSeconds(readNoiseElectrons: 5.0, skyRateElectronsPerSecond: 200)!
        #expect(brightSky < darkSky)
    }
}
