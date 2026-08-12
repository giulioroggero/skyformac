import Foundation
import Testing
@testable import skyformac

struct FITSReaderTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
    }

    @Test func roundTripsRAW8MonoFrame() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelBytes: [UInt8] = [10, 20, 30, 40]
        let original = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(pixelBytes))
        try FITSWriter.write(frame: original, instrumentName: "Test Camera", to: url)

        let parsed = try FITSReader.read(from: url)
        #expect(parsed.frame.width == 2)
        #expect(parsed.frame.height == 2)
        #expect(parsed.frame.imageType.rawValue == ASI_IMG_RAW8.rawValue)
        #expect(Array(parsed.frame.data) == pixelBytes)
        #expect(parsed.instrumentName == "Test Camera")
        #expect(parsed.isColorCamera == false)
    }

    @Test func roundTripsRAW16MonoFrame() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelValues: [UInt16] = [0, 32768, 40000, 65535]
        var data = Data(count: pixelValues.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            for (i, v) in pixelValues.enumerated() { p[i] = v }
        }
        let original = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW16, data: data)
        try FITSWriter.write(frame: original, instrumentName: "Test Camera", to: url)

        let parsed = try FITSReader.read(from: url)
        #expect(parsed.frame.imageType.rawValue == ASI_IMG_RAW16.rawValue)
        let recovered = parsed.frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            Array(raw.bindMemory(to: UInt16.self))
        }
        #expect(recovered == pixelValues)
    }

    @Test func roundTripsColorCameraBayerPattern() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = CapturedFrame(width: 4, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 128, count: 8))
        try FITSWriter.write(frame: original, instrumentName: "ASI678MC", isColorCamera: true, bayerPattern: ASI_BAYER_GB, to: url)

        let parsed = try FITSReader.read(from: url)
        #expect(parsed.isColorCamera == true)
        #expect(parsed.bayerPattern.rawValue == ASI_BAYER_GB.rawValue)
    }

    @Test func monoFrameHasNoBayerPatternRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let original = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(repeating: 50, count: 4))
        try FITSWriter.write(frame: original, instrumentName: "ASI178MM", isColorCamera: false, to: url)

        let parsed = try FITSReader.read(from: url)
        #expect(parsed.isColorCamera == false)
    }

    @Test func readingAFileThatIsNotFITSThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a fits file at all, just plain text padding it out past 80 bytes for good measure".utf8).write(to: url)

        #expect(throws: FITSReader.FITSError.self) {
            _ = try FITSReader.read(from: url)
        }
    }
}
