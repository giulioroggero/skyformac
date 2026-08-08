import Foundation

/// One entry from a bundled catalog derived from real astronomical data (the Messier subset of
/// Stellarium's DSO catalog — `nebulae/default/catalog.txt` in the `stellarium` repo — plus a
/// small hand-curated bright-star list of public J2000 coordinates/magnitudes). Used by
/// `StarPatternRecognizer` to identify what a captured star field is actually pointed at.
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

    private static func load(_ resource: String) -> [SkyCatalogObject] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "SkyCatalog")
            ?? Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let objects = try? JSONDecoder().decode([SkyCatalogObject].self, from: data)
        else { return [] }
        return objects
    }
}
