import Foundation

/// Accumulates an unbounded stream of frames into a running per-pixel average.
///
/// - Important: This is a **simple accumulator with no geometric alignment / registration**.
///   It assumes the frame content doesn't move between exposures (a tracked mount holding
///   still), the same honest scoping as e.g. SharpCap's basic live-stack mode without its
///   star-alignment step. Feeding it frames from an untracked or drifting mount will just
///   produce a blurrier average, not a crash — but it won't correct for the drift either.
///   Operates on raw (pre-debayer) sensor data, same as `FrameArithmetic`.
final class LiveStacker {
    private(set) var frameCount = 0
    private var sums: [UInt64] = []
    /// Per-pixel contribution count — usually identical to `frameCount` for every pixel, except
    /// wherever `add(_:mask:)` was given a `StreakMask` that excluded that pixel from a given
    /// frame (a detected satellite/aircraft trail), in which case it lags behind. Averaging by
    /// this instead of the single scalar `frameCount` is what lets masked-out pixels in some
    /// frames still average correctly against however many frames *did* contribute to them.
    private var counts: [UInt32] = []
    private var width = 0
    private var height = 0
    private var imageType: ASI_IMG_TYPE?

    /// Adds `frame` to the running average. Frames with a different size/type than what's
    /// already accumulated cause an implicit reset (e.g. after `changeImageType`), since
    /// averaging incompatible frames together would be meaningless.
    ///
    /// - Parameter mask: When non-nil (see `StreakMask`), pixels it marks as masked-out are
    ///   excluded from this frame's contribution to the average entirely, instead of polluting it
    ///   with a satellite/aircraft trail's pixel values.
    func add(_ frame: CapturedFrame, mask: StreakMask? = nil) {
        if imageType?.rawValue != frame.imageType.rawValue || width != frame.width || height != frame.height {
            reset(width: frame.width, height: frame.height, imageType: frame.imageType)
        }

        let count = width * height
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            guard frame.data.count >= count else { return }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count {
                    guard mask?.isKept(flatIndex: i) ?? true else { continue }
                    sums[i] += UInt64(base[i])
                    counts[i] += 1
                }
            }
        case ASI_IMG_RAW16:
            guard frame.data.count >= count * 2 else { return }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count {
                    guard mask?.isKept(flatIndex: i) ?? true else { continue }
                    sums[i] += UInt64(base[i])
                    counts[i] += 1
                }
            }
        case ASI_IMG_RGB24:
            // Webcam/iPhone frames are always this format (see `WebcamCaptureEngine`'s doc
            // comment) — this case was missing entirely, so `add` silently hit `default: return`
            // for every single webcam frame, `frameCount` never advanced, and `currentAverage()`
            // always came back `nil`. That's the actual reason "iPhone Night Mode" (built
            // directly on this accumulator) did nothing, and it silently broke plain "Live
            // Stack" for webcam/iPhone sources the same way, from before Night Mode ever existed.
            // `sums` is sized 3x (one slot per channel) for this case — see `reset`.
            guard frame.data.count >= count * 3 else { return }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count {
                    guard mask?.isKept(flatIndex: i) ?? true else { continue }
                    let o = i * 3
                    sums[o] += UInt64(base[o])
                    sums[o + 1] += UInt64(base[o + 1])
                    sums[o + 2] += UInt64(base[o + 2])
                    counts[i] += 1
                }
            }
        default:
            return
        }
        frameCount += 1
    }

    /// The current running-average frame, or `nil` if no frames have been added yet. A pixel
    /// masked out of every single contributing frame so far (`counts[i] == 0`) falls back to 0
    /// rather than dividing by zero — an edge case only a pathological all-streak mask could hit.
    func currentAverage() -> CapturedFrame? {
        guard frameCount > 0, let imageType else { return nil }
        let count = width * height

        switch imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            var output = Data(count: count)
            output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count {
                    let c = counts[i]
                    op[i] = c > 0 ? UInt8(sums[i] / UInt64(c)) : 0
                }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        case ASI_IMG_RAW16:
            var output = Data(count: count * 2)
            output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                guard let op = o.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count {
                    let c = counts[i]
                    op[i] = c > 0 ? UInt16(sums[i] / UInt64(c)) : 0
                }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        case ASI_IMG_RGB24:
            var output = Data(count: count * 3)
            output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count {
                    let c = counts[i]
                    let off = i * 3
                    if c > 0 {
                        op[off] = UInt8(sums[off] / UInt64(c))
                        op[off + 1] = UInt8(sums[off + 1] / UInt64(c))
                        op[off + 2] = UInt8(sums[off + 2] / UInt64(c))
                    } else {
                        op[off] = 0
                        op[off + 1] = 0
                        op[off + 2] = 0
                    }
                }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        default:
            return nil
        }
    }

    func reset() {
        frameCount = 0
        let channels = imageType.map(Self.channelCount) ?? 1
        sums = [UInt64](repeating: 0, count: width * height * channels)
        counts = [UInt32](repeating: 0, count: width * height)
    }

    private func reset(width: Int, height: Int, imageType: ASI_IMG_TYPE) {
        self.width = width
        self.height = height
        self.imageType = imageType
        self.frameCount = 0
        self.sums = [UInt64](repeating: 0, count: width * height * Self.channelCount(for: imageType))
        self.counts = [UInt32](repeating: 0, count: width * height)
    }

    /// `sums` needs one slot per *channel*, not per pixel — 3 for RGB24, 1 for the mono formats.
    /// `counts` always stays one slot per pixel regardless (a mask excludes/includes a whole
    /// pixel, all its channels together, never one channel alone).
    private static func channelCount(for imageType: ASI_IMG_TYPE) -> Int {
        imageType.rawValue == ASI_IMG_RGB24.rawValue ? 3 : 1
    }
}
