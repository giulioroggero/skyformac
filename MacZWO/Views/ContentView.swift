import SwiftUI

struct ContentView: View {
    @Environment(CameraManager.self) private var cameraManager
    @State private var useMetalRenderer = false

    var body: some View {
        NavigationSplitView {
            CameraListView(cameraManager: cameraManager)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    PreviewView(cameraManager: cameraManager, useMetalRenderer: useMetalRenderer)
                        .frame(minWidth: 480, minHeight: 300)
                    HistogramView(cameraManager: cameraManager)
                }
                ControlsPanelView(cameraManager: cameraManager)
                    .frame(minWidth: 260, idealWidth: 300)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                imageTypePicker
            }
            ToolbarItem {
                Toggle("Metal Renderer", systemImage: "cpu", isOn: $useMetalRenderer)
                    .help("Switch the live preview between the CPU (CGImage) and GPU (Metal) rendering paths")
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
