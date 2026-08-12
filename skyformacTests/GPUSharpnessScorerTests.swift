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

    /// A coarser checkerboard than `checkerboard(width:height:)`'s period-2 pattern — needed for
    /// any frame large enough to trigger `GPUSharpnessScorer`'s stride-based downsampling.
    /// Nearest-neighbor strided sampling of a period-2 pattern at an even stride always lands on
    /// the same phase (every sampled neighbor reads the *same* cell value), aliasing the Laplacian
    /// to exactly zero regardless of how "sharp" the original content actually was — a real
    /// property of this downsampling approach (shared with `SharpnessScorer`'s identical
    /// CPU-side nearest-neighbor stride, just never exercised by a checkerboard that small there),
    /// not a bug specific to the GPU path. `blockSize` should stay comfortably larger than
    /// whatever stride the test's frame size will compute, so sampled neighbors still land in
    /// different blocks.
    private func blockCheckerboard(width: Int, height: Int, blockSize: Int) -> CapturedFrame {
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    base[y * width + x] = ((x / blockSize) + (y / blockSize)) % 2 == 0 ? 255 : 0
                }
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: data)
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

    /// Larger than `GPUSharpnessScorer`'s own resolution cap (512) on both axes — exercises the
    /// stride-based downsampling path added to fix a real hang: a full-sensor ROI (deliberately
    /// used by the Moon's Acquisition Wizard preset) combined with Smart Live Stack's per-frame
    /// gate previously ran this scorer at full native resolution, synchronously, on every single
    /// incoming frame. Confirms the downsampled path still ranks a sharp frame above a flat one
    /// (i.e. the cap didn't just make the metric meaningless) rather than timing/crashing.
    @Test func gpuScoresLargeFrameAboveTheResolutionCapCorrectly() throws {
        guard let scorer = GPUSharpnessScorer() else { return }
        let sharpScore = try #require(scorer.score(frame: blockCheckerboard(width: 1024, height: 1024, blockSize: 32)))
        let flatScore = try #require(scorer.score(frame: flatField(width: 1024, height: 1024)))
        #expect(sharpScore > flatScore)
        #expect(flatScore == 0)
    }

    @Test func unsupportedImageTypeReturnsNil() {
        guard let scorer = GPUSharpnessScorer() else { return }
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RGB24, data: Data(count: 12))
        #expect(scorer.score(frame: frame) == nil)
    }
}
