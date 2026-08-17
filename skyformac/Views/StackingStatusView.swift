import SwiftUI

/// A live, read-only dashboard for what Live Stack is doing right now — frame count, which
/// method/rejection settings are active, and Smart Live Stack's kept/rejected counts — as its own
/// tab alongside Histogram/Curves. Modeled on SharpCap Pro's live-stacking panel, which dedicates
/// its own "Stacking" tab to exactly this instead of burying it in a settings sidebar.
///
/// Deliberately status-only, not a second copy of the on/off switches and thresholds: those stay
/// in `ControlsPanelView`'s "Live Stack" `DisclosureGroup`, which is already dense (~20 controls
/// across toggles/sliders/pickers for stacking method, drift reduction, mesh correction, dynamic
/// auto-stretch, and Smart Live Stack) — the actual reason this is a new histogram-panel tab
/// rather than yet another sub-section crammed into that same disclosure.
struct StackingStatusView: View {
    var cameraManager: CameraManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if cameraManager.isLiveStackingEnabled {
                    statusContent
                } else {
                    ContentUnavailableView(
                        "Live Stack Isn't Running", systemImage: "square.stack.3d.up.slash",
                        description: Text("Turn on Live Stack in Controls to see its status here.")
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        LabeledContent("Frames Stacked", value: "\(cameraManager.liveStackedFrameCount)")
        LabeledContent("Method", value: cameraManager.liveStackMethod.label)
        if cameraManager.liveStackMethod == .sigmaClipping {
            LabeledContent("Sigma Clipping (κ)", value: String(format: "%.1f", cameraManager.liveStackSigmaClippingKappa))
        }
        if cameraManager.isLiveStackPaused {
            Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
        }
        if cameraManager.isMeshDriftCorrectionEnabled {
            Label("Mesh Drift Correction active", systemImage: "grid")
        } else if cameraManager.isLiveStackDriftReductionEnabled {
            Label("Reduce Drift active", systemImage: "scope")
        }

        if cameraManager.isLiveStackAutoStretchContinuous {
            Divider()
            Label("Dynamic Auto-Stretch", systemImage: "wand.and.rays").font(.headline)
            LabeledContent("Aggressiveness", value: cameraManager.liveStackStretchAggressiveness.label)
            if cameraManager.isLiveStackAutoColorBalanceEnabled {
                Label("Auto Color Balance on", systemImage: "paintpalette")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if cameraManager.isSmartLiveStackEnabled {
            Divider()
            Label("Smart Live Stack (Autopilot)", systemImage: "sparkles").font(.headline)
            HStack {
                Label("\(cameraManager.smartStackKeptCount) kept", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Label("\(cameraManager.smartStackRejectedCount) rejected", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let reason = cameraManager.smartStackLastRejectionReason, cameraManager.smartStackRejectedCount > 0 {
                Text("Last rejection: \(reason.label)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let gain = cameraManager.smartStackEstimatedSNRGainPercent(forAdditionalFrames: 20) {
                Text(String(format: "Estimated SNR gain from 20 more frames: +%.1f%%", gain))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
