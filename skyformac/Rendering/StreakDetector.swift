import CoreGraphics
import Vision

/// A detected satellite/aircraft/meteor trail, in normalized (0...1, Vision's bottom-left-origin)
/// image coordinates.
struct DetectedStreak: Sendable {
    let boundingBoxNormalized: CGRect
}

/// Detects satellite/aircraft/meteor trails — long, straight, high-intensity streaks — for
/// `specs/skyformac_AI_Features_Pipeline_Spec.md` Feature 3, using the same Vision
/// `VNDetectContoursRequest` `StarDetector` already uses, with an inverted geometric filter:
/// `StarDetector` keeps small, round blobs and rejects large elongated contours as "noise,
/// gradients, or the frame border"; a streak *is* exactly a large, elongated contour, so this
/// keeps what that one throws away.
enum StreakDetector {
    /// Runs contour detection on `image` and returns streak-shaped contours: long relative to
    /// their width (aspect ratio far from 1) and long enough in absolute terms to be a real
    /// trail rather than a stray thin noise contour. Performs Vision's (synchronous, potentially
    /// slow) request handler off the caller's thread — call from a background `Task`, never from
    /// `@MainActor`, same rule as `StarDetector.detectStars`.
    static func detectStreaks(in image: CGImage) throws -> [DetectedStreak] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = false // streaks are bright trails on a dark sky background
        request.maximumImageDimension = 768

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else { return [] }

        var streaks: [DetectedStreak] = []
        for contour in observation.topLevelContours {
            let box = contour.normalizedPath.boundingBoxOfPath
            guard box.width > 0, box.height > 0 else { continue }
            let longSide = max(box.width, box.height)
            let shortSide = min(box.width, box.height)
            guard longSide > 0.15, longSide / shortSide > 6 else { continue }
            streaks.append(DetectedStreak(boundingBoxNormalized: box))
        }
        return streaks
    }
}

/// A per-pixel keep/mask-out grid derived from `StreakDetector`'s output, at the resolution of a
/// specific captured frame — `LiveStacker` skips any pixel this marks as masked when folding a
/// new frame into a running average, so a passing satellite/plane doesn't leave a bright streak
/// baked into the stack.
///
/// - Important: CPU live-stacking (`LiveStacker`) only. The GPU live-stack accumulate kernel
///   (`Shaders.metal`'s `accumulateMono`) divides every pixel by one shared scalar frame count;
///   masking specific pixels in specific frames would need a *per-pixel* count instead, which
///   would mean threading a second accumulator texture through `accumulateMono`,
///   `stretchMono`/`debayerAndStretch`, and `histogramReduce` all at once — a much bigger, riskier
///   change to already-shipped, well-tested GPU code than this feature's own scope justifies.
///   `ControlsPanelView` discloses this gap in the UI rather than silently doing nothing.
struct StreakMask: Sendable {
    let width: Int
    let height: Int
    /// `true` = keep (normal sky pixel), `false` = masked out (part of a detected streak).
    private let keep: [Bool]

    init(width: Int, height: Int, streaks: [DetectedStreak], paddingFraction: Double = 0.01) {
        self.width = width
        self.height = height
        var keep = [Bool](repeating: true, count: max(width * height, 0))
        for streak in streaks {
            let box = streak.boundingBoxNormalized
            // Pad slightly so a streak's soft/anti-aliased edges are covered too, then flip
            // Vision's bottom-left-origin rect to top-left pixel space.
            let padded = box.insetBy(dx: -box.width * paddingFraction, dy: -box.height * paddingFraction)
            // `padded.maxX`/`maxY` are an *exclusive* upper bound in normalized space (pixel `i`
            // spans `[i/width, (i+1)/width)`) — naively `.rounded(.up)`-ing them to a pixel index
            // includes one extra row/column whenever the boundary lands exactly on a pixel edge
            // (e.g. a box of width 0.5 on a 2px-wide frame: `0.5 * 2 == 1.0`, and `ceil(1.0) == 1`
            // would wrongly keep pixel index 1 too). Subtracting 1 after the ceiling converts it
            // back to the correct *inclusive* last index either way.
            let minX = max(0, Int((padded.minX * Double(width)).rounded(.down)))
            let maxX = min(width - 1, Int((padded.maxX * Double(width)).rounded(.up)) - 1)
            let minY = max(0, Int(((1 - padded.maxY) * Double(height)).rounded(.down)))
            let maxY = min(height - 1, Int(((1 - padded.minY) * Double(height)).rounded(.up)) - 1)
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                let rowBase = y * width
                for x in minX...maxX { keep[rowBase + x] = false }
            }
        }
        self.keep = keep
    }

    func isKept(flatIndex: Int) -> Bool {
        guard flatIndex >= 0, flatIndex < keep.count else { return true }
        return keep[flatIndex]
    }

    /// Fraction of pixels currently masked out — surfaced in the UI so "streak masking is on" has
    /// some live feedback even when nothing's actively being stacked.
    var maskedFraction: Double {
        guard !keep.isEmpty else { return 0 }
        return Double(keep.filter { !$0 }.count) / Double(keep.count)
    }
}
