import Foundation

/// Computes a 256-bucket luminance histogram from a captured frame for `HistogramView`.
/// CPU-only baseline (per spec Milestone 4); the GPU upgrade pass replaces this with a
/// Metal compute-shader parallel reduction so histogram redraws don't cost a full CPU
/// pass over multi-megapixel frames every update.
enum HistogramComputer {
    /// Per-channel histograms — CPU fallback for `HistogramView`'s "By Channel" display when the
    /// GPU render path is off (`MetalFrameRenderer`'s `histogramReduce`/`histogramReduceRGB24`
    /// kernels compute the equivalent on that path; see their own doc comments). `nil` for a mono
    /// camera (nothing to split into channels) or an unsupported image type.
    ///
    /// For RAW8/RAW16 (a ZWO color camera's still-mosaiced Bayer data, the same pre-debayer domain
    /// the combined luma histogram and the Black/White Point stretch both already operate in),
    /// each raw sample is binned by which channel it directly measures (`Debayer.channel`) rather
    /// than debayering first — a real per-photosite histogram, not an interpolated one, and
    /// consistent with why `histogram(for:)` itself never debayers either.
    static func channelHistograms(
        for frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN
    ) -> (red: [Int], green: [Int], blue: [Int])? {
        guard frame.imageType == ASI_IMG_RGB24
            || (isColorCamera && (frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16))
        else { return nil }
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)

        frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            switch frame.imageType {
            case ASI_IMG_RAW8:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        let value = Int(base[y * frame.width + x])
                        switch Debayer.channel(atX: x, y: y, pattern: bayerPattern) {
                        case .red: red[value] += 1
                        case .green: green[value] += 1
                        case .blue: blue[value] += 1
                        }
                    }
                }
            case ASI_IMG_RAW16:
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        let value = Int(base[y * frame.width + x] >> 8)
                        switch Debayer.channel(atX: x, y: y, pattern: bayerPattern) {
                        case .red: red[value] += 1
                        case .green: green[value] += 1
                        case .blue: blue[value] += 1
                        }
                    }
                }
            case ASI_IMG_RGB24:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = frame.width * frame.height
                for i in 0..<count {
                    let offset = i * 3
                    red[Int(base[offset])] += 1
                    green[Int(base[offset + 1])] += 1
                    blue[Int(base[offset + 2])] += 1
                }
            default:
                return
            }
        }
        return (red, green, blue)
    }

    static func histogram(for frame: CapturedFrame) -> [Int] {
        var buckets = [Int](repeating: 0, count: 256)
        frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            switch frame.imageType {
            case ASI_IMG_RAW8, ASI_IMG_Y8:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = frame.width * frame.height
                for i in 0..<count {
                    buckets[Int(base[i])] += 1
                }
            case ASI_IMG_RAW16:
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                let count = frame.width * frame.height
                for i in 0..<count {
                    buckets[Int(base[i] >> 8)] += 1
                }
            case ASI_IMG_RGB24:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let count = frame.width * frame.height
                for i in 0..<count {
                    let offset = i * 3
                    // Rough luma approximation, good enough for a histogram display.
                    let luma = (Int(base[offset]) * 3 + Int(base[offset + 1]) * 4 + Int(base[offset + 2])) / 8
                    buckets[luma] += 1
                }
            default:
                break
            }
        }
        return buckets
    }

    /// Coarse, stride-sampled mean brightness (roughly 0...255 regardless of source format) for
    /// `CloudDriftSentinel` — deliberately *not* a full per-pixel pass like `histogram(for:)`
    /// above, since this needs to run on every incoming main-pipeline frame rather than only when
    /// the histogram view redraws. Every `stride`th pixel is enough to track a sky-brightness
    /// trend; a dense cloud bank or a stray light source changes overall brightness by far more
    /// than sampling noise from skipping pixels would hide.
    static func meanBrightness(of frame: CapturedFrame, stride: Int = 16) -> Double {
        var sum = 0.0
        var sampleCount = 0
        frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = frame.width * frame.height
            switch frame.imageType {
            case ASI_IMG_RAW8, ASI_IMG_Y8:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                while i < count { sum += Double(base[i]); sampleCount += 1; i += stride }
            case ASI_IMG_RAW16:
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                var i = 0
                while i < count { sum += Double(base[i] >> 8); sampleCount += 1; i += stride }
            case ASI_IMG_RGB24:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var i = 0
                while i < count {
                    let offset = i * 3
                    let luma = (Int(base[offset]) * 3 + Int(base[offset + 1]) * 4 + Int(base[offset + 2])) / 8
                    sum += Double(luma)
                    sampleCount += 1
                    i += stride
                }
            default:
                break
            }
        }
        return sampleCount > 0 ? sum / Double(sampleCount) : 0
    }

    /// Fraction of pixels sitting exactly at the histogram's first bin (shadows) or last bin
    /// (highlights) — a pixel already pegged to black/white before any further stretch is detail
    /// that's already lost, not detail a Black/White Point slider can recover. Used by
    /// `HistogramView` to show a clipping warning alongside the live histogram.
    static func clippedFraction(_ buckets: [Int]) -> (shadows: Double, highlights: Double) {
        let total = buckets.reduce(0, +)
        guard total > 0, let first = buckets.first, let last = buckets.last else { return (0, 0) }
        return (Double(first) / Double(total), Double(last) / Double(total))
    }
}
