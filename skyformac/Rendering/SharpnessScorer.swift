import Foundation

/// Estimates frame sharpness via the classic "variance of Laplacian" metric (the same technique
/// behind e.g. OpenCV's `cv2.Laplacian(...).var()`): a sharp image has more high-frequency
/// content, so the discrete Laplacian's variance is higher; a blurred/defocused/seeing-smeared
/// frame is lower. This is what lucky imaging uses to rank a burst and keep only the sharpest
/// fraction — no Vision/ML model needed, just a well-known signal-processing measure.
enum SharpnessScorer {
    /// Maximum grid dimension used for the Laplacian pass — scores are comparative (rank within
    /// one burst), not absolute, so downsampling large frames keeps a burst of dozens of
    /// multi-megapixel frames from being needlessly expensive to score.
    private static let maxDimension = 512

    /// Higher is sharper. Operates on raw (pre-debayer) sensor data: for color cameras the
    /// Bayer mosaic is debayered first so the metric reflects real luminance detail rather than
    /// the mosaic pattern itself.
    static func score(for frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN) -> Double {
        guard let grid = luminanceGrid(for: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern) else {
            return 0
        }
        return laplacianVariance(grid)
    }

    private static func luminanceGrid(
        for frame: CapturedFrame,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN
    ) -> (values: [Double], width: Int, height: Int)? {
        let mono: [Double]
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            if isColorCamera, let rgb = Debayer.debayerRAW8(frame, pattern: bayerPattern) {
                mono = luma8(rgb, count: frame.width * frame.height)
            } else {
                mono = plane8(frame.data, count: frame.width * frame.height)
            }
        case ASI_IMG_RAW16:
            if isColorCamera, let rgb16 = Debayer.debayerRAW16(frame, pattern: bayerPattern) {
                mono = luma16(rgb16, count: frame.width * frame.height)
            } else {
                mono = plane16(frame.data, count: frame.width * frame.height)
            }
        default:
            return nil
        }
        return downsample(mono, width: frame.width, height: frame.height, maxDimension: maxDimension)
    }

    private static func plane8(_ data: Data, count: Int) -> [Double] {
        guard data.count >= count else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return (0..<count).map { Double(base[$0]) }
        }
    }

    private static func plane16(_ data: Data, count: Int) -> [Double] {
        guard data.count >= count * 2 else { return [] }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return [] }
            return (0..<count).map { Double(base[$0]) }
        }
    }

    private static func luma8(_ rgb: Data, count: Int) -> [Double] {
        guard rgb.count >= count * 3 else { return [] }
        return rgb.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return (0..<count).map { i -> Double in
                let o = i * 3
                return Double(base[o]) * 0.299 + Double(base[o + 1]) * 0.587 + Double(base[o + 2]) * 0.114
            }
        }
    }

    private static func luma16(_ rgb: Data, count: Int) -> [Double] {
        guard rgb.count >= count * 3 * 2 else { return [] }
        return rgb.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return [] }
            return (0..<count).map { i -> Double in
                let o = i * 3
                return Double(base[o]) * 0.299 + Double(base[o + 1]) * 0.587 + Double(base[o + 2]) * 0.114
            }
        }
    }

    private static func downsample(
        _ values: [Double],
        width: Int,
        height: Int,
        maxDimension: Int
    ) -> (values: [Double], width: Int, height: Int)? {
        guard !values.isEmpty, width > 0, height > 0 else { return nil }
        let stride = max(1, max(width, height) / maxDimension)
        guard stride > 1 else { return (values, width, height) }

        let newWidth = (width + stride - 1) / stride
        let newHeight = (height + stride - 1) / stride
        var output = [Double](repeating: 0, count: newWidth * newHeight)
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                output[(y / stride) * newWidth + (x / stride)] = values[y * width + x]
            }
        }
        return (output, newWidth, newHeight)
    }

    /// Variance of the discrete Laplacian over the interior of the grid (a 1-pixel border is
    /// excluded to avoid needing edge-clamping logic for this comparative-only metric).
    private static func laplacianVariance(_ grid: (values: [Double], width: Int, height: Int)) -> Double {
        let (values, width, height) = grid
        guard width > 2, height > 2 else { return 0 }

        var laplacians: [Double] = []
        laplacians.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = values[y * width + x]
                let up = values[(y - 1) * width + x]
                let down = values[(y + 1) * width + x]
                let left = values[y * width + x - 1]
                let right = values[y * width + x + 1]
                laplacians.append(4 * center - up - down - left - right)
            }
        }
        guard !laplacians.isEmpty else { return 0 }

        let mean = laplacians.reduce(0, +) / Double(laplacians.count)
        let variance = laplacians.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(laplacians.count)
        return variance
    }
}
