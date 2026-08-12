import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Small "?" button next to a setting's label that opens Help scrolled directly to that
/// setting's own explanation (`CameraManager.showHelp(topicID:sectionID:)`) — every `sectionID`
/// used below matches a `HelpSection.id` in `HelpContent.configurationReference` (or, for the
/// iPhone/webcam controls, `HelpContent.usingIPhone`). Search in Help covers the same content
/// too; this is the "I'm already looking at the control, just tell me what it does" shortcut.
private struct HelpLinkButton: View {
    var cameraManager: CameraManager
    var topicID: String
    var sectionID: String?

    var body: some View {
        Button {
            cameraManager.showHelp(topicID: topicID, sectionID: sectionID)
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("What does this do? (opens Help)")
    }
}

/// A `DisclosureGroup` title row with a trailing `HelpLinkButton` — used for every section below
/// whose entire content maps to one `HelpContent` anchor (as opposed to a section covering
/// several distinct settings, each with its own anchor, which instead places a `HelpLinkButton`
/// next to each setting individually inside the section body).
private struct HelpLinkedDisclosureLabel: View {
    var title: String
    var cameraManager: CameraManager
    var sectionID: String

    var body: some View {
        HStack {
            Text(title)
            HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: sectionID)
        }
    }
}

/// Which of the sidebar's three tabs is showing — replaces the old `ControlMode` filter
/// (General/Planetary/Deep Sky/All Tools), which grouped the same flat list of ~15 sections by
/// imaging genre. This groups them by *role* instead:
/// - `.cameraControls`: the raw per-camera hardware controls (gain, exposure, flip, cooler, ...)
///   plus Single Exposure and Export — nothing here alters the image, only what the sensor does.
/// - `.improvements`: opt-in things that change what you *see* without touching the sensor
///   (Image Enhancement, Live GPU Enhancement Controls, the AI Suite) — exactly the category of
///   state that caused the "full white/black, no live view" bug in `docs/design-notes.md` when
///   left on from a previous session.
/// - `.advanced`: imaging *workflows* (focus/tracking/stacking/calibration/recording).
///
/// The latter two tabs each get a single "Disable All" checkbox, so ruling out "one of these
/// is doing this" — or just falling back to the camera's own unmodified output — is one click
/// instead of hunting down a dozen individual toggles.
enum SidebarTab: String, CaseIterable, Identifiable {
    case cameraControls = "Camera Controls"
    case improvements = "Improvements"
    case advanced = "Advanced"

    var id: String { rawValue }

