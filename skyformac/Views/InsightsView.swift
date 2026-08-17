import SwiftUI
import Charts

/// "List in a separate page the most common actions performed, with parameters and equipment,
/// providing insights and suggestions for the next projects/sessions" — a read-only, full-width
/// dashboard over every capture across every active project (`InsightsData.build`), not a page
/// that edits anything itself.
struct InsightsView: View {
    let data: InsightsData
    var onBack: () -> Void

    @State private var granularity: ActivityGranularity = .month
    @State private var rangeOption: ActivityRangeOption = .allTime
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd: Date = Date()

    /// Every capture date within the currently-selected range — `nil` bounds (`.allTime`) keep
    /// everything, otherwise this filters before bucketing so switching ranges and switching
    /// granularity compose independently of each other.
    private var datesInRange: [Date] {
        guard let bounds = rangeOption.bounds(customStart: customStart, customEnd: customEnd) else {
            return data.allCaptureDates
        }
        return data.allCaptureDates.filter { $0 >= bounds.lowerBound && $0 <= bounds.upperBound }
    }

    private var activityBuckets: [ActivityBucket] {
        granularity.bucket(datesInRange)
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
                            activityControls
                            if activityBuckets.isEmpty {
                                Text("No captures in this range.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 100)
                            } else {
                                // A categorical (`label`) x-axis, not the bucket's own `Date`
                                // directly — see `MonthlyActivity.label`'s doc comment (same
                                // reasoning applies at every granularity) for why a continuous
                                // date axis showed misleading gaps between real buckets.
                                Chart(activityBuckets) { bucket in
                                    BarMark(x: .value(granularity.axisLabel, bucket.label), y: .value("Captures", bucket.count))
                                }
                                .frame(height: 180)
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
    }

    /// Granularity segmented control, quick-range shortcuts, and (only when "Custom" is picked)
    /// the two date pickers that define it.
    private var activityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Group by", selection: $granularity) {
                ForEach(ActivityGranularity.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            HStack(spacing: 10) {
                Picker("Range", selection: $rangeOption) {
                    ForEach(ActivityRangeOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()

                if rangeOption == .custom {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                        .labelsHidden()
                    Text("–").foregroundStyle(.secondary)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                        .labelsHidden()
                }
                Spacer()
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

/// How "Activity Over Time" buckets capture dates — hour-of-day (across the whole range, not
/// per-day), calendar day, or calendar month.
enum ActivityGranularity: String, CaseIterable, Identifiable {
    case hour, day, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: "Hour"
        case .day: "Day"
        case .month: "Month"
        }
    }

    var axisLabel: String {
        switch self {
        case .hour: "Hour of Day"
        case .day: "Day"
        case .month: "Month"
        }
    }

    func bucket(_ dates: [Date]) -> [ActivityBucket] {
        let calendar = Calendar.current
        switch self {
        case .hour:
            // "Hours" buckets by hour-of-day (0–23) regardless of which calendar day it fell on —
            // "what time of night do I actually shoot," not a many-thousand-bucket full timeline.
            let counts = Dictionary(grouping: dates) { calendar.component(.hour, from: $0) }.mapValues(\.count)
            return (0..<24).compactMap { hour in
                guard let count = counts[hour] else { return nil }
                let label = String(format: "%02d:00", hour)
                return ActivityBucket(sortKey: Double(hour), label: label, count: count)
            }
        case .day:
            let counts = Dictionary(grouping: dates) { calendar.startOfDay(for: $0) }.mapValues(\.count)
            return counts.map { date, count in
                ActivityBucket(sortKey: date.timeIntervalSinceReferenceDate, label: date.formatted(.dateTime.month(.abbreviated).day()), count: count)
            }.sorted { $0.sortKey < $1.sortKey }
        case .month:
            let counts = Dictionary(grouping: dates) { date in
                calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
            }.mapValues(\.count)
            return counts.map { date, count in
                ActivityBucket(sortKey: date.timeIntervalSinceReferenceDate, label: date.formatted(.dateTime.month(.abbreviated).year(.twoDigits)), count: count)
            }.sorted { $0.sortKey < $1.sortKey }
        }
    }
}

/// One bar in the "Activity Over Time" chart — computed fresh whenever the granularity or range
/// changes, unlike `MonthlyActivity` (which is fixed to by-month and precomputed once in
/// `InsightsData.build`).
struct ActivityBucket: Identifiable, Equatable {
    var id: String { label }
    let sortKey: Double
    let label: String
    let count: Int
}

/// The "Activity Over Time" quick shortcuts, plus "Custom" for an explicit start/end pair.
enum ActivityRangeOption: String, CaseIterable, Identifiable {
    case last7Days, last30Days, last90Days, thisYear, allTime, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .last90Days: "Last 90 Days"
        case .thisYear: "This Year"
        case .allTime: "All Time"
        case .custom: "Custom"
        }
    }

    /// `nil` means "no filtering" (`.allTime`) — every other case (including `.custom`) returns an
    /// explicit, inclusive bound.
    func bounds(customStart: Date, customEnd: Date) -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .allTime:
            return nil
        case .last7Days:
            return (calendar.date(byAdding: .day, value: -7, to: now) ?? now)...now
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now) ?? now)...now
        case .last90Days:
            return (calendar.date(byAdding: .day, value: -90, to: now) ?? now)...now
        case .thisYear:
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
            return startOfYear...now
        case .custom:
            let start = min(customStart, customEnd)
            let end = max(customStart, customEnd)
            return calendar.startOfDay(for: start)...(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end)
        }
    }
}
