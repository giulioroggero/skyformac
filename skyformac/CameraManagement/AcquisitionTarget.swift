import Foundation

/// Which capture technique(s) a target's recommended setup turns on.
enum AcquisitionMode: String, Codable, CaseIterable, Identifiable {
    case liveStack
    case luckyImaging
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liveStack: return "Live Stack"
        case .luckyImaging: return "Lucky Imaging"
        case .both: return "Live Stack + Lucky Imaging"
        }
    }

    var usesLiveStack: Bool { self == .liveStack || self == .both }
    var usesLuckyImaging: Bool { self == .luckyImaging || self == .both }

    /// What `CameraManager.currentAcquisitionPreset` derives the mode of a "snapshot of whatever's
    /// currently configured" preset from — a pure function of just these two flags, so the actual
    /// decision (not the reading of live camera state feeding into it) is unit-testable.
    static func current(isLiveStackingEnabled: Bool, hasLuckyImagingSession: Bool) -> AcquisitionMode {
        switch (isLiveStackingEnabled, hasLuckyImagingSession) {
        case (true, true): return .both
        case (true, false): return .liveStack
        case (false, _): return .luckyImaging
        }
    }
}

/// A small, curated "interesting deep-sky objects" list — deliberately not `SkyCatalog`'s full
/// database (built for matching *detected* stars against a huge real catalog for the HUD
/// overlay), just a handful of well-known, genuinely rewarding live-view targets with real
/// starting-point settings, the same "curated presets, not an exhaustive catalog" scoping
/// `PlanetaryPreset` already uses for the solar system side.
enum DeepSkyObject: String, CaseIterable, Identifiable, Codable {
    case m13 = "M13 (Hercules Cluster)"
    case m56 = "M56 (Globular Cluster)"
    case m31 = "M31 (Andromeda Galaxy)"
    case m42 = "M42 (Orion Nebula)"
    case m45 = "M45 (Pleiades)"
    case m51 = "M51 (Whirlpool Galaxy)"
    case m57 = "M57 (Ring Nebula)"
    case m27 = "M27 (Dumbbell Nebula)"
    case m81 = "M81 (Bode's Galaxy)"
    case m8 = "M8 (Lagoon Nebula)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .m13, .m56: return "circle.grid.3x3.fill"
        case .m31, .m81: return "sparkles"
        case .m42, .m8: return "cloud.fill"
        case .m45: return "star.fill"
        case .m51: return "tornado"
        case .m57: return "circle.dotted"
        case .m27: return "smallcircle.filled.circle"
        }
    }

    var summary: String {
        switch self {
        case .m13: return "A bright, dense globular cluster — resolves into individual stars quickly, forgiving of a shorter integration."
        case .m56: return "A fainter, more scattered globular cluster than M13 — rewards a longer integration and slightly higher gain."
        case .m31: return "A bright core with a large, faint extended disk — start conservative to avoid clipping the core; the outer disk needs the accumulated integration time."
        case .m42: return "A very wide dynamic range: a bright Trapezium core against much fainter nebulosity — start low to protect the core, the wings build up in the stack over time."
        case .m45: return "A bright open cluster with faint surrounding reflection nebulosity — moderate gain, the nebulosity itself is the slow-building part of the stack."
        case .m51: return "A face-on spiral galaxy with a smaller companion (NGC 5195) — genuinely faint outside its core, rewards a patient, longer-integration session."
        case .m57: return "Small and bright for its size (a planetary nebula, not a deep-sky faint smudge) — the ring shape resolves quickly, but it's tiny; a longer focal length helps more than more integration time here."
        case .m27: return "Similar story to M57 — a compact, comparatively bright planetary nebula that reveals its shape faster than most deep-sky targets, but stays small in frame."
        case .m81: return "A fairly bright spiral galaxy, often framed together with its neighbor M82 — moderate gain, forgiving of a shorter session than a fainter galaxy would need."
        case .m8: return "A bright, large emission nebula with an embedded open cluster — start low to protect the brighter regions; still one of the more forgiving nebulae for a shorter session."
        }
    }

    /// Recommended *starting* gain — matching `PlanetaryPreset.startingGain`'s own philosophy
    /// (safer to start under-exposed and raise while watching the live histogram than to start
    /// already near clipping); these still depend on the actual night's sky darkness/transparency
    /// and can't be exact regardless of which object this is.
    var recommendedGain: Int {
        switch self {
        case .m13: return 100
        case .m56: return 150
        case .m31: return 80
        case .m42: return 60
        case .m45: return 50
        case .m51: return 120
        case .m57: return 120
        case .m27: return 100
        case .m81: return 90
        case .m8: return 50
        }
    }

    /// Recommended starting per-frame (Live Exposure) length feeding Live Stack's running
    /// average — not a single dedicated long exposure.
    var recommendedExposureSeconds: Double {
        switch self {
        case .m13: return 2.0
        case .m56: return 5.0
        case .m31: return 3.0
        case .m42: return 1.5
        case .m45: return 3.0
        case .m51: return 4.0
        case .m57: return 3.0
        case .m27: return 3.0
        case .m81: return 3.5
        case .m8: return 2.0
        }
    }
}

