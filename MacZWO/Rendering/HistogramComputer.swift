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
}
