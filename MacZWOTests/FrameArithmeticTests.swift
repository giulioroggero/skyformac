import Foundation
import Testing
@testable import MacZWO

struct FrameArithmeticTests {
    @Test func subtract8ClampsAtZero() throws {
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([100, 10]))
        let dark = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([40, 50]))
        let result = try #require(FrameArithmetic.subtract(light: light, dark: dark))
        #expect(Array(result.data) == [60, 0]) // 100-40=60, 10-50 clamps to 0
    }

    @Test func subtract16ClampsAtZero() throws {
        var lightBytes = Data(count: 4)
        lightBytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 5000; p[1] = 100
        }
        var darkBytes = Data(count: 4)
        darkBytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 2000; p[1] = 200
        }
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: lightBytes)
        let dark = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: darkBytes)
        let result = try #require(FrameArithmetic.subtract(light: light, dark: dark))
        result.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            #expect(p[0] == 3000)
            #expect(p[1] == 0)
        }
    }

    @Test func subtractRejectsMismatchedDimensions() {
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([1, 2]))
        let dark = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([1]))
        #expect(FrameArithmetic.subtract(light: light, dark: dark) == nil)
    }

    @Test func subtractRejectsMismatchedImageType() {
        let light = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([1]))
        let dark = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW16, data: Data([1, 0]))
        #expect(FrameArithmetic.subtract(light: light, dark: dark) == nil)
    }

    @Test func average8ComputesEqualWeightedMean() throws {
        let frames = [
            CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([10, 100])),
            CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([20, 200])),
            CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([30, 254])),
        ]
        let result = try #require(FrameArithmetic.average(frames: frames))
        // (10+20+30)/3=20 exactly; (100+200+254)/3=184.66 -> integer division truncates to 184
        #expect(Array(result.data) == [20, 184])
    }

    @Test func averageOfEmptyArrayReturnsNil() {
        #expect(FrameArithmetic.average(frames: []) == nil)
    }
}
