import Foundation
import Testing
@testable import MacZWO

struct FlatFieldCorrectorTests {
    @Test func correctsVignettingViaDivision() throws {
        // Flat: half the frame reads 200 (fully illuminated), half reads 100 (vignetted).
        // Mean flat = 150. A uniformly-lit light frame (100 everywhere) should come out
        // *brighter* where the flat was dim (more correction needed) and dimmer where the flat
        // was bright.
        let light = CapturedFrame(width: 4, height: 1, imageType: ASI_IMG_RAW8, data: Data([100, 100, 100, 100]))
        let flat = CapturedFrame(width: 4, height: 1, imageType: ASI_IMG_RAW8, data: Data([200, 200, 100, 100]))

        let corrected = try #require(FlatFieldCorrector.correct(light: light, flat: flat))
        // corrected = light * meanFlat(150) / flatPixel
        #expect(Array(corrected.data) == [75, 75, 150, 150])
    }

    @Test func mismatchedDimensionsReturnsNil() {
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([1, 2]))
        let flat = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([1]))
        #expect(FlatFieldCorrector.correct(light: light, flat: flat) == nil)
    }

    @Test func degenerateAllZeroFlatReturnsNil() {
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([10, 10]))
        let flat = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([0, 0]))
        #expect(FlatFieldCorrector.correct(light: light, flat: flat) == nil)
    }

    @Test func raw16Correction() throws {
        var lightData = Data(count: 4)
        lightData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 1000; p[1] = 1000
        }
        var flatData = Data(count: 4)
        flatData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 40000; p[1] = 20000
        }
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: lightData)
        let flat = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: flatData)
        let corrected = try #require(FlatFieldCorrector.correct(light: light, flat: flat))
        // meanFlat = 30000; corrected[0] = 1000*30000/40000 = 750; corrected[1] = 1000*30000/20000 = 1500
        corrected.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            #expect(p[0] == 750)
            #expect(p[1] == 1500)
        }
    }
}