/// One target the Acquisition Wizard can set up for — either a `PlanetaryPreset` (already the
/// app's own solar-system preset table) or a `DeepSkyObject` (new, above). Kept as a thin wrapper
/// rather than merging the two tables, since their recommended-settings *shape* genuinely differs
/// (ROI/SER duration/burst-count for planetary vs. gain/exposure/drift-reduction for deep sky) —
/// forcing one shared struct would mean most fields are meaningless for either genre.
enum AcquisitionTarget: Identifiable, Hashable {
    case planetary(PlanetaryPreset)
    case deepSky(DeepSkyObject)

    static var all: [AcquisitionTarget] {
        PlanetaryPreset.allCases.map { .planetary($0) } + DeepSkyObject.allCases.map { .deepSky($0) }
    }

    var id: String {
        switch self {
        case .planetary(let preset): return "planetary.\(preset.rawValue)"
        case .deepSky(let object): return "deepSky.\(object.rawValue)"
        }
    }

    var name: String {
        switch self {
        case .planetary(let preset): return preset.rawValue
        case .deepSky(let object): return object.rawValue
        }
    }

    var icon: String {
        switch self {
        case .planetary(let preset): return preset.icon
        case .deepSky(let object): return object.icon
        }
    }

    /// The Moon is the one target that genuinely benefits from *both* techniques at once — Lucky
    /// Imaging for high-resolution crater/terminator detail, Live Stack for a lower-noise
    /// full-disk or earthshine shot — so it's the deliberate example of `.both`, not an arbitrary
    /// default. Every other planetary target stays Lucky-Imaging-only (the classic "small ROI,
    /// high FPS, keep the sharpest fraction" workflow for beating seeing on a small, bright disk);
    /// every deep-sky object is Live-Stack-only (long, faint, no seeing-beating burst helps here —
    /// integration time is what builds signal).
    var recommendedMode: AcquisitionMode {
        switch self {
        case .planetary(.moon): return .both
        case .planetary: return .luckyImaging
        case .deepSky: return .liveStack
        }
    }

    var summary: String {
        switch self {
        case .planetary(.moon):
            return "Both techniques are genuinely useful here: Lucky Imaging for high-resolution crater/terminator detail, Live Stack for a lower-noise full-disk or earthshine shot."
        case .planetary(let preset):
            return preset.note ?? "Small-ROI, high-FPS burst capture — the classic \"keep the sharpest fraction\" technique for beating atmospheric seeing on a small, bright disk."
        case .deepSky(let object):
            return object.summary
        }
    }

