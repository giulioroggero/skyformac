import Foundation
import Testing
@testable import skyformac

struct SERWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ser")
    }

    private func int32LE(_ data: Data, at offset: Int) -> Int32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    }

    @Test func headerReportsDimensionsAndColorIDForMonoRAW8() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = CapturedFrame(width: 4, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 0, count: 8))
        let writer = try SERWriter(
            firstFrame: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(fileData.count >= 178)
        let fileID = String(data: fileData.prefix(14), encoding: .ascii)
        #expect(fileID == "LUCAM-RECORDER")
        #expect(int32LE(fileData, at: 18) == 0) // ColorID: mono, since isColorCamera == false
        #expect(int32LE(fileData, at: 22) == 1) // LittleEndian
        #expect(int32LE(fileData, at: 26) == 4) // Width
        #expect(int32LE(fileData, at: 30) == 2) // Height
        #expect(int32LE(fileData, at: 34) == 8) // PixelDepthPerPlane (RAW8 = 8 bits)
        #expect(int32LE(fileData, at: 38) == 0) // FrameCount before any frame is written
    }

    @Test func headerReportsBayerColorIDForColorCamera() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 0, count: 4))
        let writer = try SERWriter(
            firstFrame: frame, isColorCamera: true, bayerPattern: ASI_BAYER_GB, instrumentName: "Test Camera", url: url
        )
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(int32LE(fileData, at: 18) == 10) // ColorID: BAYER_GBRG
    }

    @Test func frameCountIsPatchedAfterClose() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([1, 2, 3, 4]))
        let writer = try SERWriter(
            firstFrame: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        try writer.write(frame)
        try writer.write(frame)
        try writer.write(frame)
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(int32LE(fileData, at: 38) == 3)
    }

    @Test func frameDataRoundTripsAfterHeader() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelBytes: [UInt8] = [10, 20, 30, 40]
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(pixelBytes))
        let writer = try SERWriter(
            firstFrame: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        try writer.write(frame)
        try writer.close()

        let fileData = try Data(contentsOf: url)
        let frameData = Array(fileData[178..<(178 + pixelBytes.count)])
        #expect(frameData == pixelBytes)
    }

    @Test func fileSizeMatchesHeaderPlusFramesPlusTimestampTrailer() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelBytes: [UInt8] = [1, 2, 3, 4]
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(pixelBytes))
        let writer = try SERWriter(
            firstFrame: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        try writer.write(frame)
        try writer.write(frame)
        try writer.close()

        let fileData = try Data(contentsOf: url)
        // 178-byte header + 2 frames of 4 bytes each + 2 timestamps of 8 bytes each.
        #expect(fileData.count == 178 + 2 * 4 + 2 * 8)
    }

    @Test func rgb24UsesThreePlanesAndRGBColorID() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // 2x1 RGB24 frame: 2 pixels * 3 bytes/pixel = 6 bytes.
        let pixelBytes: [UInt8] = [255, 0, 0, 0, 255, 0]
        let frame = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RGB24, data: Data(pixelBytes))
        let writer = try SERWriter(
            firstFrame: frame, isColorCamera: true, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        try writer.write(frame)
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(int32LE(fileData, at: 18) == 100) // ColorID: RGB
        #expect(int32LE(fileData, at: 34) == 8) // 8 bits per plane
        let frameData = Array(fileData[178..<(178 + pixelBytes.count)])
        #expect(frameData == pixelBytes)
    }

    @Test func mismatchedFrameDimensionsThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstFrame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 0, count: 4))
        let writer = try SERWriter(
            firstFrame: firstFrame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        let mismatched = CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW8, data: Data(repeating: 0, count: 16))
        #expect(throws: SERWriter.SERError.self) {
            try writer.write(mismatched)
        }
        try writer.close()
    }

    @Test func blankFrameIsRejectedAndNotWritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstFrame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([1, 2, 3, 4]))
        let writer = try SERWriter(
            firstFrame: firstFrame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        // Every byte identical — no real signal at all, the exact shape of frame that made
        // Siril's stacking normalization fail outright ("MAD is null") on a real recorded file.
        let blank = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 42, count: 4))
        #expect(throws: SERWriter.SERError.blankFrame) {
            try writer.write(blank)
        }
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(int32LE(fileData, at: 38) == 0) // FrameCount — the blank frame was never counted.
        #expect(fileData.count == 178) // header only; no frame bytes, no timestamp trailer entry.
    }

    @Test func frameWithRealVarianceIsWrittenEvenIfDim() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstFrame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 0, count: 4))
        let writer = try SERWriter(
            firstFrame: firstFrame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        // Dim (mostly zero) but not perfectly flat — a single differing pixel is real signal,
        // not a blank frame, and must still be written.
        let dim = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([0, 0, 0, 1]))
        try writer.write(dim)
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(int32LE(fileData, at: 38) == 1)
    }

    @Test func blankFrameDuringARecordingDoesNotStopSubsequentWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let firstFrame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([1, 2, 3, 4]))
        let writer = try SERWriter(
            firstFrame: firstFrame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
        )
        let blank = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 0, count: 4))
        try writer.write(firstFrame)
        #expect(throws: SERWriter.SERError.blankFrame) { try writer.write(blank) }
        try writer.write(firstFrame)
        try writer.close()

        let fileData = try Data(contentsOf: url)
        #expect(int32LE(fileData, at: 38) == 2) // Only the 2 real frames counted, blank skipped.
    }

    @Test func unsupportedImageTypeThrows() {
        let url = tempURL()
        // `ASI_IMG_END` (-1) is the SDK's own "no such format" sentinel (used to mark the end of
        // a camera's `SupportedVideoFormat` array) — a genuinely unsupported `ASI_IMG_TYPE`.
        let frame = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_END, data: Data([1, 2]))
        #expect(throws: SERWriter.SERError.self) {
            _ = try SERWriter(
                firstFrame: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, instrumentName: "Test Camera", url: url
            )
        }
        try? FileManager.default.removeItem(at: url)
    }
}
