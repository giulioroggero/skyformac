import Foundation
import CoreGraphics

/// The handful of small, plain-data types nested inside `SirilElaborationService`,
/// `PlanetaryPostProcessor`, and `ImageEditor` that `ElaboratedImage.planetarySettings` embeds —
/// pulled out to their own top-level declarations here, in an otherwise `Foundation`/`CoreGraphics`
/// -only file, so `ObservationModels.swift` (shared with the "Skyformac Remote" iOS target per
/// `specs/skyformac_Mobile_Remote_Spec.md`) can decode a saved elaborated image's recipe without
/// pulling in any of those three files' actual rendering/stacking implementations (which the
/// iOS Remote app never runs, and which — `SirilElaborationService.swift` in particular, via
/// `Process` — don't even compile on iOS at all). Each original type becomes a `typealias` back
/// to its extracted counterpart here, so every existing call site (`ImageEditor.Adjustments(...)`,
/// `PlanetaryPostProcessor.StackMethod.median`, `SirilElaborationService.PixelRect(...)`) keeps
/// compiling unchanged. Also holds `FilenameSanitizer`, the same kind of extraction but for a
/// free function (`ProjectStore.sanitizeForFilename`) rather than a nested type — `ProjectStore`
/// itself is 500+ lines of real Mac-only filesystem persistence, not something the iOS Remote
/// app should touch at all, so only this one pure string function moved out.

/// Extracted from `ProjectStore.sanitizeForFilename` — see that function's own remaining doc
/// comment (still there, just delegating here now) for what it does.
enum FilenameSanitizer {
    static func sanitize(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80))
    }
}

/// Extracted from `SirilElaborationService.PixelRect` — see that type's own remaining doc comment
/// for what it's for. `asCropperRect` widened from `fileprivate` to internal (the only visibility
/// change here) since `SirilElaborationService.swift`'s own use of it now reaches across files.
struct ROIPixelRect: Equatable, Sendable, Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var asCropperRect: (x: Int, y: Int, width: Int, height: Int) { (x, y, width, height) }
}

/// Extracted from `PlanetaryPostProcessor.StackMethod`.
enum PlanetaryStackMethod: String, CaseIterable, Identifiable, Sendable, Codable {
    case mean = "Mean"
    case median = "Median"
    var id: String { rawValue }
}

/// Extracted from `PlanetaryPostProcessor.WaveletLayer`.
struct PlanetaryWaveletLayer: Identifiable, Sendable, Equatable, Codable {
    var id: Int
    var gain: Double
}

/// Extracted from `ImageEditor.Adjustments` — see that type's own remaining doc comment for what
/// each field does; only moved, not changed, including its hand-rolled `Codable` (an older saved
/// elaborated image predates several of these fields having existed at all).
struct ImageAdjustments: Equatable, Sendable, Codable {
    var rotationDegrees: Double = 0
    var cropRect: CGRect?
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var gamma: Double = 1
    var sharpenIntensity: Double = 0
    var denoiseAmount: Double = 0
    var removesHotPixels: Bool = false
    var chromaNoiseReduction: Double = 0
    var greenCastRemoval: Double = 0
    var starSizeReduction: Double = 0
    var shadowLift: Double = 0
    var highlightRecovery: Double = 0
    var posterizeLevels: Double = 0
    var vibrance: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var deconvolutionSharpen: Double = 0

    static let identity = ImageAdjustments()

    enum CodingKeys: String, CodingKey {
        case rotationDegrees, cropRect, brightness, contrast, saturation, gamma, sharpenIntensity,
             denoiseAmount, removesHotPixels, chromaNoiseReduction, greenCastRemoval, starSizeReduction,
             shadowLift, highlightRecovery, posterizeLevels, vibrance, warmth, tint, deconvolutionSharpen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rotationDegrees = try container.decode(Double.self, forKey: .rotationDegrees)
        cropRect = try container.decodeIfPresent(CGRect.self, forKey: .cropRect)
        brightness = try container.decode(Double.self, forKey: .brightness)
        contrast = try container.decode(Double.self, forKey: .contrast)
        saturation = try container.decode(Double.self, forKey: .saturation)
        gamma = try container.decode(Double.self, forKey: .gamma)
        sharpenIntensity = try container.decode(Double.self, forKey: .sharpenIntensity)
        denoiseAmount = try container.decode(Double.self, forKey: .denoiseAmount)
        removesHotPixels = try container.decode(Bool.self, forKey: .removesHotPixels)
        chromaNoiseReduction = try container.decode(Double.self, forKey: .chromaNoiseReduction)
        greenCastRemoval = try container.decode(Double.self, forKey: .greenCastRemoval)
        starSizeReduction = try container.decode(Double.self, forKey: .starSizeReduction)
        shadowLift = try container.decode(Double.self, forKey: .shadowLift)
        highlightRecovery = try container.decode(Double.self, forKey: .highlightRecovery)
        posterizeLevels = try container.decodeIfPresent(Double.self, forKey: .posterizeLevels) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        deconvolutionSharpen = try container.decodeIfPresent(Double.self, forKey: .deconvolutionSharpen) ?? 0
    }

    init(
        rotationDegrees: Double = 0, cropRect: CGRect? = nil, brightness: Double = 0, contrast: Double = 1,
        saturation: Double = 1, gamma: Double = 1, sharpenIntensity: Double = 0, denoiseAmount: Double = 0,
        removesHotPixels: Bool = false, chromaNoiseReduction: Double = 0, greenCastRemoval: Double = 0,
        starSizeReduction: Double = 0, shadowLift: Double = 0, highlightRecovery: Double = 0, posterizeLevels: Double = 0,
        vibrance: Double = 0, warmth: Double = 0, tint: Double = 0, deconvolutionSharpen: Double = 0
    ) {
        self.rotationDegrees = rotationDegrees
        self.cropRect = cropRect
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.sharpenIntensity = sharpenIntensity
        self.denoiseAmount = denoiseAmount
        self.removesHotPixels = removesHotPixels
        self.chromaNoiseReduction = chromaNoiseReduction
        self.greenCastRemoval = greenCastRemoval
        self.starSizeReduction = starSizeReduction
        self.shadowLift = shadowLift
        self.highlightRecovery = highlightRecovery
        self.posterizeLevels = posterizeLevels
        self.vibrance = vibrance
        self.warmth = warmth
        self.tint = tint
        self.deconvolutionSharpen = deconvolutionSharpen
    }
}

/// Extracted from `PlanetaryPostProcessor.SettingsSnapshot` — see that type's own remaining doc
/// comment for what it records and why.
struct PlanetarySettingsSnapshot: Codable, Sendable, Equatable {
    var roi: ROIPixelRect?
    var keepBestPercent: Double
    var stackMethod: PlanetaryStackMethod
    var waveletLayers: [PlanetaryWaveletLayer]
    var denoise: Double
    var alignRGBChannels: Bool
    var blackPoint: Double
    var whitePoint: Double
    var logStretchIntensity: Double?
    var singleShotAdjustments: ImageAdjustments?
}
