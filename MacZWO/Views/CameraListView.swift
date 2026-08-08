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
                    cameraManager.refreshWebcams()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan for connected ASI cameras and iPhone/webcam sources")
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

            webcamSection

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
        .onAppear { cameraManager.refreshWebcams() }
    }

    /// iPhone (Continuity Camera, wired over USB or wireless) or other AVFoundation webcam as a
    /// primary capture source — e.g. holding an iPhone to a telescope eyepiece (afocal
    /// projection) for lunar/planetary shots. Separate from the ZWO SDK camera list above since
    /// it's a completely different connect path (`CameraManager.connectToWebcam`).
    @ViewBuilder
    private var webcamSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhone / Webcam").font(.headline)
            if cameraManager.availableWebcams.isEmpty {
                Text("No iPhone or webcam found. Connect an iPhone via USB (or have it nearby, signed into the same Apple ID, for wireless Continuity Camera) and rescan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cameraManager.availableWebcams, id: \.uniqueID) { device in
                    HStack {
                        Text(device.localizedName)
                        Spacer()
                        if cameraManager.connectedCamera?.name == device.localizedName && cameraManager.isExternalWebcam {
                            Button("Disconnect") { cameraManager.disconnect() }
                        } else {
                            Button("Connect") {
                                Task { await cameraManager.connectToWebcam(device) }
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
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
