import CoreGraphics

/// Smooths `PlanetDetector`'s per-frame bounding box with an exponential moving average, so the
/// auto-center/crop ROI doesn't visibly jitter frame-to-frame from small
/// detection/seeing-driven fluctuations in the raw contour box.
final class PlanetTracker {
    private var smoothedBox: CGRect?
    /// How much each new detection moves the tracked box toward it: 0 = never updates,
    /// 1 = no smoothing (snaps straight to the latest detection).
    let smoothingFactor: CGFloat

    init(smoothingFactor: CGFloat = 0.3) {
        self.smoothingFactor = smoothingFactor
    }

    @discardableResult
    func update(with detection: CGRect?) -> CGRect? {
        guard let detection else { return smoothedBox }
        guard let current = smoothedBox else {
            smoothedBox = detection
            return detection
        }
        let a = smoothingFactor
        smoothedBox = CGRect(
            x: current.minX + (detection.minX - current.minX) * a,
            y: current.minY + (detection.minY - current.minY) * a,
            width: current.width + (detection.width - current.width) * a,
            height: current.height + (detection.height - current.height) * a
        )
        return smoothedBox
    }

    func reset() {
        smoothedBox = nil
    }
}
