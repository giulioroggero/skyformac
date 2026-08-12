import Foundation

/// Per-pixel arithmetic on raw (pre-debayer) mono sensor data, shared by dark-frame
/// subtraction and lucky-imaging's best-frame stacking. Operates on `CapturedFrame.data`
/// directly (RAW8/Y8 or RAW16) — never on already-debayered/stretched display pixels, matching
/// how real capture pipelines apply calibration before any display processing.
enum FrameArithmetic {
    /// `light - dark`, clamped at 0 per pixel. `nil` if the frames don't match in dimensions
    /// or image type (e.g. a RAW16 dark can't calibrate a RAW8 light).
    static func subtract(light: CapturedFrame, dark: CapturedFrame) -> CapturedFrame? {
        guard light.imageType.rawValue == dark.imageType.rawValue,
              light.width == dark.width, light.height == dark.height
        else { return nil }

        switch light.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            return subtract8(light: light, dark: dark)
        case ASI_IMG_RAW16:
            return subtract16(light: light, dark: dark)
        default:
            return nil
        }
    }

    /// Equal-weighted mean of `frames`, per pixel. All frames must share dimensions and image
    /// type; returns `nil` for an empty array or a mismatch. Used by lucky imaging to stack its
    /// top-scoring subset of a burst.
    static func average(frames: [CapturedFrame]) -> CapturedFrame? {
        guard let first = frames.first else { return nil }
        guard frames.allSatisfy({
            $0.imageType.rawValue == first.imageType.rawValue
                && $0.width == first.width && $0.height == first.height
        }) else { return nil }

        switch first.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            return average8(frames: frames)
        case ASI_IMG_RAW16:
            return average16(frames: frames)
        case ASI_IMG_RGB24:
            return average24(frames: frames)
        default:
            return nil
        }
    }

    // MARK: - RAW8 / Y8

    private static func subtract8(light: CapturedFrame, dark: CapturedFrame) -> CapturedFrame? {
        let count = light.width * light.height
        guard light.data.count >= count, dark.data.count >= count else { return nil }

        var output = Data(count: count)
        light.data.withUnsafeBytes { (l: UnsafeRawBufferPointer) in
            dark.data.withUnsafeBytes { (d: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                    guard let lp = l.bindMemory(to: UInt8.self).baseAddress,
                          let dp = d.bindMemory(to: UInt8.self).baseAddress,
                          let op = o.bindMemory(to: UInt8.self).baseAddress
                    else { return }
                    for i in 0..<count {
                        op[i] = UInt8(clamping: Int(lp[i]) - Int(dp[i]))
                    }
                }
            }
        }
        return CapturedFrame(width: light.width, height: light.height, imageType: light.imageType, data: output)
    }

    private static func average8(frames: [CapturedFrame]) -> CapturedFrame? {
        let width = frames[0].width
        let height = frames[0].height
        let count = width * height
        var sums = [UInt32](repeating: 0, count: count)

        for frame in frames {
            guard frame.data.count >= count else { return nil }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count { sums[i] += UInt32(base[i]) }
            }
        }

        var output = Data(count: count)
        let divisor = UInt32(frames.count)
        output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<count { op[i] = UInt8(sums[i] / divisor) }
        }
        return CapturedFrame(width: width, height: height, imageType: frames[0].imageType, data: output)
    }

    // MARK: - RAW16

    private static func subtract16(light: CapturedFrame, dark: CapturedFrame) -> CapturedFrame? {
        let count = light.width * light.height
        guard light.data.count >= count * 2, dark.data.count >= count * 2 else { return nil }

        var output = Data(count: count * 2)
        light.data.withUnsafeBytes { (l: UnsafeRawBufferPointer) in
            dark.data.withUnsafeBytes { (d: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                    guard let lp = l.bindMemory(to: UInt16.self).baseAddress,
                          let dp = d.bindMemory(to: UInt16.self).baseAddress,
                          let op = o.bindMemory(to: UInt16.self).baseAddress
                    else { return }
                    for i in 0..<count {
                        op[i] = UInt16(clamping: Int(lp[i]) - Int(dp[i]))
                    }
                }
            }
        }
        return CapturedFrame(width: light.width, height: light.height, imageType: light.imageType, data: output)
    }

    private static func average16(frames: [CapturedFrame]) -> CapturedFrame? {
        let width = frames[0].width
        let height = frames[0].height
        let count = width * height
        var sums = [UInt32](repeating: 0, count: count)

        for frame in frames {
            guard frame.data.count >= count * 2 else { return nil }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count { sums[i] += UInt32(base[i]) }
            }
        }

        var output = Data(count: count * 2)
        let divisor = UInt32(frames.count)
        output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            guard let op = o.bindMemory(to: UInt16.self).baseAddress else { return }
            for i in 0..<count { op[i] = UInt16(sums[i] / divisor) }
        }
        return CapturedFrame(width: width, height: height, imageType: frames[0].imageType, data: output)
    }

    // MARK: - RGB24

    /// Webcam/iPhone frames only (see `WebcamCaptureEngine`'s doc comment) — packed R,G,B
    /// triplets, averaged per channel independently. This case was missing entirely, so
    /// `LuckyImagingSession.stackBest` silently returned `nil` for every iPhone/webcam burst —
    /// Lucky Imaging produced nothing at all for that source, on top of `SharpnessScorer` scoring
    /// every frame in the burst as 0 (see its own doc comment for that half of the same gap).
    private static func average24(frames: [CapturedFrame]) -> CapturedFrame? {
        let width = frames[0].width
        let height = frames[0].height
        let count = width * height * 3
        var sums = [UInt32](repeating: 0, count: count)

        for frame in frames {
            guard frame.data.count >= count else { return nil }
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count { sums[i] += UInt32(base[i]) }
            }
        }

        var output = Data(count: count)
        let divisor = UInt32(frames.count)
        output.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            guard let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<count { op[i] = UInt8(sums[i] / divisor) }
        }
        return CapturedFrame(width: width, height: height, imageType: frames[0].imageType, data: output)
    }
}
