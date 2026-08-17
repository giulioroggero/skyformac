import Foundation
import simd

/// A software-side color/contrast preview stylized after a common astronomy filter's "look" —
/// deliberately **not** an optical simulation. A real narrowband (Hα/OIII/SII) or light-pollution
/// (UHC/CLS) filter works by physically blocking wavelengths *before* they reach the sensor —
/// that's what lets it cut through light pollution or isolate a faint emission line. Nothing
/// applied after an already-captured Bayer/RGB frame can replicate that: the wavelength
/// information a real filter would have rejected was never captured differently in the first
/// place. This exists purely as a live-preview/stylistic aid — previewing a narrowband "look"
/// while framing a target — and is labeled as such everywhere it's surfaced in the UI
/// (`FiltersTabContent`).
enum AstronomyFilterType: String, Codable, CaseIterable, Identifiable, Sendable {
    case hAlpha
    case oiii
    case sii
    case uhc
    case lEnhance

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hAlpha: return "Hα"
        case .oiii: return "OIII"
        case .sii: return "SII"
        case .uhc: return "UHC / CLS"
        case .lEnhance: return "L-eNhance (duo-band)"
        }
    }

    var summary: String {
        switch self {
        case .hAlpha:
            return "Emphasizes red — the deep-red glow hydrogen-alpha emission nebulae are usually shown in."
        case .oiii:
            return "Emphasizes cyan/teal — the color doubly-ionized oxygen emission is usually mapped to."
        case .sii:
            return "Emphasizes deep orange-red — the sulfur-II line, often combined with Hα/OIII in an SHO palette."
        case .uhc:
            return "A broad contrast boost approximating a light-pollution/UHC filter's effect on nebulosity."
        case .lEnhance:
            return "Combines the Hα and OIII looks — a stylized take on a duo-band nebula filter."
        }
    }

    /// The per-channel multiplier this filter's "look" nudges toward — combined with an
    /// `intensity` in `FilterSelection.combinedGain(for:)`, never applied directly at full
    /// strength on its own. Deliberately mild (never below `0.2`) so even a full-intensity filter
    /// tints the image rather than clipping a channel to pure black.
    var channelGain: SIMD3<Float> {
        switch self {
        case .hAlpha: return SIMD3(1.5, 0.25, 0.25)
        case .oiii: return SIMD3(0.2, 1.35, 1.2)
        case .sii: return SIMD3(1.4, 0.35, 0.2)
        case .uhc: return SIMD3(1.1, 0.85, 1.15)
        case .lEnhance: return SIMD3(1.35, 0.4, 1.05)
        }
    }
}

/// One active filter and how strongly it's blended in (`0...1` — `0` is a no-op, `1` is
/// `AstronomyFilterType.channelGain` at full strength). Persisted in
/// `AcquisitionPreset.selectedFilters` so which filters were active for a given capture can be
/// recalled later, the same way gain/exposure/ROI already are.
struct FilterSelection: Codable, Equatable, Identifiable, Sendable {
    var filter: AstronomyFilterType
    var intensity: Double

    var id: String { filter.rawValue }

    /// Folds every active selection into one per-channel multiplier for the render pipeline
    /// (`CameraManager.combinedFilterGain`) — each filter's own `channelGain` is blended toward
    /// `(1, 1, 1)` (no-op) by `1 - intensity`, then every selection's result multiplies together,
    /// so selecting more than one filter composes their effects rather than one overriding the
    /// other. Empty input is exactly `(1, 1, 1)`, letting the GPU/CPU stage skip itself entirely.
    static func combinedGain(for selections: [FilterSelection]) -> SIMD3<Float> {
        selections.reduce(SIMD3<Float>(repeating: 1)) { result, selection in
            let t = Float(max(0, min(1, selection.intensity)))
            let blended = SIMD3<Float>(repeating: 1) + (selection.filter.channelGain - SIMD3<Float>(repeating: 1)) * t
            return result * blended
        }
    }
}
