import AppKit
import SwiftUI

/// Which tool sections `ControlsPanelView` shows for a given `ControlMode` — a light filter over
/// an otherwise-flat list of ~15 `DisclosureGroup`s, so a planetary imaging session isn't stuck
/// scrolling past live-stacking/polar-alignment controls it'll never touch, and vice versa.
/// `.all` is the escape hatch: nothing is ever actually removed, just organized by default.
enum ControlMode: String, CaseIterable, Identifiable {
    case general = "General"
    case planetary = "Planetary"
    case deepSky = "Deep Sky"
    case all = "All Tools"

    var id: String { rawValue }
}

enum ToolSection: CaseIterable {
    case focusAssist, smartExposure, planetary, polarAlignment, enhancement
    case darkFrame, liveStack, luckyImaging, recording, liveGPU, aiSuite

    func isVisible(in mode: ControlMode) -> Bool {
        switch mode {
        case .all: return true
        case .general: return [.focusAssist, .smartExposure, .darkFrame, .liveGPU, .aiSuite].contains(self)
        case .planetary: return [.planetary, .enhancement, .luckyImaging, .recording].contains(self)
        case .deepSky: return [.focusAssist, .smartExposure, .darkFrame, .liveStack, .polarAlignment, .liveGPU, .aiSuite].contains(self)
        }
    }
}

/// Dynamically builds one control (slider/toggle) per `ASI_CONTROL_CAPS` the connected camera
/// reports, rather than hardcoding gain/exposure/cooler fields — per spec Milestone 3. A handful
/// of well-known control types (exposure, cooler on/off, temperature) get a friendlier
/// presentation than a raw min/max slider; everything else falls back to a generic slider.
///
/// Also hosts the capture-tools stack built on top of the raw capture pipeline: dark-frame
/// subtraction, live stacking, lucky imaging, and export — all documented inline with the
/// scoping caveats that apply (no geometric alignment in stacking/lucky-imaging, FITS carries
/// raw sensor data rather than the debayered preview, etc). "Single Exposure", "Export", and the
/// dynamic per-camera controls always show, regardless of `ControlMode` — everything else is
/// filtered by `ToolSection.isVisible(in:)`.
struct ControlsPanelView: View {
    var cameraManager: CameraManager
    @AppStorage("controlMode") private var mode: ControlMode = .general

    @AppStorage("exposureSeconds") private var exposureSeconds: Double = 1.0
    @AppStorage("darkFrameSeconds") private var darkFrameSeconds: Double = 1.0
    @AppStorage("flatFrameSeconds") private var flatFrameSeconds: Double = 0.5
    @AppStorage("luckyBurstCount") private var luckyBurstCount: Double = 30
    @AppStorage("luckyKeepFraction") private var luckyKeepFraction: Double = 0.2

