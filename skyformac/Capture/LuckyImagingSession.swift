import Foundation

/// Collects a fixed-size burst of frames (scored by `SharpnessScorer` as they arrive) and stacks
/// only the sharpest fraction — the classic "lucky imaging" technique for beating atmospheric
/// seeing on planetary/lunar targets by keeping the moments the air happened to be steadiest.
///
/// - Important: Holds every captured frame in memory for the duration of the burst (needed
///   since which frames are "best" isn't known until the whole burst is scored) — keep
///   `targetFrameCount` modest for large sensors. No geometric alignment between kept frames,
///   same honest scoping as `LiveStacker`.
final class LuckyImagingSession {
    struct ScoredFrame {
        let frame: CapturedFrame
        let score: Double
    }

    let targetFrameCount: Int
    private(set) var scoredFrames: [ScoredFrame] = []

    init(targetFrameCount: Int) {
        self.targetFrameCount = max(1, targetFrameCount)
    }

    var capturedCount: Int { scoredFrames.count }
    var isComplete: Bool { scoredFrames.count >= targetFrameCount }

    /// Scores and stores `frame`. No-op once `isComplete`.
    func add(_ frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN) {
        guard !isComplete else { return }
        let score = SharpnessScorer.score(for: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern)
        scoredFrames.append(ScoredFrame(frame: frame, score: score))
    }

    /// Stacks the sharpest `fraction` (clamped to (0, 1]) of the burst captured so far.
    /// Returns `nil` if nothing has been captured yet.
    func stackBest(fraction: Double) -> CapturedFrame? {
        guard !scoredFrames.isEmpty else { return nil }
        let clampedFraction = min(max(fraction, 0.01), 1.0)
        let keepCount = max(1, Int((Double(scoredFrames.count) * clampedFraction).rounded(.up)))
        let best = scoredFrames
            .sorted { $0.score > $1.score }
            .prefix(keepCount)
            .map { $0.frame }
        return FrameArithmetic.average(frames: Array(best))
    }
}
