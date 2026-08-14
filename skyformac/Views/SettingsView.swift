import AppKit
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
    @State private var customEquipmentPath: String? = AppSettings.customEquipmentDirectoryPath
    @State private var customKnowledgeBasePath: String? = AppSettings.customKnowledgeBaseDirectoryPath
    @State private var isTestingOllama = false
    @State private var ollamaTestResult: OllamaTestResult?
    @State private var serverURLText = AppSettings.ollamaServerURL.absoluteString
    @State private var selectedModel: String? = AppSettings.ollamaModel
    @State private var sessionSuggestionSkill = AppSettings.sessionSuggestionSkill

    private var currentProjectsFolder: URL {
        customPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProjectStore.defaultRootDirectory()
    }

    private var currentEquipmentFolder: URL {
        customEquipmentPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? EquipmentLibrary.defaultRootDirectory()
    }

    private var currentKnowledgeBaseFolder: URL {
        customKnowledgeBasePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AstronomyKnowledgeBase.defaultRootDirectory()
    }

    /// The Model picker's own choices — every model "Test Connection" last found installed, plus
    /// whatever's currently pinned even if a test hasn't been run yet (or found something
    /// different since) — so the picker never silently shows a blank selection for a model that's
    /// still actually configured.
    private var availableModelChoices: [String] {
        var models = ollamaTestResult?.installedModels ?? []
        if let selectedModel, !models.contains(selectedModel) {
            models.append(selectedModel)
        }
        return models
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

                Section("Equipment Folder") {
                    Text(currentEquipmentFolder.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Choose Folder…") { chooseEquipmentFolder() }
                        if customEquipmentPath != nil {
                            Button("Reset to Default") {
                                customEquipmentPath = nil
                                AppSettings.customEquipmentDirectoryPath = nil
                            }
                        }
                    }
                    Text("Takes effect the next time Skyformac launches — existing equipment files stay right where they are and aren't moved automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Astronomy Knowledge") {
                    Text(currentKnowledgeBaseFolder.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Choose Folder…") { chooseKnowledgeBaseFolder() }
                        if customKnowledgeBasePath != nil {
                            Button("Reset to Default") {
                                customKnowledgeBasePath = nil
                                AppSettings.customKnowledgeBaseDirectoryPath = nil
                            }
                        }
                        Button("Reveal in Finder") {
                            AstronomyKnowledgeBase.ensureDefaultsExist(in: currentKnowledgeBaseFolder)
                            NSWorkspace.shared.activateFileViewerSelecting([currentKnowledgeBaseFolder])
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Restore Default Content") {
                            AstronomyKnowledgeBase.restoreDefaults(in: currentKnowledgeBaseFolder)
                        }
                    }
                    Text("A folder of plain `.md` files — general astronomy facts (Messier season, planet visibility rules) folded into every AI request, so a local model has real reference material instead of guessing. Add, edit, or remove any `.md` file directly in Finder; \"Restore Default Content\" resets just the shipped defaults back to their original text, leaving anything else you've added untouched.")
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
                        TextField("Server URL", text: $serverURLText, prompt: Text("http://localhost:11434"))
                            .onSubmit(applyServerURL)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Model", selection: $selectedModel) {
                        Text("Auto (recommended)").tag(String?.none)
                        ForEach(availableModelChoices, id: \.self) { model in
                            Text(model).tag(String?.some(model))
                        }
                    }
                    .onChange(of: selectedModel) { _, newValue in
                        cameraManager.updateOllamaConfiguration(serverURL: AppSettings.ollamaServerURL, model: newValue)
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
                    Text("Used by \"Ask AI to Plan…\", \"Ask AI to Describe…\", and the AI panel — requires a local Ollama server; see [ollama.com](https://ollama.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("AI Skill: Suggest Next Session") {
                    TextEditor(text: $sessionSuggestionSkill)
                        .font(.body)
                        .frame(minHeight: 90)
                        .onChange(of: sessionSuggestionSkill) { _, newValue in
                            AppSettings.sessionSuggestionSkill = newValue
                        }
                    HStack {
                        Spacer()
                        Button("Reset to Default") {
                            sessionSuggestionSkill = AppSettings.defaultSessionSuggestionSkill
                            AppSettings.sessionSuggestionSkill = AppSettings.defaultSessionSuggestionSkill
                        }
                        .disabled(sessionSuggestionSkill == AppSettings.defaultSessionSuggestionSkill)
                    }
                    Text("Standing instructions folded into every \"suggest my next session\" request — tune what the AI favors (equipment, target types, repeat vs. variety) without touching a single prompt in code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 580)
    }

    /// Applies whatever's currently typed into the server URL field — invalid/empty text is
    /// silently ignored rather than clearing the existing configuration, since a URL field mid-edit
    /// (an incomplete paste, say) is a much more likely reason for it to briefly not parse than the
    /// user actually wanting to reset anything.
    private func applyServerURL() {
        let trimmed = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        cameraManager.updateOllamaConfiguration(serverURL: url, model: selectedModel)
    }

    /// `isAvailable()` alone only confirms the server answers at all — a real "does this work"
    /// check also needs `installedModels()`, since a reachable server with nothing pulled fails
    /// every actual plan/describe request the exact same way an unreachable one does.
    private func testOllama() async {
        applyServerURL()
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

    private func chooseEquipmentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentEquipmentFolder
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            customEquipmentPath = url.path
            AppSettings.customEquipmentDirectoryPath = url.path
        }
    }

    private func chooseKnowledgeBaseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentKnowledgeBaseFolder
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            customKnowledgeBasePath = url.path
            AppSettings.customKnowledgeBaseDirectoryPath = url.path
            AstronomyKnowledgeBase.ensureDefaultsExist(in: url)
        }
    }
}
