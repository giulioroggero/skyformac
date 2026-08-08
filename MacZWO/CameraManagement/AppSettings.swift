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
}
