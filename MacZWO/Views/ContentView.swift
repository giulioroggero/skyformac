import SwiftUI

struct ContentView: View {
    @Environment(CameraManager.self) private var cameraManager

    var body: some View {
        NavigationSplitView {
            CameraListView(cameraManager: cameraManager)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    PreviewView(cameraManager: cameraManager, useMetalRenderer: cameraManager.useMetalRenderer)
                        .frame(minWidth: 480, minHeight: 300)
                        .overlay(alignment: .bottomTrailing) {
                            if cameraManager.isAllSkyMonitorVisible {
                                AllSkyMonitorView()
                                    .frame(width: 220)
                                    .padding(12)
                            }
                        }
                    HistogramView(cameraManager: cameraManager, useMetalRenderer: cameraManager.useMetalRenderer)
                }
                ControlsPanelView(cameraManager: cameraManager)
                    .frame(minWidth: 320, idealWidth: 340)
            }
        }
        // Night mode: preserves dark adaptation by rendering the whole content area in red only
        // (green/blue channels zeroed via component-wise color multiplication). Applied to the
        // SwiftUI content, not the native window toolbar chrome above it.
        .compositingGroup()
        .colorMultiply(cameraManager.isNightModeEnabled ? .red : .white)
        .toolbar {
            ToolbarItem(placement: .principal) {
                imageTypePicker
            }
            ToolbarItem {
                Toggle(isOn: Binding(
                    get: { cameraManager.useMetalRenderer },
                    set: { cameraManager.useMetalRenderer = $0 }
                )) {
                    Label(
                        cameraManager.useMetalRenderer ? "GPU" : "CPU",
                        systemImage: cameraManager.useMetalRenderer ? "bolt.fill" : "cpu"
                    )
                    .foregroundStyle(cameraManager.useMetalRenderer ? .green : .primary)
                }
                .help(cameraManager.useMetalRenderer
                    ? "Rendering on GPU (Metal compute shaders). Click to switch to the CPU (CGImage) path."
                    : "Rendering on CPU (CGImage). Click to switch to the GPU (Metal) path.")
                .accessibilityIdentifier("RenderPathToggle")
            }
            ToolbarItem {
                Toggle("Night Mode", systemImage: "moon.stars.fill", isOn: Binding(
                    get: { cameraManager.isNightModeEnabled },
                    set: { cameraManager.isNightModeEnabled = $0 }
                ))
                    .help("Red-only UI to preserve night vision during visual observation")
            }
            ToolbarItem {
                Toggle("All-Sky Monitor", systemImage: "cloud.sun", isOn: Binding(
                    get: { cameraManager.isAllSkyMonitorVisible },
                    set: { cameraManager.isAllSkyMonitorVisible = $0 }
                ))
                    .help("Picture-in-picture feed from a secondary webcam or nearby iPhone (Continuity Camera) for watching clouds/cables")
            }
            ToolbarItem {
                if cameraManager.isSimulating {
                    Button("Exit Demo Mode", systemImage: "xmark.circle") {
                        cameraManager.disconnect()
                    }
                    .help("Stop the simulated camera and return to the disconnected state")
                }
            }
            ToolbarItem(placement: .status) {
                statusText
            }
        }
        .alert(
            "Camera Error",
            isPresented: errorBinding,
            presenting: cameraManager.lastErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var imageTypePicker: some View {
        if let camera = cameraManager.connectedCamera {
            Picker("Format", selection: Binding(
                get: { cameraManager.selectedImageType.rawValue },
                set: { raw in
                    cameraManager.changeImageType(ASI_IMG_TYPE(rawValue: raw))
                }
            )) {
                if camera.supportedVideoFormats.contains(ASI_IMG_RAW8) {
                    Text("RAW8").tag(ASI_IMG_RAW8.rawValue)
                }
                if camera.supportedVideoFormats.contains(ASI_IMG_RAW16) {
                    Text("RAW16").tag(ASI_IMG_RAW16.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }

    private var statusText: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption)
            Text("SDK \(ZWOSDK.sdkVersion())")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch cameraManager.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .streaming: return "Streaming"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        switch cameraManager.connectionState {
        case .disconnected: return .gray
        case .connecting: return .yellow
        case .connected, .streaming: return .green
        case .error: return .red
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { cameraManager.lastErrorMessage != nil },
            set: { if !$0 { } }
        )
    }
}
