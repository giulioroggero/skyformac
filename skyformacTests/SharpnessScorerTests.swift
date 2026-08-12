import Foundation
import Testing
@testable import skyformac

struct SharpnessScorerTests {
    /// A checkerboard has maximal high-frequency content at every pixel — clearly "sharper"
    /// than a flat field under any reasonable Laplacian-based metric.
    private func checkerboard(width: Int, height: Int) -> CapturedFrame {
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    base[y * width + x] = (x + y) % 2 == 0 ? 255 : 0
                }
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: data)
    }

    private func flatField(width: Int, height: Int, value: UInt8 = 128) -> CapturedFrame {
        CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(repeating: value, count: width * height))
    }

    @Test func sharperImageScoresHigherThanFlatField() {
        let sharp = SharpnessScorer.score(for: checkerboard(width: 32, height: 32), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        let flat = SharpnessScorer.score(for: flatField(width: 32, height: 32), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        #expect(sharp > flat)
        #expect(flat == 0)
    }

    @Test func toleratesTinyFrames() {
        // 2x2 has no interior pixels for the Laplacian pass — must not crash, just score 0.
        let score = SharpnessScorer.score(for: flatField(width: 2, height: 2), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        #expect(score == 0)
    }

    private func checkerboardRGB24(width: Int, height: Int) -> CapturedFrame {
        var data = Data(count: width * height * 3)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let value: UInt8 = (x + y) % 2 == 0 ? 255 : 0
                    let o = (y * width + x) * 3
                    base[o] = value
                    base[o + 1] = value
                    base[o + 2] = value
                }
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RGB24, data: data)
    }

    private func flatFieldRGB24(width: Int, height: Int, value: UInt8 = 128) -> CapturedFrame {
        CapturedFrame(width: width, height: height, imageType: ASI_IMG_RGB24, data: Data(repeating: value, count: width * height * 3))
    }

    // Webcam/iPhone (RGB24) frames were missing a case entirely — every frame scored 0
    // regardless of actual sharpness, making Lucky Imaging's ranking meaningless for that source.
    @Test func rgb24SharperImageScoresHigherThanFlatField() {
        let sharp = SharpnessScorer.score(for: checkerboardRGB24(width: 32, height: 32), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        let flat = SharpnessScorer.score(for: flatFieldRGB24(width: 32, height: 32), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        #expect(sharp > flat)
        #expect(flat == 0)
    }
}

struct LuckyImagingSessionTests {
    private func frame(value: UInt8) -> CapturedFrame {
        // A checkerboard whose contrast we vary via `value` so different frames score
        // differently but predictably: higher `value` -> bigger swing -> higher sharpness score.
        var data = Data(count: 16)
        for i in 0..<16 { data[i] = (i % 2 == 0) ? value : 0 }
        return CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW8, data: data)
    }

    @Test func isCompleteAfterTargetFrameCount() {
        let session = LuckyImagingSession(targetFrameCount: 2)
        #expect(!session.isComplete)
        session.add(frame(value: 100), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        #expect(!session.isComplete)
        session.add(frame(value: 200), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        #expect(session.isComplete)
        #expect(session.capturedCount == 2)
    }

    @Test func addIsNoOpOnceComplete() {
        let session = LuckyImagingSession(targetFrameCount: 1)
        session.add(frame(value: 100), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        session.add(frame(value: 200), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        #expect(session.capturedCount == 1)
    }

    @Test func stackBestKeepsHighestScoringSubset() throws {
        let session = LuckyImagingSession(targetFrameCount: 4)
        // Sharper (higher contrast) frames should be preferentially kept at a low fraction.
        session.add(frame(value: 10), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        session.add(frame(value: 250), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        session.add(frame(value: 20), isColorCamera: false, bayerPattern: ASI_BAYER_RG)
        session.add(frame(value: 240), isColorCamera: false, bayerPattern: ASI_BAYER_RG)

        let result = try #require(session.stackBest(fraction: 0.5))
        // Averaging the two highest-value frames (250, 240) at even indices -> ~245, odd -> 0.
        #expect(Int(result.data[0]) > 200)
    }

    @Test func stackBestOnEmptySessionReturnsNil() {
        let session = LuckyImagingSession(targetFrameCount: 4)
        #expect(session.stackBest(fraction: 0.5) == nil)
    }
}
