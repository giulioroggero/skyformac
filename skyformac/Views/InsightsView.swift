import SwiftUI
import Charts

/// "List in a separate page the most common actions performed, with parameters and equipment,
/// providing insights and suggestions for the next projects/sessions" — a read-only, full-width
/// dashboard over every capture across every active project (`InsightsData.build`), not a page
/// that edits anything itself.
struct InsightsView: View {
    let data: InsightsData
    var onBack: () -> Void

    /// Starts at the top (one bar per year with any activity) — tapping a bar drills one level
    /// deeper (year → month → day → hour → minute), the breadcrumb trail jumps back up. Replaces
    /// the old independent "Group by"/"Range" pickers: those let you pick *a* granularity over
    /// *some* range, but not "the days of August" or "the hours of the 16th" specifically — a real
    /// drill-down is what actually answers that.
    @State private var drillLevel: DrillLevel = .year
    @State private var chartSelection: String?

    private var activityBuckets: [ActivityBucket] {
        drillLevel.bucket(data.allCaptureDates)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Overview") {
                    StatsGridView(stats: [
                        StatItem(label: "Projects", value: "\(data.totalProjects)"),
                        StatItem(label: "Sessions", value: "\(data.totalSessions)"),
                        StatItem(label: "Captures", value: "\(data.totalCaptures)"),
                    ])
                }