    /// Short enough to sit under an icon in the vertical tab strip's ~60pt width without wrapping.
    var shortLabel: String {
        switch self {
        case .cameraControls: return "Camera"
        case .improvements: return "Improve"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .cameraControls: return "camera"
        case .improvements: return "wand.and.stars"
        case .advanced: return "gearshape.2"
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
/// raw sensor data rather than the debayered preview, etc). Which sections show is decided
/// entirely by `tab` (`SidebarTab`) — see its doc comment for the three-way split.
struct ControlsPanelView: View {
    var cameraManager: CameraManager
    @AppStorage("sidebarTab") private var tab: SidebarTab = .cameraControls

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
    @State private var showExportedFilesSection = false
    @State private var showRecordingSection = false
    @AppStorage("recordingThreshold") private var recordingThreshold: Double = 0
    @State private var showSmartExposureSection = false
    @State private var showPlanetarySection = false
    @State private var showPolarAlignmentSection = false
    @State private var showST4GuidingSection = false
    @State private var st4GuideDurationMilliseconds: Double = 500
    @State private var showEnhancementSection = false
    @State private var showLiveGPUSection = false
    @State private var showAISuiteSection = false
    @State private var showIPhoneWebcamSection = false
    @AppStorage("nightModeSeconds") private var nightModeSeconds: Double = 10
    @State private var showGainOffsetPresetsSection = false
    @State private var showPlanetaryPresetsSection = false
    @State private var showCaptureROISection = false
    @State private var customROIWidth: Int = 800
    @State private var customROIHeight: Int = 600
    @State private var customROICenterX: Int?
    @State private var customROICenterY: Int?
    @State private var showSERRecordingSection = false
    @AppStorage("serRecordingDurationSeconds") private var serRecordingDurationSeconds: Double = 180

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .cameraControls:
                        cameraControlsTabContent
                    case .improvements:
                        improvementsTabContent
                    case .advanced:
                        advancedTabContent
                    }
                }
                // The window's own toolbar (GPU/CPU, Night Mode, All-Sky Monitor) overlaps this
                // pane's content area by more than the first estimate (40pt) accounted for — the
                // "Disable All" checkbox was still unclickable at that clearance, so this is
                // 70pt now. Not a SwiftUI-side mystery, an actual toolbar hit-testing overlap:
                // every "unclickable at the top of the sidebar" report so far (the old Mode
                // picker, both "Disable All" checkboxes) was this. `verticalTabStrip` uses the
                // same value.
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 70)
            }

            if cameraManager.connectedCamera != nil {
                Divider()
                verticalTabStrip
            }
        }
    }

    /// Vertical tab strip on the sidebar's trailing edge, rather than a horizontal picker above
    /// the content — the window's own toolbar (GPU/CPU, Night Mode, All-Sky Monitor) overlaps
    /// this pane by more than first estimated, which is what made every control that's ever sat
    /// there unclickable (see `docs/design-notes.md`). `.padding(.top, 70)` below clears it —
    /// kept in sync with `body`'s `ScrollView` content, which needed the same bump.
    @ViewBuilder
    private var verticalTabStrip: some View {
        VStack(spacing: 6) {
            ForEach(SidebarTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 16))
                        Text(candidate.shortLabel)
                            .font(.caption2)
                    }
                    .frame(width: 56)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab == candidate ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .foregroundStyle(tab == candidate ? Color.accentColor : Color.primary)
                    // Without this, the button's tappable area is just the tight bounding box of
                    // its actual glyphs (the icon's drawn strokes and the text) — clicking
                    // anywhere else in the visible rounded-rect background (most of its area)
                    // did nothing. This makes the whole frame+background react, not just the
                    // "ink" inside it.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(candidate.rawValue)
            }

            Divider().padding(.vertical, 4)

            // The live preview's own overlay button for this was reported unclickable too (same
            // screen-position issue) — this and the "Full Screen Preview" menu bar item
            // (`SkyformacCommands`) are both independent paths to the same
            // `cameraManager.isPreviewFullScreenEnabled` state. This whole sidebar (and this
            // button with it) disappears once fullscreen is entered — ⌘⇧F or Esc are what get
            // the user back out again, not this button a second time.
            Button {
                cameraManager.isPreviewFullScreenEnabled = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16))
                    Text("Full Screen")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 56)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Full screen live preview with a zoom overlay (⌘⇧F)")

            Spacer()
        }
        .padding(.top, 70)
        .padding(.horizontal, 6)
        .frame(width: 68)
    }

    // MARK: - Tab contents

    @ViewBuilder
    private var cameraControlsTabContent: some View {
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

        if let dropped = cameraManager.droppedFrameCount {
            HStack {
                Label("\(dropped) dropped frames", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(dropped > 0 ? .orange : .secondary)
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.droppedFrames")
            }
            .help("Frames the camera captured but this app failed to read off the USB connection in time — a rising count usually means Bandwidth (below, if your camera reports it) is set too high for your USB port/cable.")
            Divider()
        }

        if cameraManager.gainOffsetPresets != nil || cameraManager.lmhGainOffsetPresets != nil {
            DisclosureGroup(isExpanded: $showGainOffsetPresetsSection) {
                gainOffsetPresetsSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Gain/Offset Presets", cameraManager: cameraManager, sectionID: "setting.gainOffsetPresets")
            }
            Divider()
        }

        if cameraManager.connectedCamera != nil {
            singleExposureSection
            Divider()

            if !cameraManager.isExternalWebcam {
                DisclosureGroup(isExpanded: $showPlanetaryPresetsSection) {
                    planetaryPresetsSection
                } label: {
                    HelpLinkedDisclosureLabel(title: "Planetary Presets", cameraManager: cameraManager, sectionID: "setting.planetaryPresets")
                }
                Divider()
            }

            if !cameraManager.isExternalWebcam {
                DisclosureGroup(isExpanded: $showCaptureROISection) {
                    captureROISection
                } label: {
                    HelpLinkedDisclosureLabel(title: "Capture ROI (higher FPS)", cameraManager: cameraManager, sectionID: "setting.captureROI")
                }
                Divider()
            }

            if cameraManager.isExternalWebcam {
                DisclosureGroup("iPhone / Webcam", isExpanded: $showIPhoneWebcamSection) {
                    iPhoneWebcamSection
                }
                Divider()
            }

            if !cameraManager.isExternalWebcam {
                DisclosureGroup(isExpanded: $showSERRecordingSection) {
                    serRecordingSection
                } label: {
                    HelpLinkedDisclosureLabel(title: "Record SER Video (planetary/lunar)", cameraManager: cameraManager, sectionID: "setting.serRecording")
                }
                Divider()
            }

            DisclosureGroup("Export", isExpanded: $showExportSection) {
                exportSection
            }
            Divider()

            DisclosureGroup(isExpanded: $showExportedFilesSection) {
                exportedFilesSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Exported Files", cameraManager: cameraManager, sectionID: "setting.exportedFiles")
            }
        }
    }

    // MARK: - iPhone / webcam: focus lock + Night Mode

    @ViewBuilder
    private var iPhoneWebcamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Focus").font(.caption.bold())
                    HelpLinkButton(cameraManager: cameraManager, topicID: "using-iphone", sectionID: "setting.lockFocus")
                }
                Text("A webcam's own continuous autofocus actively fights afocal projection (phone held to an eyepiece) — it keeps hunting for a \"normal\" subject distance and refocuses away from the telescope's actual focal plane. Lock it once focus looks right.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle("Lock Focus", isOn: Binding(
                    get: { cameraManager.isWebcamFocusLocked },
                    set: { cameraManager.setWebcamFocusLocked($0) }
                ))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Night Mode").font(.caption.bold())
                    HelpLinkButton(cameraManager: cameraManager, topicID: "using-iphone", sectionID: "setting.iphoneNightMode")
                }
                Text("No hardware exposure to set here — this instead accumulates that many seconds of live frames (the same computational multi-frame stacking Apple's own iPhone Night Mode uses internally) and freezes on the brighter result.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("Duration", selection: $nightModeSeconds) {
                    Text("10 sec").tag(10.0)
                    Text("60 sec").tag(60.0)
                }
                .pickerStyle(.segmented)
                .disabled(cameraManager.isCapturingNightMode)

                if cameraManager.isCapturingNightMode {
                    ProgressView(
                        value: cameraManager.nightModeTotalSeconds - cameraManager.nightModeRemainingSeconds,
                        total: max(cameraManager.nightModeTotalSeconds, 0.001)
                    ) {
                        Text(String(format: "Capturing… %.0fs left", cameraManager.nightModeRemainingSeconds))
                            .font(.caption)
                    }
                    Button("Cancel", role: .destructive) { cameraManager.cancelIPhoneNightModeCapture() }
                } else {
                    Button("Start Night Mode Capture") {
                        cameraManager.startIPhoneNightModeCapture(seconds: nightModeSeconds)
                    }
                    if !cameraManager.isLiveViewActive {
                        Button("Resume Live View") { cameraManager.resumeLiveView() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var improvementsTabContent: some View {
        if cameraManager.connectedCamera == nil {
            Text("Connect a camera to see improvement controls.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // Back at the top on purpose — the pane's first row is only unclickable without the
            // `.padding(.top, 70)` clearing the window toolbar's overlap (see `body`'s doc
            // comment); with that in place, a master switch reads naturally as the first thing
            // in its tab.
            HStack {
                Toggle("Disable All Improvements", isOn: allImprovementsDisabled)
                    .toggleStyle(.checkbox)
                    .help("Turns off Image Enhancement, Live GPU Enhancement Controls, and the AI Suite's streak masking/cloud sentinel in one click — for ruling out a visual side effect from one of them, or just to see exactly what the camera itself is producing.")
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.disableImprovements")
            }
            Divider()

            DisclosureGroup(isExpanded: $showEnhancementSection) {
                enhancementSection
            } label: {
                Text("Image Enhancement")
            }
            Divider()
            DisclosureGroup(isExpanded: $showLiveGPUSection) {
                liveGPUControlsSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Live GPU Enhancement Controls", cameraManager: cameraManager, sectionID: "setting.liveGPU")
            }
            Divider()
            DisclosureGroup(isExpanded: $showAISuiteSection) {
                aiSuiteSection
            } label: {
                HelpLinkedDisclosureLabel(title: "AI & Machine Learning Suite", cameraManager: cameraManager, sectionID: "setting.aiSuite")
            }
        }
    }

    @ViewBuilder
    private var advancedTabContent: some View {
        if cameraManager.connectedCamera == nil {
            Text("Connect a camera to see advanced imaging tools.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Toggle("Disable All Advanced Features", isOn: allAdvancedDisabled)
                    .toggleStyle(.checkbox)
                    .help("Turns off Focus Assist, Planetary tracking/crop, Live Stacking, and Dark/Flat calibration, and stops any active disk recording — for ruling one of these out, or to fall back to a plain, unmodified live view.")
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.disableAdvanced")
            }
            Divider()

            DisclosureGroup(isExpanded: $showFocusAssistSection) {
                focusAssistSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Focus Assist", cameraManager: cameraManager, sectionID: "setting.focusAssist")
            }
            Divider()
            DisclosureGroup(isExpanded: $showSmartExposureSection) {
                smartExposureSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Smart Exposure", cameraManager: cameraManager, sectionID: "setting.smartExposure")
            }
            Divider()
            DisclosureGroup(isExpanded: $showPlanetarySection) {
                planetarySection
            } label: {
                HelpLinkedDisclosureLabel(title: "Planetary Auto-Center", cameraManager: cameraManager, sectionID: "setting.planetaryAutoCenter")
            }
            Divider()
            DisclosureGroup(isExpanded: $showPolarAlignmentSection) {
                polarAlignmentSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Polar Alignment", cameraManager: cameraManager, sectionID: "setting.polarAlignment")
            }
            Divider()
            if cameraManager.connectedCamera?.hasST4Port == true {
                DisclosureGroup(isExpanded: $showST4GuidingSection) {
                    st4GuidingSection
                } label: {
                    HelpLinkedDisclosureLabel(title: "ST4 Guiding", cameraManager: cameraManager, sectionID: "setting.st4Guiding")
                }
                Divider()
            }
            DisclosureGroup(isExpanded: $showDarkFrameSection) {
                darkFrameSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Calibration (Dark/Flat)", cameraManager: cameraManager, sectionID: "setting.calibration")
            }
            Divider()
            DisclosureGroup(isExpanded: $showLiveStackSection) {
                liveStackSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Live Stack", cameraManager: cameraManager, sectionID: "setting.liveStack")
            }
            Divider()
            DisclosureGroup(isExpanded: $showLuckyImagingSection) {
                luckyImagingSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Lucky Imaging", cameraManager: cameraManager, sectionID: "setting.luckyImaging")
            }
            Divider()
            DisclosureGroup(isExpanded: $showRecordingSection) {
                recordingSection
            } label: {
                HelpLinkedDisclosureLabel(title: "Record to Disk (GPU sharpness gate)", cameraManager: cameraManager, sectionID: "setting.recordToDisk")
            }
        }
    }

    /// `true` only when every "Improvements" toggle is already off — checking it forces them all
    /// off in one click; unchecking it is a no-op (turning individual features back on is each
    /// feature's own toggle, not this checkbox's job — it summarizes "all off", it doesn't
    /// remember "what was on before").
    private var allImprovementsDisabled: Binding<Bool> {
        Binding(
            get: {
                !cameraManager.isDenoisingEnabled
                    && !cameraManager.isWaveletSharpeningEnabled
                    && !cameraManager.gpuControls.isEnabled
                    && !cameraManager.isStreakMaskingEnabled
                    && !cameraManager.isCloudSentinelEnabled
            },
            set: { disableAll in
                guard disableAll else { return }
                cameraManager.isDenoisingEnabled = false
                cameraManager.isWaveletSharpeningEnabled = false
                cameraManager.gpuControls.isEnabled = false
                cameraManager.isStreakMaskingEnabled = false
                cameraManager.isCloudSentinelEnabled = false
            }
        )
    }

    /// Same "summarizes all-off, doesn't restore previous state" shape as
    /// `allImprovementsDisabled` above.
    private var allAdvancedDisabled: Binding<Bool> {
        Binding(
            get: {
                !cameraManager.isFocusAssistEnabled
                    && !cameraManager.isPlanetaryTrackingEnabled
                    && !cameraManager.isPlanetaryCropEnabled
                    && !cameraManager.isLiveStackingEnabled
                    && !cameraManager.isDarkSubtractionEnabled
                    && !cameraManager.isFlatCorrectionEnabled
                    && !cameraManager.isRecordingToDisk
            },
            set: { disableAll in
                guard disableAll else { return }
                cameraManager.isFocusAssistEnabled = false
                cameraManager.isPlanetaryTrackingEnabled = false
                cameraManager.isPlanetaryCropEnabled = false
                cameraManager.isLiveStackingEnabled = false
                cameraManager.isDarkSubtractionEnabled = false
                cameraManager.isFlatCorrectionEnabled = false
                if cameraManager.isRecordingToDisk { cameraManager.stopRecording() }
            }
        )
    }

    // MARK: - Single exposure

    @ViewBuilder
    private var singleExposureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Single Exposure").font(.headline)
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.singleExposure")
            }
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

    // MARK: - Planetary presets

    @ViewBuilder
    private var planetaryPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One tap sets RAW8, a small Capture ROI, and a safe starting exposure/gain for a specific target — raise Gain/Exposure from there while watching the histogram (under the live preview) until its peak sits in the target range below. Tuned around a modern ~2µm-pixel planetary camera (e.g. ASI678MC) behind a modest f/10-f/12 Mak/SCT, which needs no Barlow at that pairing.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(PlanetaryPreset.allCases) { preset in
                Button {
                    cameraManager.applyPlanetaryPreset(preset)
                    serRecordingDurationSeconds = preset.recommendedMaxDurationSeconds
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(preset.rawValue, systemImage: preset.icon)
                                .font(.callout.bold())
                            Spacer()
                            Text(preset.roi.map { "\($0.width)×\($0.height)" } ?? "Full Sensor")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(String(
                            format: "%.0f-%.0f ms · Gain %d-%d · up to %.0fs · histogram %.0f-%.0f%%",
                            preset.exposureRangeSeconds.lowerBound * 1000,
                            preset.exposureRangeSeconds.upperBound * 1000,
                            preset.gainRange.lowerBound,
                            preset.gainRange.upperBound,
                            preset.recommendedMaxDurationSeconds,
                            preset.histogramTargetPercent.lowerBound,
                            preset.histogramTargetPercent.upperBound
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        if let note = preset.note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    // Without this, the button's tappable area is just the tight bounding box of
                    // its text glyphs — clicking the row's background/padding did nothing (same
                    // fix the vertical tab strip's buttons already needed).
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Gain/Offset presets (ZWO's own recommended reference points)

    @ViewBuilder
    private var gainOffsetPresetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ZWO's own recommended Gain/Offset reference points for this camera model (the same numbers SharpCap's gain presets and ZWO's ASICap show) — one tap applies Gain and/or Offset above directly.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let presets = cameraManager.gainOffsetPresets {
                gainOffsetPresetRow(
                    title: "Highest Dynamic Range", detail: "Gain 0, Offset \(presets.offsetHighestDynamicRange)",
                    action: { cameraManager.applyGainOffsetPreset(.highestDynamicRange) }
                )
                gainOffsetPresetRow(
                    title: "Unity Gain", detail: "Offset \(presets.offsetUnityGain) (gain unchanged — not reported by the SDK)",
                    action: { cameraManager.applyGainOffsetPreset(.unityGain) }
                )
                gainOffsetPresetRow(
                    title: "Lowest Read Noise", detail: "Gain \(presets.gainLowestReadNoise), Offset \(presets.offsetLowestReadNoise)",
                    action: { cameraManager.applyGainOffsetPreset(.lowestReadNoise) }
                )
            }

            if let lmh = cameraManager.lmhGainOffsetPresets {
                Divider()
                Text("Frequently-used gain steps for this model:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                gainOffsetPresetRow(title: "Low Gain", detail: "Gain \(lmh.lowGain)", action: { cameraManager.applyGainOffsetPreset(.lmhLow) })
                gainOffsetPresetRow(title: "Middle Gain", detail: "Gain \(lmh.middleGain)", action: { cameraManager.applyGainOffsetPreset(.lmhMiddle) })
                gainOffsetPresetRow(
                    title: "High Gain (Lowest Read Noise)", detail: "Gain \(lmh.highGain), Offset \(lmh.highOffset)",
                    action: { cameraManager.applyGainOffsetPreset(.lmhHigh) }
                )
            }
        }
    }

    private func gainOffsetPresetRow(title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apply", action: action)
        }
    }

    // MARK: - Capture ROI (small region -> higher frame rate)

    private enum CaptureROIPreset: Hashable {
        case full
        case custom(width: Int, height: Int)

        static let all: [CaptureROIPreset] = [.full, .custom(width: 640, height: 480), .custom(width: 800, height: 600)]

        var label: String {
            switch self {
            case .full: return "Full Sensor"
            case .custom(let width, let height): return "\(width) × \(height)"
            }
        }
    }

    private var currentROIPreset: CaptureROIPreset {
        guard let width = cameraManager.captureROIWidth, let height = cameraManager.captureROIHeight else { return .full }
        return .custom(width: width, height: height)
    }

    /// `TextField(value:format:)` needs a non-optional `Binding<Int>` — these fall back to the
    /// sensor's own center for display until the user actually edits the field, at which point
    /// `customROICenterX`/`Y` become a real, explicit value.
    private var customROICenterXBinding: Binding<Int> {
        Binding(
            get: { customROICenterX ?? (cameraManager.connectedCamera?.maxWidth ?? 0) / 2 },
            set: { customROICenterX = $0 }
        )
    }
    private var customROICenterYBinding: Binding<Int> {
        Binding(
            get: { customROICenterY ?? (cameraManager.connectedCamera?.maxHeight ?? 0) / 2 },
            set: { customROICenterY = $0 }
        )
    }

    @ViewBuilder
    private var captureROISection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A smaller region reads off the sensor faster, directly increasing achievable frame rate — the same \"small ROI, high FPS\" technique planetary/lunar lucky-imaging workflows rely on. Restarts the live stream to take effect.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Region", selection: Binding(
                get: { currentROIPreset },
                set: { preset in
                    switch preset {
                    case .full:
                        cameraManager.changeCaptureROI(width: nil, height: nil)
                    case .custom(let width, let height):
                        cameraManager.changeCaptureROI(width: width, height: height)
                        customROIWidth = width
                        customROIHeight = height
                    }
                }
            )) {
                ForEach(CaptureROIPreset.all, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if let width = cameraManager.captureROIWidth, let height = cameraManager.captureROIHeight {
                let centerX = cameraManager.captureROICenterX ?? (cameraManager.connectedCamera?.maxWidth ?? 0) / 2
                let centerY = cameraManager.captureROICenterY ?? (cameraManager.connectedCamera?.maxHeight ?? 0) / 2
                Text("Streaming at \(width) × \(height), centered at (\(centerX), \(centerY)) on the sensor — expect noticeably faster live/SER frame rates than full sensor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            customCaptureROIFields
        }
    }

    /// Manual width/height/center entry, for any rectangle — not just the two fixed presets
    /// above. Also the only way to move the ROI off the sensor's default center at all: without
    /// an explicit center, a small ROI would silently sit wherever `ASISetStartPos` last left it
    /// (the sensor's top-left corner, if never called) instead of wherever the actual target is
    /// framed — see `ROIGeometry.startPosition`'s doc comment.
    @ViewBuilder
    private var customCaptureROIFields: some View {
        DisclosureGroup("Custom size & center") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Size")
                        .font(.caption)
                        .frame(width: 44, alignment: .leading)
                    TextField("Width", value: $customROIWidth, format: .number)
                        .frame(width: 70)
                    Text("×")
                    TextField("Height", value: $customROIHeight, format: .number)
                        .frame(width: 70)
                    Text("px").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Center")
                        .font(.caption)
                        .frame(width: 44, alignment: .leading)
                    TextField("X", value: customROICenterXBinding, format: .number)
                        .frame(width: 70)
                    TextField("Y", value: customROICenterYBinding, format: .number)
                        .frame(width: 70)
                    Text("px on sensor").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Apply") {
                        cameraManager.changeCaptureROI(
                            width: customROIWidth, height: customROIHeight,
                            centerX: customROICenterX, centerY: customROICenterY
                        )
                    }
                    Button("Center on Sensor") {
                        if let camera = cameraManager.connectedCamera {
                            customROICenterX = camera.maxWidth / 2
                            customROICenterY = camera.maxHeight / 2
                        }
                    }
                }
                if let camera = cameraManager.connectedCamera {
                    Text("Sensor is \(camera.maxWidth) × \(camera.maxHeight) — width rounds down to a multiple of 8, height to a multiple of 2, and the center clamps so the ROI stays fully on-sensor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            .onAppear {
                if customROICenterX == nil || customROICenterY == nil, let camera = cameraManager.connectedCamera {
                    customROICenterX = cameraManager.captureROICenterX ?? camera.maxWidth / 2
                    customROICenterY = cameraManager.captureROICenterY ?? camera.maxHeight / 2
                }
                if let width = cameraManager.captureROIWidth, let height = cameraManager.captureROIHeight {
                    customROIWidth = width
                    customROIHeight = height
                }
            }
        }
        .font(.caption)
    }

    // MARK: - SER video recording (planetary/lunar workflow)

    @ViewBuilder
    private var serRecordingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Writes every incoming frame, undiscarded, into a single .ser video — the standard format AutoStakkert!3, PIPP, and similar tools expect for their own frame alignment/stacking. Pair with a small Capture ROI above for the classic high-FPS planetary workflow.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if cameraManager.isRecordingSERVideo {
                ProgressView(
                    value: cameraManager.serRecordingElapsedSeconds,
                    total: max(serRecordingDurationSeconds, 0.001)
                ) {
                    Text(String(format: "Recording… %.0fs / %.0fs · %d frames", cameraManager.serRecordingElapsedSeconds, serRecordingDurationSeconds, cameraManager.serRecordedFrameCount))
                        .font(.caption)
                }
                Button("Stop Recording", role: .destructive) { cameraManager.stopSERRecording() }
            } else {
                HStack {
                    Text("\(Int(serRecordingDurationSeconds))s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .leading)
                    Slider(value: $serRecordingDurationSeconds, in: 10...600, step: 10)
                }
                Button("Choose File & Start…") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = []
                    panel.nameFieldStringValue = "capture.ser"
                    panel.prompt = "Start Recording"
                    if panel.runModal() == .OK, let url = panel.url {
                        cameraManager.startSERRecording(to: url, durationSeconds: serRecordingDurationSeconds)
                    }
                }
                .disabled(cameraManager.currentFrame == nil)
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

    // MARK: - ST4 guide port (pulse guiding)

    private var st4GuidingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Untested against real guiding hardware — verify with an actual mount/ST4 cable before relying on this for a real session.", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("Sends a single pulse-guide correction (ASIPulseGuideOn, then off after the duration below) on the camera's ST4 port. The classic manual-guiding sanity check: pulse one direction a few times and confirm the mount actually nudges that way in your guiding software before trusting an automated routine on top of this.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            LabeledContent("Duration") {
                HStack {
                    Slider(value: $st4GuideDurationMilliseconds, in: 20...2000, step: 20)
                    Text("\(Int(st4GuideDurationMilliseconds)) ms")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }

            Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Button("North") { cameraManager.pulseGuide(direction: ASI_GUIDE_NORTH, durationMilliseconds: Int(st4GuideDurationMilliseconds)) }
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
                GridRow {
                    Button("West") { cameraManager.pulseGuide(direction: ASI_GUIDE_WEST, durationMilliseconds: Int(st4GuideDurationMilliseconds)) }
                    Text("").frame(width: 1)
                    Button("East") { cameraManager.pulseGuide(direction: ASI_GUIDE_EAST, durationMilliseconds: Int(st4GuideDurationMilliseconds)) }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Button("South") { cameraManager.pulseGuide(direction: ASI_GUIDE_SOUTH, durationMilliseconds: Int(st4GuideDurationMilliseconds)) }
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
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

            HStack {
                Toggle("Denoise", isOn: Binding(
                    get: { cameraManager.isDenoisingEnabled },
                    set: { cameraManager.isDenoisingEnabled = $0 }
                ))
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.denoise")
            }
            HStack {
                Toggle("Wavelet Sharpening", isOn: Binding(
                    get: { cameraManager.isWaveletSharpeningEnabled },
                    set: { cameraManager.isWaveletSharpeningEnabled = $0 }
                ))
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.waveletSharpening")
            }
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
            if cameraManager.isStreakMaskingEnabled {
                Text(streakStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if cameraManager.useMetalRenderer && cameraManager.isLiveStackDriftReductionEnabled {
                    Label("Streak masking takes priority over Reduce Drift when both are on at once — this live stack won't be alignment-corrected while masking is active.", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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
            Text("Running average of incoming frames — by default no star alignment, so it assumes a tracked, stationary mount. \"Reduce Drift\" below adds basic single-star-lock alignment (GPU only) for mounts that don't track perfectly.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Live Stack", isOn: Binding(
                get: { cameraManager.isLiveStackingEnabled },
                set: { cameraManager.isLiveStackingEnabled = $0 }
            ))

            HStack {
                Toggle("Reduce Drift (align to a locked star)", isOn: Binding(
                    get: { cameraManager.isLiveStackDriftReductionEnabled },
                    set: { cameraManager.isLiveStackDriftReductionEnabled = $0 }
                ))
                .disabled(!cameraManager.useMetalRenderer)
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.liveStackDriftReduction")
            }
            if !cameraManager.useMetalRenderer {
                Label("GPU renderer only — turn on \"GPU\" in the toolbar to use this.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Label("\(cameraManager.liveStackedFrameCount) frames stacked", systemImage: "square.stack.3d.up")
                    .font(.caption)
                if cameraManager.isLiveStackingEnabled && cameraManager.isLiveStackPaused {
                    Text("(paused)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if cameraManager.isLiveStackingEnabled {
                    Button {
                        cameraManager.isLiveStackPaused.toggle()
                    } label: {
                        Label(
                            cameraManager.isLiveStackPaused ? "Resume" : "Pause",
                            systemImage: cameraManager.isLiveStackPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .help(cameraManager.isLiveStackPaused
                        ? "Resumes folding new frames into the stack."
                        : "Freezes the stack exactly as it is right now — new frames stop being added, without losing what's already stacked — so you can actually look at the current result (focus, alignment) before deciding to continue.")
                    Button("Reset") { cameraManager.resetLiveStack() }
                }
            }

            if cameraManager.isLiveStackingEnabled {
                Button {
                    cameraManager.exportCurrentFrame(as: .png)
                } label: {
                    Label("Save Stacked Image…", systemImage: "square.and.arrow.down")
                }
                .disabled(cameraManager.liveStackedFrameCount == 0)
                .help("Saves the stacked average exactly as it looks right now (debayered/stretched, same as the live preview) as a PNG — a quick snapshot, not the raw sensor data FITS export below writes.")
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

    // MARK: - Exported Files (open/view what's already been exported or recorded)

    @ViewBuilder
    private var exportedFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Every export and recording this app has written, oldest first below — plus any FITS/PNG/TIFF file, even from outside skyformac, you want to view here directly.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Open File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data, .png, .tiff, .jpeg]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    cameraManager.openExportedFile(url)
                }
            }

            if cameraManager.exportHistory.isEmpty {
                Text("Nothing exported yet.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(cameraManager.exportHistory.reversed()) { entry in
                    exportHistoryRow(entry)
                }
                Button("Clear History", role: .destructive) { cameraManager.clearExportHistory() }
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func exportHistoryRow(_ entry: ExportHistoryEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.kind.icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.kind.isViewableInApp {
                Button {
                    cameraManager.openExportedFile(entry.url)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.plain)
                .help("View in skyformac")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
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
        case ASI_COOLER_ON, ASI_FAN_ON, ASI_ANTI_DEW_HEATER, ASI_HARDWARE_BIN, ASI_HIGH_SPEED_MODE, ASI_MONO_BIN:
            // Real on/off controls per `ASICamera2.h` (0 or 1, not a range) — a generic slider
            // would let you drag to any integer, most of which aren't meaningful values.
            toggleRow(cap)
        case ASI_EXPOSURE:
            exposureRow(cap)
        case ASI_GAIN:
            gainRow(cap)
        case ASI_FLIP:
            flipRow(cap)
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
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.genericControl")
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
        HStack {
            Toggle(cap.name, isOn: Binding(
                get: { isOn },
                set: { cameraManager.setControlValue(cap.controlType, value: $0 ? 1 : 0) }
            ))
            .disabled(!cap.isWritable)
            .help(cap.controlDescription)
            HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: toggleRowSectionID(cap))
        }
    }

    /// Maps this group of on/off hardware toggles to the two `config-reference` anchors that
    /// actually cover them — `ASI_COOLER_ON`/`ASI_FAN_ON`/`ASI_ANTI_DEW_HEATER` are all
    /// cooling-related, everything else in this switch (`controlRow`'s first case) is a
    /// binning/speed mode.
    private func toggleRowSectionID(_ cap: ZWOControlCaps) -> String {
        switch cap.controlType {
        case ASI_COOLER_ON, ASI_FAN_ON, ASI_ANTI_DEW_HEATER:
            return "setting.cooler"
        default:
            return "setting.binningModes"
        }
    }

    /// The camera's own `ASI_EXPOSURE` control — governs the *continuous live-view video* poll
    /// loop's exposure, a different thing from the "Single Exposure" section above (which
    /// triggers one `ASIStartExposure`/`ASIGetDataAfterExp` still capture via
    /// `captureSingleExposure`). They used to look like duplicates of the same "Exposure"
    /// control because this one used a plain linear `Slider` over the camera's raw µs range —
    /// unusable at the low end (a real ASI sensor's range spans µs to tens of seconds, the same
    /// "linear slider can't cover that" problem `docs/design-notes.md` already documents for the
    /// Single Exposure field) and visually indistinguishable from it. Labeled "Live Exposure" and
    /// reuses the same log-scale `ExposureField` now, so it actually covers 1 µs-to-seconds usably
    /// and reads as the different control it is.
    @ViewBuilder
    private func exposureRow(_ cap: ZWOControlCaps) -> some View {
        let currentMicroseconds = currentValue(for: cap)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Live Exposure")
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.liveExposure")
            }
            if cap.isWritable, cap.minValue < cap.maxValue {
                ExposureField(
                    seconds: Binding(
                        get: { Double(currentMicroseconds) / 1_000_000.0 },
                        set: { cameraManager.setControlValue(cap.controlType, value: Int($0 * 1_000_000)) }
                    ),
                    minSeconds: max(Double(cap.minValue) / 1_000_000.0, 0.000_001),
                    maxSeconds: max(Double(cap.maxValue) / 1_000_000.0, 0.000_002)
                )
            }
        }
        .help("Continuous live-view exposure — different from \"Single Exposure\" above, which captures one still frame. \(cap.controlDescription)")
    }

    /// `ASI_GAIN` — a plain linear `Slider` over the camera's full range (often 0...500+) gives
    /// unusably coarse control right where it matters most: the low, conservative end (0...20)
    /// this app's own default (`ASI_GAIN = 5`, see `CameraManager.connect(to:)`) sits in, since
    /// dragging one pixel of slider width jumps several real gain steps there. `GainField` gives
    /// most of the slider's width to that 0...20 sub-range instead.
    @ViewBuilder
    private func gainRow(_ cap: ZWOControlCaps) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Gain")
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.gain")
            }
            if cap.isWritable, cap.minValue < cap.maxValue {
                GainField(
                    value: Binding(
                        get: { currentValue(for: cap) },
                        set: { cameraManager.setControlValue(cap.controlType, value: $0) }
                    ),
                    minValue: cap.minValue,
                    maxValue: cap.maxValue,
                    fineBreakpoint: min(20, cap.maxValue)
                )
            } else {
                Text(cap.isWritable ? "Fixed value" : "Read-only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(cap.controlDescription)
    }

    /// `ASI_FLIP`: `ASI_FLIP_NONE`/`ASI_FLIP_HORIZ`/`ASI_FLIP_VERT`/`ASI_FLIP_BOTH` (0...3, per
    /// `ASICamera2.h`) — a 4-way mode selector, not a boolean or a freely-draggable range.
    @ViewBuilder
    private func flipRow(_ cap: ZWOControlCaps) -> some View {
        let current = currentValue(for: cap)
        HStack {
            Picker("Flip", selection: Binding(
                get: { current },
                set: { cameraManager.setControlValue(cap.controlType, value: $0) }
            )) {
                Text("None").tag(Int(ASI_FLIP_NONE.rawValue))
                Text("Horizontal").tag(Int(ASI_FLIP_HORIZ.rawValue))
                Text("Vertical").tag(Int(ASI_FLIP_VERT.rawValue))
                Text("Both").tag(Int(ASI_FLIP_BOTH.rawValue))
            }
            .disabled(!cap.isWritable)
            .help(cap.controlDescription)
            HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.flip")
        }
    }

    @ViewBuilder
    private func temperatureReadoutRow(_ cap: ZWOControlCaps) -> some View {
        // ASICamera2.h: ASI_TEMPERATURE "return 10*temperature".
        let celsius = Double(currentValue(for: cap)) / 10.0
        HStack {
            Label("Sensor Temperature", systemImage: "thermometer.medium")
            HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.cooler")
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

/// `ASI_GAIN` control: devotes most (`fineFraction`) of the slider's width to the
/// `minValue...fineBreakpoint` sub-range and the rest to `fineBreakpoint...maxValue` — a
/// piecewise-linear remap of the same shape as `ExposureField`'s log10 mapping, just linear
/// instead of logarithmic (gain doesn't have exposure's natural log distribution across decades;
/// it just needs one deliberate breakpoint at the range that actually matters).
private struct GainField: View {
    @Binding var value: Int
    var minValue: Int
    var maxValue: Int
    var fineBreakpoint: Int
    var fineFraction: Double = 0.7

    /// Slider position in `0...1`, split at `fineFraction` between the two sub-ranges.
    private var position: Binding<Double> {
        Binding(
            get: { Self.toPosition(value, minValue: minValue, maxValue: maxValue, breakpoint: clampedBreakpoint, fineFraction: fineFraction) },
            set: { value = Self.fromPosition($0, minValue: minValue, maxValue: maxValue, breakpoint: clampedBreakpoint, fineFraction: fineFraction) }
        )
    }

    /// `fineBreakpoint` must sit strictly between `minValue` and `maxValue` for the piecewise
    /// split to be meaningful — clamped rather than asserted, since a camera's actual gain range
    /// could in principle be narrower than the requested 0...20 fine zone.
    private var clampedBreakpoint: Int {
        min(max(fineBreakpoint, minValue + 1), maxValue - 1)
    }

    var body: some View {
        HStack {
            Text("\(value)")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .leading)
            Slider(value: position, in: 0...1)
        }
    }

    private static func toPosition(_ value: Int, minValue: Int, maxValue: Int, breakpoint: Int, fineFraction: Double) -> Double {
        let clamped = min(max(value, minValue), maxValue)
        if clamped <= breakpoint {
            let fraction = Double(clamped - minValue) / Double(breakpoint - minValue)
            return fraction * fineFraction
        } else {
            let fraction = Double(clamped - breakpoint) / Double(maxValue - breakpoint)
            return fineFraction + fraction * (1 - fineFraction)
        }
    }

    private static func fromPosition(_ position: Double, minValue: Int, maxValue: Int, breakpoint: Int, fineFraction: Double) -> Int {
        if position <= fineFraction {
            let fraction = position / fineFraction
            return minValue + Int((fraction * Double(breakpoint - minValue)).rounded())
        } else {
            let fraction = (position - fineFraction) / (1 - fineFraction)
            return breakpoint + Int((fraction * Double(maxValue - breakpoint)).rounded())
        }
    }
}
