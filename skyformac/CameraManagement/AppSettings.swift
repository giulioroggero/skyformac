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
}
