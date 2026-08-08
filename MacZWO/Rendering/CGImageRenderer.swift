import CoreGraphics
import Foundation

/// Converts a `CapturedFrame` into a displayable `CGImage`, applying the color camera's
/// Bayer debayer (via `Debayer`) and a black/white point `DisplayStretch` down to 8-bit
/// output. This is the CPU baseline per spec 3.4 / Milestone 4; the GPU upgrade pass replaces
/// it with a `MetalKit`-backed renderer that does the stretch (and debayer) on the GPU.
enum CGImageRenderer {
    static func makeDisplayImage(
        from frame: CapturedFrame,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN,
        stretch: DisplayStretch
    ) -> CGImage? {
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            if isColorCamera, frame.imageType == ASI_IMG_RAW8,
               let rgb = Debayer.debayerRAW8(frame, pattern: bayerPattern) {
                return makeRGB8Image(rgb, width: frame.width, height: frame.height, stretch: stretch)
            }
            return makeGrayscaleImage(
                frame.data,
                width: frame.width,
                height: frame.height,
                maxValue: 255,
                bytesPerSample: 1,
                stretch: stretch
            )
        case ASI_IMG_RAW16:
            if isColorCamera, let rgb16 = Debayer.debayerRAW16(frame, pattern: bayerPattern) {
                return makeRGB16Image(rgb16, width: frame.width, height: frame.height, stretch: stretch)
            }
            return makeGrayscaleImage(
                frame.data,
                width: frame.width,
                height: frame.height,
                maxValue: 65535,
                bytesPerSample: 2,
                stretch: stretch
            )
        case ASI_IMG_RGB24:
            return makeRGB8Image(frame.data, width: frame.width, height: frame.height, stretch: stretch)
        default:
            return nil
        }
    }

    // MARK: - Mono

    private static func makeGrayscaleImage(
        _ data: Data,
        width: Int,
        height: Int,
        maxValue: Int,
        bytesPerSample: Int,
        stretch: DisplayStretch
    ) -> CGImage? {
        guard data.count >= width * height * bytesPerSample else { return nil }
        let lut = stretch.lookupTable(maxValue: maxValue)
        var output = Data(count: width * height)

        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                if bytesPerSample == 1 {
                    guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<(width * height) {
                        dstBase[i] = lut[Int(srcBase[i])]
                    }
                } else {
                    guard let srcBase = src.bindMemory(to: UInt16.self).baseAddress else { return }
                    for i in 0..<(width * height) {
                        dstBase[i] = lut[Int(srcBase[i])]
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Color

    private static func makeRGB8Image(
        _ rgbData: Data,
        width: Int,
        height: Int,
        stretch: DisplayStretch
    ) -> CGImage? {
        guard rgbData.count >= width * height * 3 else { return nil }
        let lut = stretch.lookupTable(maxValue: 255)
        var output = Data(count: width * height * 3)
        rgbData.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = width * height * 3
                for i in 0..<count {
                    dstBase[i] = lut[Int(srcBase[i])]
                }
            }
        }
        return makeRGB8CGImage(output, width: width, height: height)
    }

    private static func makeRGB16Image(
        _ rgb16Data: Data,
        width: Int,
        height: Int,
        stretch: DisplayStretch
    ) -> CGImage? {
        guard rgb16Data.count >= width * height * 3 * 2 else { return nil }
        let lut = stretch.lookupTable(maxValue: 65535)
        var output = Data(count: width * height * 3)
        rgb16Data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.bindMemory(to: UInt16.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = width * height * 3
                for i in 0..<count {
                    dstBase[i] = lut[Int(srcBase[i])]
                }
            }
        }
        return makeRGB8CGImage(output, width: width, height: height)
    }

    private static func makeRGB8CGImage(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
