import Foundation

/// CPU bilinear Bayer demosaic for RAW8/RAW16 color-camera frames.
///
/// - Note: The project spec suggested `vImageBayerToRGB` from Accelerate/vImage as the CPU
///   debayer path. That symbol does not exist in the current Accelerate/vImage headers (there is
///   no Bayer/demosaic API in `vImage.framework/Headers` at all — checked `Conversion.h`,
///   `vImage_Utilities.h`, etc.). This implements the standard bilinear demosaic algorithm by
///   hand instead. The GPU upgrade pass replaces this with an equivalent Metal compute kernel.
enum Debayer {
    /// Demosaics an 8-bit-per-pixel Bayer `frame` into interleaved 8-bit RGB (3 bytes/pixel).
    static func debayerRAW8(_ frame: CapturedFrame, pattern: ASI_BAYER_PATTERN) -> Data? {
        guard frame.imageType == ASI_IMG_RAW8 else { return nil }
        let width = frame.width
        let height = frame.height
        guard frame.data.count >= width * height else { return nil }

        var output = Data(count: width * height * 3)
        frame.data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                debayerBilinear8(
                    src: srcBase,
                    dst: dstBase,
                    width: width,
                    height: height,
                    pattern: pattern
                )
            }
        }
        return output
    }

    /// Demosaics a 16-bit-per-pixel (little-endian) Bayer `frame` into interleaved 16-bit RGB
    /// (6 bytes/pixel, little-endian).
    static func debayerRAW16(_ frame: CapturedFrame, pattern: ASI_BAYER_PATTERN) -> Data? {
        guard frame.imageType == ASI_IMG_RAW16 else { return nil }
        let width = frame.width
        let height = frame.height
        guard frame.data.count >= width * height * 2 else { return nil }

        var output = Data(count: width * height * 3 * 2)
        frame.data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.bindMemory(to: UInt16.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt16.self).baseAddress else { return }
                debayerBilinear16(
                    src: srcBase,
                    dst: dstBase,
                    width: width,
                    height: height,
                    pattern: pattern
                )
            }
        }
        return output
    }

    /// Which color channel a given (x, y) Bayer sample directly measures — `internal`, not
    /// `private`, so `HistogramComputer` can classify raw sensor pixels into per-channel
    /// histograms without duplicating this same pattern-matching logic a third time (`Shaders
    /// .metal`'s `isRedAt`/`isBlueAt` inline functions are the GPU-side equivalent).
    enum Channel: Equatable { case red, green, blue }

    static func channel(atX x: Int, y: Int, pattern: ASI_BAYER_PATTERN) -> Channel {
        let evenX = x % 2 == 0
        let evenY = y % 2 == 0
        switch pattern {
        case ASI_BAYER_RG: // RGGB: (even,even)=R (odd,even)=G (even,odd)=G (odd,odd)=B
            if evenX, evenY { return .red }
            if !evenX, !evenY { return .blue }
            return .green
        case ASI_BAYER_BG: // BGGR
            if evenX, evenY { return .blue }
            if !evenX, !evenY { return .red }
            return .green
        case ASI_BAYER_GR: // GRBG: (even,even)=G (odd,even)=R (even,odd)=B (odd,odd)=G
            if !evenX, evenY { return .red }
            if evenX, !evenY { return .blue }
            return .green
        case ASI_BAYER_GB: // GBRG
            if evenX, evenY { return .green }
            if !evenX, evenY { return .blue }
            if evenX, !evenY { return .red }
            return .green
        default:
            return .green
        }
    }

    private static func debayerBilinear8(
        src: UnsafePointer<UInt8>,
        dst: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        pattern: ASI_BAYER_PATTERN
    ) {
        @inline(__always) func sample(_ x: Int, _ y: Int) -> Int {
            let cx = min(max(x, 0), width - 1)
            let cy = min(max(y, 0), height - 1)
            return Int(src[cy * width + cx])
        }

        for y in 0..<height {
            for x in 0..<width {
                let here = channel(atX: x, y: y, pattern: pattern)
                var r = 0, g = 0, b = 0

                switch here {
                case .red:
                    r = sample(x, y)
                    g = (sample(x - 1, y) + sample(x + 1, y) + sample(x, y - 1) + sample(x, y + 1)) / 4
                    b = (sample(x - 1, y - 1) + sample(x + 1, y - 1) + sample(x - 1, y + 1) + sample(x + 1, y + 1)) / 4
                case .blue:
                    b = sample(x, y)
                    g = (sample(x - 1, y) + sample(x + 1, y) + sample(x, y - 1) + sample(x, y + 1)) / 4
                    r = (sample(x - 1, y - 1) + sample(x + 1, y - 1) + sample(x - 1, y + 1) + sample(x + 1, y + 1)) / 4
                case .green:
                    g = sample(x, y)
                    // Neighboring rows alternate which of R/B run horizontally vs vertically.
                    let leftRightIsRed = channel(atX: x - 1, y: y, pattern: pattern) == .red
                        || channel(atX: x + 1, y: y, pattern: pattern) == .red
                    if leftRightIsRed {
                        r = (sample(x - 1, y) + sample(x + 1, y)) / 2
                        b = (sample(x, y - 1) + sample(x, y + 1)) / 2
                    } else {
                        b = (sample(x - 1, y) + sample(x + 1, y)) / 2
                        r = (sample(x, y - 1) + sample(x, y + 1)) / 2
                    }
                }

                let offset = (y * width + x) * 3
                dst[offset] = UInt8(clamping: r)
                dst[offset + 1] = UInt8(clamping: g)
                dst[offset + 2] = UInt8(clamping: b)
            }
        }
    }

    private static func debayerBilinear16(
        src: UnsafePointer<UInt16>,
        dst: UnsafeMutablePointer<UInt16>,
        width: Int,
        height: Int,
        pattern: ASI_BAYER_PATTERN
    ) {
        @inline(__always) func sample(_ x: Int, _ y: Int) -> Int {
            let cx = min(max(x, 0), width - 1)
            let cy = min(max(y, 0), height - 1)
            return Int(src[cy * width + cx])
        }

        for y in 0..<height {
            for x in 0..<width {
                let here = channel(atX: x, y: y, pattern: pattern)
                var r = 0, g = 0, b = 0

                switch here {
                case .red:
                    r = sample(x, y)
                    g = (sample(x - 1, y) + sample(x + 1, y) + sample(x, y - 1) + sample(x, y + 1)) / 4
                    b = (sample(x - 1, y - 1) + sample(x + 1, y - 1) + sample(x - 1, y + 1) + sample(x + 1, y + 1)) / 4
                case .blue:
                    b = sample(x, y)
                    g = (sample(x - 1, y) + sample(x + 1, y) + sample(x, y - 1) + sample(x, y + 1)) / 4
                    r = (sample(x - 1, y - 1) + sample(x + 1, y - 1) + sample(x - 1, y + 1) + sample(x + 1, y + 1)) / 4
                case .green:
                    g = sample(x, y)
                    let leftRightIsRed = channel(atX: x - 1, y: y, pattern: pattern) == .red
                        || channel(atX: x + 1, y: y, pattern: pattern) == .red
                    if leftRightIsRed {
                        r = (sample(x - 1, y) + sample(x + 1, y)) / 2
                        b = (sample(x, y - 1) + sample(x, y + 1)) / 2
                    } else {
                        b = (sample(x - 1, y) + sample(x + 1, y)) / 2
                        r = (sample(x, y - 1) + sample(x, y + 1)) / 2
                    }
                }

                let offset = (y * width + x) * 3
                dst[offset] = UInt16(clamping: r)
                dst[offset + 1] = UInt16(clamping: g)
                dst[offset + 2] = UInt16(clamping: b)
            }
        }
    }
}
