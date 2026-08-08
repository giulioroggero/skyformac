import SwiftUI

struct CameraListView: View {
    var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cameras")
                    .font(.headline)
                Spacer()
                Button {
                    cameraManager.refreshCameraList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan for connected ASI cameras")
            }

            if cameraManager.availableCameras.isEmpty {
                ContentUnavailableView(
                    "No ZWO Cameras Found",
                    systemImage: "camera.metering.none",
                    description: Text("Connect an ASI camera over USB, then rescan.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(cameraManager.availableCameras) { camera in
                    cameraRow(camera)
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("No hardware handy? Exercise the full pipeline (debayer, histogram, Metal render) with a synthetic pattern:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Simulate Mono") { cameraManager.simulateTestPattern(color: false) }
                    Button("Simulate Color") { cameraManager.simulateTestPattern(color: true) }
                }
                .controlSize(.small)

                Text("Or a recognizable demo target (real positions/magnitudes from Stellarium's catalog):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Menu("Demo Target…") {
                    Section("Planets") {
                        Button("Jupiter") { cameraManager.simulateDemoTarget(.jupiter) }
                        Button("Saturn") { cameraManager.simulateDemoTarget(.saturn) }
                        Button("Mars") { cameraManager.simulateDemoTarget(.mars) }
                    }
                    Section("Stars") {
                        Button("Star Field") { cameraManager.simulateDemoTarget(.starField) }
                    }
                    Section("Deep Sky") {
                        ForEach(DemoTarget.deepSkyShowcase) { target in
                            Button(target.displayName) { cameraManager.simulateDemoTarget(target) }
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func cameraRow(_ camera: ZWOCameraInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(camera.name).font(.body.bold())
                Text("\(camera.maxWidth)×\(camera.maxHeight) · \(camera.bitDepth)-bit · \(camera.isColorCamera ? "Color" : "Mono")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if cameraManager.connectedCamera == camera {
                Button("Disconnect") { cameraManager.disconnect() }
            } else {
                Button("Connect") {
                    Task { await cameraManager.connect(to: camera) }
                }
                .disabled(cameraManager.connectionState == .connecting)
            }
        }
    }
}
