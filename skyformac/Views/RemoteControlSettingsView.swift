import SwiftUI

/// Settings' "Remote" tab — starts/stops `CameraManager.remoteControlServer` and shows whatever a
/// user needs to actually pair: the on-screen pairing code while a phone is connecting, and basic
/// connection status once paired. See `specs/skyformac_Mobile_Remote_Spec.md`.
struct RemoteControlSettingsView: View {
    var cameraManager: CameraManager
    @State private var startErrorMessage: String?

    private var server: RemoteControlServer { cameraManager.remoteControlServer }

    var body: some View {
        Form {
            Section("Skyformac Remote") {
                Toggle("Enable Remote Access", isOn: Binding(
                    get: { server.isRunning },
                    set: { newValue in newValue ? start() : server.stop() }
                ))
                Text("Lets \"Skyformac Remote\" on your iPhone browse projects, watch a live view, and start/stop capture — over your local network only. No internet access, no account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let startErrorMessage {
                    Text(startErrorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            if server.isRunning {
                Section("Status") {
                    if let code = server.pendingPairingCode {
                        LabeledContent("Pairing Code") {
                            Text(code)
                                .font(.title2.monospacedDigit().bold())
                                .textSelection(.enabled)
                        }
                        Text("Enter this code in Skyformac Remote on your iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let connectionDescription = server.connectionDescription {
                        LabeledContent("Connected", value: connectionDescription)
                    } else {
                        Text("Waiting for a connection…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func start() {
        do {
            try server.start()
            startErrorMessage = nil
        } catch {
            startErrorMessage = error.localizedDescription
        }
    }
}
