import Foundation

/// The "how much longer is it worth stacking" estimate Smart Live Stack surfaces live —
/// real, well-known signal-processing math (SNR from averaging N independent-noise frames scales
/// with `sqrt(N)`), not a fabricated readout. Kept as a pure function for the same reason
/// `DriftAligner`/`ExposureOptimizer` are: the arithmetic is easy to get subtly wrong (off-by-one
/// in which count is the baseline, forgetting the percentage conversion) and is worth testing
/// directly rather than only ever exercised end-to-end.
enum StackSNREstimator {
    /// The percentage SNR improvement stacking `additionalFrames` more frames would give, relative
    /// to the `currentFrameCount` already kept — `sqrt(current + additional) / sqrt(current) - 1`,
    /// as a percentage. `nil` when there's no current baseline to measure a gain relative to.
    ///
    /// - Important: This is the same fractional gain regardless of *when* you ask relative to a
    ///   fixed doubling (going from N to 2N frames is always a ~41% SNR gain, at any N) — what
    ///   actually diminishes is the gain from a *fixed* number of additional frames as the session
    ///   goes on (the 10 frames that took you from 10 to 20 helped far more than the 10 that take
    ///   you from 200 to 210). Always call this with the same fixed `additionalFrames` (e.g. "the
    ///   next 20") to get an honest, falling-over-time "is this still worth it" trend — comparing
    ///   across different `additionalFrames` values isn't meaningful.
    static func relativeSNRGainPercent(currentFrameCount: Int, additionalFrames: Int) -> Double? {
        guard currentFrameCount > 0, additionalFrames >= 0 else { return nil }
        let current = Double(currentFrameCount)
        let projected = current + Double(additionalFrames)
        return (projected.squareRoot() / current.squareRoot() - 1) * 100
    }
}
