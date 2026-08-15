import Foundation

/// Plain value snapshot of `GPUControlSettings`, threaded through `MetalPreviewView.pendingUpdate`
/// into `MetalFrameRenderer` — mirrors how `sharpenAmount`/`isDenoisingEnabled` etc. are already
/// passed as primitives rather than handing the renderer a live `@Observable` reference.
struct GPULiveControlsSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    var temporalAlpha: Float
    var spatialSigma: Float
    var rangeSigma: Float
    var stretchIntensity: Float
    var blackPoint: Float
    var whitePoint: Float
}

/// State for the "Live GPU Enhancement Controls" panel (see
/// `specs/skyformac_GPU_Live_Controls_Spec.md`): a three-stage GPU pipeline — temporal (EMA)
/// denoise, spatial (bilateral) denoise, and an arcsinh non-linear contrast stretch — independent
/// of the pre-existing "Image Enhancement" (bilateral denoise / wavelet sharpen) controls and the
/// base `DisplayStretch` black/white sliders. See `MetalFrameRenderer`'s doc comments for exactly
/// how each stage is wired into the render pipeline, and the spec file itself for two deliberate
/// deviations from its literal text (no `MPSImageBilateralScale` — it doesn't exist in
/// `MetalPerformanceShaders` — and additive layering rather than outright replacement of the
/// existing linear stretch).
@Observable
final class GPUControlSettings {
    /// Defaults to `false`, unlike the spec's literal `= true` — every other visually-altering
    /// toggle in this app (`isDenoisingEnabled`, `isWaveletSharpeningEnabled`) starts opt-in, and
    /// a brand new three-stage pipeline silently changing everyone's live view the first time
    /// they update the app would be a surprising default to ship.
    var isEnabled = AppSettings.isLiveGPUControlsEnabled {
        didSet { AppSettings.isLiveGPUControlsEnabled = isEnabled }
    }

    /// Stage 1 (temporal EMA blend factor): 0.01 (heavy smoothing, slow to react to real motion)
    /// to 1.0 (instant passthrough, no smoothing).
    var temporalAlpha: Float = AppSettings.gpuTemporalAlpha {
        didSet {
            // `didSet` fires on *every* assignment, including ones made from inside itself — so
            // `temporalAlpha = temporalAlpha.clamped(...)` unconditionally, with no check that
            // the value actually changed, recurses forever (verified the hard way: it stack-
            // overflowed a background test run). Every property below guards the self-reassignment
            // the same way: compute the clamped value into a local, and only write back — which
            // re-enters `didSet` exactly once more — when it actually differs; the second entry
            // then finds the clamp already idempotent and stops.
            let clamped = temporalAlpha.clamped(to: 0.01...1.0)
            guard clamped != temporalAlpha else {
                AppSettings.gpuTemporalAlpha = temporalAlpha
                return
            }
            temporalAlpha = clamped
        }
    }

    /// Stage 2 (spatial bilateral denoise) — reuses `Shaders.metal`'s existing `bilateralDenoise`
    /// kernel (see the spec file's deviation note) with these user-adjustable parameters, as an
    /// independent stage from the "Image Enhancement" section's own (fixed-parameter) use of the
    /// same kernel.
    var spatialSigma: Float = AppSettings.gpuSpatialSigma {
        didSet {
            let clamped = spatialSigma.clamped(to: 1.0...10.0)
            guard clamped != spatialSigma else {
                AppSettings.gpuSpatialSigma = spatialSigma
                return
            }
            spatialSigma = clamped
        }
    }
    var rangeSigma: Float = AppSettings.gpuRangeSigma {
        didSet {
            let clamped = rangeSigma.clamped(to: 0.01...0.50)
            guard clamped != rangeSigma else {
                AppSettings.gpuRangeSigma = rangeSigma
                return
            }
            rangeSigma = clamped
        }
    }

    /// Stage 3 (arcsinh non-linear stretch): 1.0 (linear, a no-op) to 200.0 (extreme boost).
    var stretchIntensity: Float = AppSettings.gpuStretchIntensity {
        didSet {
            let clamped = stretchIntensity.clamped(to: 1.0...200.0)
            guard clamped != stretchIntensity else {
                AppSettings.gpuStretchIntensity = stretchIntensity
                return
            }
            stretchIntensity = clamped
        }
    }

    /// Guardrails (spec section 6): `whitePoint` can never drop within 0.05 of `blackPoint` (a
    /// near-zero denominator would blow the stretch up to near-solid white/noise), and never
    /// below 0.10 outright. Each setter re-clamps the *other* property when needed rather than
    /// just itself, so the invariant holds no matter which one changes; both setters converge
    /// (verified in `GPUControlSettingsTests`) since each only nudges the other when the
    /// invariant is actually violated, and every self-reassignment is itself guarded against
    /// re-firing when already idempotent (see `temporalAlpha`'s doc comment above).
    var blackPoint: Float = AppSettings.gpuBlackPoint {
        didSet {
            let clamped = blackPoint.clamped(to: 0...0.4)
            guard clamped == blackPoint else {
                blackPoint = clamped // re-enters didSet once more, now idempotent
                return
            }
            if whitePoint < blackPoint + 0.05 { whitePoint = blackPoint + 0.05 }
            AppSettings.gpuBlackPoint = blackPoint
        }
    }
    var whitePoint: Float = AppSettings.gpuWhitePoint {
        didSet {
            let clamped = max(whitePoint, 0.10)
            guard clamped == whitePoint else {
                whitePoint = clamped // re-enters didSet once more, now idempotent
                return
            }
            if whitePoint < blackPoint + 0.05 { blackPoint = whitePoint - 0.05 }
            AppSettings.gpuWhitePoint = whitePoint
        }
    }

    var snapshot: GPULiveControlsSnapshot {
        GPULiveControlsSnapshot(
            isEnabled: isEnabled, temporalAlpha: temporalAlpha, spatialSigma: spatialSigma,
            rangeSigma: rangeSigma, stretchIntensity: stretchIntensity,
            blackPoint: blackPoint, whitePoint: whitePoint
        )
    }

    /// "Auto-Stretch Safety Lock" (spec section 5): sets `blackPoint`/`whitePoint` to the 1st/99th
    /// percentile of `histogram` (a 256-bucket count array, e.g. `CameraManager.gpuHistogramCounts`
    /// or `HistogramComputer.histogram(for:)`) and scales `stretchIntensity` to the resulting
    /// dynamic range, so a wide (already well-exposed) range gets a gentle boost and a narrow
    /// (low-contrast/low-light) one gets pushed harder. No-op on an empty/all-zero histogram.
    func autoStretch(histogram: [Int]) {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return }

        func percentile(_ fraction: Double) -> Float {
            let target = Double(total) * fraction
            var cumulative = 0
            for (bucket, count) in histogram.enumerated() {
                cumulative += count
                if Double(cumulative) >= target { return Float(bucket) / Float(histogram.count - 1) }
            }
            return 1.0
        }

        let low = percentile(0.01)
        let high = percentile(0.99)
        blackPoint = low
        whitePoint = max(high, low + 0.05)
        stretchIntensity = (50.0 / max(whitePoint - blackPoint, 0.01)).clamped(to: 1.0...200.0)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
