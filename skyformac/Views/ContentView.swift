import SwiftUI

struct ContentView: View {
    @Environment(CameraManager.self) private var cameraManager

    var body: some View {
        Group {
            if cameraManager.isPreviewFullScreenEnabled {
                fullScreenPreview
            } else {
                mainContent
            }
        }
        // A `.sheet` on the app's one window, not a second `Window` scene — see
        // `SkyformacApp`'s doc comment for why this app is deliberately single-window.
        .sheet(isPresented: Binding(
            get: { cameraManager.isHelpPresented },
            set: { cameraManager.isHelpPresented = $0 }
        )) {
            HelpView(initialTopicID: cameraManager.helpAnchorTopicID, initialSectionID: cameraManager.helpAnchorSectionID)
        }
        .sheet(isPresented: Binding(
            get: { cameraManager.viewingExportedFile != nil },
            set: { if !$0 { cameraManager.viewingExportedFile = nil } }
        )) {
            ExportedFileViewerView(cameraManager: cameraManager)
        }
        .sheet(isPresented: Binding(
            get: { cameraManager.isAcquisitionWizardPresented },
            set: { cameraManager.isAcquisitionWizardPresented = $0 }
        )) {
            AcquisitionWizardView(cameraManager: cameraManager)
        }
    }

    /// The live video alone, filling the entire window with its own overlay controls (zoom
    /// slider, Exit) — no sidebar, camera list, or histogram competing for attention, for
    /// actually seeing faint stars rather than just previewing framing. Reuses `PreviewView`
    /// itself rather than a separate view, so there's no second rendering path (CPU/GPU, all the
    /// Vision overlays) to keep in sync with the embedded one — see its `onExitFullScreen` doc
    /// comment for exactly what changes between the two presentations.
    private var fullScreenPreview: some View {
        PreviewView(
            cameraManager: cameraManager,
            useMetalRenderer: cameraManager.useMetalRenderer,
            onExitFullScreen: { cameraManager.isPreviewFullScreenEnabled = false }
        )
        .ignoresSafeArea()
        .background(Color.black)
        .colorMultiply(cameraManager.isNightModeEnabled ? .red : .white)
        // `PreviewView`'s own `.onExitCommand` only fires while it (or a descendant) is actually
        // first responder — not guaranteed here, since nothing in this fullscreen presentation
        // necessarily holds keyboard focus. A hidden button with an explicit `.keyboardShortcut`
        // is a real menu-command-equivalent shortcut, not tied to first-responder status, so Esc
        // reliably exits regardless of what currently has focus.
        .background {
            Button("") { cameraManager.isPreviewFullScreenEnabled = false }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { cameraManager.isCameraListSidebarVisible ? .all : .detailOnly },
            set: { cameraManager.isCameraListSidebarVisible = $0 != .detailOnly }
        )) {
            CameraListView(cameraManager: cameraManager)
                // `max` matters here, not just `min`/`ideal` — the "detail" side (the HSplitView
                // below, `PreviewView`/`ControlsPanelView`) has its own real minimum width
                // (480 + 320 = 800pt). Without a cap here, dragging this sidebar wider than what
                // that leaves available forced the *whole window* to grow instead — since
                // `NavigationSplitView` won't shrink `detail` below its declared minimum, growing
                // the window was its only way to satisfy both at once, which could push the
                // window partly off-screen on a smaller display. Capped comfortably under that
                // threshold so this column always resizes within the existing window instead, the
                // same way dragging the divider between `PreviewView`/`ControlsPanelView` already
                // does (a plain `HSplitView`, which never grows the window either).
                .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 280)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    PreviewView(
                        cameraManager: cameraManager,
                        useMetalRenderer: cameraManager.useMetalRenderer,
                        onEnterFullScreen: { cameraManager.isPreviewFullScreenEnabled = true }
                    )
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
                if cameraManager.isExternalWebcam {
                    Button("Disconnect Camera", systemImage: "xmark.circle") {
                        cameraManager.disconnect()
                    }
                    .help("Stop the iPhone/webcam feed and return to the disconnected state")
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
        // Drag a FITS/PNG/TIFF/JPEG file (from Finder, or the Exported Files section's own
        // history rows) anywhere onto the window to open it — the same native "just drop it on
        // the app" interaction macOS users already expect, rather than requiring the Camera
        // Controls tab's "Open File…" button every time. `openExportedFile` already handles an
        // unsupported extension by explaining why in the viewer sheet, so no extension
        // filtering/validation is needed here.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            cameraManager.openExportedFile(url)
            return true
        }
    }

    @ViewBuilder
    private var imageTypePicker: some View {
        // RGB24-only sources (webcam/iPhone) have no RAW8/RAW16 to switch between — showing an
        // empty segmented control would be worse than showing none.
        if let camera = cameraManager.connectedCamera,
           camera.supportedVideoFormats.contains(ASI_IMG_RAW8) || camera.supportedVideoFormats.contains(ASI_IMG_RAW16) {
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
