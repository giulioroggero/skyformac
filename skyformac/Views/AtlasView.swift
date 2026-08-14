import SwiftUI
import Charts

/// One session plotted on the atlas — its first planned object's fixed sky position
/// (`SkyAtlasLookup`), plus enough of the session/project itself to filter and navigate by.
private struct PlottedSession: Identifiable {
    var id: Session.ID { session.id }
    let project: Project
    let session: Session
    let object: String
    let position: SkyAtlasLookup.Position
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
    @State private var selectedPlotted: PlottedSession?

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

    private var plotted: [PlottedSession] {
        filteredEntries.compactMap { entry in
            guard let object = entry.session.plannedObjects.first,
                  let position = SkyAtlasLookup.position(forObjectName: object)
            else { return nil }
            return PlottedSession(project: entry.project, session: entry.session, object: object, position: position)
        }
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
                            description: Text("Sessions targeting a cataloged Messier object or bright star show up here, positioned by right ascension and declination.")
                        )
                        .frame(height: 200)
                    } else {
                        Chart(plotted) { entry in
                            PointMark(
                                x: .value("Right Ascension", entry.position.raDegrees),
                                y: .value("Declination", entry.position.decDegrees)
                            )
                            .foregroundStyle(entry.id == selectedPlotted?.id ? Color.accentColor : Color.blue)
                            .symbolSize(entry.id == selectedPlotted?.id ? 160 : 80)
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
                    }
                }

                if let selectedPlotted {
                    PageSection(title: "Selected Session") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(selectedPlotted.project.name) — \(selectedPlotted.session.name)").font(.headline)
                                Text("Target: \(selectedPlotted.object)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { onSelectSession(selectedPlotted.project, selectedPlotted.session) }
                                .buttonStyle(.borderedProminent)
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
    private func closestPlotted(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> PlottedSession? {
        let origin = geometry[proxy.plotAreaFrame].origin
        let relativeLocation = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
        guard let (ra, dec) = proxy.value(at: relativeLocation, as: (Double, Double).self) else { return nil }
        return plotted.min { lhs, rhs in
            let lhsDistance = pow(lhs.position.raDegrees - ra, 2) + pow(lhs.position.decDegrees - dec, 2)
            let rhsDistance = pow(rhs.position.raDegrees - ra, 2) + pow(rhs.position.decDegrees - dec, 2)
            return lhsDistance < rhsDistance
        }
    }
}
