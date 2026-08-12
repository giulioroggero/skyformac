import Foundation

/// A single user-editable control point on a `ToneCurve`, both coordinates normalized 0...1.
struct CurvePoint: Equatable, Sendable {
    var x: Double
    var y: Double
}

/// One channel's tone curve (Photoshop-style "Curves") — a small set of user-placed control
/// points, sampled into a 256-entry lookup table for display. This is a post-stretch grading
/// tool, layered on top of the Black/White Point stretch (`DisplayStretch`/`PerChannelStretch`)
/// rather than replacing it: the stretch sets the overall exposure range, curves shape the
/// tonality within it (e.g. lifting shadows, rolling off highlights) — the same two-stage
/// division most photo tools make between "levels" and "curves".
struct ToneCurve: Equatable, Sendable {
    var points: [CurvePoint]

    static let identity = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])

    /// Samples a monotonic cubic Hermite spline (Fritsch-Carlson) through `points` into a
    /// 256-entry 0...255 output lookup table.
    ///
    /// Monotonic, not a plain natural cubic spline, on purpose: a natural spline can overshoot
    /// between widely-spaced hand-placed points and locally *reverse* brightness order (a higher
    /// input mapping to a lower output than a slightly darker one right next to it) — a visible
    /// banding/posterization artifact in a live preview. Fritsch-Carlson clamps each segment's
    /// tangents so the interpolated curve never does that, at the cost of not passing through a
    /// perfectly smooth "ideal" spline shape — the right trade for a tool with only a handful of
    /// points, not hundreds of samples.
    func lookupTable() -> [UInt8] {
        let sorted = points.sorted { $0.x < $1.x }
        var deduped: [CurvePoint] = []
        for point in sorted {
            if let last = deduped.last, abs(last.x - point.x) < 1e-9 {
                deduped[deduped.count - 1] = point
            } else {
                deduped.append(point)
            }
        }

        guard deduped.count >= 2 else {
            return (0...255).map { UInt8($0) }
        }

        let xs = deduped.map { $0.x }
        let ys = deduped.map { $0.y }
        let n = xs.count

        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = xs[i + 1] - xs[i]
            secants[i] = dx > 0 ? (ys[i + 1] - ys[i]) / dx : 0
        }

        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2
        }
        for i in 0..<(n - 1) {
            guard secants[i] != 0 else {
                tangents[i] = 0
                tangents[i + 1] = 0
                continue
            }
            let a = tangents[i] / secants[i]
            let b = tangents[i + 1] / secants[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                tangents[i] = t * a * secants[i]
                tangents[i + 1] = t * b * secants[i]
            }
        }

        func hermite(_ x: Double) -> Double {
            if x <= xs[0] { return ys[0] }
            if x >= xs[n - 1] { return ys[n - 1] }
            var i = 0
            while i < n - 2 && x > xs[i + 1] { i += 1 }
            let dx = xs[i + 1] - xs[i]
            let t = (x - xs[i]) / dx
            let t2 = t * t
            let t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            return h00 * ys[i] + h10 * dx * tangents[i] + h01 * ys[i + 1] + h11 * dx * tangents[i + 1]
        }

        return (0...255).map { sample in
            let x = Double(sample) / 255.0
            let y = min(max(hermite(x), 0), 1)
            return UInt8((y * 255.0).rounded())
        }
    }
}

/// A master ("RGB") curve plus three independent per-channel curves, matching the layered
/// convention most curve-grading tools use: the master curve applies to all three channels
/// identically, and is composed with (applied before) each channel's own independent curve —
/// so a per-channel tweak sits on top of whatever master grading is already dialed in, rather
/// than replacing it.
struct ChannelToneCurves: Equatable, Sendable {
    var master: ToneCurve = .identity
    var red: ToneCurve = .identity
    var green: ToneCurve = .identity
    var blue: ToneCurve = .identity

    static let identity = ChannelToneCurves()

    var effectiveRedLUT: [UInt8] { Self.compose(master, red) }
    var effectiveGreenLUT: [UInt8] { Self.compose(master, green) }
    var effectiveBlueLUT: [UInt8] { Self.compose(master, blue) }

    private static func compose(_ first: ToneCurve, _ second: ToneCurve) -> [UInt8] {
        let firstLUT = first.lookupTable()
        let secondLUT = second.lookupTable()
        return firstLUT.map { secondLUT[Int($0)] }
    }
}
