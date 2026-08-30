import Foundation

/// Thin typed wrapper around `UserDefaults` for the handful of `CameraManager` preferences that
/// should survive a relaunch — render path, image-enhancement toggles, and which overlays are
/// enabled. Deliberately excludes anything that's session state rather than a preference (e.g.
/// `isLiveStackingEnabled`, `darkFrame`, `polarAlignmentStage`) — those should always start
/// fresh, not resume mid-session on next launch.
enum AppSettings {
    private enum Key: String {
        case useMetalRenderer
        case isDenoisingEnabled
        case isWaveletSharpeningEnabled
        case waveletSharpenAmount
        case sharpnessDiscardThreshold
        case isFocusAssistEnabled
        case isStarRecognitionEnabled
        case isPlanetaryTrackingEnabled
        case isPlanetaryCropEnabled
        case isNightModeEnabled
        case isNightModePreviewTinted
        case isLiveGPUControlsEnabled
        case gpuTemporalAlpha
        case gpuSpatialSigma
        case gpuRangeSigma
        case gpuStretchIntensity
        case gpuBlackPoint
        case gpuWhitePoint
        case isCloudSentinelEnabled
        case isStreakMaskingEnabled
        case exportHistory
        case smartLiveStackQualityFraction
        case telescopeProfile
        case equipmentSystems
        case customProjectsRootDirectoryPath
        case customEquipmentDirectoryPath
        case customKnowledgeBaseDirectoryPath
        case customAIChatsDirectoryPath
        case ollamaServerURLString
        case ollamaModel
        case ollamaMaxResponseTokens
        case aiProvider
        case anthropicModel
        case geminiModel
        case geminiImageModel
        case geminiUsesVertex
        case geminiVertexProjectID
        case geminiVertexRegion
        case sessionSuggestionSkill
        case sessionPlanningInstructions
        case projectPlanningInstructions
        case assistantChatInstructions
        case planetaryStackingInstructions
        case imageAssistantInstructions
        case summaryInstructions
        case suggestTagsInstructions
        case isAssistantPanelVisible
        case isAssistantMinimized
        case isAssistantDetached
        case isOnlineObjectInfoEnabled
        case isSirilIntegrationEnabled
        case sirilCLIPath
        case isGraXpertIntegrationEnabled
        case graXpertCLIPath
        case isStarNetIntegrationEnabled
        case starNetCLIPath
        case liveStackMethod
        case liveStackSigmaClippingKappa
        case isLiveStackAutoStretchContinuous
        case liveStackStretchAggressiveness
        case liveStackAutoBlackPointOffset
        case isLiveStackAutoColorBalanceEnabled
        case horizonProfile
        case fieldOfViewWidthArcmin
        case fieldOfViewHeightArcmin
        case skyVisibilityConfig
        case galleryLibrary
    }

