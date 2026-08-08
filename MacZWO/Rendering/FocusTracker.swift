import Foundation
import Observation

struct HFDSample: Sendable {
    let timestamp: Date
    let medianHFD: Double
}

/// Keeps a rolling history of median-HFD samples and flags "thermal drift" — focus quietly
/// getting worse over time, typically from a telescope tube/mirror cell shrinking or expanding
/// as the ambient temperature changes through a session — via a simple linear-regression trend
/// over the most recent samples.
///
/// `@Observable` so SwiftUI picks up changes even though `CameraManager` (also `@Observable`)
/// only holds this as a `let` reference — Swift's Observation framework tracks nested
/// `@Observable` objects transitively when their properties are read from a view.
@Observable
final class FocusTracker {
    private(set) var samples: [HFDSample] = []
    private let maxSamples: Int

    init(maxSamples: Int = 300) {
        self.maxSamples = maxSamples
    }

    func record(medianHFD: Double, at date: Date) {
        samples.append(HFDSample(timestamp: date, medianHFD: medianHFD))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func reset() {
        samples.removeAll()
    }

    /// `true` if HFD has been trending upward (worsening) over the last `window` samples faster
    /// than `thresholdPerMinute` — e.g. the default 0.5 px/minute means focus drifting by half a
    /// pixel of HFD every minute, worth a "recheck focus" nudge on longer imaging sessions.
    func isDriftDetected(window: Int = 20, thresholdPerMinute: Double = 0.5) -> Bool {
        trendPerMinute(window: window).map { $0 > thresholdPerMinute } ?? false
    }

    /// The regression slope itself (HFD pixels/minute), for display — positive means worsening.
    func trendPerMinute(window: Int = 20) -> Double? {
        let recent = samples.suffix(window)
        guard recent.count >= 5, let first = recent.first else { return nil }

        let xs = recent.map { $0.timestamp.timeIntervalSince(first.timestamp) / 60.0 }
        let ys = recent.map { $0.medianHFD }
        let n = Double(xs.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return nil }
        return (n * sumXY - sumX * sumY) / denominator
    }
}
