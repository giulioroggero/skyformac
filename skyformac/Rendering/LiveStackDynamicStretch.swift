import Foundation

/// Which of the two stacking algorithms `specs/live-stackig-fix-spec.md` calls for is currently
/// active. `.average` is `LiveStacker`/`accumulateMono`'s pre-existing plain running mean;
/// `.sigmaClipping` is `accumulateMonoSigmaClipped`'s GPU-only per-pixel outlier rejection (see
/// that kernel's own doc comment) — falls back to plain averaging on the CPU render path, which
/// has no sigma-clipping implementation.
enum LiveStackMethod: String, CaseIterable, Identifiable, Sendable {
    case average
    case sigmaClipping

    var id: String { rawValue }

    var label: String {
        switch self {
        case .average: "Average"
        case .sigmaClipping: "Sigma Clipping"
        }
    }
}

/// How hard "Dynamic Auto-Stretch" pushes faint signal — the spec's "Stretch Aggressiveness:
/// [Low, Medium, High]" control. Multiplies the arcsinh intensity `LiveStackDynamicStretch
/// .compute` would otherwise land on from the stack's own dynamic range.
enum StretchAggressiveness: String, CaseIterable, Identifiable, Sendable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var intensityMultiplier: Float {
        switch self {
        case .low: 0.5
        case .medium: 1.0
        case .high: 2.0
        }
    }
}

/// The actual fix behind `specs/live-stackig-fix-spec.md`: deep-sky stacking averages away noise
/// (raising SNR) without changing pixel brightness at all — a *fixed* linear black/white stretch
/// therefore looks identical frame 1 vs. frame 200 even though the underlying data has genuinely
/// improved. This computes a **dynamic** non-linear (arcsinh/MTF-style) stretch from the stack's
/// own current histogram instead, re-run periodically as the stack grows (see
/// `CameraManager.updateContinuousLiveStackAutoStretchIfNeeded`) — so the live view visibly reveals
/// more as SNR improves, matching the SharpCap/ASIAIR/Jocular "screen transfer function" behavior
/// the spec asks for. Pure function of a histogram + two user preferences, kept separate from
/// `GPUControlSettings`'s own live `@Observable` state so this math is unit-testable without one.
enum LiveStackDynamicStretch {
    struct Result: Equatable {
        var blackPoint: Float
        var whitePoint: Float
        var stretchIntensity: Float
    }

    /// - Parameters:
    ///   - histogram: A 256-bucket histogram of the current stacked (averaged) frame —
    ///     `HistogramComputer.histogram(for:)`'s own output shape.
    ///   - aggressiveness: Scales the resulting `stretchIntensity` — see its own doc comment.
    ///   - blackPointOffset: The spec's "Auto Black Point Offset" slider — a user nudge added
    ///     directly to the computed black point (positive digs further into the background,
    ///     hiding more faint noise/glow at the cost of also hiding faint real signal near it).
    ///     Clamped so it can't push the black point past the white point.
    /// - Returns: `nil` on an empty/all-zero histogram (nothing to stretch yet — same "no signal"
    ///   case `DisplayStretch.autoStretch`/`GPUControlSettings.autoStretch` already special-case).
    static func compute(histogram: [Int], aggressiveness: StretchAggressiveness, blackPointOffset: Float) -> Result? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }

        func percentile(_ fraction: Double) -> Float {
            let target = Double(total) * fraction
            var cumulative = 0
            for (bucket, count) in histogram.enumerated() {
                cumulative += count
                if Double(cumulative) >= target { return Float(bucket) / Float(histogram.count - 1) }
            }
            return 1.0
        }

        // The sky background/noise floor sits at the histogram's own peak bucket (by far the most
        // common value in a real frame — mostly featureless background), not some fixed
        // percentile — "find the peak of the histogram... set the Black Point just to the left of
        // the peak" (spec step 5). The 1st percentile alone (what the pre-existing linear
        // `DisplayStretch.autoStretch` uses) tracks the noise floor's low tail, not its peak, and
        // barely moves as a stack's noise shrinks — which is a real part of why the existing
        // automatic re-stretch looked static.
        let peakBucket = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        let backgroundPeak = Float(peakBucket) / Float(histogram.count - 1)
        let low = max(min(backgroundPeak + blackPointOffset, 0.95), 0.0)
        let high = max(percentile(0.999), low + 0.05)

        // Same dynamic-range-to-intensity scaling `GPUControlSettings.autoStretch` already uses
        // (a narrow range — faint, low-contrast signal — gets pushed harder), just further scaled
        // by the user's chosen aggressiveness on top.
        let baseIntensity = 50.0 / max(high - low, 0.01)
        let intensity = (baseIntensity * aggressiveness.intensityMultiplier).clamped(to: 1.0...200.0)

        return Result(blackPoint: low, whitePoint: high, stretchIntensity: intensity)
    }

    /// Normalized (0...1, matching every other stretch-related value in this codebase) standard
    /// deviation of a 256-bucket histogram — `accumulateMonoSigmaClipped`'s single global
    /// per-frame noise estimate: `kappaSigma = kappa * standardDeviation(histogram:)`. `0` for an
    /// empty/all-zero histogram (nothing to estimate from — the caller's `currentCount > 2` gate
    /// means this only ever matters once real frames have already started accumulating anyway).
    static func standardDeviation(histogram: [Int]) -> Float {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let bucketCount = Float(histogram.count - 1)
        let mean = histogram.enumerated().reduce(Float(0)) { $0 + Float($1.offset) * Float($1.element) } / Float(total) / bucketCount
        let variance = histogram.enumerated().reduce(Float(0)) { partial, entry in
            let normalizedBucket = Float(entry.offset) / bucketCount
            let delta = normalizedBucket - mean
            return partial + delta * delta * Float(entry.element)
        } / Float(total)
        return variance.squareRoot()
    }
}
