import Foundation

/// One bucket of "how many captures happened in this calendar month" — what the Insights page's
/// activity chart plots, computed once rather than repeated per render.
struct MonthlyActivity: Identifiable, Equatable {
    var id: Date { month }
    let month: Date
    let count: Int
}

/// A named count — "M13, 6" — the shape every one of the Insights page's own breakdowns (by
/// object, by equipment system, by acquisition mode) reduces to, so one `List`/`Chart` row type
/// covers all three instead of three near-identical ones.
struct NamedCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

/// Aggregates every capture across every active (non-deleted) project into the breakdowns and
/// suggestions the Insights page shows — "what have I actually been doing," not just "what's in
/// this one project." A pure function of `projects`/`equipmentSystems`/`knownObjects` (plus
/// `now`, injected rather than read live, so this stays testable without depending on the actual
/// current date), not a `@MainActor` type — nothing here touches a camera or the filesystem.
struct InsightsData: Equatable {
    let totalProjects: Int
    let totalSessions: Int
    let totalCaptures: Int
    let byObject: [NamedCount]
    let byEquipmentSystem: [NamedCount]
    let byAcquisitionMode: [NamedCount]
    let monthlyActivity: [MonthlyActivity]
    /// Curated objects the user has never actually captured — what the "try this next" suggestion
    /// row offers, in catalog order (already alphabetical) rather than randomized, so the same
    /// input always produces the same suggestions (see the type's own no-`Date`/`random` testing
    /// note above; determinism here is for the same reason, not that one).
    let suggestedNextObjects: [String]

    static let empty = InsightsData(
        totalProjects: 0, totalSessions: 0, totalCaptures: 0, byObject: [], byEquipmentSystem: [],
        byAcquisitionMode: [], monthlyActivity: [], suggestedNextObjects: []
    )

    static func build(
        projects: [Project], equipmentSystems: [EquipmentSystem], knownObjects: [String], now: Date
    ) -> InsightsData {
        let captures = projects.flatMap { project in project.sessions.flatMap(\.captures) }
        guard !captures.isEmpty else {
            let captured = Set<String>()
            return InsightsData(
                totalProjects: projects.count, totalSessions: projects.reduce(0) { $0 + $1.sessions.count },
                totalCaptures: 0, byObject: [], byEquipmentSystem: [], byAcquisitionMode: [], monthlyActivity: [],
                suggestedNextObjects: Array(knownObjects.filter { !captured.contains($0) }.prefix(5))
            )
        }

        let objectCounts = Dictionary(grouping: captures.compactMap(\.object), by: { $0 }).mapValues(\.count)
        let equipmentNameByID = Dictionary(uniqueKeysWithValues: equipmentSystems.map { ($0.id, $0.name) })
        let equipmentCounts = Dictionary(
            grouping: captures.compactMap { $0.equipmentSystemID.flatMap { equipmentNameByID[$0] } }, by: { $0 }
        ).mapValues(\.count)
        let modeCounts = Dictionary(grouping: captures.compactMap { $0.preset?.mode.label }, by: { $0 }).mapValues(\.count)

        let calendar = Calendar.current
        let monthCounts = Dictionary(grouping: captures) { capture in
            calendar.date(from: calendar.dateComponents([.year, .month], from: capture.date)) ?? capture.date
        }.mapValues(\.count)

        let capturedObjects = Set(objectCounts.keys.map { $0.lowercased() })
        let suggestions = knownObjects.filter { !capturedObjects.contains($0.lowercased()) }

        return InsightsData(
            totalProjects: projects.count,
            totalSessions: projects.reduce(0) { $0 + $1.sessions.count },
            totalCaptures: captures.count,
            byObject: Self.sortedCounts(objectCounts),
            byEquipmentSystem: Self.sortedCounts(equipmentCounts),
            byAcquisitionMode: Self.sortedCounts(modeCounts),
            monthlyActivity: monthCounts.map { MonthlyActivity(month: $0.key, count: $0.value) }.sorted { $0.month < $1.month },
            suggestedNextObjects: Array(suggestions.prefix(5))
        )
    }

    private static func sortedCounts(_ counts: [String: Int]) -> [NamedCount] {
        counts.map { NamedCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }
}
