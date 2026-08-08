import CoreGraphics
import Foundation
import SQLite3

/// One row from `astro_catalog.sqlite` (spec/MacZWO_Catalog_HUD_Spec.md section 2.2) — a galaxy,
/// nebula, cluster, or bright star with real celestial coordinates, ready to project onto a
/// frame via `WCSFrame.projectToPixel`.
struct SkyObject: Identifiable, Hashable, Sendable {
    enum ObjectType: String, Sendable {
        case galaxy = "G"
        case planetaryNebula = "PN"
        case emissionNebula = "E"
        case openCluster = "OC"
        case globularCluster = "GC"
        case star = "S"
    }

    let id: Int
    let catalog: String
    let catalogNumber: Int?
    let commonName: String?
    let type: ObjectType
    let raDeg: Double
    let decDeg: Double
    let magnitude: Double?
    let sizeArcmin: CGSize?
    let positionAngleDeg: Double?

    /// "M31 · Andromeda Galaxy" when a proper name is known, else "NGC 224" / "HIP" for stars
    /// (already-named by `commonName`, e.g. "Sirius").
    var label: String {
        guard let catalogNumber else { return commonName ?? catalog }
        let designation = "\(catalog) \(catalogNumber)"
        guard let commonName else { return designation }
        return catalog == "M" ? commonName : "\(designation) · \(commonName)"
    }

    /// Which row of the spec's Visual Style Guide (section 5.1) this object renders as. Messier
    /// membership wins regardless of physical type — a Messier galaxy still gets the gold
    /// reticle badge, not the red galaxy ellipse.
    var badgeStyle: HUDBadgeStyle {
        if catalog == "M" { return .messier }
        switch type {
        case .galaxy: return .galaxy
        case .planetaryNebula, .emissionNebula: return .nebula
        case .openCluster, .globularCluster: return .cluster
        case .star: return .star
        }
    }
}

enum HUDBadgeStyle {
    case messier, galaxy, nebula, cluster, star
}

/// Read-only SQLite access to the bundled astronomical catalog. An actor per spec section 6.1:
/// every query (and the SQLite C calls backing it) stays off the main thread, so `SkyHUDView`
/// never blocks a `body` evaluation on disk/DB I/O.
actor CatalogRepository {
    static let shared = CatalogRepository()

    private var db: OpaquePointer?

    private init() {
        guard let url = Bundle.main.url(forResource: "astro_catalog", withExtension: "sqlite", subdirectory: "AstroCatalog")
            ?? Bundle.main.url(forResource: "astro_catalog", withExtension: "sqlite")
        else { return }
        // SQLITE_OPEN_READONLY: the bundled file is a build artifact, never written to at runtime.
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            db = nil
        }
    }

    /// Dynamic level-of-detail magnitude cutoff, per spec section 6.2 — wider fields get pruned
    /// to only the brightest/most notable objects so the HUD stays legible and the query stays
    /// small, while high-magnification fields reveal fainter catalog entries.
    static func magnitudeLimit(forFOVDegrees fov: Double) -> Double {
        if fov > 5 { return 6.0 }
        if fov > 1 { return 10.0 }
        return 14.0
    }

    /// Fetches every catalog object inside `bounds` at or brighter than `maxMagnitude` (spec
    /// section 3.2). Objects with a `NULL` magnitude (some faint NGC/IC entries have none on
    /// record) are always included — omitting them would silently hide real objects a plate
    /// solve did find.
    func fetchObjects(in bounds: BoundingBox, maxMagnitude: Double) -> [SkyObject] {
        guard let db else { return [] }

        let raClause = bounds.wrapsAround
            ? "(ra_deg >= ? OR ra_deg <= ?)"
            : "(ra_deg BETWEEN ? AND ?)"
        let sql = """
            SELECT id, catalog, catalog_number, common_name, object_type,
                   ra_deg, dec_deg, v_mag, major_axis_arcmin, minor_axis_arcmin, position_angle_deg
            FROM catalog_objects
            WHERE dec_deg BETWEEN ? AND ?
              AND \(raClause)
              AND (v_mag IS NULL OR v_mag <= ?)
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }

        sqlite3_bind_double(statement, 1, bounds.decMinDeg)
        sqlite3_bind_double(statement, 2, bounds.decMaxDeg)
        sqlite3_bind_double(statement, 3, bounds.raMinDeg)
        sqlite3_bind_double(statement, 4, bounds.raMaxDeg)
        sqlite3_bind_double(statement, 5, maxMagnitude)

        var results: [SkyObject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let typeCString = sqlite3_column_text(statement, 4),
                  let catalogCString = sqlite3_column_text(statement, 1),
                  let type = SkyObject.ObjectType(rawValue: String(cString: typeCString))
            else { continue }

            let catalogNumber = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(statement, 2))
            let commonName = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let magnitude = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 7)
            let major = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 8)
            let minor = sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 9)
            let positionAngle = sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 10)

            results.append(SkyObject(
                id: Int(sqlite3_column_int(statement, 0)),
                catalog: String(cString: catalogCString),
                catalogNumber: catalogNumber,
                commonName: commonName,
                type: type,
                raDeg: sqlite3_column_double(statement, 5),
                decDeg: sqlite3_column_double(statement, 6),
                magnitude: magnitude,
                sizeArcmin: major.map { CGSize(width: $0, height: minor ?? $0) },
                positionAngleDeg: positionAngle
            ))
        }
        return results
    }
}
