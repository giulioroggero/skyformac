import SwiftUI

/// One currently-running capture pipeline — Live Stack, Lucky Imaging, Recording to Disk, SER
/// recording, Planetary Tracking, Polar Alignment, Cloud Sentinel, or Focus Assist — surfaced by
/// `ActivePipelinesView` right next to the camera in the left sidebar (see that view's doc
/// comment for why there, not just in the right-hand Controls tabs).
struct ActivePipelineStatus: Identifiable {
    var id: String
    var icon: String
    var title: String
    var detail: String
    /// Which `SidebarTab` this pipeline's own controls live under — "Focus Control" jumps here.
    var tab: SidebarTab
    var stop: () -> Void
}

extension CameraManager {
    /// Every currently-running pipeline this camera is in the middle of, for `ActivePipelinesView`.
    /// Modifiers of a pipeline (Smart Live Stack/Reduce Drift/Mesh Drift Correction are all
    /// specifically Live Stack's own settings, not independent pipelines of their own) fold into
    /// that pipeline's `detail` string rather than getting their own row — Cloud Sentinel and
    /// Focus Assist are the two genuinely independent *continuous monitoring* processes that
    /// aren't a modifier of anything else, so they do get their own rows.
    var activePipelineStatuses: [ActivePipelineStatus] {
        var statuses: [ActivePipelineStatus] = []

        if isLiveStackingEnabled {
            var detail = "\(liveStackedFrameCount) frames"
            if isLiveStackPaused { detail += " · Paused" }
            if isSmartLiveStackEnabled {
                detail += " · Autopilot"
                if smartStackRejectedCount > 0 {
                    detail += " (\(smartStackRejectedCount) rejected"
                    if let reason = smartStackLastRejectionReason {
                        detail += ": \(reason.label)"
                    }
                    detail += ")"
                }
            }
            if isMeshDriftCorrectionEnabled {
                detail += " · Mesh Drift"
            } else if isLiveStackDriftReductionEnabled {
                detail += " · Reduce Drift"
            }
            statuses.append(ActivePipelineStatus(
                id: "liveStack", icon: "square.stack.3d.up.fill", title: "Live Stack", detail: detail,
                tab: .deepSky, stop: { [weak self] in self?.isLiveStackingEnabled = false }
            ))
        }

        if let progress = luckyImagingProgress {
            // `luckyImagingSession` (and so `luckyImagingProgress`) stays non-nil after the burst
            // itself finishes filling — it's held ready for `stackLuckyImagingBest` to be called
            // (possibly more than once, with different fractions) until explicitly discarded —
            // so this reflects that instead of implying a capture is still actively running.
            let detail = progress.captured >= progress.total
                ? "Burst complete (\(progress.total) frames) — ready to stack"
                : "\(progress.captured) / \(progress.total) frames"
            statuses.append(ActivePipelineStatus(
                id: "luckyImaging", icon: "bolt.badge.clock.fill", title: "Lucky Imaging", detail: detail,
                tab: .planetary, stop: { [weak self] in self?.discardLuckyImagingSession() }
            ))
        }

        if isRecordingToDisk {
            statuses.append(ActivePipelineStatus(
                id: "recordToDisk", icon: "record.circle.fill", title: "Recording to Disk", detail: "Continuous FITS recording",
                tab: .deepSky, stop: { [weak self] in self?.stopRecording() }
            ))
        }

        if isRecordingSERVideo {
            statuses.append(ActivePipelineStatus(
                id: "serRecording", icon: "video.fill", title: "SER Recording", detail: "Video capture in progress",
                tab: .planetary, stop: { [weak self] in self?.stopSERRecording() }
            ))
        }

        if isPlanetaryTrackingEnabled {
            statuses.append(ActivePipelineStatus(
                id: "planetaryTracking", icon: "scope", title: "Planetary Tracking", detail: "Auto-centering on the tracked disk",
                tab: .planetary, stop: { [weak self] in self?.isPlanetaryTrackingEnabled = false }
            ))
        }

        if polarAlignmentStage != .idle {
            let detail = polarAlignmentStage == .firstFrameCaptured ? "Waiting for the second frame" : "Complete"
            statuses.append(ActivePipelineStatus(
                id: "polarAlignment", icon: "location.north.line.fill", title: "Polar Alignment", detail: detail,
                tab: .deepSky, stop: { [weak self] in self?.resetPolarAlignment() }
            ))
        }

        if isCloudSentinelEnabled {
            statuses.append(ActivePipelineStatus(
                id: "cloudSentinel", icon: "cloud.fill", title: "Cloud Sentinel", detail: "Monitoring for cloud/glare interruption",
                tab: .deepSky, stop: { [weak self] in self?.isCloudSentinelEnabled = false }
            ))
        }

        if isFocusAssistEnabled {
            var detail = focusAssist?.medianStarDiameterPixels
                .map { "Median star diameter \(String(format: "%.1f", $0))px" } ?? "Waiting for a star"
            if let latestHFD = focusTracker.samples.last?.medianHFD {
                detail += String(format: " · HFD %.2fpx", latestHFD)
                if isFocusDriftDetected {
                    detail += " — thermal drift"
                }
            }
            statuses.append(ActivePipelineStatus(
                id: "focusAssist",
                icon: isFocusDriftDetected ? "thermometer.sun.fill" : "camera.metering.center.weighted",
                title: "Focus Assist", detail: detail,
                tab: .improvements, stop: { [weak self] in self?.isFocusAssistEnabled = false }
            ))
        }

        return statuses
    }
}

/// "What's actually running right now" — shown right next to the camera in the left sidebar
/// (`CameraListView`), not tucked away in the right-hand Controls tabs, the same "lives where the
/// camera itself is" reasoning `CameraListView.acquisitionSection`'s own doc comment already
/// uses. A pipeline left running from a previous session (or just easy to forget about once its
/// tab isn't the one showing) is otherwise invisible until you go looking for it; this makes it
/// impossible to miss, and one click away from being turned off, right where you're already
/// looking at the camera itself.
struct ActivePipelinesView: View {
    var cameraManager: CameraManager
    @AppStorage("sidebarTab") private var tab: SidebarTab = .cameraControls

    var body: some View {
        let statuses = cameraManager.activePipelineStatuses
        if !statuses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Running").font(.headline)
                ForEach(statuses) { status in
                    row(status)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ status: ActivePipelineStatus) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Image(systemName: status.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title).font(.caption.bold())
                Text(status.detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                tab = status.tab
            } label: {
                Image(systemName: "arrow.forward.circle")
            }
            .buttonStyle(.plain)
            .help("Jump to \(status.tab.shortLabel)'s controls for this")
            Button {
                status.stop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Stop \(status.title)")
        }
        .padding(.vertical, 2)
    }
}
