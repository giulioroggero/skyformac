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

    private static func load(_ resource: String) -> [SkyCatalogObject] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "SkyCatalog")
            ?? Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let objects = try? JSONDecoder().decode([SkyCatalogObject].self, from: data)
        else { return [] }
        return objects
    }
}