                if data.totalCaptures == 0 {
                    PageSection {
                        ContentUnavailableView(
                            "No Activity Yet", systemImage: "chart.bar",
                            description: Text("Once you've captured something, this page fills in with what you actually do most.")
                        )
                    }
                } else {
                    PageSection(title: "Activity Over Time") {
                        VStack(alignment: .leading, spacing: 12) {
                            breadcrumbBar
                            if activityBuckets.isEmpty {
                                Text("No captures in this period.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 100)
                            } else {
                                // A categorical (`label`) x-axis, not a continuous `Date` — a
                                // continuous axis renders misleading gaps for a period with no
                                // activity, and every sub-level here is already zero-filled
                                // across its own known range (all 12 months, all days in the
                                // month, all 24 hours, all 60 minutes) rather than only showing
                                // buckets that happen to have data.
                                Chart(activityBuckets) { bucket in
                                    BarMark(x: .value(drillLevel.axisLabel, bucket.label), y: .value("Captures", bucket.count))
                                }
                                .chartXSelection(value: $chartSelection)
                                .frame(height: 180)
                                if !drillLevel.isDeepest {
                                    Text("Tap a bar to drill in.")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if !data.byObject.isEmpty {
                        PageSection(title: "Most Captured Objects") {
                            breakdownChart(data.byObject, color: .blue)
                        }
                    }

                    if !data.byEquipmentSystem.isEmpty {
                        PageSection(title: "Most Used Equipment") {
                            breakdownChart(data.byEquipmentSystem, color: .orange)
                        }
                    }

                    if !data.byAcquisitionMode.isEmpty {
                        PageSection(title: "Most Common Acquisition Mode") {
                            breakdownChart(data.byAcquisitionMode, color: .purple)
                        }
                    }
                }

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Insights")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: onBack)
            }
        }
        .onChange(of: chartSelection) { _, newValue in
            guard let newValue, let bucket = activityBuckets.first(where: { $0.label == newValue }),
                  let next = drillLevel.drilling(into: bucket)
            else { return }
            drillLevel = next
            chartSelection = nil
        }
    }

    /// A Finder-style path bar — every earlier level is a tappable jump straight to it, the last
    /// (current) segment is plain text. `id: \.offset` since `DrillLevel`/its title pairing has no
    /// other stable identity worth introducing just for this list.
    private var breadcrumbBar: some View {
        let trail = drillLevel.breadcrumbTrail
        return HStack(spacing: 4) {
            ForEach(trail.indices, id: \.self) { (index: Int) -> AnyView in
                AnyView(breadcrumbSegment(trail: trail, index: index))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func breadcrumbSegment(trail: [(level: DrillLevel, title: String)], index: Int) -> some View {
        let item = trail[index]
        HStack(spacing: 4) {
            if index > 0 {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            if index == trail.count - 1 {
                Text(item.title).font(.caption.bold())
            } else {
                Button(item.title) { drillLevel = item.level }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func breakdownChart(_ counts: [NamedCount], color: Color) -> some View {
        Chart(counts.prefix(10)) { item in
            BarMark(x: .value("Count", item.count), y: .value("Name", item.name))
        }
        .foregroundStyle(color)
        .frame(height: CGFloat(min(counts.count, 10)) * 28 + 20)
    }
}

/// Where "Activity Over Time" currently is in the year → month → day → hour → minute drill-down —
/// each level's `bucket(_:)` scopes to whatever its associated values pin down (e.g. `.day(year:
/// 2026, month: 8)` only ever looks at August 2026's captures) and, unlike the old
/// `ActivityGranularity`, zero-fills every sub-period in that scope (all 12 months, all days in
/// the month, all 24 hours, all 60 minutes) rather than only showing periods that had activity —
/// once you've drilled into a specific year/month/day/hour, "no activity on the 12th" is itself
/// useful information, not a gap to hide.
enum DrillLevel: Equatable {
    case year
    case month(year: Int)
    case day(year: Int, month: Int)
    case hour(year: Int, month: Int, day: Int)
    case minute(year: Int, month: Int, day: Int, hour: Int)

    /// `true` for `.minute`, the deepest level — nothing left to drill into from there.
    var isDeepest: Bool {
        if case .minute = self { return true }
        return false
    }

    var axisLabel: String {
        switch self {
        case .year: "Year"
        case .month: "Month"
        case .day: "Day"
        case .hour: "Hour"
        case .minute: "Minute"
        }
    }

    /// One segment per level from the root down to (and including) `self`.
    var breadcrumbTrail: [(level: DrillLevel, title: String)] {
        switch self {
        case .year:
            return [(.year, "All Time")]
        case .month(let year):
            return DrillLevel.year.breadcrumbTrail + [(self, "\(year)")]
        case .day(let year, let month):
            return DrillLevel.month(year: year).breadcrumbTrail + [(self, Self.monthName(month))]
        case .hour(let year, let month, let day):
            return DrillLevel.day(year: year, month: month).breadcrumbTrail + [(self, "\(day)")]
        case .minute(let year, let month, let day, let hour):
            return DrillLevel.hour(year: year, month: month, day: day).breadcrumbTrail + [(self, String(format: "%02d:00", hour))]
        }
    }

    private static func monthName(_ month: Int, style: Date.FormatStyle.Symbol.Month = .wide) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = month
        components.day = 1
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.month(style))
    }

    /// One level deeper, using `bucket`'s `component` (the year/month/day/hour it represents) —
    /// `nil` once already at `.minute`, the deepest level, nothing further to drill into.
    func drilling(into bucket: ActivityBucket) -> DrillLevel? {
        switch self {
        case .year: return .month(year: bucket.component)
        case .month(let year): return .day(year: year, month: bucket.component)
        case .day(let year, let month): return .hour(year: year, month: month, day: bucket.component)
        case .hour(let year, let month, let day): return .minute(year: year, month: month, day: day, hour: bucket.component)
        case .minute: return nil
        }
    }

    func bucket(_ dates: [Date]) -> [ActivityBucket] {
        let calendar = Calendar.current
        switch self {
        case .year:
            let counts = Dictionary(grouping: dates) { calendar.component(.year, from: $0) }.mapValues(\.count)
            return counts.map { year, count in
                ActivityBucket(sortKey: Double(year), label: "\(year)", count: count, component: year)
            }.sorted { $0.sortKey < $1.sortKey }

        case .month(let year):
            let scoped = dates.filter { calendar.component(.year, from: $0) == year }
            let counts = Dictionary(grouping: scoped) { calendar.component(.month, from: $0) }.mapValues(\.count)
            return (1...12).map { month in
                ActivityBucket(sortKey: Double(month), label: Self.monthName(month, style: .abbreviated), count: counts[month] ?? 0, component: month)
            }

        case .day(let year, let month):
            let scoped = dates.filter { calendar.component(.year, from: $0) == year && calendar.component(.month, from: $0) == month }
            let counts = Dictionary(grouping: scoped) { calendar.component(.day, from: $0) }.mapValues(\.count)
            var components = DateComponents()
            components.year = year
            components.month = month
            let daysInMonth = calendar.range(of: .day, in: .month, for: calendar.date(from: components) ?? Date())?.count ?? 31
            return (1...daysInMonth).map { day in
                ActivityBucket(sortKey: Double(day), label: "\(day)", count: counts[day] ?? 0, component: day)
            }

        case .hour(let year, let month, let day):
            let scoped = dates.filter {
                calendar.component(.year, from: $0) == year
                    && calendar.component(.month, from: $0) == month
                    && calendar.component(.day, from: $0) == day
            }
            let counts = Dictionary(grouping: scoped) { calendar.component(.hour, from: $0) }.mapValues(\.count)
            return (0..<24).map { hour in
                ActivityBucket(sortKey: Double(hour), label: String(format: "%02d", hour), count: counts[hour] ?? 0, component: hour)
            }

        case .minute(let year, let month, let day, let hour):
            let scoped = dates.filter {
                calendar.component(.year, from: $0) == year
                    && calendar.component(.month, from: $0) == month
                    && calendar.component(.day, from: $0) == day
                    && calendar.component(.hour, from: $0) == hour
            }
            let counts = Dictionary(grouping: scoped) { calendar.component(.minute, from: $0) }.mapValues(\.count)
            return (0..<60).map { minute in
                ActivityBucket(sortKey: Double(minute), label: "\(minute)", count: counts[minute] ?? 0, component: minute)
            }
        }
    }
}

/// One bar in the "Activity Over Time" chart, computed fresh whenever `drillLevel` changes.
struct ActivityBucket: Identifiable, Equatable {
    var id: String { label }
    let sortKey: Double
    let label: String
    let count: Int
    /// The raw calendar component this bucket represents (a year, a month 1...12, a day 1...31,
    /// an hour 0...23, or a minute 0...59, depending on the active `DrillLevel`) — lets tapping a
    /// bar drill down without re-parsing its display `label`.
    let component: Int
}
