import Foundation

/// Pure, testable rolling-baseline brightness tracker behind the main-pipeline "Cloud & Drift
/// Sentinel" (see `specs/skyformac_AI_Features_Pipeline_Spec.md` Feature 5) — the same detection
/// math `AllSkyMonitor` already uses for its own cloud/light alert (`AllSkyAnalyzer`), applied to
/// the primary ZWO/webcam capture pipeline instead of a secondary monitor camera, so a sudden
/// drop in sky brightness (dense cloud rolling in) can pause an unattended imaging session and
/// notify instead of silently recording a stack of ruined frames.
///
/// - Important: There's no dedicated "drift" signal here despite the name — cable/mount drift is
///   already covered by `AllSkyAnalyzer.isMotionAlert` on the All-Sky monitor's own secondary
///   camera (a stationary framing you can compare frame-to-frame); the *main* imaging camera's
///   framing is expected to change as it tracks/slews, so frame-to-frame differencing on it would
///   false-positive on every intentional mount move. "Drift" in the name follows the spec's own
///   naming for this feature; what it actually implements is the brightness half.
final class CloudDriftSentinel {
    private(set) var baseline: Double?
    private(set) var isAlerting = false

    /// Feeds one brightness sample (roughly 0...255) and updates the rolling baseline exactly
    /// like `AllSkyMonitor.applyAnalysis` does: an unconditional slow exponential moving average,
    /// every sample, alerting or not — so the baseline keeps drifting with dawn/dusk without
    /// itself being fooled by short-lived events, at the cost of eventually absorbing a
    /// *sustained* cloud bank as "the new normal" and self-clearing. That's an accepted,
    /// already-shipped tradeoff (see `AllSkyMonitor`), not a new one introduced here.
    ///
    /// Returns `true` exactly on the transition into an alert (not on every sample while already
    /// alerting), so callers can fire a one-shot pause/notification instead of one per frame.
    @discardableResult
    func evaluate(brightness: Double) -> Bool {
        if let baseline {
            self.baseline = baseline * 0.98 + brightness * 0.02
        } else {
            baseline = brightness
        }
        let alerting = AllSkyAnalyzer.isCloudOrLightAlert(currentBrightness: brightness, baseline: baseline ?? brightness)
        let justStarted = alerting && !isAlerting
        isAlerting = alerting
        return justStarted
    }

    func reset() {
        baseline = nil
        isAlerting = false
    }
}
