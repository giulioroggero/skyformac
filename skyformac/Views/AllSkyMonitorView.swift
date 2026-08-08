import AVFoundation
import SwiftUI

/// Picture-in-picture live view of `AllSkyMonitor`'s capture session (a secondary webcam or
/// Continuity Camera iPhone) via `AVCaptureVideoPreviewLayer` — the standard AVFoundation way to
/// show a live camera feed in an AppKit view.
private struct CaptureSessionPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

/// Small floating panel: device picker, start/stop, and the live PiP preview — an all-sky/cloud/
/// rig safety monitor that has nothing to do with the ZWO capture pipeline, so it's deliberately
/// a self-contained overlay rather than wired into `CameraManager`.
struct AllSkyMonitorView: View {
    @StateObject private var monitor = AllSkyMonitor()
    @State private var selectedDeviceID: String?
    @State private var isShowingAddiPhoneSheet = false

    private var continuityCameraDevices: [AVCaptureDevice] {
        monitor.availableDevices.filter { $0.deviceType == .continuityCamera }
    }

    private var otherDevices: [AVCaptureDevice] {
        monitor.availableDevices.filter { $0.deviceType != .continuityCamera }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("All-Sky / Rig Monitor").font(.caption.bold())
                Spacer()
                Button {
                    isShowingAddiPhoneSheet = true
                } label: {
                    Image(systemName: "iphone.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Add an iPhone as a wireless all-sky camera via Continuity Camera")
                Button {
                    monitor.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Rescan for cameras (built-in, external, or a nearby iPhone via Continuity Camera)")
            }

            if monitor.availableDevices.isEmpty {
                Text("No secondary camera found. Tap the iPhone icon above to add one, or connect a webcam.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Source", selection: $selectedDeviceID) {
                    if !continuityCameraDevices.isEmpty {
                        Section("iPhone (Continuity Camera)") {
                            ForEach(continuityCameraDevices, id: \.uniqueID) { device in
                                Label(device.localizedName, systemImage: "iphone").tag(Optional(device.uniqueID))
                            }
                        }
                    }
                    if !otherDevices.isEmpty {
                        Section("Other Cameras") {
                            ForEach(otherDevices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(Optional(device.uniqueID))
                            }
                        }
                    }
                }
                .labelsHidden()
                .font(.caption)

                if monitor.isRunning {
                    CaptureSessionPreview(session: monitor.session)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            if monitor.isCloudOrLightAlert || monitor.isMotionAlert {
                                VStack(alignment: .leading, spacing: 2) {
                                    if monitor.isCloudOrLightAlert {
                                        Label("Sky brightness changed", systemImage: "cloud.fill")
                                    }
                                    if monitor.isMotionAlert {
                                        Label("Motion detected", systemImage: "exclamationmark.triangle.fill")
                                    }
                                }
                                .font(.caption2.bold())
                                .padding(4)
                                .background(.red.opacity(0.85))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                            }
                        }
                    Button("Stop") { monitor.stop() }
                } else {
                    Button("Start Monitoring") {
                        guard let id = selectedDeviceID,
                              let device = monitor.availableDevices.first(where: { $0.uniqueID == id })
                        else { return }
                        monitor.start(with: device)
                    }
                    .disabled(selectedDeviceID == nil)
                }
            }

            if let error = monitor.lastErrorMessage {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            monitor.refreshDevices()
            selectedDeviceID = continuityCameraDevices.first?.uniqueID ?? monitor.availableDevices.first?.uniqueID
        }
        .onChange(of: monitor.availableDevices.count) {
            guard selectedDeviceID == nil || !monitor.availableDevices.contains(where: { $0.uniqueID == selectedDeviceID }) else { return }
            selectedDeviceID = continuityCameraDevices.first?.uniqueID ?? monitor.availableDevices.first?.uniqueID
        }
        .sheet(isPresented: $isShowingAddiPhoneSheet) {
            AddiPhoneCompanionSheet(monitor: monitor, isPresented: $isShowingAddiPhoneSheet)
        }
    }
}

/// Continuity Camera has no in-app "pair now" API — macOS discovers a nearby, signed-in iPhone
/// on its own once the system-level prerequisites are met. This sheet can't trigger that
/// discovery directly; it just makes the prerequisites and current discovery state visible, and
/// offers a Refresh button that re-runs `AVCaptureDevice.DiscoverySession`.
private struct AddiPhoneCompanionSheet: View {
    @ObservedObject var monitor: AllSkyMonitor
    @Binding var isPresented: Bool

    private var foundDevices: [AVCaptureDevice] {
        monitor.availableDevices.filter { $0.deviceType == .continuityCamera }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add iPhone as All-Sky Camera", systemImage: "iphone.badge.plus")
                .font(.headline)

            Text("macOS discovers a nearby iPhone automatically via Continuity Camera — there's no manual pairing step in skyformac itself. To make it appear here:")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label("Sign in to the same Apple ID on both the Mac and the iPhone", systemImage: "1.circle")
                Label("Turn on Wi-Fi, Bluetooth, and Handoff on both devices", systemImage: "2.circle")
                Label("Keep the iPhone nearby, awake, and unlocked (or mounted on the rig)", systemImage: "3.circle")
                Label("Wait a few seconds, then tap Refresh below", systemImage: "4.circle")
            }
            .font(.callout)

            Divider()

            if foundDevices.isEmpty {
                Label("No iPhone found yet", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(foundDevices, id: \.uniqueID) { device in
                    Label(device.localizedName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HStack {
                Button("Refresh") { monitor.refreshDevices() }
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
