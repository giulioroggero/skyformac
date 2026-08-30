import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var maxResponseTokens = AppSettings.ollamaMaxResponseTokens
    @State private var aiProvider = AppSettings.aiProvider
    @State private var anthropicAPIKeyText = AppSettings.anthropicAPIKey ?? ""
    @State private var geminiAPIKeyText = AppSettings.geminiAPIKey ?? ""
    @State private var geminiUsesVertex = AppSettings.geminiUsesVertex
    @State private var geminiVertexProjectIDText = AppSettings.geminiVertexProjectID ?? ""
    @State private var geminiVertexRegionText = AppSettings.geminiVertexRegion ?? ""
    @State private var isImportingVertexServiceAccount = false
    @State private var vertexServiceAccountErrorMessage: String?
    @State private var geminiImageModelText = AppSettings.geminiImageModel ?? GeminiImageEnhancer.availableModels[0]
    @State private var aiSettingsSegment = 0
    @State private var integrationsSegment = 0

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

            TabView {
                foldersForm
                    .tabItem { Label("Folders", systemImage: "folder") }
                renderingForm
                    .tabItem { Label("Rendering", systemImage: "camera.aperture") }
                aiTabContent
                    .tabItem { Label("AI", systemImage: "sparkles") }
                StorageSettingsView(cameraManager: cameraManager)
                    .tabItem { Label("Storage", systemImage: "internaldrive") }
                integrationsTabContent
                    .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                CommunitySettingsView()
                    .tabItem { Label("Community", systemImage: "person.2") }
            }
        }
        .frame(width: 640, height: 640)
    }

    private var foldersForm: some View {
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
        }
        .formStyle(.grouped)
    }

    private var renderingForm: some View {
        Form {
                Section("Rendering") {
                    Toggle("Use Metal (GPU) Renderer", isOn: Binding(
                        get: { cameraManager.useMetalRenderer },
                        set: { cameraManager.useMetalRenderer = $0 }
                    ))
                    HStack {
                        Toggle("Night Mode", isOn: Binding(
                            get: { cameraManager.isNightModeEnabled },
                            set: { cameraManager.isNightModeEnabled = $0 }
                        ))
                        HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.nightModeApp")
                    }
                }
        }
        .formStyle(.grouped)
    }

    /// The "AI" tab combines model/provider config and every task's editable system instructions
    /// in one place (previously two separate tabs) — a segmented switch between two independent
    /// root views rather than nesting one `Form` inside another, which macOS doesn't render
    /// cleanly.
    private var aiTabContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $aiSettingsSegment) {
                Text("Models & Provider").tag(0)
                Text("Instructions").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            if aiSettingsSegment == 0 {
                aiForm
            } else {
                AIInstructionsSettingsView()
            }
        }
    }

    /// "Aggregate in an Integrations tab: Siril, GraXpert, StarNet" — same segmented-switch
    /// approach as `aiTabContent`, for the same reason.
    private var integrationsTabContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $integrationsSegment) {
                Text("Siril").tag(0)
                Text("GraXpert").tag(1)
                Text("StarNet").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            switch integrationsSegment {
            case 0: SirilSettingsView()
            case 1: GraXpertSettingsView()
            default: StarNetSettingsView()
            }
        }
    }

    private var aiForm: some View {
        Form {
                Section("AI Provider") {
                    Picker("Provider", selection: $aiProvider) {
                        ForEach(AppSettings.AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: aiProvider) { _, _ in applyAIProviderConfiguration() }
                    switch aiProvider {
                    case .ollama:
                        Text("Runs entirely on your own machine via a local Ollama server — no account, nothing leaves your computer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .anthropic:
                        // Saved on every keystroke, not just `.onSubmit` — a `SecureField` a user
                        // fills in and then just closes Settings without pressing Return (the
                        // common case; nothing else here needs Return to "commit") used to leave
                        // `AppSettings.anthropicAPIKey` `nil` forever, silently sending every
                        // request with an *empty* `x-api-key` header — confirmed live: Anthropic's
                        // API rejects that with "x-api-key header is required," which reads like
                        // the key was never entered at all rather than what was actually wrong.
                        SecureField("API Key", text: $anthropicAPIKeyText, prompt: Text("sk-ant-…"))
                            .onSubmit(applyAIProviderConfiguration)
                            .onChange(of: anthropicAPIKeyText) { _, _ in applyAIProviderConfiguration() }
                        Text("Requests go to Anthropic's own servers using this key — see [console.anthropic.com](https://console.anthropic.com) to create one. Not stored in this app's own preferences file; kept in the macOS Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .gemini:
                        Toggle("Use Vertex AI", isOn: $geminiUsesVertex)
                            .onChange(of: geminiUsesVertex) { _, newValue in AppSettings.geminiUsesVertex = newValue }
                        if geminiUsesVertex {
                            // Vertex has no `?key=` auth at all — every request needs a real
                            // GCP project plus a service-account-signed Bearer token
                            // (`VertexServiceAccountAuthenticator`), not the plain API key below.
                            TextField("GCP Project ID", text: $geminiVertexProjectIDText, prompt: Text("my-project-123"))
                                .onChange(of: geminiVertexProjectIDText) { _, newValue in
                                    AppSettings.geminiVertexProjectID = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            TextField("Region", text: $geminiVertexRegionText, prompt: Text(GeminiEndpoint.defaultVertexRegion))
                                .onChange(of: geminiVertexRegionText) { _, newValue in
                                    AppSettings.geminiVertexRegion = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            HStack {
                                Button("Import Service Account JSON…") { isImportingVertexServiceAccount = true }
                                if AppSettings.geminiVertexServiceAccountJSON?.isEmpty == false {
                                    Label("Configured", systemImage: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                            .fileImporter(isPresented: $isImportingVertexServiceAccount, allowedContentTypes: [.json]) { result in
                                switch result {
                                case .success(let url): importVertexServiceAccount(from: url)
                                case .failure(let error): vertexServiceAccountErrorMessage = error.localizedDescription
                                }
                            }
                            if let vertexServiceAccountErrorMessage {
                                Text(vertexServiceAccountErrorMessage).font(.caption).foregroundStyle(.red)
                            }
                            Text("Requests go through your GCP project's Vertex AI endpoint, authenticated with this service account — see [cloud.google.com/vertex-ai/docs](https://cloud.google.com/vertex-ai/docs) for creating a project and a service account key (with the \"Vertex AI User\" role). The key is kept in the macOS Keychain, never this app's own preferences file.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            SecureField("API Key", text: $geminiAPIKeyText, prompt: Text("AIza…"))
                                .onSubmit(applyAIProviderConfiguration)
                                .onChange(of: geminiAPIKeyText) { _, _ in applyAIProviderConfiguration() }
                            Text("Requests go to Google's own servers using this key — see [aistudio.google.com](https://aistudio.google.com/apikey) to create one. Not stored in this app's own preferences file; kept in the macOS Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Picker("AI Enhance Model", selection: $geminiImageModelText) {
                            ForEach(GeminiImageEnhancer.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .onChange(of: geminiImageModelText) { _, newValue in AppSettings.geminiImageModel = newValue }
                        Text("Which Gemini image-generation model Edit Image's \"AI Enhance\" uses — a separate capability from the chat model above (only these specific models can output an edited image at all).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if aiProvider == .ollama {
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
                    LabeledContent("Max Response Length") {
                        Stepper(value: $maxResponseTokens, in: 100...4000, step: 100) {
                            Text("\(maxResponseTokens) tokens")
                        }
                    }
                    .onChange(of: maxResponseTokens) { _, newValue in
                        AppSettings.ollamaMaxResponseTokens = newValue
                    }
                    Text("Caps how long a single AI response may generate (Ollama's own `num_predict`). A reasoning model's hidden \"thinking\" pass counts against this same limit before it ever reaches the actual answer — set too low, it can get cut off before producing a usable reply. Responses stream in live as they generate, so you'll see a reply forming instead of just waiting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Used by \"Ask AI to Plan…\", \"Ask AI to Describe…\", and the AI panel — requires a local Ollama server; see [ollama.com](https://ollama.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }

        }
        .formStyle(.grouped)
    }

    /// Applies whatever's currently typed into the server URL field — invalid/empty text is
    /// silently ignored rather than clearing the existing configuration, since a URL field mid-edit
    /// (an incomplete paste, say) is a much more likely reason for it to briefly not parse than the
    /// user actually wanting to reset anything.
    private func applyAIProviderConfiguration() {
        cameraManager.updateAIProviderConfiguration(
            provider: aiProvider,
            anthropicAPIKey: anthropicAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines),
            geminiAPIKey: geminiAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Reads the downloaded service-account JSON key file straight into the Keychain — a security-
    /// scoped `fileImporter` URL only grants access for the duration of this call, so the read has
    /// to happen right here rather than being deferred.
    private func importVertexServiceAccount(from url: URL) {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let json = String(data: data, encoding: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                vertexServiceAccountErrorMessage = "That file doesn't look like a valid JSON key."
                return
            }
            AppSettings.geminiVertexServiceAccountJSON = json
            vertexServiceAccountErrorMessage = nil
        } catch {
            vertexServiceAccountErrorMessage = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

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
