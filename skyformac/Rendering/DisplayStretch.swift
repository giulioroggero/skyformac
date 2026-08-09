import Foundation

/// Black/white point stretch applied when mapping raw sensor data (8- or 16-bit, linear) down
/// to an 8-bit displayable image. Values are normalized fractions of the source bit depth's
/// full range, e.g. `blackPoint: 0.1, whitePoint: 0.6` on a RAW16 frame clips below 6553 and
/// above 39321, linearly stretching the rest across the visible 0...255 output range.
struct DisplayStretch: Equatable, Sendable {
    var blackPoint: Double
    var whitePoint: Double

    static let identity = DisplayStretch(blackPoint: 0, whitePoint: 1)

    /// 1st/99th-percentile auto-stretch from a 256-bucket histogram (`HistogramComputer
    /// .histogram(for:)`) — the same percentile approach `GPUControlSettings.autoStretch`
    /// already uses for its own independent stretch, applied to this base stretch instead.
    /// `.identity` looks solid black on real sensor data: a real linear sensor's actual signal
    /// (sky background + stars) typically occupies a small fraction of the full digital range,
    /// especially at conservative gain — displaying the *full* range as visible tonal range makes
    /// that small fraction round down to black. `nil` on an empty/all-zero histogram (no signal
    /// to stretch to yet).
    static func autoStretch(histogram: [Int]) -> DisplayStretch? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }

        func percentile(_ fraction: Double) -> Double {
            let target = Double(total) * fraction
            var cumulative = 0
            for (bucket, count) in histogram.enumerated() {
                cumulative += count
                if Double(cumulative) >= target { return Double(bucket) / Double(histogram.count - 1) }
            }
            return 1.0
        }

        let low = percentile(0.01)
        let high = percentile(0.99)
        return DisplayStretch(blackPoint: low, whitePoint: max(high, low + 0.05))
    }

    /// Builds an 8-bit lookup table mapping a raw sample (already scaled into `0...maxValue`)
    /// to a stretched `0...255` display value.
    func lookupTable(maxValue: Int) -> [UInt8] {
        let black = blackPoint * Double(maxValue)
        let white = max(whitePoint * Double(maxValue), black + 1)
        return (0...maxValue).map { raw in
            let normalized = (Double(raw) - black) / (white - black)
            let clamped = min(max(normalized, 0), 1)
            return UInt8(clamped * 255.0)
        }
    }
}
