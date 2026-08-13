import SwiftUI

/// "Point at an object, get the best setup for it" — picks a target (a `PlanetaryPreset` or
/// `DeepSkyObject`, wrapped as `AcquisitionTarget`), shows/edits its recommended
/// `AcquisitionPreset` (mode, ROI, gain, exposure, Reduce Drift/Smart Live Stack), and applies it
/// in one step via `CameraManager.applyAcquisitionPreset`. Presets round-trip to their own JSON
/// file (`saveAcquisitionPreset`/`loadAcquisitionPreset`), one file per preset, so a favorite
/// setup (a specific object under a specific telescope/camera pairing) survives beyond one
/// session without needing to re-derive it from scratch each time.
///
/// Deliberately still just a *setup* step, not a new capture technique of its own — applying a
/// preset only turns on/configures features (Live Stack, Reduce Drift, Smart Live Stack, Capture
/// ROI, Lucky Imaging's burst count) that already exist and are already documented on their own
/// terms elsewhere; this view's whole job is picking sensible starting values for them per
/// target, the same "starting point, not a promise" philosophy `PlanetaryPreset` already uses.
struct AcquisitionWizardView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTarget: AcquisitionTarget?
    @State private var workingPreset: AcquisitionPreset?
    @State private var presetName: String = ""
    @State private var loadedFromUnknownTarget = false
    @State private var confirmationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The target list is a picker, not the main content — it should read as roughly a
            // quarter of the editor pane's width, not split evenly with it. `idealWidth` values
            // are in that 1:4 ratio (220:880); `maxWidth` on the list keeps it from being dragged
            // much wider than that and crowding out the editor, which still gets the rest via
            // `maxWidth: .infinity`.
            HSplitView {
                targetList
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 320, maxHeight: .infinity)
                Group {
                    if let workingPreset {
                        presetEditor(workingPreset)
                    } else {
                        Text("Pick a target on the left to see its recommended setup, or Load Preset… above.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding()
                .frame(minWidth: 440, idealWidth: 880, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Sized generously — the target list (two sections, several rows each, each with a
        // secondary caption line) plus the preset editor's own grid of fields need real room;
        // the previous, much smaller fixed minimum left both cramped enough that the recommended
        // settings grid effectively disappeared off the bottom of the editor pane unscrolled in
        // practice. `idealWidth`/`idealHeight` open it close to a full display by default rather
        // than at the bare minimum.
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 760)
    }

    private var header: some View {
        HStack {
            Text("Acquisition Wizard").font(.headline)
            Spacer()
            // Only actually changes anything for a `.planetary` target's starting exposure (see
            // `AcquisitionTarget.recommendedPreset(name:telescope:)`'s doc comment) — shown
            // regardless of which target is currently selected, since switching telescopes mid-
            // session (or before picking a target at all) should still stick for whichever
            // planetary target gets picked next.
            Picker("Telescope", selection: Binding(
                get: { cameraManager.telescopeProfile },
                set: { newValue in
                    cameraManager.telescopeProfile = newValue
                    if let selectedTarget, case .planetary = selectedTarget {
                        workingPreset?.exposureSeconds = selectedTarget.recommendedPreset(telescope: newValue).exposureSeconds
                    }
                }
            )) {
                ForEach(TelescopeProfile.allCases) { telescope in
                    Text(telescope.rawValue).tag(telescope)
                }
            }
            .frame(width: 260)
            Button("Load Preset…") {
                cameraManager.loadAcquisitionPreset { preset, target in
                    workingPreset = preset
                    presetName = preset.name
                    selectedTarget = target
                    loadedFromUnknownTarget = target == nil
                }
            }
            Button("Close") { dismiss() }
        }
        .padding()
    }

    @ViewBuilder
    private var targetList: some View {
        List(selection: Binding(
            get: { selectedTarget },
            set: { newTarget in
                selectedTarget = newTarget
                loadedFromUnknownTarget = false
                guard let newTarget else { return }
                let preset = newTarget.recommendedPreset(telescope: cameraManager.telescopeProfile)
                workingPreset = preset
                presetName = preset.name
            }
        )) {
            Section("Planetary") {
                ForEach(AcquisitionTarget.all.filter { if case .planetary = $0 { return true }; return false }) { target in
                    targetRow(target).tag(target)
                }
            }
            Section("Deep Sky") {
                ForEach(AcquisitionTarget.all.filter { if case .deepSky = $0 { return true }; return false }) { target in
                    targetRow(target).tag(target)
                }
            }
        }
    }

    private func targetRow(_ target: AcquisitionTarget) -> some View {
        HStack {
            Image(systemName: target.icon)
                .frame(width: 20)
            VStack(alignment: .leading) {
                Text(target.name)
                Text(target.recommendedMode.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func presetEditor(_ preset: AcquisitionPreset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loadedFromUnknownTarget {
                    Label("This preset's target isn't one this build recognizes — settings below still apply normally, just without a matching description.", systemImage: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let selectedTarget {
                    Text(selectedTarget.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)

                Picker("Mode", selection: modeBinding) {
                    ForEach(AcquisitionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    if let gain = preset.gain {
                        GridRow {
                            Text("Gain").font(.caption)
                            Stepper(value: gainBinding, in: 0...600) {
                                Text("\(gain)").font(.caption.monospacedDigit())
                            }
                        }
                    }
                    if let exposure = preset.exposureSeconds {
                        GridRow {
                            Text("Exposure").font(.caption)
                            Stepper(value: exposureBinding, in: 0.0001...30, step: exposure < 1 ? 0.0005 : 0.5) {
                                Text(exposure < 1 ? String(format: "%.4f s", exposure) : String(format: "%.2f s", exposure))
                                    .font(.caption.monospacedDigit())
                            }
                        }
                    }
                    if let width = preset.roiWidth, let height = preset.roiHeight {
                        GridRow {
                            Text("ROI").font(.caption)
                            Text("\(width) × \(height)").font(.caption.monospacedDigit())
                        }
                    }
                    if preset.mode.usesLiveStack {
                        GridRow {
                            Text("Reduce Drift").font(.caption)
                            Toggle("", isOn: driftReductionBinding).labelsHidden()
                        }
                        GridRow {
                            Text("Smart Live Stack").font(.caption)
                            Toggle("", isOn: smartLiveStackBinding).labelsHidden()
                        }
                        GridRow {
                            HStack(spacing: 4) {
                                Text("Mesh Drift Correction").font(.caption)
                                Text("Experimental")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                            Toggle("", isOn: meshDriftCorrectionBinding).labelsHidden()
                        }
                        .help("Tracks a grid of points instead of one locked star — worth trying for a long, multi-minute-plus integration where field rotation or differential drift matters (e.g. an alt-az mount), not needed for a short session. Takes priority over \"Reduce Drift\" above when both are on.")
                    }
                    if let burstCount = preset.luckyBurstCount {
                        GridRow {
                            Text("Lucky burst count").font(.caption)
                            Stepper(value: burstCountBinding, in: 5...500, step: 5) {
                                Text("\(burstCount) frames").font(.caption.monospacedDigit())
                            }
                        }
                    }
                    if let duration = preset.serDurationSeconds {
                        GridRow {
                            Text("SER duration").font(.caption)
                            Text(String(format: "%.0f s", duration)).font(.caption.monospacedDigit())
                        }
                    }
                }

                Divider()

                HStack {
                    Button {
                        cameraManager.applyAcquisitionPreset(preset)
                        confirmationMessage = cameraManager.isExternalWebcam
                            ? "Applied — Live Stack/Lucky Imaging mode is set; " + (preset.mode.usesLuckyImaging ? "start a burst when ready." : "Live Stack is running.")
                            : "Applied — Live Exposure, Gain, and ROI are set; " +
                                (preset.mode.usesLuckyImaging ? "start a Lucky Imaging burst when ready." : "Live Stack is running.")
                    } label: {
                        Label("Apply Setup", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(cameraManager.connectedCamera == nil)

                    Button {
                        cameraManager.saveAcquisitionPreset(withName(preset))
                    } label: {
                        Label("Save Preset…", systemImage: "square.and.arrow.down")
                    }
                }

                if cameraManager.isExternalWebcam {
                    // Genuinely applies here, unlike the old "ZWO cameras only" message this
                    // replaced — Live Stack/Lucky Imaging/Smart Live Stack all already work for
                    // an RGB24 (webcam/iPhone) source (see `LiveStacker`/`SharpnessScorer`'s own
                    // RGB24 cases). ROI/gain/exposure/Reduce Drift are the genuine exceptions:
                    // the first three have no hardware equivalent on this source at all, and
                    // Reduce Drift's GPU accumulator is mono-only, so it gets set but does nothing
                    // visible — worth saying plainly rather than implying it takes effect.
                    Label("On an iPhone/webcam source, Live Stack/Lucky Imaging/Smart Live Stack apply normally — ROI, Gain, Exposure, and Reduce Drift don't (no hardware equivalent, or Reduce Drift's GPU accumulator being mono-only).", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if cameraManager.connectedCamera == nil {
                    Label("Connect a camera to apply a setup.", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if let confirmationMessage {
                    Text(confirmationMessage)
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private func withName(_ preset: AcquisitionPreset) -> AcquisitionPreset {
        var updated = preset
        updated.name = presetName.isEmpty ? preset.name : presetName
        return updated
    }

    private var modeBinding: Binding<AcquisitionMode> {
        Binding(get: { workingPreset?.mode ?? .liveStack }, set: { workingPreset?.mode = $0 })
    }
    private var gainBinding: Binding<Int> {
        Binding(get: { workingPreset?.gain ?? 0 }, set: { workingPreset?.gain = $0 })
    }
    private var exposureBinding: Binding<Double> {
        Binding(get: { workingPreset?.exposureSeconds ?? 0 }, set: { workingPreset?.exposureSeconds = $0 })
    }
    private var driftReductionBinding: Binding<Bool> {
        Binding(get: { workingPreset?.isDriftReductionEnabled ?? false }, set: { workingPreset?.isDriftReductionEnabled = $0 })
    }
    private var smartLiveStackBinding: Binding<Bool> {
        Binding(get: { workingPreset?.isSmartLiveStackEnabled ?? false }, set: { workingPreset?.isSmartLiveStackEnabled = $0 })
    }
    private var meshDriftCorrectionBinding: Binding<Bool> {
        Binding(
            get: { workingPreset?.isMeshDriftCorrectionEnabled ?? false },
            set: { workingPreset?.isMeshDriftCorrectionEnabled = $0 }
        )
    }
    private var burstCountBinding: Binding<Int> {
        Binding(get: { workingPreset?.luckyBurstCount ?? 60 }, set: { workingPreset?.luckyBurstCount = $0 })
    }
}
