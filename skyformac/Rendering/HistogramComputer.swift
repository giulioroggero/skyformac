import Foundation

/// Computes a 256-bucket luminance histogram from a captured frame for `HistogramView`.
/// CPU-only baseline (per spec Milestone 4); the GPU upgrade pass replaces this with a
/// Metal compute-shader parallel reduction so histogram redraws don't cost a full CPU
/// pass over multi-megapixel frames every update.
enum HistogramComputer {
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
}
