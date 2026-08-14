import SwiftUI

/// The app's central preferences — a `.sheet` (this app is deliberately single-window; see
/// `SkyformacApp`), not a real `Settings` scene. Currently just the Projects folder location —
/// the one setting genuinely useful to change and otherwise buried with no UI at all — plus the
/// rendering/night-mode toggles already in the camera view's toolbar, gathered here too so
/// there's one place to review every persisted preference, not just the ones with room for a
/// toolbar button.
struct SettingsView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var customPath: String? = AppSettings.customProjectsRootDirectoryPath

    private var currentProjectsFolder: URL {
        customPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProjectStore.defaultRootDirectory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Form {
                Section("Projects Folder") {
                    Text(currentProjectsFolder.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Choose Folder…") { chooseFolder() }
                        if customPath != nil {
                            Button("Reset to Default") {
                                customPath = nil
                                AppSettings.customProjectsRootDirectoryPath = nil
                            }
                        }
                    }
                    Text("Takes effect the next time Skyformac launches — existing project files stay right where they are and aren't moved automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Rendering") {
                    Toggle("Use Metal (GPU) Renderer", isOn: Binding(
                        get: { cameraManager.useMetalRenderer },
                        set: { cameraManager.useMetalRenderer = $0 }
                    ))
                    Toggle("Night Mode", isOn: Binding(
                        get: { cameraManager.isNightModeEnabled },
                        set: { cameraManager.isNightModeEnabled = $0 }
                    ))
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 380)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentProjectsFolder
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            customPath = url.path
            AppSettings.customProjectsRootDirectoryPath = url.path
        }
    }
}