    /// The actual recommended starting point this target's setup applies — a pure function of the
    /// target alone (see `AcquisitionPresetTests`), so it's testable without a camera or GPU.
    /// `presetName` is caller-supplied (defaults to the target's own name) since a user saving a
    /// preset may want to name it after their specific setup ("M13 — 6 inch f/8") rather than just
    /// the object.
    ///
    /// `isMeshDriftCorrectionEnabled` is never recommended `true` here, deliberately — it's
    /// rougher than the single-star lock (`isDriftReductionEnabled`, above) and worth trying
    /// deliberately, not silently inherited from a "recommended" preset. It's still exposed as an
    /// editable row in the Wizard for any target this preset turns Live Stack on for (deep-sky
    /// objects, and the Moon's `.both` mode) — genuinely long, multi-minute-plus integrations are
    /// exactly where field rotation/differential drift a single global shift can't correct
    /// becomes real, unlike a Lucky Imaging burst that's over in seconds.
    /// `telescope` only affects a `.planetary` target's starting exposure (via `PlanetaryPreset
    /// .startingExposureSeconds(for:)`) — a `.deepSky` object's own starting exposure already
    /// spans several seconds, far longer than any telescope's focal-ratio difference alone would
    /// meaningfully move it, and gain/integration time there are the levers that actually matter.
    func recommendedPreset(name presetName: String? = nil, telescope: TelescopeProfile = .reference) -> AcquisitionPreset {
        let mode = recommendedMode
        switch self {
        case .planetary(let preset):
            return AcquisitionPreset(
                name: presetName ?? name,
                targetID: id,
                mode: mode,
                gain: preset.startingGain,
                exposureSeconds: preset.startingExposureSeconds(for: telescope),
                roiWidth: preset.roi?.width,
                roiHeight: preset.roi?.height,
                isDriftReductionEnabled: false,
                isSmartLiveStackEnabled: mode.usesLiveStack,
                luckyBurstCount: mode.usesLuckyImaging ? 60 : nil,
                serDurationSeconds: preset.recommendedMaxDurationSeconds,
                isMeshDriftCorrectionEnabled: false
            )
        case .deepSky(let object):
            return AcquisitionPreset(
                name: presetName ?? name,
                targetID: id,
                mode: mode,
                gain: object.recommendedGain,
                exposureSeconds: object.recommendedExposureSeconds,
                roiWidth: nil,
                roiHeight: nil,
                // Deep-sky integration runs long enough that mount tracking error accumulates
                // into real trailing — Reduce Drift defaults on here, unlike planetary (a burst
                // is over in seconds, not minutes+, so drift barely matters there).
                isDriftReductionEnabled: true,
                isSmartLiveStackEnabled: true,
                luckyBurstCount: nil,
                serDurationSeconds: nil,
                isMeshDriftCorrectionEnabled: false
            )
        }
    }

    /// Resolves a persisted `targetID` (`AcquisitionPreset.targetID`, from `id` above) back to a
    /// concrete target — `nil` if it doesn't match anything this build knows about (an older or
    /// newer version's target list, or a hand-edited file).
    static func resolve(id: String) -> AcquisitionTarget? {
        all.first { $0.id == id }
    }
}

/// A saved (or freshly-recommended) Acquisition Wizard setup — `Codable` so it round-trips to/from
/// its own JSON file (`CameraManager.saveAcquisitionPreset`/`loadAcquisitionPreset`), one file per
/// preset, exactly the "save one file per preset for the object" shape asked for. Optional fields
/// are `nil` when they don't apply to this preset's `mode`/target genre (a planetary preset has no
/// `isDriftReductionEnabled` opinion worth persisting since Lucky Imaging doesn't use it; a
/// deep-sky preset has no ROI or SER duration).
struct AcquisitionPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Matches an `AcquisitionTarget.id` — resolved back via `AcquisitionTarget.resolve(id:)` when
    /// loaded, so the wizard can show the target's own name/icon/summary again, not just raw
    /// numbers. Kept as a plain `String`, not the enum itself, so an older preset file still loads
    /// (with an "unknown target" fallback) even if a future version renames/removes a target.
    var targetID: String
    var mode: AcquisitionMode
    var gain: Int?
    var exposureSeconds: Double?
    var roiWidth: Int?
    var roiHeight: Int?
    var isDriftReductionEnabled: Bool
    var isSmartLiveStackEnabled: Bool
    var luckyBurstCount: Int?
    var serDurationSeconds: Double?
    /// "Experimental" mesh-based drift correction (`CameraManager.isMeshDriftCorrectionEnabled`)
    /// — `Optional`, not a plain `Bool`, specifically so a preset file saved before this field
    /// existed still decodes (`decodeIfPresent`'s automatic `nil` for a missing key) instead of
    /// failing to load outright. Never recommended on by default (see `recommendedPreset`'s doc
    /// comment) — offered as an opt-in row in the Wizard editor for any Live-Stack-using target,
    /// not auto-enabled for any of them.
    var isMeshDriftCorrectionEnabled: Bool?

    /// A short, one-line human summary of the parameters actually set — "Live Stack · Gain 100 ·
    /// 2.0s · ROI 800×600" — shared by the Recall Parameters picker and the Insights page's own
    /// "most common parameters" breakdown, rather than each formatting this by hand.
    var summaryLine: String {
        var parts = [mode.label]
        if let gain { parts.append("Gain \(gain)") }
        if let exposureSeconds { parts.append("\(exposureSeconds.formatted(.number.precision(.fractionLength(0...2))))s") }
        if let roiWidth, let roiHeight { parts.append("ROI \(roiWidth)×\(roiHeight)") }
        if let serDurationSeconds { parts.append("SER \(Int(serDurationSeconds))s") }
        if let luckyBurstCount { parts.append("Burst \(luckyBurstCount)") }
        return parts.joined(separator: " · ")
    }
}
