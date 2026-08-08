import Foundation

/// Crops a `CapturedFrame`'s raw sensor data to a pixel-space sub-rectangle — used by the
/// planetary auto-crop ROI so the whole downstream pipeline (debayer, stretch, histogram,
/// export, recording) operates on just the tracked disk instead of the full sensor frame.
enum FrameCropper {
    static func crop(_ frame: CapturedFrame, toPixelRect rect: (x: Int, y: Int, width: Int, height: Int)) -> CapturedFrame? {
        let bytesPerPixel: Int
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8: bytesPerPixel = 1
        case ASI_IMG_RAW16: bytesPerPixel = 2
        case ASI_IMG_RGB24: bytesPerPixel = 3
        default: return nil
        }

        let x = max(0, min(rect.x, frame.width - 1))
        let y = max(0, min(rect.y, frame.height - 1))
        let width = max(1, min(rect.width, frame.width - x))
        let height = max(1, min(rect.height, frame.height - y))
        guard width > 0, height > 0 else { return nil }

        var output = Data(count: width * height * bytesPerPixel)
        let sourceRowBytes = frame.width * bytesPerPixel
        let destRowBytes = width * bytesPerPixel

        frame.data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.baseAddress else { return }
                for row in 0..<height {
                    let srcOffset = (y + row) * sourceRowBytes + x * bytesPerPixel
                    let dstOffset = row * destRowBytes
                    memcpy(dstBase + dstOffset, srcBase + srcOffset, destRowBytes)
                }
            }
        }

        return CapturedFrame(width: width, height: height, imageType: frame.imageType, data: output)
    }
}
