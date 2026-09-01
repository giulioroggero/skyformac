import AVFoundation
import CoreVideo
import Testing
@testable import skyformac

struct VideoFrameReaderTests {
    /// A tiny, real H.264 `.mov` with a handful of solid-color frames — genuinely encoding and
    /// decoding through `AVAssetWriter`/`AVAssetReader` (not a hand-rolled container) is what
    /// actually exercises `VideoFrameReader.read`'s real code path, the same "construct real
    /// bytes of the format under test" discipline `PlanetaryPostProcessorTests.writeTestSER`
    /// already uses for `.ser`.
    private func makeTestVideo(width: Int, height: Int, frameColors: [(UInt8, UInt8, UInt8)], to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for (index, color) in frameColors.enumerated() {
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for row in 0..<height {
                for col in 0..<width {
                    let offset = row * bytesPerRow + col * 4
                    base[offset] = color.2 // B
                    base[offset + 1] = color.1 // G
                    base[offset + 2] = color.0 // R
                    base[offset + 3] = 255 // A
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    @Test func readExtractsEveryFrameAsRGB24() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeTestVideo(width: 16, height: 16, frameColors: [(200, 50, 50), (50, 200, 50), (50, 50, 200)], to: url)

        let parsed = try VideoFrameReader.read(from: url)
        #expect(parsed.frames.count == 3)
        #expect(parsed.width == 16)
        #expect(parsed.height == 16)
        #expect(parsed.isColorCamera)
        #expect(parsed.imageType == ASI_IMG_RGB24)
        for frame in parsed.frames {
            #expect(frame.data.count == 16 * 16 * 3)
        }
    }

    /// The cheap preview-only shortcut `PlanetaryPostProcessingView.loadSourcePreview` uses for an
    /// imported video — should decode just the first frame (matching what `read`'s own first
    /// frame would be), not the whole file.
    @Test func readFirstFrameMatchesTheFirstFrameOfFullRead() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeTestVideo(width: 16, height: 16, frameColors: [(200, 50, 50), (50, 200, 50), (50, 50, 200)], to: url)

        let firstFrame = try VideoFrameReader.readFirstFrame(from: url)
        let fullRead = try VideoFrameReader.read(from: url)

        #expect(firstFrame.width == 16)
        #expect(firstFrame.height == 16)
        #expect(firstFrame.data == fullRead.frames[0].data)
    }

    @Test func readFirstFrameThrowsForAFileWithNoVideoTrack() {
        let bogusURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        #expect(throws: Error.self) {
            _ = try VideoFrameReader.readFirstFrame(from: bogusURL)
        }
    }

    @Test func readThrowsForAFileWithNoVideoTrack() {
        // An empty/nonexistent file has no video track at all — `AVURLAsset` on a bogus URL
        // reports zero tracks rather than throwing itself, so this is `VideoFrameReader`'s own
        // `noVideoTrack` guard doing its job, not `AVFoundation` failing first.
        let bogusURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        #expect(throws: Error.self) {
            _ = try VideoFrameReader.read(from: bogusURL)
        }
    }

    /// End-to-end through the same entry point "Post-Process…" actually calls — proves an
    /// imported `.mov` reaches `PlanetaryPostProcessor.loadSequence` correctly, not just
    /// `VideoFrameReader` in isolation.
    @Test func loadSequenceViaPlanetaryPostProcessorAcceptsAnImportedVideoFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await makeTestVideo(width: 16, height: 16, frameColors: [(200, 50, 50), (50, 200, 50)], to: url)

        let sequence = try PlanetaryPostProcessor.loadSequence(from: url)
        #expect(sequence.frames.count == 2)
        #expect(sequence.isColorCamera)
    }
}
