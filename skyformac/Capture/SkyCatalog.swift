import Foundation

/// One entry from a bundled catalog derived from real astronomical data (the Messier and
/// Caldwell subsets of Stellarium's DSO catalog — `nebulae/default/catalog.txt` and
/// `names.dat` in the `stellarium` repo — plus a small hand-curated bright-star list of public
/// J2000 coordinates/magnitudes). Used by `StarPatternRecognizer` to identify what a captured
/// star field is actually pointed at, and by `SkyAtlasLookup`/the AI panel to resolve a free-text
/// object name to a real position.
struct SkyCatalogObject: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let commonName: String?
    let objectType: String
    let raDegrees: Double
    let decDegrees: Double
    let magnitude: Double
    var majorAxisArcmin: Double?
    var minorAxisArcmin: Double?

    var displayName: String { commonName ?? id }
}

enum SkyCatalog {
    static let messierObjects: [SkyCatalogObject] = load("messier")
    static let brightStars: [SkyCatalogObject] = load("bright_stars")
    /// The 109-object Caldwell catalog — Patrick Moore's well-known "beyond Messier" complement,
    /// covering plenty of bright targets Messier's own list misses (far-southern objects, mainly).
    /// Extracted the same way `messierObjects` was: real RA/Dec/magnitude from Stellarium's own
    /// DSO catalog, common names (where Stellarium's `names.dat` has one) preferring a "WK"
    /// (well-known) source when more than one name is listed for the same object.
    static let caldwellObjects: [SkyCatalogObject] = load("caldwell")
    /// A curated NGC/IC subset (V mag < 9.0, real Stellarium DSO-catalog coordinates, the same
    /// source Messier/Caldwell already came from) — everything bright enough to be a realistic
    /// imaging target that Messier/Caldwell's own ~220 objects between them don't already cover
    /// (an object with a Messier or Caldwell number is excluded here, so it's never listed twice
    /// under two different catalog IDs). Extends `SkyAtlasLookup`'s reach well past "only Messier/
    /// Caldwell/bright stars can be plotted" without hand-curating coordinates.
    static let ngcObjects: [SkyCatalogObject] = load("ngc")

    /// Logs (rather than just silently returning `[]`) on any failure — a missing bundle
    /// resource, an unreadable file, or a JSON schema mismatch would otherwise leave the entire
    /// Messier/Caldwell/bright-star catalog empty with zero indication of *why*, since every
    /// consumer (`SkyAtlasLookup`, `StarPatternRecognizer`, `ProjectSearch`) just treats an empty
    /// catalog as "nothing matched" rather than "something's actually broken." `logFailure` hops
    /// to `@MainActor` in a detached `Task` rather than calling `AppLog` directly — `load` runs
    /// from `static let` initializers that may first execute off the main actor (e.g. from
    /// `StarPatternRecognizer`'s background Focus Assist path), and `AppLog.shared` itself is
    /// `@MainActor`-isolated.
    private static func load(_ resource: String) -> [SkyCatalogObject] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "SkyCatalog")
            ?? Bundle.main.url(forResource: resource, withExtension: "json")
        else {
            logFailure("SkyCatalog: couldn't find bundled resource \"\(resource).json\".")
            return []
        }
        guard let data = try? Data(contentsOf: url) else {
            logFailure("SkyCatalog: couldn't read \"\(resource).json\" at \(url.path).")
            return []
        }
        do {
            return try JSONDecoder().decode([SkyCatalogObject].self, from: data)
        } catch {
            logFailure("SkyCatalog: couldn't decode \"\(resource).json\" — \(error.localizedDescription)")
            return []
        }
    }

    private static func logFailure(_ message: String) {
        Task { @MainActor in AppLog.shared.log(message) }
    }
}
