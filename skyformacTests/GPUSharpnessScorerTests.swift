import Foundation
import Testing
@testable import skyformac

struct GPUSharpnessScorerTests {
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

    private func flatField(width: Int, height: Int) -> CapturedFrame {
        CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(repeating: 128, count: width * height))
    }

    @Test func gpuScoresSharperImageHigherThanFlatField() throws {
        guard let scorer = GPUSharpnessScorer() else {
            // No Metal device available in this environment — nothing to test.
            return
        }
        let sharpScore = try #require(scorer.score(frame: checkerboard(width: 32, height: 32)))
        let flatScore = try #require(scorer.score(frame: flatField(width: 32, height: 32)))
        #expect(sharpScore > flatScore)
        #expect(flatScore == 0)
    }

    @Test func unsupportedImageTypeReturnsNil() {
        guard let scorer = GPUSharpnessScorer() else { return }
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RGB24, data: Data(count: 12))
        #expect(scorer.score(frame: frame) == nil)
    }
}
