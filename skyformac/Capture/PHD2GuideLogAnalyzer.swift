import Foundation

/// Diagnostics computed from a parsed `PHD2GuideLogSession` — the multi-session periodogram and
/// orthogonality readouts this app's own guiding tools (manual pulse-guiding only, see
/// `ControlsPanelView`'s own doc comment) have no equivalent for, since there's no closed-loop
/// autoguiding here to generate this kind of log from directly. Reads an *imported* PHD2 log
/// instead — this app doesn't need to run PHD2 itself to benefit from having guided with it.
enum PHD2GuideLogAnalyzer {
    struct Stats {
        var rmsRA: Double
        var rmsDec: Double
        var rmsTotal: Double
        var peakRA: Double
        var peakDec: Double
        /// Pearson correlation between the RA and Dec error series, -1...1. A well-orthogonal
        /// mount/guide-camera setup should show this close to 0 — RA and Dec drift are physically
        /// independent axes, so a strong correlation either way points at real cross-talk (a
        /// guide camera that isn't actually square to the mount's RA/Dec axes, most commonly).
        var orthogonality: Double
    }

    struct PeriodogramPoint: Identifiable {
        var id: Double { periodSeconds }
        var periodSeconds: Double
        var power: Double
    }

    static func stats(for session: PHD2GuideLogSession) -> Stats {
        let ra = session.frames.map(\.raDistance)
        let dec = session.frames.map(\.decDistance)
        return Stats(
            rmsRA: rootMeanSquare(ra), rmsDec: rootMeanSquare(dec),
            rmsTotal: rootMeanSquare(zip(ra, dec).map { ($0 * $0 + $1 * $1).squareRoot() }),
            peakRA: ra.map(abs).max() ?? 0, peakDec: dec.map(abs).max() ?? 0,
            orthogonality: pearsonCorrelation(ra, dec)
        )
    }

    /// A basic periodogram (unnormalized Lomb-Scargle-style amplitude spectrum) over
    /// `minPeriodSeconds...maxPeriodSeconds` — deliberately not a plain FFT, since PHD2's own
    /// frame timestamps are rarely perfectly uniformly spaced (guide star SNR/exposure time
    /// varies frame to frame) and this handles that directly rather than needing a resampling
    /// step first. Default range (60–600s) covers the worm-gear periods realistic amateur mounts
    /// actually have; `stepCount` trades resolution for compute (this is O(samples × stepCount),
    /// trivially fast for a single guiding session's worth of frames either way).
    static func periodogram(
        times: [Double], values: [Double], minPeriodSeconds: Double = 60, maxPeriodSeconds: Double = 600, stepCount: Int = 120
    ) -> [PeriodogramPoint] {
        guard times.count == values.count, times.count > 4, stepCount > 1 else { return [] }
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        var points: [PeriodogramPoint] = []
        points.reserveCapacity(stepCount)
        for step in 0..<stepCount {
            let period = minPeriodSeconds + (maxPeriodSeconds - minPeriodSeconds) * Double(step) / Double(stepCount - 1)
            var sumCos = 0.0
            var sumSin = 0.0
            for (t, v) in zip(times, centered) {
                let phase = 2 * Double.pi * t / period
                sumCos += v * cos(phase)
                sumSin += v * sin(phase)
            }
            let n = Double(values.count)
            let power = (sumCos * sumCos + sumSin * sumSin) / (n * n)
            points.append(PeriodogramPoint(periodSeconds: period, power: power))
        }
        return points
    }

    private static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    private static func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for i in 0..<a.count {
            let da = a[i] - meanA
            let db = b[i] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        let denominator = (varianceA * varianceB).squareRoot()
        return denominator == 0 ? 0 : covariance / denominator
    }
}
