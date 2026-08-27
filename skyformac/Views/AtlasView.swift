import SwiftUI
import Charts

/// One *object* plotted on the atlas — every session (across every project) that targeted it,
/// grouped into a single point rather than one point per session. A session's object resolves to
/// a fixed position by name (`SkyAtlasLookup`), so two sessions on the same object always land on
/// the exact same point anyway; plotting them separately just stacked identical dots on top of
/// each other with no way to tell "I've shot this once" from "I've shot this a dozen times."
private struct PlottedObject: Identifiable {
    var id: String { object }
    let object: String
    let position: SkyAtlasLookup.Position
    let entries: [(project: Project, session: Session)]

    var sessionCount: Int { entries.count }
}

/// A session with an object that couldn't be placed — either a Solar System object (the Moon,
/// a planet — genuinely no fixed position) or something not in the bundled catalog at all.
/// Listed separately rather than silently dropped, so coverage gaps stay visible.
private struct UnplottedSession: Identifiable {
    var id: Session.ID { session.id }
    let project: Project
    let session: Session
    let object: String
    let isSolarSystemObject: Bool
}

/// The Projects page's third view mode — "show all sessions of all projects and place the
/// session in the sky atlas depending on the session's observed objects." A `Chart` of
/// `PointMark`s over right ascension (x) / declination (y), the same fixed-position sky-atlas
/// idea a paper star atlas or planetarium app uses, built entirely from the bundled
/// Stellarium-derived `SkyCatalog` (see `SkyAtlasLookup`) — no live/interactive star field, just
/// "where in the sky has this session's target actually been."
struct AtlasView: View {
    let projects: [Project]
    var onSelectSession: (Project, Session) -> Void

    @State private var projectNameFilter = ""
    @State private var objectFilter: String?
    @State private var hasDateRange = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var selectedPlotted: PlottedObject?

    private var allObjectNames: [String] {
        Array(Set(projects.flatMap { project in project.sessions.compactMap(\.plannedObjects.first) })).sorted()
    }

    /// Every session across every project, paired with its own project — the raw material both
    /// `plotted`/`unplotted` filter down from.
    private var allSessionEntries: [(project: Project, session: Session)] {
        projects.flatMap { project in project.sessions.map { (project, $0) } }
    }