    /// Defaults to `true` (GPU render path) when never explicitly set — `UserDefaults.bool`
    /// itself returns `false` for a missing key, so the "unset" case needs an explicit check.
    static var useMetalRenderer: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.useMetalRenderer.rawValue) != nil
                ? UserDefaults.standard.bool(forKey: Key.useMetalRenderer.rawValue)
                : true
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.useMetalRenderer.rawValue) }
    }

    static var isDenoisingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isDenoisingEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isDenoisingEnabled.rawValue) }
    }

    static var isWaveletSharpeningEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isWaveletSharpeningEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isWaveletSharpeningEnabled.rawValue) }
    }

    static var waveletSharpenAmount: Double {
        get { UserDefaults.standard.object(forKey: Key.waveletSharpenAmount.rawValue) != nil ? UserDefaults.standard.double(forKey: Key.waveletSharpenAmount.rawValue) : 1.0 }
        set { UserDefaults.standard.set(newValue, forKey: Key.waveletSharpenAmount.rawValue) }
    }

    static var sharpnessDiscardThreshold: Double {
        get { UserDefaults.standard.double(forKey: Key.sharpnessDiscardThreshold.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sharpnessDiscardThreshold.rawValue) }
    }

    /// Defaults to 0.5 (keep frames at least half as sharp as the best one seen so far this
    /// session) when never explicitly set.
    static var smartLiveStackQualityFraction: Double {
        get {
            UserDefaults.standard.object(forKey: Key.smartLiveStackQualityFraction.rawValue) != nil
                ? UserDefaults.standard.double(forKey: Key.smartLiveStackQualityFraction.rawValue)
                : 0.5
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.smartLiveStackQualityFraction.rawValue) }
    }

    /// Which telescope `PlanetaryPreset`'s starting exposure is scaled for — see
    /// `PlanetaryPreset.startingExposureSeconds(for:)`. Defaults to `TelescopeProfile.reference`
    /// (a Maksutov 127mm/1500mm, what those base numbers are already tuned for) when never
    /// explicitly set, or when the stored raw value doesn't match any current case (an older
    /// build's now-renamed/removed profile).
    static var telescopeProfile: TelescopeProfile {
        get {
            UserDefaults.standard.string(forKey: Key.telescopeProfile.rawValue)
                .flatMap(TelescopeProfile.init(rawValue:)) ?? .reference
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.telescopeProfile.rawValue) }
    }

    static var isFocusAssistEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isFocusAssistEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isFocusAssistEnabled.rawValue) }
    }

    static var isStarRecognitionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isStarRecognitionEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isStarRecognitionEnabled.rawValue) }
    }

    static var isPlanetaryTrackingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isPlanetaryTrackingEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isPlanetaryTrackingEnabled.rawValue) }
    }

    static var isPlanetaryCropEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isPlanetaryCropEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isPlanetaryCropEnabled.rawValue) }
    }

    static var isNightModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isNightModeEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isNightModeEnabled.rawValue) }
    }

    /// Off by default — preserves the original behavior (live image always true color) for
    /// anyone who hasn't discovered this yet. When on, the live preview's actual image is also
    /// red-tinted along with the rest of the UI, for observing sessions dark-adapted enough that
    /// even a small true-color preview is too much; the toggle right on `PreviewView` lets it be
    /// flipped back to true color ("normal") without leaving Night Mode altogether.
    static var isNightModePreviewTinted: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isNightModePreviewTinted.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isNightModePreviewTinted.rawValue) }
    }

    // MARK: - Live GPU Enhancement Controls (specs/skyformac_GPU_Live_Controls_Spec.md)

    static var isLiveGPUControlsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isLiveGPUControlsEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isLiveGPUControlsEnabled.rawValue) }
    }

    private static func storedFloat(_ key: Key, default defaultValue: Float) -> Float {
        UserDefaults.standard.object(forKey: key.rawValue) != nil
            ? UserDefaults.standard.float(forKey: key.rawValue)
            : defaultValue
    }

    static var gpuTemporalAlpha: Float {
        get { storedFloat(.gpuTemporalAlpha, default: 0.15) }
        set { UserDefaults.standard.set(newValue, forKey: Key.gpuTemporalAlpha.rawValue) }
    }

    static var gpuSpatialSigma: Float {
        get { storedFloat(.gpuSpatialSigma, default: 3.5) }
        set { UserDefaults.standard.set(newValue, forKey: Key.gpuSpatialSigma.rawValue) }
    }

    static var gpuRangeSigma: Float {
        get { storedFloat(.gpuRangeSigma, default: 0.12) }
        set { UserDefaults.standard.set(newValue, forKey: Key.gpuRangeSigma.rawValue) }
    }

    static var gpuStretchIntensity: Float {
        get { storedFloat(.gpuStretchIntensity, default: 25.0) }
        set { UserDefaults.standard.set(newValue, forKey: Key.gpuStretchIntensity.rawValue) }
    }

    static var gpuBlackPoint: Float {
        get { storedFloat(.gpuBlackPoint, default: 0.02) }
        set { UserDefaults.standard.set(newValue, forKey: Key.gpuBlackPoint.rawValue) }
    }

    static var gpuWhitePoint: Float {
        get { storedFloat(.gpuWhitePoint, default: 0.98) }
        set { UserDefaults.standard.set(newValue, forKey: Key.gpuWhitePoint.rawValue) }
    }

    // MARK: - Live Stack (specs/live-stackig-fix-spec.md)

    /// "Average" unless a valid `LiveStackMethod` raw value was stored — same "unrecognized/never
    /// set falls back to the default" reasoning every enum-backed setting here uses.
    static var liveStackMethod: LiveStackMethod {
        get { UserDefaults.standard.string(forKey: Key.liveStackMethod.rawValue).flatMap(LiveStackMethod.init(rawValue:)) ?? .average }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.liveStackMethod.rawValue) }
    }

    static var liveStackSigmaClippingKappa: Float {
        get { storedFloat(.liveStackSigmaClippingKappa, default: 3.0) }
        set { UserDefaults.standard.set(newValue, forKey: Key.liveStackSigmaClippingKappa.rawValue) }
    }

    /// Opt-in, like every other visually-altering toggle in this app — off by default so updating
    /// doesn't silently change what an existing session's live view looks like.
    static var isLiveStackAutoStretchContinuous: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isLiveStackAutoStretchContinuous.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isLiveStackAutoStretchContinuous.rawValue) }
    }

    static var liveStackStretchAggressiveness: StretchAggressiveness {
        get {
            UserDefaults.standard.string(forKey: Key.liveStackStretchAggressiveness.rawValue)
                .flatMap(StretchAggressiveness.init(rawValue:)) ?? .medium
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.liveStackStretchAggressiveness.rawValue) }
    }

    static var liveStackAutoBlackPointOffset: Float {
        get { storedFloat(.liveStackAutoBlackPointOffset, default: 0) }
        set { UserDefaults.standard.set(newValue, forKey: Key.liveStackAutoBlackPointOffset.rawValue) }
    }

    static var isLiveStackAutoColorBalanceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isLiveStackAutoColorBalanceEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isLiveStackAutoColorBalanceEnabled.rawValue) }
    }

    // MARK: - AI Suite (specs/skyformac_AI_Features_Pipeline_Spec.md)

    static var isCloudSentinelEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isCloudSentinelEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isCloudSentinelEnabled.rawValue) }
    }

    static var isStreakMaskingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isStreakMaskingEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isStreakMaskingEnabled.rawValue) }
    }

    // MARK: - Exported Files section

    /// Where every single-frame export, recording-folder start, and SER recording start landed
    /// — this genuinely is preference-shaped state (a persistent record of past actions the user
    /// wants to find again later, like a browser's download history), not session state that
    /// should reset on relaunch the way `isLiveStackingEnabled`/`darkFrame` do. Capped at 50
    /// entries on write so this can't grow unbounded across many sessions.
    static var exportHistory: [ExportHistoryEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.exportHistory.rawValue),
                  let decoded = try? JSONDecoder().decode([ExportHistoryEntry].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let capped = Array(newValue.suffix(50))
            guard let data = try? JSONEncoder().encode(capped) else { return }
            UserDefaults.standard.set(data, forKey: Key.exportHistory.rawValue)
        }
    }

    // MARK: - Equipment

    /// Every named `EquipmentSystem` the user has set up — a handful of named rigs at most, not
    /// hundreds of items, so a single JSON array in `UserDefaults` fits the same "small dataset,
    /// no database needed" reasoning `ProjectStore`'s own doc comment applies at the (much
    /// larger) Projects scale.
    static var equipmentSystems: [EquipmentSystem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.equipmentSystems.rawValue),
                  let decoded = try? JSONDecoder().decode([EquipmentSystem].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Key.equipmentSystems.rawValue)
        }
    }

    /// The observer's own real horizon (rooftops, trees, a neighboring building), not the
    /// astronomical one — set once in "What to See," it should stick around across launches the
    /// same way `equipmentSystems` does, since a physical obstruction doesn't change session to
    /// session.
    static var horizonProfile: HorizonProfile {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.horizonProfile.rawValue),
                  let decoded = try? JSONDecoder().decode(HorizonProfile.self, from: data)
            else { return .clear }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Key.horizonProfile.rawValue)
        }
    }

    /// A custom field-of-view, in arcminutes — not tied to any particular `EquipmentSystem` (those
    /// don't record focal length or sensor size today), just a number the user works out
    /// themselves (their own focal-length/sensor-size math, or an online FOV calculator) so "What
    /// to See" can flag whether an object actually fits the frame. Defaults to roughly a common
    /// small-refractor-plus-APS-C-camera field (1° × 0.67°) — a reasonable starting point to tweak
    /// from, not a claim about what the user actually owns.
    static var fieldOfViewWidthArcmin: Double {
        get { UserDefaults.standard.object(forKey: Key.fieldOfViewWidthArcmin.rawValue) != nil ? UserDefaults.standard.double(forKey: Key.fieldOfViewWidthArcmin.rawValue) : 60 }
        set { UserDefaults.standard.set(newValue, forKey: Key.fieldOfViewWidthArcmin.rawValue) }
    }

    static var fieldOfViewHeightArcmin: Double {
        get { UserDefaults.standard.object(forKey: Key.fieldOfViewHeightArcmin.rawValue) != nil ? UserDefaults.standard.double(forKey: Key.fieldOfViewHeightArcmin.rawValue) : 40 }
        set { UserDefaults.standard.set(newValue, forKey: Key.fieldOfViewHeightArcmin.rawValue) }
    }

    /// "What to See"'s own last-used location/sort/filters — `nil` the first time the page is ever
    /// opened, at which point it falls back to its own built-in defaults (current location,
    /// tonight at 23:00, sort by peak altitude, no filters).
    static var skyVisibilityConfig: SkyVisibilityConfig? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.skyVisibilityConfig.rawValue) else { return nil }
            return try? JSONDecoder().decode(SkyVisibilityConfig.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: Key.skyVisibilityConfig.rawValue)
                return
            }
            UserDefaults.standard.set(data, forKey: Key.skyVisibilityConfig.rawValue)
        }
    }

    /// The Gallery's own folders/albums/favorites — one shared library across every project's
    /// elaborated images, not scoped to any one project (matching the Gallery page itself).
    static var galleryLibrary: GalleryLibrary {
        get {
            guard let data = UserDefaults.standard.data(forKey: Key.galleryLibrary.rawValue),
                  let decoded = try? JSONDecoder().decode(GalleryLibrary.self, from: data)
            else { return GalleryLibrary() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Key.galleryLibrary.rawValue)
        }
    }

    // MARK: - Custom folder resolution

    /// Shared by every "user-chosen folder instead of a default" store
    /// (`ProjectStore`/`EquipmentLibrary`/`AIChatLibrary`/`AstronomyKnowledgeBase`) — each of
    /// their own `defaultRootDirectory()` used to copy-paste this exact same four-line "check the
    /// custom path, else fall back to `~/Documents/<folderName>`" logic.
    /// `SKYFORMAC_UITEST_ROOT` (set via `XCUIApplication.launchEnvironment` — see
    /// `SkyformacUITests`) redirects every root directory this resolves — Projects, Equipment,
    /// Knowledge Base — into an isolated per-run temp folder, overriding even a real, persisted
    /// `customPath` from a previous non-test launch. Without this, a UI test's real actions
    /// (Quick Start creates a genuine on-disk project, say) land in the developer's actual
    /// `~/Documents/Skyformac Projects` (or wherever Settings points), same as any other launch —
    /// exactly what left stray test projects behind before this existed.
    static func resolveRootDirectory(customPath: String?, defaultFolderName: String) -> URL {
        if let testRoot = ProcessInfo.processInfo.environment["SKYFORMAC_UITEST_ROOT"], !testRoot.isEmpty {
            return URL(fileURLWithPath: testRoot, isDirectory: true).appendingPathComponent(defaultFolderName, isDirectory: true)
        }
        if let customPath, !customPath.isEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent(defaultFolderName, isDirectory: true)
    }

    // MARK: - Projects folder

    /// A user-chosen folder to keep project/session data in instead of the default
    /// `~/Documents/Skyformac Projects` (`ProjectStore.defaultRootDirectory()`) — `nil` when
    /// never changed. Read once at launch (`ProjectStore()`'s own default argument), so changing
    /// this in Settings takes effect the next time the app starts, not live — moving a folder
    /// full of a user's real capture files out from under an already-running `ProjectStore`
    /// (open file handles, an active session mid-write) is exactly the kind of "silently do
    /// something destructive" this app avoids elsewhere.
    static var customProjectsRootDirectoryPath: String? {
        get { UserDefaults.standard.string(forKey: Key.customProjectsRootDirectoryPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.customProjectsRootDirectoryPath.rawValue) }
    }

    // MARK: - Equipment folder

    /// Same "user-chosen folder instead of a default, read once at launch" shape as the Projects
    /// folder above — `EquipmentLibrary` reads this once at `init`, see its own doc comment for
    /// why equipment moved from `UserDefaults` to real files on disk.
    static var customEquipmentDirectoryPath: String? {
        get { UserDefaults.standard.string(forKey: Key.customEquipmentDirectoryPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.customEquipmentDirectoryPath.rawValue) }
    }

    // MARK: - Astronomy Knowledge folder

    /// Same "user-chosen folder instead of a default" shape as Projects/Equipment above —
    /// `AstronomyKnowledgeBase` reads this each time it needs the folder (no in-memory cache to
    /// keep in sync, since it's just plain `.md` files read fresh off disk per AI request).
    static var customKnowledgeBaseDirectoryPath: String? {
        get { UserDefaults.standard.string(forKey: Key.customKnowledgeBaseDirectoryPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.customKnowledgeBaseDirectoryPath.rawValue) }
    }

    // MARK: - AI Chats folder

    /// Same "user-chosen folder instead of a default" shape as Projects/Equipment above —
    /// `AIChatLibrary` reads this once at `init`, the same "read once at launch" timing
    /// `ProjectStore`/`EquipmentLibrary` already use for their own folders.
    static var customAIChatsDirectoryPath: String? {
        get { UserDefaults.standard.string(forKey: Key.customAIChatsDirectoryPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.customAIChatsDirectoryPath.rawValue) }
    }

    // MARK: - Ollama (AI)

    /// The local Ollama server every AI feature (Ask AI to Plan/Describe, the sidebar AI chat)
    /// talks to — defaults to `http://localhost:11434` (Ollama's own default) when never changed
    /// or the stored value somehow isn't a valid URL. Unlike the Projects/Equipment folder
    /// settings, this one *does* take effect immediately — `CameraManager
    /// .updateOllamaConfiguration(serverURL:model:)` rebuilds `ollamaPlanner` live, since there's
    /// no destructive side effect to changing which server a network request goes to the way
    /// there is for relocating files an app already has open.
    static var ollamaServerURL: URL {
        get {
            if let raw = UserDefaults.standard.string(forKey: Key.ollamaServerURLString.rawValue), let url = URL(string: raw) {
                return url
            }
            return URL(string: "http://localhost:11434")!
        }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: Key.ollamaServerURLString.rawValue) }
    }

    /// `nil` (the default) means "auto-detect" — see `OllamaPlanner.resolveModel()`. Set
    /// explicitly (Settings, or the AI panel's own model menu) to pin a specific installed model.
    static var ollamaModel: String? {
        get { UserDefaults.standard.string(forKey: Key.ollamaModel.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.ollamaModel.rawValue) }
    }

    /// Ollama's own `num_predict` option (max tokens a single response may generate), sent with
    /// every request — without it the server has no cap at all and a local model can run for as
    /// long as it wants. A *reasoning* model (`OllamaPlanner.preferredModel`, "qwen3:8b") still
    /// counts its own hidden `<think>...</think>` chain-of-thought against this same budget before
    /// it ever reaches the actual answer, so this needs enough headroom for that reasoning trace
    /// too, not just the final visible text — set too low, a reasoning model can get cut off
    /// mid-thought without ever producing a usable reply. 800 is a middle ground: generous enough
    /// for typical reasoning + a short answer, while still bounding a truly runaway generation.
    static var ollamaMaxResponseTokens: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Key.ollamaMaxResponseTokens.rawValue)
            return stored > 0 ? stored : defaultOllamaMaxResponseTokens
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.ollamaMaxResponseTokens.rawValue) }
    }

    static let defaultOllamaMaxResponseTokens = 800

    /// Which service the assistant/planning features (`OllamaPlanner`, despite the name — see its
    /// own doc comment) actually talk to. "Configure AI with Ollama, or with an Anthropic/Gemini
    /// API key" — Ollama stays the default (matches the app's own no-account/no-cloud stance
    /// unless the user opts in to a cloud provider themselves).
    enum AIProvider: String, CaseIterable, Identifiable {
        case ollama, anthropic, gemini
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .ollama: return "Ollama (local)"
            case .anthropic: return "Anthropic Claude"
            case .gemini: return "Google Gemini"
            }
        }
    }

    static var aiProvider: AIProvider {
        get { UserDefaults.standard.string(forKey: Key.aiProvider.rawValue).flatMap(AIProvider.init(rawValue:)) ?? .ollama }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.aiProvider.rawValue) }
    }

    /// API keys live in the Keychain (`KeychainStore`), never `UserDefaults`'s own plist — see
    /// that type's own doc comment for why. `nil` means "not configured yet."
    static var anthropicAPIKey: String? {
        get { KeychainStore.string(forKey: "anthropicAPIKey") }
        set { KeychainStore.set(newValue, forKey: "anthropicAPIKey") }
    }

    static var geminiAPIKey: String? {
        get { KeychainStore.string(forKey: "geminiAPIKey") }
        set { KeychainStore.set(newValue, forKey: "geminiAPIKey") }
    }

    /// `nil` (the default) picks each client's own built-in default model — see
    /// `AnthropicTransport`/`GeminiTransport`'s own doc comments for what that is.
    static var anthropicModel: String? {
        get { UserDefaults.standard.string(forKey: Key.anthropicModel.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.anthropicModel.rawValue) }
    }

    static var geminiModel: String? {
        get { UserDefaults.standard.string(forKey: Key.geminiModel.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.geminiModel.rawValue) }
    }

    /// Which Gemini image-generation ("Nano Banana" family) model Edit Image's "AI Enhance" uses
    /// — a separate setting from `geminiModel` above, since that one's for the text/vision chat
    /// and this family of models is a genuinely different capability (only some Gemini models can
    /// output an edited image at all). `nil` picks `GeminiImageEnhancer`'s own default.
    static var geminiImageModel: String? {
        get { UserDefaults.standard.string(forKey: Key.geminiImageModel.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.geminiImageModel.rawValue) }
    }

    /// `true` routes every Gemini request through Vertex AI (a GCP project, billed/quota'd there)
    /// instead of the plain Gemini API (`generativelanguage.googleapis.com`, billed against a
    /// simple AI Studio API key) — same request/response JSON shape either way
    /// (`GeminiTransport`/`GeminiImageEnhancer`'s own payload-building code is unchanged), only the
    /// endpoint URL and how the request authenticates differ. See `geminiVertexServiceAccountJSON`.
    static var geminiUsesVertex: Bool {
        get { UserDefaults.standard.bool(forKey: Key.geminiUsesVertex.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.geminiUsesVertex.rawValue) }
    }

    static var geminiVertexProjectID: String? {
        get { UserDefaults.standard.string(forKey: Key.geminiVertexProjectID.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.geminiVertexProjectID.rawValue) }
    }

    /// e.g. `"us-central1"` — both part of the Vertex endpoint URL itself and the token's own
    /// `aud`ience implicitly, via that URL. `nil`/empty falls back to `"us-central1"` at the call
    /// site (`VertexEndpoint.resolve`) rather than here, so this getter still reports the user's
    /// own literal, possibly-empty setting.
    static var geminiVertexRegion: String? {
        get { UserDefaults.standard.string(forKey: Key.geminiVertexRegion.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.geminiVertexRegion.rawValue) }
    }

    /// The full downloaded service-account JSON key file's contents (not just a path — the
    /// credential itself), Keychain-backed like the plain API keys above since it's just as
    /// sensitive (arguably more: it grants a JWT-mintable identity, not a single revocable key).
    /// `VertexServiceAccountAuthenticator` parses `client_email`/`private_key`/`token_uri` out of
    /// this at request time.
    static var geminiVertexServiceAccountJSON: String? {
        get { KeychainStore.string(forKey: "geminiVertexServiceAccountJSON") }
        set { KeychainStore.set(newValue, forKey: "geminiVertexServiceAccountJSON") }
    }

    /// `true` when launched by `SkyformacUITests` (which sets `SKYFORMAC_UITEST_ROOT` —
    /// `ProjectStore.resolveRootDirectory`'s own isolation marker). The assistant panel's
    /// visible/minimized/detached state below piggybacks on the same flag to isolate itself too,
    /// for a genuinely real reason found the hard way: every `XCUIApplication().launch()` in one
    /// test run is a fresh *process*, but they all still share the *same* on-disk
    /// `~/Library/Preferences/.../com.giulioroggero.skyformac.plist` within that one CI job. A
    /// `setUpWithError()` reset of these keys between tests raced the previous test's just-
    /// terminated app process still flushing its own write to that same file — passed most of the
    /// time locally, failed on *every single* CI run, since GitHub's runner has different I/O
    /// timing than a local Mac. Routing these three through `uiTestScopedStorage` instead of real
    /// `UserDefaults` during a UI test removes the shared file — and the race — entirely.
    static var isRunningUITests: Bool {
        ProcessInfo.processInfo.environment["SKYFORMAC_UITEST_ROOT"] != nil
    }

    /// Backing store for `isAssistantPanelVisible`/`isAssistantMinimized`/`isAssistantDetached`
    /// while `isRunningUITests` — plain in-memory, scoped to this one process, exactly as
    /// isolated as `SKYFORMAC_UITEST_ROOT` already makes the Projects/Equipment/Knowledge Base
    /// folders for the same reason.
    nonisolated(unsafe) private static var uiTestScopedStorage: [String: Bool] = [:]

    /// Whether the AI sidebar/panel should be shown at all — "closed" is a deliberate user choice
    /// that used to reset to visible (the default) on every relaunch, since `CameraManager` held
    /// this as plain in-memory state. Defaults to `true` (shown) when never explicitly set.
    static var isAssistantPanelVisible: Bool {
        get {
            if isRunningUITests { return uiTestScopedStorage[Key.isAssistantPanelVisible.rawValue] ?? true }
            return UserDefaults.standard.object(forKey: Key.isAssistantPanelVisible.rawValue) != nil
                ? UserDefaults.standard.bool(forKey: Key.isAssistantPanelVisible.rawValue)
                : true
        }
        set {
            if isRunningUITests {
                uiTestScopedStorage[Key.isAssistantPanelVisible.rawValue] = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: Key.isAssistantPanelVisible.rawValue)
            }
        }
    }

    static var isAssistantMinimized: Bool {
        get {
            if isRunningUITests { return uiTestScopedStorage[Key.isAssistantMinimized.rawValue] ?? false }
            return UserDefaults.standard.bool(forKey: Key.isAssistantMinimized.rawValue)
        }
        set {
            if isRunningUITests {
                uiTestScopedStorage[Key.isAssistantMinimized.rawValue] = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: Key.isAssistantMinimized.rawValue)
            }
        }
    }

    static var isAssistantDetached: Bool {
        get {
            if isRunningUITests { return uiTestScopedStorage[Key.isAssistantDetached.rawValue] ?? false }
            return UserDefaults.standard.bool(forKey: Key.isAssistantDetached.rawValue)
        }
        set {
            if isRunningUITests {
                uiTestScopedStorage[Key.isAssistantDetached.rawValue] = newValue
            } else {
                UserDefaults.standard.set(newValue, forKey: Key.isAssistantDetached.rawValue)
            }
        }
    }

    /// The instructions folded into every "suggest my next session" request
    /// (`OllamaPlanner.suggestNextSession(context:skill:)`) — a user-editable "skill," not a fixed
    /// prompt, so preferences like "favor deep-sky over planetary" or "consider my dual-scope rig"
    /// can be tuned from Settings without a code change. Falls back to `defaultSessionSuggestionSkill`
    /// whenever nothing's been customized yet or the user resets it.
    static var sessionSuggestionSkill: String {
        get { UserDefaults.standard.string(forKey: Key.sessionSuggestionSkill.rawValue) ?? defaultSessionSuggestionSkill }
        set { UserDefaults.standard.set(newValue, forKey: Key.sessionSuggestionSkill.rawValue) }
    }

    static let defaultSessionSuggestionSkill = """
    Prefer objects that fit well with the observer's equipment and favorite/highly-rated past \
    projects and sessions. Favor a good variety over repeating the same target, unless a repeat \
    under better conditions is clearly worthwhile. Attach the session to an existing project when \
    one genuinely fits its goal; otherwise propose a new project.
    """

    // MARK: - AI system instructions
    //
    // "All system instructions, for each model, page, and task, are visible in Settings and can be
    // updated by the user" — the opening persona/behavior paragraph `OllamaPlanner` sends for each
    // distinct AI task, editable here the same way `sessionSuggestionSkill` already was. The JSON
    // response-format scaffolding that follows each of these in `OllamaPlanner` stays fixed in
    // code (not exposed) since editing it would silently break response parsing; what's exposed is
    // genuinely just the instructions, not the contract the app depends on to read the reply back.

    static var sessionPlanningInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.sessionPlanningInstructions.rawValue) ?? defaultSessionPlanningInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.sessionPlanningInstructions.rawValue) }
    }
    static let defaultSessionPlanningInstructions =
        "You are an assistant helping an amateur astronomer plan a single observing session."

    static var projectPlanningInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.projectPlanningInstructions.rawValue) ?? defaultProjectPlanningInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.projectPlanningInstructions.rawValue) }
    }
    static let defaultProjectPlanningInstructions =
        "You are an assistant helping an amateur astronomer plan a multi-session observing project."

    static var assistantChatInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.assistantChatInstructions.rawValue) ?? defaultAssistantChatInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.assistantChatInstructions.rawValue) }
    }
    static let defaultAssistantChatInstructions = """
    You are an assistant embedded in the sidebar of an astrophotography capture app, grounded in \
    the current page's own context below — use it, don't ignore it. If an image is attached, it's \
    a snapshot of whatever's currently on screen (a capture, an elaborated image) — actually look \
    at it before answering a question like "what is that?" rather than guessing from the context \
    text alone.
    """

    static var planetaryStackingInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.planetaryStackingInstructions.rawValue) ?? defaultPlanetaryStackingInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.planetaryStackingInstructions.rawValue) }
    }
    static let defaultPlanetaryStackingInstructions = """
    You are an assistant embedded in this astrophotography app's Planetary Post-Processing tool, \
    at its very first "Set Up Stacking" step, before any stacking has actually run yet. An image \
    of a single representative frame from the capture is attached — actually look at it and \
    identify what it shows: a planet or the Moon (a small, bright, high-contrast disk) or a \
    deep-sky object (an extended, fainter nebula/galaxy/star cluster) — good starting values \
    differ a lot between the two.
    """

    static var imageAssistantInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.imageAssistantInstructions.rawValue) ?? defaultImageAssistantInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.imageAssistantInstructions.rawValue) }
    }
    static let defaultImageAssistantInstructions = """
    You are an assistant embedded in this astrophotography app's Edit Image tool. An image of the \
    photo currently being edited is attached — actually look at it: its color balance, noise \
    level, sharpness, contrast, and any visible artifacts (gradient/vignetting, hot pixels, \
    bloated stars, green color cast).
    You can either just answer a question about the image, or propose a specific set of adjustment \
    slider values that would improve it, grounded only in what you actually see — never propose \
    changing a slider that's already fine as-is, and never invent an artifact that isn't visible \
    in the image.
    """

    static var summaryInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.summaryInstructions.rawValue) ?? defaultSummaryInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.summaryInstructions.rawValue) }
    }
    static let defaultSummaryInstructions = """
    You are an assistant helping an amateur astronomer write a short, engaging description of \
    their observing project or session, grounded only in the facts given below — don't invent \
    details (equipment, dates, objects) that aren't in this data.
    """

    static var suggestTagsInstructions: String {
        get { UserDefaults.standard.string(forKey: Key.suggestTagsInstructions.rawValue) ?? defaultSuggestTagsInstructions }
        set { UserDefaults.standard.set(newValue, forKey: Key.suggestTagsInstructions.rawValue) }
    }
    static let defaultSuggestTagsInstructions = """
    You are an assistant suggesting short organizational tags for an amateur astronomer's \
    observing project or session, grounded only in the facts given below — don't invent details \
    (equipment, dates, objects) that aren't in this data.
    """

    // MARK: - Siril integration

    /// Off by default — Siril is a real external process dependency this app doesn't bundle;
    /// "Elaborate…" prompts the user to turn this on here rather than silently doing nothing (or
    /// silently shelling out) when it's off. See `SirilElaborationService`.
    /// Gates every live network call `SkyVisibilityExplorerView`'s object detail sheet makes
    /// (Wikipedia/SDSS's own public APIs for a description/thumbnail/sky-survey image) — this is
    /// the one place in the app that reaches the network at all, so "no telemetry, no network
    /// dependency" (see `docs/distribution.md`) no longer holds universally once this is on.
    /// Enabled by default (moved to Settings › Community, alongside the other "connects to the
    /// outside world for community/reference info" toggle there) — a deliberate call that the
    /// value of seeing a description/photo outweighs staying silent by default here, unlike this
    /// app's other opt-in integrations (Siril/GraXpert/StarNet), which stay off by default since
    /// those actually shell out to a separate local app. Turning this off doesn't affect the
    /// "Search on AstroBin"/"Search on Reddit" links, which just open the user's own browser — no
    /// request this app itself makes either way.
    static var isOnlineObjectInfoEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Key.isOnlineObjectInfoEnabled.rawValue) == nil { return true }
            return UserDefaults.standard.bool(forKey: Key.isOnlineObjectInfoEnabled.rawValue)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.isOnlineObjectInfoEnabled.rawValue) }
    }

    static var isSirilIntegrationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isSirilIntegrationEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isSirilIntegrationEnabled.rawValue) }
    }

    /// `nil` means "use `SirilElaborationService.defaultCLIPath()`" (the standard
    /// `/Applications/Siril.app` location) — set only when the user's picked a different one.
    static var sirilCLIPath: String? {
        get { UserDefaults.standard.string(forKey: Key.sirilCLIPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sirilCLIPath.rawValue) }
    }

    // MARK: - GraXpert integration

    /// Off by default, same reasoning as `isSirilIntegrationEnabled` — GraXpert is a separate app
    /// this doesn't bundle. See `GraXpertElaborationService`.
    static var isGraXpertIntegrationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isGraXpertIntegrationEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isGraXpertIntegrationEnabled.rawValue) }
    }

    /// `nil` means "use `GraXpertElaborationService.defaultCLIPath()`" (the standard
    /// `/Applications/GraXpert.app` location) — set only when the user's picked a different one.
    static var graXpertCLIPath: String? {
        get { UserDefaults.standard.string(forKey: Key.graXpertCLIPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.graXpertCLIPath.rawValue) }
    }

    // MARK: - StarNet integration

    /// Off by default, same reasoning as `isSirilIntegrationEnabled` — StarNet is a separate CLI
    /// tool this doesn't bundle. See `StarNetElaborationService`.
    static var isStarNetIntegrationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.isStarNetIntegrationEnabled.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.isStarNetIntegrationEnabled.rawValue) }
    }

    /// Unlike Siril/GraXpert, StarNet has no standard `.app`-bundle install location at all — it's
    /// a bare CLI binary an installer script places wherever it likes. `nil` falls back to
    /// `/usr/local/bin/starnet2`, a reasonable guess (not a guarantee) rather than nothing; most
    /// users will need to set this explicitly in Settings > StarNet.
    static var starNetCLIPath: String? {
        get { UserDefaults.standard.string(forKey: Key.starNetCLIPath.rawValue) }
        set { UserDefaults.standard.set(newValue, forKey: Key.starNetCLIPath.rawValue) }
    }
}
