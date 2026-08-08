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
    private var width = 0
    private var height = 0
    private var imageType: ASI_IMG_TYPE?

    /// Adds `frame` to the running average. Frames with a different size/type than what's
    /// already accumulated cause an implicit reset (e.g. after `changeImageType`), since
    /// averaging incompatible frames together would be meaningless.
    func add(_ frame: CapturedFrame) {
        if imageType?.rawValue != frame.imageType.rawValue || width != frame.width || height != frame.height {
            reset(width: frame.width, height: frame.height, imageType: frame.imageType)
        }

        let count = width * height
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            guard frame.data.count >= count else { return }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count { sums[i] += UInt64(base[i]) }
            }
        case ASI_IMG_RAW16:
            guard frame.data.count >= count * 2 else { return }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count { sums[i] += UInt64(base[i]) }
            }
        default:
            return
        }
        frameCount += 1
    }

    /// The current running-average frame, or `nil` if no frames have been added yet.
    func currentAverage() -> CapturedFrame? {
        guard frameCount > 0, let imageType else { return nil }
        let count = width * height

        switch imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            var output = Data(count: count)
            output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count { op[i] = UInt8(sums[i] / UInt64(frameCount)) }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        case ASI_IMG_RAW16:
            var output = Data(count: count * 2)
            output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                guard let op = o.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count { op[i] = UInt16(sums[i] / UInt64(frameCount)) }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        default:
            return nil
        }
    }

    func reset() {
        frameCount = 0
        sums = [UInt64](repeating: 0, count: width * height)
    }

    private func reset(width: Int, height: Int, imageType: ASI_IMG_TYPE) {
        self.width = width
        self.height = height
        self.imageType = imageType
        self.frameCount = 0
        self.sums = [UInt64](repeating: 0, count: width * height)
    }
}
