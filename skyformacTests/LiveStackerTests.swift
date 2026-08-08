import Foundation
import Testing
@testable import skyformac

struct LiveStackerTests {
    @Test func averagesMultipleRAW8Frames() throws {
        let stacker = LiveStacker()
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([10, 100])))
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([20, 200])))
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([30, 254])))

        #expect(stacker.frameCount == 3)
        let result = try #require(stacker.currentAverage())
        #expect(Array(result.data) == [20, 184])
    }

    @Test func emptyStackerReturnsNil() {
        let stacker = LiveStacker()
        #expect(stacker.currentAverage() == nil)
        #expect(stacker.frameCount == 0)
    }

    @Test func resetClearsAccumulatedFrames() {
        let stacker = LiveStacker()
        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([200])))
        #expect(stacker.frameCount == 1)
        stacker.reset()
        #expect(stacker.frameCount == 0)
        #expect(stacker.currentAverage() == nil)
    }

    @Test func changingFrameDimensionsImplicitlyResets() throws {
        let stacker = LiveStacker()
        stacker.add(CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([100, 100])))
        stacker.add(CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([50])))
        #expect(stacker.frameCount == 1) // the dimension change reset the accumulator
        let result = try #require(stacker.currentAverage())
        #expect(Array(result.data) == [50])
    }

    @Test func averagesRAW16Frames() throws {
        let stacker = LiveStacker()
        func frame16(_ values: [UInt16]) -> CapturedFrame {
            var data = Data(count: values.count * 2)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let p = raw.bindMemory(to: UInt16.self)
                for (i, v) in values.enumerated() { p[i] = v }
            }
            return CapturedFrame(width: values.count, height: 1, imageType: ASI_IMG_RAW16, data: data)
        }
        stacker.add(frame16([1000, 2000]))
        stacker.add(frame16([3000, 4000]))
        let result = try #require(stacker.currentAverage())
        result.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            #expect(p[0] == 2000)
            #expect(p[1] == 3000)
        }
    }
}
