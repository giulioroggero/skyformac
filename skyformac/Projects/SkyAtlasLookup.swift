import Foundation

/// Resolves a free-text observed-object name (as typed/picked into `Session.plannedObjects`)
/// into a fixed sky position — "the sky atlas is in stellarium, leverage it": reuses the same
/// bundled `SkyCatalog` (Messier + Caldwell objects, and bright stars, extracted from
/// Stellarium's own DSO catalog — see `SkyCatalog`'s own doc comment) the rest of the app already
/// treats as its Stellarium data, rather than parsing the sibling `stellarium` source repository
/// directly at runtime (a fragile, non-shippable dependency on one development machine's local
/// path — the same call `ObservedObjectCatalog` already made for the Filters popover's own
/// object list).
///
/// Deliberately can't resolve everything: planets and the Moon (`PlanetaryPreset`) move across
/// the sky and have no single fixed position a static atlas can place them at without real
/// ephemeris math, which is out of scope here — `AtlasView` lists those separately instead of
/// plotting them somewhere misleading.
enum SkyAtlasLookup {
    struct Position: Equatable {
        let raDegrees: Double
        let decDegrees: Double
    }

    /// `nil` when `name` doesn't match anything in the bundled catalog — a free-typed object
    /// ("a comet," something not in Messier or the bright-star list) simply has nowhere fixed to
    /// place it either.
    static func position(forObjectName name: String) -> Position? {
        catalogObject(forObjectName: name).map { Position(raDegrees: $0.raDegrees, decDegrees: $0.decDegrees) }
    }

    /// Same resolution as `position(forObjectName:)`, but returns the full matched
    /// `SkyCatalogObject` — its type/magnitude/display name, not just where to plot it. Added for
    /// `SkyObjectResolver`, which needs those to show the same detail sheet "What to See" itself
    /// shows, from anywhere in the app an object name appears (a session's planned objects, a
    /// capture's target).
    static func catalogObject(forObjectName name: String) -> SkyCatalogObject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A Messier/Caldwell designation can show up in several different spellings across this
        // app ("M13" typed free-hand, "M13 (Hercules Cluster)" from the Quick Start/
        // `DeepSkyObject` list) — extracting just the catalog number and matching it against
        // `SkyCatalog`'s own `id` (always the bare "M13"/"C14" form) handles all of them at once,
        // rather than requiring an exact string match against whichever format happened to be
        // used.
        if let messierID = catalogID(prefix: "M", in: trimmed),
           let match = SkyCatalog.messierObjects.first(where: { $0.id.caseInsensitiveCompare(messierID) == .orderedSame }) {
            return match
        }
        if let caldwellID = catalogID(prefix: "C", in: trimmed),
           let match = SkyCatalog.caldwellObjects.first(where: { $0.id.caseInsensitiveCompare(caldwellID) == .orderedSame }) {
            return match
        }
        // "NGC" itself is 3 letters, unlike Messier/Caldwell's single-letter prefixes — tried as
        // its own literal prefix (not `catalogID`'s generic single-char form) alongside "IC".
        if let ngcID = catalogID(prefix: "NGC", in: trimmed) ?? catalogID(prefix: "IC", in: trimmed),
           let match = SkyCatalog.ngcObjects.first(where: { $0.id.caseInsensitiveCompare(ngcID) == .orderedSame }) {
            return match
        }

        let namedObjects: [SkyCatalogObject] = SkyCatalog.messierObjects + SkyCatalog.caldwellObjects + SkyCatalog.ngcObjects
        if let match = namedObjects.first(where: { $0.commonName?.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }

        for star in SkyCatalog.brightStars {
            let idMatches = star.id.caseInsensitiveCompare(trimmed) == .orderedSame
            let nameMatches = star.commonName.map { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? false
            if idMatches || nameMatches {
                return star
            }
        }

        return nil
    }

    /// `true` for anything `PlanetaryPreset` covers (by name) — the Moon and every planet, all of
    /// which genuinely have no single fixed position, as opposed to just "not in our catalog."
    /// `AtlasView` uses this to label those two "unplaced" cases differently: "moves across the
    /// sky" vs. "not in the bundled catalog."
    static func isSolarSystemObject(_ name: String) -> Bool {
        PlanetaryPreset.allCases.contains { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Extracts a bare "M13"/"C14"-style designation from the start of `text` for `prefix`
    /// ("M" or "C"), regardless of a space between the letter and number or trailing text
    /// ("M13 (Hercules Cluster)" still yields "M13").
    private static func catalogID(prefix: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^\(prefix)\\s?(\\d+)", options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return "\(prefix)\(text[numberRange])"
    }
}
