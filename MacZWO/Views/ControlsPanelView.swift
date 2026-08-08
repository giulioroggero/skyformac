import SwiftUI

/// Dynamically builds one control (slider/toggle) per `ASI_CONTROL_CAPS` the connected camera
/// reports, rather than hardcoding gain/exposure/cooler fields — per spec Milestone 3. A handful
/// of well-known control types (exposure, cooler on/off, temperature) get a friendlier
/// presentation than a raw min/max slider; everything else falls back to a generic slider.
struct ControlsPanelView: View {
    var cameraManager: CameraManager
    @State private var exposureSeconds: Double = 1.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if cameraManager.connectedCamera != nil {
                    singleExposureSection
                    Divider()
                    Toggle("Focus Assist (star detection)", isOn: Binding(
                        get: { cameraManager.isFocusAssistEnabled },
                        set: { cameraManager.isFocusAssistEnabled = $0 }
                    ))
                    .help("Detects point sources in the live preview via Vision and shows a sharpness readout to help focusing.")
                    if let assist = cameraManager.focusAssist {
                        focusAssistSummary(assist)
                    }
                    Divider()
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

    @ViewBuilder
    private var singleExposureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Single Exposure").font(.headline)
            HStack {
                Text(String(format: "%.1f s", exposureSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .leading)
                Slider(value: $exposureSeconds, in: 0.1...60)
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

    @ViewBuilder
    private func focusAssistSummary(_ assist: FocusAssistResult) -> some View {
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
