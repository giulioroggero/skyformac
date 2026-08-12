import simd

/// Pure math behind live-stack drift reduction — kept separate from `MetalFrameRenderer`'s GPU
/// dispatch/readback plumbing (`findBrightestPoint`/`computeCentroid`/`computeDriftShift`) so the
/// actual arithmetic is unit-testable without a real `MTLDevice`. See `MetalFrameRenderer`'s
/// "Drift reduction" section for how this fits into the GPU live-stack accumulate pass.
enum DriftAligner {
    /// Weighted intensity centroid from summed `(sumI, sumIx, sumIy)` partials — `nil` if there's
    /// essentially no signal in the region (the tracked star was lost, e.g. behind a cloud, or
    /// the tracking ROI has drifted onto empty sky), so the caller can fall back to unaligned
    /// accumulation for that frame instead of dividing by ~zero.
    static func centroid(sumI: Float, sumIx: Float, sumIy: Float, minimumSignal: Float = 0.001) -> SIMD2<Float>? {
        guard sumI > minimumSignal else { return nil }
        return SIMD2<Float>(sumIx / sumI, sumIy / sumI)
    }

    /// How far `current` has drifted from `reference` — the shift `accumulateMonoAligned` samples
    /// the source texture by, so the drifted star lands back where the reference (first stacked)
    /// frame had it. Deliberately just a subtraction (not clamped/smoothed) — the caller is
    /// responsible for deciding whether a given frame's estimate is trustworthy enough to use at
    /// all (see `centroid`'s `nil` case).
    static func shift(current: SIMD2<Float>, reference: SIMD2<Float>) -> SIMD2<Float> {
        current - reference
    }

    /// The brightest of a set of per-threadgroup `(maxValue, x, y)` partials, or `nil` if every
    /// partial reports non-positive brightness (an all-black/no-signal frame) — used to pick the
    /// initial lock-on point on the first frame of a stacking session, before any reference
    /// centroid exists yet to search a small ROI around instead.
    static func brightestPoint(partials: [SIMD3<Float>]) -> SIMD2<Float>? {
        guard let best = partials.max(by: { $0.x < $1.x }), best.x > 0 else { return nil }
        return SIMD2<Float>(best.y, best.z)
    }

    /// Turns a region's raw `(sum, sumOfSquares, count)` (`roiStatsPartial`'s GPU reduction,
    /// combined across threadgroups on the CPU side) into a sigma-clipped background level and
    /// threshold — `centroidPartial` then only weights pixels brighter than `threshold`, by how
    /// far above `background` they are. `nil` for an empty region (`count <= 0`), which the
    /// caller should treat the same as "no usable signal" rather than divide by zero.
    ///
    /// - Important: This is the actual fix for drift reduction's centroid silently tracking
    ///   nothing — a plain intensity-weighted centroid over a whole ROI is dominated by the sky
    ///   background (far more pixels than the star occupies), not the star itself, so the
    ///   "tracked" position barely moves frame to frame regardless of where the star actually is.
    ///   Excluding everything but a few sigma above the local background before weighting is what
    ///   makes the centroid track the star instead of the ROI's own geometric center.
    static func backgroundThreshold(sum: Float, sumOfSquares: Float, count: Float, sigmaMultiplier: Float = 3.0) -> (background: Float, threshold: Float)? {
        guard count > 0 else { return nil }
        let mean = sum / count
        // Population variance from the two raw moments (E[X^2] - E[X]^2); clamped at 0 since
        // floating-point cancellation can otherwise nudge a near-uniform region's variance
        // slightly negative.
        let variance = max(sumOfSquares / count - mean * mean, 0)
        let stddev = variance.squareRoot()
        return (background: mean, threshold: mean + sigmaMultiplier * stddev)
    }
}
