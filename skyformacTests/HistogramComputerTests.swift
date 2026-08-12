import Foundation
import Testing
@testable import skyformac

struct HistogramComputerTests {
    @Test func channelHistogramsReturnsNilForMonoCamera() {
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([10, 20, 30, 40]))
        #expect(HistogramComputer.channelHistograms(for: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG) == nil)
    }

    @Test func channelHistogramsReturnsNilForUnsupportedImageType() {
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_Y8, data: Data([10, 20, 30, 40]))
        #expect(HistogramComputer.channelHistograms(for: frame, isColorCamera: true, bayerPattern: ASI_BAYER_RG) == nil)
    }

    @Test func channelHistogramsBinsRGB24TripletsDirectly() throws {
        // Two pixels: (10, 20, 30) and (40, 50, 60).
        let frame = CapturedFrame(
            width: 2, height: 1, imageType: ASI_IMG_RGB24,
            data: Data([10, 20, 30, 40, 50, 60])
        )
        let channels = try #require(HistogramComputer.channelHistograms(for: frame, isColorCamera: true, bayerPattern: ASI_BAYER_RG))
        #expect(channels.red[10] == 1)
        #expect(channels.red[40] == 1)
        #expect(channels.green[20] == 1)
        #expect(channels.green[50] == 1)
        #expect(channels.blue[30] == 1)
        #expect(channels.blue[60] == 1)
        #expect(channels.red.reduce(0, +) == 2)
    }

    @Test func channelHistogramsClassifiesRAW8ByBayerPosition() throws {
        // RGGB, 2x2: (0,0)=R (1,0)=G (0,1)=G (1,1)=B — matching `Debayer.channel`'s own mapping.
        let frame = CapturedFrame(
            width: 2, height: 2, imageType: ASI_IMG_RAW8,
            data: Data([100, 150, 150, 200])
        )
        let channels = try #require(HistogramComputer.channelHistograms(for: frame, isColorCamera: true, bayerPattern: ASI_BAYER_RG))
        #expect(channels.red[100] == 1)
        #expect(channels.green[150] == 2)
        #expect(channels.blue[200] == 1)
        #expect(channels.red.reduce(0, +) == 1)
        #expect(channels.green.reduce(0, +) == 2)
        #expect(channels.blue.reduce(0, +) == 1)
    }

    @Test func channelHistogramsClassifiesRAW16ByBayerPositionAndScalesDown() throws {
        var data = Data(count: 8)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 100 << 8 // R
            p[1] = 150 << 8 // G
            p[2] = 150 << 8 // G
            p[3] = 200 << 8 // B
        }
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW16, data: data)
        let channels = try #require(HistogramComputer.channelHistograms(for: frame, isColorCamera: true, bayerPattern: ASI_BAYER_RG))
        #expect(channels.red[100] == 1)
        #expect(channels.green[150] == 2)
        #expect(channels.blue[200] == 1)
    }
}
