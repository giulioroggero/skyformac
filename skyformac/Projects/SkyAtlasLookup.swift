import Foundation

/// Resolves a free-text observed-object name (as typed/picked into `Session.plannedObjects`)
/// into a fixed sky position — "the sky atlas is in stellarium, leverage it": reuses the same
/// bundled `SkyCatalog` (Messier objects + bright stars, extracted from Stellarium's own DSO
/// catalog — see `SkyCatalog`'s own doc comment) the rest of the app already treats as its
/// Stellarium data, rather than parsing the sibling `stellarium` source repository directly (a
/// fragile, non-shippable dependency on one development machine's local path — the same call
/// `ObservedObjectCatalog` already made for the Filters popover's own object list).
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A Messier designation can show up in several different spellings across this app
        // ("M13" typed free-hand, "M13 (Hercules Cluster)" from the Quick Start/`DeepSkyObject`
        // list) — extracting just the catalog number and matching it against `SkyCatalog`'s own
        // `id` (always the bare "M13" form) handles all of them at once, rather than requiring
        // an exact string match against whichever format happened to be used.
        if let messierID = messierCatalogID(in: trimmed),
           let match = SkyCatalog.messierObjects.first(where: { $0.id.caseInsensitiveCompare(messierID) == .orderedSame }) {
            return Position(raDegrees: match.raDegrees, decDegrees: match.decDegrees)
        }

        if let match = SkyCatalog.messierObjects.first(where: { ($0.commonName?.caseInsensitiveCompare(trimmed)) == .orderedSame }) {
            return Position(raDegrees: match.raDegrees, decDegrees: match.decDegrees)
        }

        for star in SkyCatalog.brightStars {
            let idMatches = star.id.caseInsensitiveCompare(trimmed) == .orderedSame
            let nameMatches = star.commonName.map { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? false
            if idMatches || nameMatches {
                return Position(raDegrees: star.raDegrees, decDegrees: star.decDegrees)
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

    private static func messierCatalogID(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^M\s?(\d+)"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let numberRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return "M\(text[numberRange])"
    }
}
