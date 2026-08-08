import Foundation

/// Black/white point stretch applied when mapping raw sensor data (8- or 16-bit, linear) down
/// to an 8-bit displayable image. Values are normalized fractions of the source bit depth's
/// full range, e.g. `blackPoint: 0.1, whitePoint: 0.6` on a RAW16 frame clips below 6553 and
/// above 39321, linearly stretching the rest across the visible 0...255 output range.
struct DisplayStretch: Equatable, Sendable {
    var blackPoint: Double
    var whitePoint: Double

    static let identity = DisplayStretch(blackPoint: 0, whitePoint: 1)

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
