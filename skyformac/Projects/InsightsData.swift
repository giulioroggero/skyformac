import Foundation

/// One bucket of "how many captures happened in this calendar month" — what the Insights page's
/// activity chart plots, computed once rather than repeated per render.
struct MonthlyActivity: Identifiable, Equatable {
    var id: Date { month }
    let month: Date
    let count: Int

    /// What the chart actually plots along its x-axis — a `BarMark` keyed on `month` as a `Date`
    /// with a `unit: .month` component uses a *continuous* time axis, so a gap between two real
    /// months with activity (say, January and August) renders intermediate month tick marks for
    /// every month in between even though nothing happened then — which is exactly what looked
    /// like "dates in the past without real activities." A categorical (`String`) x-axis instead
    /// only ever shows the months that actually exist in `monthlyActivity`, since there's no
    /// continuous date domain for Charts to interpolate ticks across.
    var label: String {
        month.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
    }
}

/// A named count — "M13, 6" — the shape every one of the Insights page's own breakdowns (by
/// object, by equipment system, by acquisition mode) reduces to, so one `List`/`Chart` row type
/// covers all three instead of three near-identical ones.
struct NamedCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

/// One highly-rated (4 or 5 star) action, with the parameters actually used — "provide
/// suggestions for the best settings depending on the observation": this is the raw material
/// both the AI panel's own context and a future "what worked" UI read from, rather than either
/// re-deriving it from scratch. Only ever built from captures the user themselves rated well;
/// there's no attempt to infer quality from anything else (capture count, recency, etc.).
struct RatedAction: Identifiable, Equatable {
    let id: CaptureRecord.ID
    let object: String
    let rating: Rating
    let presetSummary: String
    let date: Date
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
    /// Every capture's raw timestamp — what the Insights page's own "Activity Over Time" chart
    /// re-buckets on the fly (by hour/day/month, over whatever range the user picks) instead of
    /// being limited to `monthlyActivity`'s fixed by-month grouping.
    let allCaptureDates: [Date]
    /// Curated objects the user has never actually captured — what the "try this next" suggestion
    /// row offers, in catalog order (already alphabetical) rather than randomized, so the same
    /// input always produces the same suggestions (see the type's own no-`Date`/`random` testing
    /// note above; determinism here is for the same reason, not that one).
    let suggestedNextObjects: [String]
    /// Every 4-or-5-star capture with parameters attached, newest first — "vote … to provide
    /// suggestions for the best settings depending on the observation."
    let topRatedActions: [RatedAction]

    static let empty = InsightsData(
        totalProjects: 0, totalSessions: 0, totalCaptures: 0, byObject: [], byEquipmentSystem: [],
        byAcquisitionMode: [], monthlyActivity: [], allCaptureDates: [], suggestedNextObjects: [], topRatedActions: []
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
                allCaptureDates: [],
                suggestedNextObjects: Array(knownObjects.filter { !captured.contains($0) }.prefix(5)),
                topRatedActions: []
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

        let topRated = captures
            .filter { $0.rating >= 4 }
            .compactMap { capture -> RatedAction? in
                guard let object = capture.object, let preset = capture.preset else { return nil }
                return RatedAction(id: capture.id, object: object, rating: capture.rating, presetSummary: preset.summaryLine, date: capture.date)
            }
            .sorted { $0.rating != $1.rating ? $0.rating > $1.rating : $0.date > $1.date }

        return InsightsData(
            totalProjects: projects.count,
            totalSessions: projects.reduce(0) { $0 + $1.sessions.count },
            totalCaptures: captures.count,
            byObject: Self.sortedCounts(objectCounts),
            byEquipmentSystem: Self.sortedCounts(equipmentCounts),
            byAcquisitionMode: Self.sortedCounts(modeCounts),
            monthlyActivity: monthCounts.map { MonthlyActivity(month: $0.key, count: $0.value) }.sorted { $0.month < $1.month },
            allCaptureDates: captures.map(\.date),
            suggestedNextObjects: Array(suggestions.prefix(5)),
            topRatedActions: Array(topRated.prefix(10))
        )
    }

    private static func sortedCounts(_ counts: [String: Int]) -> [NamedCount] {
        counts.map { NamedCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }
}
