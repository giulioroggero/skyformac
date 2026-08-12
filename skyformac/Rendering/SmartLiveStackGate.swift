import Foundation

/// Why `SmartLiveStackGate.decide` rejected a frame from "Smart Live Stack" — surfaced to the UI
/// so a session shows *why* frames are being skipped, not just a silent count.
enum SmartLiveStackRejectionReason: Equatable {
    /// Cloud Sentinel currently reports a brightness anomaly (a passing cloud, headlights, a
    /// bright flash) — folding this frame into the stack would bake that transient into the
    /// average rather than the actual target.
    case cloudsOrBrightFlash
    /// Sharpness fell below `qualityFraction` of the best frame this session has actually seen —
    /// seeing blur, a focus drift, wind shake, or (with Reduce Drift on) a lost tracking lock all
    /// show up as a softer frame the same way.
    case belowSharpnessThreshold

    var label: String {
        switch self {
        case .cloudsOrBrightFlash: return "possible clouds/bright flash (Cloud Sentinel)"
        case .belowSharpnessThreshold: return "below sharpness threshold"
        }
    }
}

/// Pure decision logic behind "Smart Live Stack" — kept separate from `CameraManager`'s frame
/// ingest plumbing (GPU sharpness scoring, Cloud Sentinel state) so the actual keep/reject rule is
/// unit-testable without a real camera or GPU.
///
/// The core idea: real deep-sky/planetary sessions run for a long time, and not every frame is
/// worth keeping — a gust of wind, a thin cloud drifting past, a moment of bad seeing, or Reduce
/// Drift briefly losing its lock all produce a genuinely worse frame than the session's best. The
/// traditional workflow curates this *after* the fact (PixInsight's SubframeSelector, AutoStakkert!3's
/// quality graph) from a full recorded sequence. This gates it live instead — the stack you're
/// watching build is already curated, frame by frame, as it happens.
enum SmartLiveStackGate {
    enum Decision: Equatable {
        case keep
        case reject(SmartLiveStackRejectionReason)
    }

    /// - Parameters:
    ///   - sharpnessScore: This frame's GPU Laplacian-variance sharpness score, or `nil` if it
    ///     couldn't be scored at all (e.g. an RGB24 webcam/iPhone frame — `GPUSharpnessScorer`
    ///     only supports mono ZWO RAW8/RAW16). `nil` always keeps: there's nothing to gate on.
    ///   - maxObservedScore: The sharpest score seen so far this stacking session. `0` (nothing
    ///     observed yet, e.g. the very first frame) always keeps too — there's no baseline yet to
    ///     compare against.
    ///   - qualityFraction: Keep frames scoring at least this fraction of `maxObservedScore` —
    ///     e.g. `0.5` keeps anything at least half as sharp as the best frame seen so far.
    ///   - isCloudAlertActive: Cloud Sentinel's current alert state (only meaningful when that
    ///     feature is itself enabled — the caller is responsible for that check).
    static func decide(
        sharpnessScore: Double?,
        maxObservedScore: Double,
        qualityFraction: Double,
        isCloudAlertActive: Bool
    ) -> Decision {
        if isCloudAlertActive {
            return .reject(.cloudsOrBrightFlash)
        }
        guard let sharpnessScore else { return .keep }
        guard maxObservedScore > 0 else { return .keep }
        let threshold = maxObservedScore * qualityFraction
        return sharpnessScore < threshold ? .reject(.belowSharpnessThreshold) : .keep
    }
}