    private var filteredEntries: [(project: Project, session: Session)] {
        allSessionEntries.filter { entry in
            if !projectNameFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard entry.project.name.localizedCaseInsensitiveContains(projectNameFilter) else { return false }
            }
            if let objectFilter, entry.session.plannedObjects.first != objectFilter {
                return false
            }
            if hasDateRange {
                let date = entry.session.plannedDate ?? entry.session.createdDate
                guard (startDate...endDate).contains(date) else { return false }
            }
            return true
        }
    }

    /// Grouped by object name (not one entry per session — see `PlottedObject`'s own doc comment)
    /// and sorted by descending session count, so the chart's largest, most-imaged points and
    /// "Selected Object"'s own list both read most-shot-first.
    private var plotted: [PlottedObject] {
        var byObject: [String: (position: SkyAtlasLookup.Position, entries: [(project: Project, session: Session)])] = [:]
        for entry in filteredEntries {
            guard let object = entry.session.plannedObjects.first,
                  let position = SkyAtlasLookup.position(forObjectName: object)
            else { continue }
            byObject[object, default: (position, [])].entries.append((entry.project, entry.session))
        }
        return byObject
            .map { PlottedObject(object: $0.key, position: $0.value.position, entries: $0.value.entries) }
            .sorted { $0.sessionCount > $1.sessionCount }
    }

    /// Roughly what's worth pointing at tonight (see `SolarPosition`'s own doc comment on what
    /// this can/can't actually promise) — one or two RA bands, since the visible half of the sky
    /// can straddle the chart's own 0°/360° seam.
    private var tonightVisibleRARanges: [(start: Double, end: Double)] {
        SolarPosition.tonightVisibleRARanges()
    }

    private var unplotted: [UnplottedSession] {
        filteredEntries.compactMap { entry in
            guard let object = entry.session.plannedObjects.first else { return nil }
            guard SkyAtlasLookup.position(forObjectName: object) == nil else { return nil }
            return UnplottedSession(
                project: entry.project, session: entry.session, object: object,
                isSolarSystemObject: SkyAtlasLookup.isSolarSystemObject(object)
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Filters") {
                    HStack {
                        TextField("Project name", text: $projectNameFilter, prompt: Text("Any project"))
                            .frame(maxWidth: 220)
                        Picker("Object", selection: $objectFilter) {
                            Text("Any object").tag(String?.none)
                            ForEach(allObjectNames, id: \.self) { object in
                                Text(object).tag(String?.some(object))
                            }
                        }
                        .frame(maxWidth: 220)
                        Toggle("Date Range", isOn: $hasDateRange)
                        if hasDateRange {
                            DatePicker("From", selection: $startDate, displayedComponents: .date)
                            DatePicker("To", selection: $endDate, displayedComponents: .date)
                        }
                        Spacer()
                    }
                }

                PageSection(title: "Sky Atlas") {
                    if plotted.isEmpty {
                        ContentUnavailableView(
                            "No Placeable Sessions", systemImage: "map",
                            description: Text("Sessions targeting a cataloged Messier/Caldwell/NGC/IC object or bright star show up here, positioned by right ascension and declination.")
                        )
                        .frame(height: 200)
                    } else {
                        Chart {
                            // Roughly what's up overnight, shaded behind the points — see
                            // `SolarPosition`'s own doc comment on exactly what this can/can't
                            // promise (no real location/horizon math, just "opposite the Sun").
                            ForEach(tonightVisibleRARanges, id: \.start) { range in
                                RectangleMark(
                                    xStart: .value("Start", range.start), xEnd: .value("End", range.end),
                                    yStart: .value("Bottom", -90), yEnd: .value("Top", 90)
                                )
                                .foregroundStyle(.yellow.opacity(0.10))
                            }
                            ForEach(plotted) { entry in
                                PointMark(
                                    x: .value("Right Ascension", entry.position.raDegrees),
                                    y: .value("Declination", entry.position.decDegrees)
                                )
                                .foregroundStyle(entry.id == selectedPlotted?.id ? Color.accentColor : Color.blue)
                                .symbolSize(pointSize(for: entry))
                                .annotation(position: .top) {
                                    Text(entry.sessionCount > 1 ? "\(entry.object) (\(entry.sessionCount))" : entry.object)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        // A sky atlas conventionally reads right-to-left (RA increases eastward,
                        // but the sky is viewed from inside the celestial sphere) — reversed here
                        // to match that convention rather than an ordinary left-to-right chart.
                        // NOTE: a `ClosedRange` (`360...0`) traps at runtime since it requires
                        // lowerBound <= upperBound — Charts' array-domain form is the supported way
                        // to reverse a continuous axis, by giving the bounds in descending order.
                        .chartXScale(domain: [360, 0])
                        .chartYScale(domain: -90...90)
                        .chartXAxisLabel("Right Ascension (°)")
                        .chartYAxisLabel("Declination (°)")
                        .frame(height: 360)
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onTapGesture { location in
                                        selectedPlotted = closestPlotted(to: location, proxy: proxy, geometry: geometry)
                                    }
                            }
                        }
                        Text("Shaded band: roughly up overnight, opposite the Sun — an approximation (ignores your actual location and horizon), not exact rise/set times. A point's size reflects how many sessions have targeted that object.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let selectedPlotted {
                    PageSection(title: "Selected Object") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedPlotted.object).font(.headline)
                            Text("\(selectedPlotted.sessionCount) session\(selectedPlotted.sessionCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(selectedPlotted.entries, id: \.session.id) { entry in
                                HStack {
                                    Text("\(entry.project.name) — \(entry.session.name)").font(.body)
                                    Spacer()
                                    Button("Open") { onSelectSession(entry.project, entry.session) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }

                if !unplotted.isEmpty {
                    PageSection(title: "Not Shown on the Atlas") {
                        Text("Solar System objects move across the sky and have no fixed position; anything else here just isn't in the bundled catalog.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(unplotted) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(entry.project.name) — \(entry.session.name)").font(.body)
                                    Text(entry.isSolarSystemObject ? "\(entry.object) — moves across the sky" : "\(entry.object) — not in the bundled catalog")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button("Open") { onSelectSession(entry.project, entry.session) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Finds the plotted point nearest a tap — `Chart`'s own hit-testing needs a manual nearest-
    /// neighbor search like this since `PointMark` doesn't expose per-point tap gestures directly.
    private func closestPlotted(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> PlottedObject? {
        let origin = geometry[proxy.plotAreaFrame].origin
        let relativeLocation = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard let (ra, dec) = proxy.value(at: relativeLocation, as: (Double, Double).self) else { return nil }
        return plotted.min { lhs, rhs in
            let lhsDistance = pow(lhs.position.raDegrees - ra, 2) + pow(lhs.position.decDegrees - dec, 2)
            let rhsDistance = pow(rhs.position.raDegrees - ra, 2) + pow(rhs.position.decDegrees - dec, 2)
            return lhsDistance < rhsDistance
        }
    }

    /// Base size scales with how many sessions have targeted this object (capped so one
    /// wildly-repeated target doesn't dwarf everything else on the chart), boosted further while
    /// selected — the same "bigger = selected" signal the original single-size chart used, now
    /// layered on top of "bigger = more sessions" instead of replacing it.
    private func pointSize(for entry: PlottedObject) -> CGFloat {
        let frequencyBoost = CGFloat(min(entry.sessionCount - 1, 6)) * 20
        let base: CGFloat = 80 + frequencyBoost
        return entry.id == selectedPlotted?.id ? base * 1.6 : base
    }
}
