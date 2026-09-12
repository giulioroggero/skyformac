import Foundation

/// Which capture technique(s) a target's recommended setup turns on.
enum AcquisitionMode: String, Codable, CaseIterable, Identifiable {
    case liveStack
    case luckyImaging
    case both
    /// Neither Live Stack nor a Lucky Imaging burst is active — a single plain exposure. Only
    /// ever produced by `current(isLiveStackingEnabled:hasLuckyImagingSession:)`'s "neither" case,
    /// tagging a capture record/preset snapshot accurately; deliberately excluded from
    /// `AcquisitionWizardView`'s Mode picker, since a saved preset always represents one of the
    /// three real toggleable acquisition techniques, never "none of them."
    case single

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liveStack: return "Live Stack"
        case .luckyImaging: return "Lucky Imaging"
        case .both: return "Live Stack + Lucky Imaging"
        case .single: return "Single Exposure"
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
        case (false, true): return .luckyImaging
        case (false, false): return .single
        }
    }
}

/// A saved (or freshly-recommended) Acquisition Wizard setup — `Codable` so it round-trips to/from
/// its own JSON file (`CameraManager.saveAcquisitionPreset`/`loadAcquisitionPreset`), one file per
/// preset, exactly the "save one file per preset for the object" shape asked for. Optional fields
/// are `nil` when they don't apply to this preset's `mode`/target genre (a planetary preset has no
/// `isDriftReductionEnabled` opinion worth persisting since Lucky Imaging doesn't use it; a
/// deep-sky preset has no ROI or SER duration).
///
/// Moved out of `AcquisitionTarget.swift` (alongside `AcquisitionMode` above) into its own file so
/// both can be shared with the "Skyformac Remote" iOS target (`ObservationModels.swift`'s
/// `CaptureRecord.preset` needs this type) without also pulling in `AcquisitionTarget.swift`'s own
/// `AcquisitionTarget`/`DeepSkyObject` — those reference `PlanetaryPreset`, which lives in
/// `CameraManager.swift` and isn't iOS-shareable.
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
    /// The "Filters" tab's active selections at the moment this preset was captured/saved —
    /// `Optional`, same back-compat reasoning as `isMeshDriftCorrectionEnabled` above (a preset
    /// saved before "Filters" existed decodes as `nil`, not a load failure). `nil` and `[]` both
    /// mean "no filters," but `nil` is what an old preset actually decodes to.
    var selectedFilters: [FilterSelection]?
    /// 2×2 pixel binning (`CameraManager.captureBinning`) — `Optional`, same back-compat
    /// reasoning as `isMeshDriftCorrectionEnabled` above (a preset saved before binning existed
    /// decodes as `nil`, treated the same as 1/off by every reader). `1` and `nil` both mean "no
    /// binning" — `nil` is just what an old preset actually decodes to.
    var binning: Int?

    /// A short, one-line human summary of the parameters actually set — "Live Stack · Gain 100 ·
    /// 2.0s · ROI 800×600" — shared by the Recall Parameters picker and the Insights page's own
    /// "most common parameters" breakdown, rather than each formatting this by hand.
    var summaryLine: String {
        var parts = [mode.label]
        if let gain { parts.append("Gain \(gain)") }
        if let exposureSeconds { parts.append("\(exposureSeconds.formatted(.number.precision(.fractionLength(0...2))))s") }
        if let roiWidth, let roiHeight { parts.append("ROI \(roiWidth)×\(roiHeight)") }
        if let binning, binning > 1 { parts.append("Bin \(binning)×\(binning)") }
        if let serDurationSeconds { parts.append("SER \(Int(serDurationSeconds))s") }
        if let luckyBurstCount { parts.append("Burst \(luckyBurstCount)") }
        if let selectedFilters, !selectedFilters.isEmpty {
            parts.append(selectedFilters.map(\.filter.displayName).joined(separator: "+"))
        }
        return parts.joined(separator: " · ")
    }
}
