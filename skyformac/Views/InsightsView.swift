import SwiftUI
import Charts

/// "List in a separate page the most common actions performed, with parameters and equipment,
/// providing insights and suggestions for the next projects/sessions" — a read-only, full-width
/// dashboard over every capture across every active project (`InsightsData.build`), not a page
/// that edits anything itself.
struct InsightsView: View {
    let data: InsightsData
    var cameraManager: CameraManager
    var onBack: () -> Void
    var onSuggestQuickStart: (String) -> Void

    /// Same "start with the synchronous catalog fallback, replace with the AI list once it
    /// resolves" shape `DashboardHomeView`'s own copy of this section uses.
    @State private var ideas: [String] = []

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
                    if !data.monthlyActivity.isEmpty {
                        PageSection(title: "Activity Over Time") {
                            // A categorical (`label`) x-axis, not `bucket.month` directly — see
                            // `MonthlyActivity.label`'s own doc comment for why a continuous date
                            // axis showed misleading gaps between real months.
                            Chart(data.monthlyActivity) { bucket in
                                BarMark(x: .value("Month", bucket.label), y: .value("Captures", bucket.count))
                            }
                            .frame(height: 180)
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

                // Shown regardless of whether anything's been captured yet — a target worth
                // trying next is just as useful advice before the first session as after it.
                if !ideas.isEmpty {
                    PageSection(title: "Ideas for Next Time") {
                        Text("Common targets you haven't captured yet:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(ideas, id: \.self) { object in
                            HStack {
                                Text(object)
                                Spacer()
                                Button("Quick Start…") { onSuggestQuickStart(object) }
                                    .buttonStyle(.borderless)
                            }
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
        .task(id: data.suggestedNextObjects) {
            ideas = data.suggestedNextObjects
            ideas = await cameraManager.fetchSuggestedNextObjects(fallback: data.suggestedNextObjects)
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