    @State private var showFocusAssistSection = false
    @State private var showDarkFrameSection = false
    @State private var showLiveStackSection = false
    @State private var showLuckyImagingSection = false
    @State private var showExportSection = false
    @State private var showRecordingSection = false
    @AppStorage("recordingThreshold") private var recordingThreshold: Double = 0
    @State private var showSmartExposureSection = false
    @State private var showPlanetarySection = false
    @State private var showPolarAlignmentSection = false
    @State private var showEnhancementSection = false
    @State private var showLiveGPUSection = false
    @State private var showAISuiteSection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cameraManager.connectedCamera != nil {
                // This used to be the first row *inside* the `ScrollView` below — first a
                // `Picker(selection:)` with `.pickerStyle(.menu)` (an `NSPopUpButton`), then a
                // `Menu`, both reported to reliably fail to open (no menu, on any click count)
                // specifically there, while an identical menu-bar `Picker`/`Button` set bound to
                // the same `@AppStorage("controlMode")` key (`SkyformacCommands`'s Mode menu)
                // always worked — ruling out the state/binding and pointing at *that screen
                // position* (the very first view inside this pane's `ScrollView`, directly under
                // the window's toolbar) rather than either control itself. Moved out of the
                // `ScrollView` entirely, into its own fixed header row above it, so it's not the
                // scroll content's first pixel anymore — also better UX, since the mode stays
                // visible and clickable while the tool list below it scrolls.
                HStack {
                    Text("Mode")
                    Spacer()
                    Menu(mode.rawValue) {
                        ForEach(ControlMode.allCases) { candidate in
                            Button {
                                mode = candidate
                            } label: {
                                if candidate == mode {
                                    Label(candidate.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(candidate.rawValue)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .help("Filters which tool sections below are shown — nothing is ever disabled, \"All Tools\" always shows everything.")
                .padding(.horizontal)
                .padding(.vertical, 10)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if cameraManager.connectedCamera != nil {
                        singleExposureSection
                        Divider()

                        if ToolSection.focusAssist.isVisible(in: mode) {
                            DisclosureGroup("Focus Assist", isExpanded: $showFocusAssistSection) {
                                focusAssistSection
                            }
                            Divider()
                        }
                        if ToolSection.smartExposure.isVisible(in: mode) {
                            DisclosureGroup("Smart Exposure", isExpanded: $showSmartExposureSection) {
                                smartExposureSection
                            }
                            Divider()
                        }
                        if ToolSection.planetary.isVisible(in: mode) {
                            DisclosureGroup("Planetary Auto-Center", isExpanded: $showPlanetarySection) {
                                planetarySection
                            }
                            Divider()
                        }
                        if ToolSection.polarAlignment.isVisible(in: mode) {
                            DisclosureGroup("Polar Alignment", isExpanded: $showPolarAlignmentSection) {
                                polarAlignmentSection
                            }
                            Divider()
                        }
                        if ToolSection.enhancement.isVisible(in: mode) {
                            DisclosureGroup("Image Enhancement", isExpanded: $showEnhancementSection) {
                                enhancementSection
                            }
                            Divider()
                        }
                        if ToolSection.liveGPU.isVisible(in: mode) {
                            DisclosureGroup("Live GPU Enhancement Controls", isExpanded: $showLiveGPUSection) {
                                liveGPUControlsSection
                            }
                            Divider()
                        }
                        if ToolSection.aiSuite.isVisible(in: mode) {
                            DisclosureGroup("AI & Machine Learning Suite", isExpanded: $showAISuiteSection) {
                                aiSuiteSection
                            }
                            Divider()
                        }
                        if ToolSection.darkFrame.isVisible(in: mode) {
                            DisclosureGroup("Calibration (Dark/Flat)", isExpanded: $showDarkFrameSection) {
                                darkFrameSection
                            }
                            Divider()
                        }
                        if ToolSection.liveStack.isVisible(in: mode) {
                            DisclosureGroup("Live Stack", isExpanded: $showLiveStackSection) {
                                liveStackSection
                            }
                            Divider()
                        }
                        if ToolSection.luckyImaging.isVisible(in: mode) {
                            DisclosureGroup("Lucky Imaging", isExpanded: $showLuckyImagingSection) {
                                luckyImagingSection
                            }
                            Divider()
                        }

                        DisclosureGroup("Export", isExpanded: $showExportSection) {
                            exportSection
                        }
                        Divider()

                        if ToolSection.recording.isVisible(in: mode) {
                            DisclosureGroup("Record to Disk (GPU sharpness gate)", isExpanded: $showRecordingSection) {
                                recordingSection
                            }
                            Divider()
                        }
                    }

                    Text("Controls").font(.headline)

                    if cameraManager.controls.isEmpty {
                        Text("Connect a camera to see its controls.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(cameraManager.controls) { cap in
                            controlRow(cap)
                            Divider()
                        }
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Single exposure

    @ViewBuilder
    private var singleExposureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Single Exposure").font(.headline)
            // Safety guardrail (specs/skyformac_GPU_Live_Controls_Spec.md section 6.2): a webcam
            // has no real controllable exposure (see `CameraManager.captureSingleExposure`'s
            // `cameraID == -2` branch — it freezes the current frame regardless of this value),
            // so there's no hardware reason to floor it at 1ms specifically; this exists purely
            // so the slider doesn't invite dialing in a value that implies a capability the
            // source doesn't have.
            ExposureField(seconds: $exposureSeconds, minSeconds: cameraManager.isExternalWebcam ? 0.001 : 0.000_001)
            if cameraManager.isExternalWebcam && exposureSeconds < 0.010 {
                Label("iPhone/webcam sources ignore exposure length — \"Capture\" just freezes the current frame.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button {
                    Task { await cameraManager.captureSingleExposure(seconds: exposureSeconds) }
                } label: {
                    if cameraManager.isCapturingExposure {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Capture")
                    }
                }
                .disabled(cameraManager.isCapturingExposure)

                if !cameraManager.isLiveViewActive {
                    Button("Resume Live View") { cameraManager.resumeLiveView() }
                }
            }
        }
    }

    // MARK: - Focus assist

    @ViewBuilder
    private var focusAssistSection: some View {
        Toggle("Focus Assist (star detection)", isOn: Binding(
            get: { cameraManager.isFocusAssistEnabled },
            set: { cameraManager.isFocusAssistEnabled = $0 }
        ))
        .help("Detects point sources in the live preview via Vision and shows a sharpness readout to help focusing.")
        if let assist = cameraManager.focusAssist {
            HStack {
                Label("\(assist.stars.count) stars", systemImage: "sparkles")
                Spacer()
                if let diameter = assist.medianStarDiameterPixels {
                    Text(String(format: "%.1f px", diameter))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }

        Toggle("Recognize Stars (vs. Stellarium catalog)", isOn: Binding(
            get: { cameraManager.isStarRecognitionEnabled },
            set: { cameraManager.isStarRecognitionEnabled = $0 }
        ))
        .disabled(!cameraManager.isFocusAssistEnabled)
        .help("Simplified triangle-pattern matching against a small bright-star catalog — not a full plate solver.")
        if !cameraManager.recognizedObjects.isEmpty {
            Text(cameraManager.recognizedObjects.prefix(3).map(\.object.displayName).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !cameraManager.focusTracker.samples.isEmpty {
            hfdTrendView
        }
    }

    @ViewBuilder
    private var hfdTrendView: some View {
        let samples = cameraManager.focusTracker.samples
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("HFD Trend").font(.caption)
                Spacer()
                if let latest = samples.last {
                    Text(String(format: "%.2f px", latest.medianHFD))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if cameraManager.isFocusDriftDetected {
                Label("Thermal drift detected — focus is worsening over time", systemImage: "thermometer.sun.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Canvas { context, size in
                guard samples.count > 1 else { return }
                let maxHFD = max(samples.map(\.medianHFD).max() ?? 1, 0.01)
                let minHFD = min(samples.map(\.medianHFD).min() ?? 0, maxHFD - 0.01)
                let range = max(maxHFD - minHFD, 0.01)
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(max(samples.count - 1, 1))
                    let normalized = (sample.medianHFD - minHFD) / range
                    let y = size.height * (1 - CGFloat(normalized))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(cameraManager.isFocusDriftDetected ? .orange : .accentColor), lineWidth: 1.5)
            }
            .frame(height: 50)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Smart Exposure

    @ViewBuilder
    private var smartExposureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measures read noise from a bias frame and sky brightness from a 2s test exposure, then recommends a sub-exposure length so read noise stays a small fraction of total noise.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                Task { await cameraManager.measureSmartExposure() }
            } label: {
                if cameraManager.isMeasuringSmartExposure {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Measure")
                }
            }
            .disabled(cameraManager.isMeasuringSmartExposure)

            if let recommendation = cameraManager.smartExposureRecommendation {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow {
                        Text("Read noise").font(.caption)
                        Text(String(format: "%.2f e⁻", recommendation.readNoiseElectrons))
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Sky rate").font(.caption)
                        Text(String(format: "%.1f e⁻/s", recommendation.skyRateElectronsPerSecond))
                            .font(.caption.monospacedDigit())
                    }
                    GridRow {
                        Text("Recommended sub").font(.caption.bold())
                        Text(String(format: "%.1f s", recommendation.recommendedSubExposureSeconds))
                            .font(.caption.bold().monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Planetary auto-center & crop

    @ViewBuilder
    private var planetarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tracks the largest bright disk in view (Vision contours) and can dynamically crop to it — for keeping a planet centered in a small, fast-to-read-out ROI during video capture.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Track Disk", isOn: Binding(
                get: { cameraManager.isPlanetaryTrackingEnabled },
                set: { cameraManager.isPlanetaryTrackingEnabled = $0 }
            ))
            Toggle("Auto-Crop to ROI", isOn: Binding(
                get: { cameraManager.isPlanetaryCropEnabled },
                set: { cameraManager.isPlanetaryCropEnabled = $0 }
            ))
            .disabled(!cameraManager.isPlanetaryTrackingEnabled)

            if cameraManager.isPlanetaryTrackingEnabled {
                Text(cameraManager.planetROI == nil ? "No disk detected" : "Disk tracked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Polar alignment

    @ViewBuilder
    private var polarAlignmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Point near the celestial pole. Capture, rotate the mount's RA axis ~90° (alt/az knobs untouched), then capture again to solve the mount's actual rotation center from matched stars. Not a full plate solver — see code docs for exactly what this can and can't tell you.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            switch cameraManager.polarAlignmentStage {
            case .idle:
                Button("1. Capture Reference Frame") {
                    Task { await cameraManager.capturePolarAlignmentReferenceFrame() }
                }
            case .firstFrameCaptured:
                Text("Reference captured. Now rotate RA ~90°, then:")
                    .font(.caption2)
                Button("2. Capture & Solve") {
                    Task { await cameraManager.solvePolarAlignment() }
                }
                Button("Cancel") { cameraManager.resetPolarAlignment() }
            case .complete:
                if let center = cameraManager.polarAlignmentRotationCenter {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                        GridRow {
                            Text("Matched stars").font(.caption)
                            Text("\(cameraManager.polarAlignmentCorrespondenceCount)").font(.caption.monospacedDigit())
                        }
                        GridRow {
                            Text("Rotation center").font(.caption)
                            Text(String(format: "(%.0f, %.0f) px", center.x, center.y)).font(.caption.monospacedDigit())
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Button("Start Over") { cameraManager.resetPolarAlignment() }
            }
        }
    }

    // MARK: - Image enhancement (denoise + wavelet sharpening)

    @ViewBuilder
    private var enhancementSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Real-time bilateral denoise and à trous wavelet sharpening (RegiStax-style multiscale sharpening for Lunar/planetary/solar detail). Runs as Metal compute kernels with the GPU renderer on, or an equivalent CPU implementation otherwise — either way, display-only, never baked into exported/recorded frames.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Denoise", isOn: Binding(
                get: { cameraManager.isDenoisingEnabled },
                set: { cameraManager.isDenoisingEnabled = $0 }
            ))
            Toggle("Wavelet Sharpening", isOn: Binding(
                get: { cameraManager.isWaveletSharpeningEnabled },
                set: { cameraManager.isWaveletSharpeningEnabled = $0 }
            ))
            if cameraManager.isWaveletSharpeningEnabled {
                HStack {
                    Text("Amount").font(.caption)
                    Slider(value: Binding(
                        get: { cameraManager.waveletSharpenAmount },
                        set: { cameraManager.waveletSharpenAmount = $0 }
                    ), in: 0...3)
                }
            }
        }
    }

    // MARK: - Live GPU Enhancement Controls (specs/skyformac_GPU_Live_Controls_Spec.md)

    @ViewBuilder
    private var liveGPUControlsSection: some View {
        let gpu = cameraManager.gpuControls
        VStack(alignment: .leading, spacing: 8) {
            Text("A three-stage GPU pipeline — temporal + spatial denoise, then a non-linear contrast stretch — independent of Image Enhancement above and the Black/White Point sliders under the histogram. GPU renderer only.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Enabled", isOn: Binding(get: { gpu.isEnabled }, set: { gpu.isEnabled = $0 }))

            Text("Temporal Denoise (Live Smoothing)").font(.caption.bold())
            gpuSlider("Smoothness", value: Binding(get: { gpu.temporalAlpha }, set: { gpu.temporalAlpha = $0 }), range: 0.01...1.0)

            Text("Spatial Denoise (Bilateral)").font(.caption.bold())
            gpuSlider("Radius", value: Binding(get: { gpu.spatialSigma }, set: { gpu.spatialSigma = $0 }), range: 1.0...10.0)
            gpuSlider("Range", value: Binding(get: { gpu.rangeSigma }, set: { gpu.rangeSigma = $0 }), range: 0.01...0.50)

            Text("Non-Linear Contrast (Arcsinh Stretch)").font(.caption.bold())
            gpuSlider("Boost", value: Binding(get: { gpu.stretchIntensity }, set: { gpu.stretchIntensity = $0 }), range: 1.0...200.0)
            gpuSlider("Black Pt", value: Binding(get: { gpu.blackPoint }, set: { gpu.blackPoint = $0 }), range: 0...0.4)
            gpuSlider("White Pt", value: Binding(get: { gpu.whitePoint }, set: { gpu.whitePoint = $0 }), range: 0.10...1.0)

            Button("Auto-Stretch Safety Lock") {
                gpu.autoStretch(histogram: cameraManager.gpuHistogramCounts ?? currentCPUHistogram())
            }
            .help("Sets Black/White Point and Boost from the current frame's histogram (1st/99th percentile).")
        }
    }

    @ViewBuilder
    private func gpuSlider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    /// Fallback for "Auto-Stretch Safety Lock" when the GPU histogram isn't populated yet (e.g.
    /// Metal renderer just turned on, no frame processed since) — same underlying math
    /// (`HistogramComputer`), just computed on-demand from the raw sensor frame instead of read
    /// from the live GPU compute-kernel histogram.
    private func currentCPUHistogram() -> [Int] {
        guard let frame = cameraManager.currentFrame else { return [] }
        return HistogramComputer.histogram(for: frame)
    }

    // MARK: - AI & Machine Learning Suite (specs/skyformac_AI_Features_Pipeline_Spec.md)

    @ViewBuilder
    private var aiSuiteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Two of the spec's five features (Neural Engine AI Denoise, AI Super-Resolution) need a trained Core ML model this app doesn't ship and can't fabricate — see the spec file's Implementation Notes. Denoise already has a real classical-technique equivalent under Image Enhancement; Lucky Imaging's real quality scoring is under its own section, with a live readout there.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Text("Satellite & Aircraft Trail Masking").font(.caption.bold())
            Toggle("Enabled", isOn: Binding(
                get: { cameraManager.isStreakMaskingEnabled },
                set: { cameraManager.isStreakMaskingEnabled = $0 }
            ))
            if cameraManager.useMetalRenderer {
                Label("Only affects the CPU (non-GPU) live-stack path — see the spec file's Implementation Notes for why the GPU accumulate kernel isn't wired up yet. Turn off \"GPU\" in the toolbar to use this.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if cameraManager.isStreakMaskingEnabled {
                Text(streakStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Cloud Cover & Drift Sentinel").font(.caption.bold())
            Toggle("Enabled", isOn: Binding(
                get: { cameraManager.isCloudSentinelEnabled },
                set: { cameraManager.isCloudSentinelEnabled = $0 }
            ))
            if cameraManager.isCloudSentinelEnabled {
                Label(
                    cameraManager.isCloudAlertActive ? "Cloud/Light Alert — recording paused" : "Sky Stable • Baseline Locked",
                    systemImage: cameraManager.isCloudAlertActive ? "cloud.fill" : "checkmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(cameraManager.isCloudAlertActive ? .orange : .secondary)
                Text("Pauses active disk recording and sends a system notification on a sudden sky-brightness drop or spike, using the same baseline-tracking logic as the All-Sky Monitor's own alerts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var streakStatusText: String {
        guard let mask = cameraManager.currentStreakMask else { return "Watching for streaks…" }
        let percent = mask.maskedFraction * 100
        return percent > 0.01
            ? String(format: "Masking ~%.1f%% of frame (streak detected)", percent)
            : "No streaks detected in the current frame."
    }

    // MARK: - Dark frame

    @ViewBuilder
    private var darkFrameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            calibrationSubsection(
                title: "Dark Frames",
                helpText: "Lens capped / scope covered — removes fixed-pattern noise and hot pixels.",
                seconds: $darkFrameSeconds,
                captureLabel: "Capture Dark",
                frames: cameraManager.calibrationLibrary.darkFrames,
                activeID: cameraManager.calibrationLibrary.activeDarkID,
                onCapture: { await cameraManager.captureDarkFrame(seconds: darkFrameSeconds) },
                onSelect: { cameraManager.calibrationLibrary.activeDarkID = $0 },
                onRemove: { cameraManager.calibrationLibrary.removeDark(id: $0) },
                isEnabled: Binding(
                    get: { cameraManager.isDarkSubtractionEnabled },
                    set: { cameraManager.isDarkSubtractionEnabled = $0 }
                ),
                enabledLabel: "Subtract Active Dark"
            )

            Divider()

            calibrationSubsection(
                title: "Flat Frames",
                helpText: "Even illumination (twilight sky, light panel) — corrects vignetting and dust shadows.",
                seconds: $flatFrameSeconds,
                captureLabel: "Capture Flat",
                frames: cameraManager.calibrationLibrary.flatFrames,
                activeID: cameraManager.calibrationLibrary.activeFlatID,
                onCapture: { await cameraManager.captureFlatFrame(seconds: flatFrameSeconds) },
                onSelect: { cameraManager.calibrationLibrary.activeFlatID = $0 },
                onRemove: { cameraManager.calibrationLibrary.removeFlat(id: $0) },
                isEnabled: Binding(
                    get: { cameraManager.isFlatCorrectionEnabled },
                    set: { cameraManager.isFlatCorrectionEnabled = $0 }
                ),
                enabledLabel: "Apply Active Flat"
            )
        }
    }

    @ViewBuilder
    private func calibrationSubsection(
        title: String,
        helpText: String,
        seconds: Binding<Double>,
        captureLabel: String,
        frames: [CalibrationFrame],
        activeID: UUID?,
        onCapture: @escaping () async -> Void,
        onSelect: @escaping (UUID) -> Void,
        onRemove: @escaping (UUID) -> Void,
        isEnabled: Binding<Bool>,
        enabledLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
            Text(helpText).font(.caption2).foregroundStyle(.secondary)

            ExposureField(seconds: seconds)
            Button(captureLabel) { Task { await onCapture() } }
                .disabled(cameraManager.isCapturingExposure)

            if frames.isEmpty {
                Text("None captured yet.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(frames) { entry in
                    HStack {
                        Image(systemName: entry.id == activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(entry.id == activeID ? Color.accentColor : .secondary)
                            .onTapGesture { onSelect(entry.id) }
                        Text(entry.name).font(.caption)
                        Spacer()
                        Button {
                            onRemove(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle(enabledLabel, isOn: isEnabled)
                    .disabled(activeID == nil)
            }
        }
    }

    // MARK: - Live stacking

    @ViewBuilder
    private var liveStackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running average of incoming frames — no star alignment, so it assumes a tracked, stationary mount.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Live Stack", isOn: Binding(
                get: { cameraManager.isLiveStackingEnabled },
                set: { cameraManager.isLiveStackingEnabled = $0 }
            ))

            HStack {
                Label("\(cameraManager.liveStackedFrameCount) frames stacked", systemImage: "square.stack.3d.up")
                    .font(.caption)
                Spacer()
                if cameraManager.isLiveStackingEnabled {
                    Button("Reset") { cameraManager.resetLiveStack() }
                }
            }
        }
    }

    // MARK: - Lucky imaging

    @ViewBuilder
    private var luckyImagingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Captures a burst, scores each frame's sharpness, and stacks only the best fraction — for beating atmospheric seeing on the Moon/planets. No frame alignment.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let score = cameraManager.currentFrameQualityScore {
                HStack {
                    Text("Live Score").font(.caption)
                    Spacer()
                    Text(String(format: "%.1f / 100", score))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Relative to the sharpest frame seen so far this session — not a calibrated absolute scale, since Laplacian-variance sharpness has no fixed ceiling.")
            }

            HStack {
                Text("\(Int(luckyBurstCount)) frames")
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .leading)
                Slider(value: $luckyBurstCount, in: 5...200, step: 5)
            }
            Button("Start Burst") {
                cameraManager.startLuckyImagingBurst(frameCount: Int(luckyBurstCount))
            }
            .disabled(!cameraManager.isLiveViewActive)

            if let progress = cameraManager.luckyImagingProgress {
                ProgressView(value: Double(progress.captured), total: Double(progress.total)) {
                    Text("\(progress.captured) / \(progress.total) captured")
                        .font(.caption)
                }

                if cameraManager.isLuckyImagingBurstComplete {
                    HStack {
                        Text(String(format: "Keep best %.0f%%", luckyKeepFraction * 100))
                            .font(.caption)
                        Slider(value: $luckyKeepFraction, in: 0.05...1.0)
                    }
                    HStack {
                        Button("Stack") { cameraManager.stackLuckyImagingBest(fraction: luckyKeepFraction) }
                        Button("Discard", role: .destructive) { cameraManager.discardLuckyImagingSession() }
                    }
                }
            }
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FITS saves the raw sensor data (for processing in tools like PixInsight/Siril); PNG/TIFF save the stretched preview you see on screen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("FITS") { cameraManager.exportCurrentFrame(as: .fits) }
                Button("PNG") { cameraManager.exportCurrentFrame(as: .png) }
                Button("TIFF") { cameraManager.exportCurrentFrame(as: .tiff) }
            }
            .disabled(cameraManager.currentFrame == nil)
        }
    }

    // MARK: - Continuous recording (GPU sharpness gate)

    @ViewBuilder
    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Writes every incoming frame as FITS to a folder, scoring sharpness on the GPU (Laplacian energy) and discarding frames below the threshold before they hit disk.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Text("Min sharpness").font(.caption)
                Slider(value: $recordingThreshold, in: 0...50)
                Text(String(format: "%.0f", recordingThreshold))
                    .font(.caption.monospacedDigit())
                    .frame(width: 30)
            }
            .disabled(cameraManager.isRecordingToDisk)

            if cameraManager.recordingLowDiskSpaceStopped {
                Label("Stopped: recording volume ran low on disk space", systemImage: "exclamationmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if cameraManager.isRecordingToDisk {
                HStack {
                    Label("\(cameraManager.recordedFrameCount) saved", systemImage: "square.and.arrow.down")
                    Label("\(cameraManager.discardedFrameCount) discarded", systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if let perFrame = cameraManager.estimatedBytesPerFrame {
                    Text("\(ByteCountFormatter.string(fromByteCount: perFrame, countStyle: .file))/frame · \(ByteCountFormatter.string(fromByteCount: cameraManager.recordingBytesWritten, countStyle: .file)) written")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Stop Recording", role: .destructive) { cameraManager.stopRecording() }
            } else {
                Button("Choose Folder & Start…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Start Recording"
                    if panel.runModal() == .OK, let url = panel.url {
                        cameraManager.sharpnessDiscardThreshold = recordingThreshold
                        cameraManager.startRecording(to: url)
                    }
                }
                .disabled(cameraManager.currentFrame == nil)
            }
        }
    }

    // MARK: - Dynamic per-camera controls (spec Milestone 3)

    @ViewBuilder
    private func controlRow(_ cap: ZWOControlCaps) -> some View {
        switch cap.controlType {
        case ASI_COOLER_ON, ASI_FAN_ON, ASI_ANTI_DEW_HEATER:
            toggleRow(cap)
        case ASI_EXPOSURE:
            exposureRow(cap)
        case ASI_TEMPERATURE:
            temperatureReadoutRow(cap)
        default:
            genericSliderRow(cap)
        }
    }

    private func currentValue(for cap: ZWOControlCaps) -> Int {
        cameraManager.controlValues[cap.id]?.value ?? cap.defaultValue
    }

    @ViewBuilder
    private func genericSliderRow(_ cap: ZWOControlCaps) -> some View {
        let current = currentValue(for: cap)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cap.name)
                Spacer()
                Text("\(current)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if cap.isWritable, cap.minValue < cap.maxValue {
                Slider(
                    value: Binding(
                        get: { Double(current) },
                        set: { cameraManager.setControlValue(cap.controlType, value: Int($0)) }
                    ),
                    in: Double(cap.minValue)...Double(cap.maxValue)
                )
            } else {
                Text(cap.isWritable ? "Fixed value" : "Read-only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(cap.controlDescription)
    }

    @ViewBuilder
    private func toggleRow(_ cap: ZWOControlCaps) -> some View {
        let isOn = currentValue(for: cap) != 0
        Toggle(cap.name, isOn: Binding(
            get: { isOn },
            set: { cameraManager.setControlValue(cap.controlType, value: $0 ? 1 : 0) }
        ))
        .disabled(!cap.isWritable)
        .help(cap.controlDescription)
    }

    @ViewBuilder
    private func exposureRow(_ cap: ZWOControlCaps) -> some View {
        let currentMicroseconds = currentValue(for: cap)
        let seconds = Double(currentMicroseconds) / 1_000_000.0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Exposure")
                Spacer()
                Text(String(format: "%.3f s", seconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if cap.isWritable, cap.minValue < cap.maxValue {
                Slider(
                    value: Binding(
                        get: { Double(currentMicroseconds) },
                        set: { cameraManager.setControlValue(cap.controlType, value: Int($0)) }
                    ),
                    in: Double(cap.minValue)...Double(cap.maxValue)
                )
            }
        }
        .help(cap.controlDescription)
    }

    @ViewBuilder
    private func temperatureReadoutRow(_ cap: ZWOControlCaps) -> some View {
        // ASICamera2.h: ASI_TEMPERATURE "return 10*temperature".
        let celsius = Double(currentValue(for: cap)) / 10.0
        HStack {
            Label("Sensor Temperature", systemImage: "thermometer.medium")
            Spacer()
            Text(String(format: "%.1f °C", celsius))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(cap.controlDescription)
    }
}

/// Exposure-duration control shared by "Single Exposure", "Dark Frames", and "Flat Frames":
/// real ASI sensors expose exposure lengths from tens of microseconds (planetary/lucky imaging)
/// up to hundreds of seconds (deep sky), a range a linear seconds slider can't usefully cover —
/// at 0.1s resolution over a 60s span, there's no way to dial in, say, 500µs. The slider itself
/// operates in log10(seconds) space so every decade (µs/ms/s) gets equal room, while the
/// underlying binding stays plain seconds — `CameraManager.captureSingleExposure`/
/// `captureDarkFrame`/`captureFlatFrame` all already take fractional seconds and convert to
/// microseconds internally, so no call site needed to change.
private struct ExposureField: View {
    @Binding var seconds: Double
    var minSeconds: Double = 0.000_001 // 1 µs — comfortably below any real ASI sensor's floor
    var maxSeconds: Double = 60

    private var logRange: ClosedRange<Double> { log10(minSeconds)...log10(maxSeconds) }

    private var logValue: Binding<Double> {
        Binding(
            get: { log10(min(max(seconds, minSeconds), maxSeconds)) },
            set: { seconds = pow(10, $0) }
        )
    }

    var body: some View {
        HStack {
            Text(Self.format(seconds))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .leading)
            Slider(value: logValue, in: logRange)
        }
    }

    private static func format(_ seconds: Double) -> String {
        if seconds < 0.001 {
            return String(format: "%.0f µs", seconds * 1_000_000)
        } else if seconds < 1 {
            return String(format: "%.1f ms", seconds * 1_000)
        } else {
            return String(format: "%.2f s", seconds)
        }
    }
}
