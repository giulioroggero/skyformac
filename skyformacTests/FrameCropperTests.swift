import Foundation
import Testing
@testable import skyformac

struct FrameCropperTests {
    @Test func cropsExpectedSubregionForRAW8() throws {
        // 4x4 frame, values 0...15 row-major.
        let bytes: [UInt8] = Array(0..<16)
        let frame = CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW8, data: Data(bytes))

        let cropped = try #require(FrameCropper.crop(frame, toPixelRect: (x: 1, y: 1, width: 2, height: 2)))
        #expect(cropped.width == 2)
        #expect(cropped.height == 2)
        // Row1: [4,5,6,7], Row2: [8,9,10,11] -> crop at (1,1) size 2x2 = [5,6,9,10]
        #expect(Array(cropped.data) == [5, 6, 9, 10])
    }

    @Test func clampsRectToFrameBounds() throws {
        let bytes: [UInt8] = Array(0..<16)
        let frame = CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW8, data: Data(bytes))

        // Requesting a crop that overruns the frame should clamp rather than crash or read OOB.
        let cropped = try #require(FrameCropper.crop(frame, toPixelRect: (x: 3, y: 3, width: 10, height: 10)))
        #expect(cropped.width == 1)
        #expect(cropped.height == 1)
        #expect(Array(cropped.data) == [15])
    }

    @Test func preservesRAW16BytesPerPixel() throws {
        let values: [UInt16] = Array(0..<16).map { UInt16($0) }
        var data = Data(count: 32)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            for (i, v) in values.enumerated() { p[i] = v }
        }
        let frame = CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW16, data: data)
        let cropped = try #require(FrameCropper.crop(frame, toPixelRect: (x: 0, y: 0, width: 2, height: 1)))
        cropped.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            #expect(p[0] == 0)
            #expect(p[1] == 1)
        }
    }
}
