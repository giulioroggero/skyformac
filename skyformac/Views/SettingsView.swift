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
    @State private var isTestingOllama = false
    @State private var ollamaTestResult: OllamaTestResult?

    private var currentProjectsFolder: URL {
        customPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProjectStore.defaultRootDirectory()
    }

    /// What "Test Connection" actually reports — reachability plus every installed model, since
    /// "is it working" for a local Ollama setup really means both at once: a server that answers
    /// but has nothing pulled is just as unusable as one that isn't running at all (see
    /// `OllamaError.noModelsInstalled`).
    private struct OllamaTestResult {
        var isReachable: Bool
        var installedModels: [String]
        var errorMessage: String?

        /// Mirrors `OllamaPlanner.resolveModel()`'s own preference order — what "Ask AI to
        /// Plan…"/"Ask AI to Describe…" will actually use, not just "something is installed."
        var modelThatWouldBeUsed: String? {
            if installedModels.contains(OllamaPlanner.preferredModel) { return OllamaPlanner.preferredModel }
            return installedModels.first
        }
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

                Section("AI (Ollama)") {
                    LabeledContent("Server") {
                        Text(cameraManager.ollamaPlanner.baseURL.absoluteString).foregroundStyle(.secondary)
                    }
                    LabeledContent("Preferred Model") {
                        Text(OllamaPlanner.preferredModel).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Test Connection") { Task { await testOllama() } }
                            .disabled(isTestingOllama)
                        if isTestingOllama {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let result = ollamaTestResult {
                        if result.isReachable {
                            Label("Reachable", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if result.installedModels.isEmpty {
                                Text("No models installed — run `ollama pull <model>` first.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Installed models: \(result.installedModels.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let used = result.modelThatWouldBeUsed {
                                    Text("Will use: \(used)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Label(result.errorMessage ?? "Not reachable", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    Text("Used by \"Ask AI to Plan…\" and \"Ask AI to Describe…\" — requires a local Ollama server; see [ollama.com](https://ollama.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 520)
    }

    /// `isAvailable()` alone only confirms the server answers at all — a real "does this work"
    /// check also needs `installedModels()`, since a reachable server with nothing pulled fails
    /// every actual plan/describe request the exact same way an unreachable one does.
    private func testOllama() async {
        isTestingOllama = true
        defer { isTestingOllama = false }
        let planner = cameraManager.ollamaPlanner
        guard await planner.isAvailable() else {
            ollamaTestResult = OllamaTestResult(isReachable: false, installedModels: [], errorMessage: "Couldn't reach the Ollama server.")
            return
        }
        do {
            let models = try await planner.installedModels()
            ollamaTestResult = OllamaTestResult(isReachable: true, installedModels: models, errorMessage: nil)
        } catch {
            ollamaTestResult = OllamaTestResult(isReachable: true, installedModels: [], errorMessage: String(describing: error))
        }
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
