import Charts
import SwiftUI

/// "A database of sky objects with what can be seen in a certain period of time, at what
/// lat/long. Starting from that the user can create a new project, or a session in an existing
/// project, or launch a capture for an existing session." — scans the bundled Messier/Caldwell/
/// NGC catalog (`SkyCatalog`) against `SkyVisibilityCalculator` for a chosen night/location, and
/// turns any result directly into one of those three actions. Each result also shows its type,
/// magnitude, and peak time, and the whole list can be sorted/filtered by any of those.
///
/// "Add an image example of each object" — deliberately not a real per-object photo: bundling one
/// for every catalog entry (hundreds of objects) would meaningfully bloat the app, and fetching
/// one from the network on demand would be this app's first real network dependency, contrary to
/// the "runs entirely locally, no telemetry, no account" stance the rest of it holds to (see
/// `docs/distribution.md`). Each row instead gets a representative SF Symbol for its object type
/// (`SkyCatalogObject.symbolName`) — genuinely just a type indicator, not presented as a photo of
/// that specific object.
struct SkyVisibilityExplorerView: View {
    var cameraManager: CameraManager
    /// Mirrors `NewProjectSheet`'s own completion closure — the caller decides what "created,
    /// now go look at it" means (`ProjectsBrowserView` resets its path to the new project).
    var onCreateProject: (Project) -> Void
    var onOpenSession: (Project, Session) -> Void

    @State private var date = Date()
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var minAltitude: Double = 20
    @State private var results: [SkyVisibilityCalculator.Result] = []
    @State private var isCalculating = false
    @State private var hasCalculated = false
    @State private var addingToProjectObject: SkyCatalogObject?
    @State private var launchingCaptureObject: SkyCatalogObject?
    @State private var conjunctions: [SkyEventsCalculator.Conjunction] = []
    @State private var sortField: SortField = .peakAltitude
    @State private var sortAscending = false
    @State private var typeFilter: String?
    @State private var planetResults: [SkyVisibilityCalculator.PlanetResult] = []
    @State private var detailSubject: DetailSubject?
    @State private var searchText = ""
    @State private var resultCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]
    @State private var planetCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]

    private struct DetailSubject: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbolName: String
        let riseTime: Date?
        let peakTime: Date
        let setTime: Date?
        /// `nil` for planets/the Moon — a real-sky-survey cutout is meaningless for a body that
        /// moves, and SDSS's own imagery doesn't cover the solar system anyway.
        let skyCoordinates: (raDegrees: Double, decDegrees: Double)?
    }

    private enum SortField: String, CaseIterable, Identifiable {
        case name = "Name", type = "Type", magnitude = "Magnitude", peakAltitude = "Peak Altitude", peakTime = "Peak Time"
        var id: String { rawValue }
    }

    init(cameraManager: CameraManager, onCreateProject: @escaping (Project) -> Void, onOpenSession: @escaping (Project, Session) -> Void) {
        self.cameraManager = cameraManager
        self.onCreateProject = onCreateProject
        self.onOpenSession = onOpenSession
        let location = cameraManager.locationProvider.lastLocation
        _latitudeText = State(initialValue: location.map { String(format: "%.4f", $0.latitude) } ?? "")
        _longitudeText = State(initialValue: location.map { String(format: "%.4f", $0.longitude) } ?? "")
    }

    /// Messier + Caldwell + NGC — real deep-sky imaging targets. Bright stars are left out on
    /// purpose: they're catalog entries for plate-solving/star-pattern recognition, not the kind
    /// of thing this planning tool is for.
    private var catalog: [SkyCatalogObject] {
        SkyCatalog.messierObjects + SkyCatalog.caldwellObjects + SkyCatalog.ngcObjects
    }

    /// The "move time like Stellarium" slider — reads/writes the same `date` the DatePicker above
    /// does, as hours-since-midnight of its own calendar day, so dragging one moves the other.
    private var timeOfDayBinding: Binding<Double> {
        Binding(
            get: {
                let calendar = Calendar(identifier: .gregorian)
                let components = calendar.dateComponents([.hour, .minute], from: date)
                return Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60
            },
            set: { newValue in
                let calendar = Calendar(identifier: .gregorian)
                let startOfDay = calendar.startOfDay(for: date)
                date = startOfDay.addingTimeInterval(newValue * 3600)
            }
        )
    }

    private var parsedLatitude: Double? { Double(latitudeText) }
    private var parsedLongitude: Double? { Double(longitudeText) }

    /// Every distinct object type actually present in the current results — a dropdown listing
    /// types that would filter everything out isn't useful, so this only ever shows what's here.
    private var availableTypes: [String] {
        Array(Set(results.map(\.object.friendlyTypeName))).sorted()
    }

    private var displayedResults: [SkyVisibilityCalculator.Result] {
        var filtered = typeFilter.map { type in results.filter { $0.object.friendlyTypeName == type } } ?? results
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            filtered = filtered.filter {
                $0.object.displayName.localizedCaseInsensitiveContains(trimmedSearch) || $0.object.id.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        let sorted: [SkyVisibilityCalculator.Result]
        switch sortField {
        case .name: sorted = filtered.sorted { $0.object.displayName < $1.object.displayName }
        case .type: sorted = filtered.sorted { $0.object.friendlyTypeName < $1.object.friendlyTypeName }
        case .magnitude: sorted = filtered.sorted { $0.object.magnitude < $1.object.magnitude }
        case .peakAltitude: sorted = filtered.sorted { $0.maxAltitudeDegrees < $1.maxAltitudeDegrees }
        case .peakTime: sorted = filtered.sorted { $0.timeOfMaxAltitude < $1.timeOfMaxAltitude }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Where and When") {
                    LabeledContent("Date & Time") {
                        DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    }
                    Text("The date picks which night to scan; the time is used for each result's own \"Altitude Now\" reading below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Time of Day") {
                        HStack {
                            Slider(value: timeOfDayBinding, in: 0...24, step: 5.0 / 60)
                            Text(Self.timeFormatter.string(from: date)).monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                    }
                    .help("Scrub through the day, Stellarium-style — moves the same \"Date & Time\" above.")
                    LabeledContent("Latitude") {
                        TextField("e.g. 45.4642", text: $latitudeText).frame(width: 140)
                    }
                    LabeledContent("Longitude") {
                        TextField("e.g. 9.1900", text: $longitudeText).frame(width: 140)
                    }
                    Button("Use Current Location") {
                        cameraManager.locationProvider.requestCurrentLocation { location in
                            guard let location else { return }
                            latitudeText = String(format: "%.4f", location.latitude)
                            longitudeText = String(format: "%.4f", location.longitude)
                        }
                    }
                    LabeledContent("Minimum Altitude") {
                        Stepper(value: $minAltitude, in: 0...80, step: 5) {
                            Text("\(Int(minAltitude))°")
                        }
                    }
                    HStack {
                        Button("Find What's Visible") { Task { await calculate() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(parsedLatitude == nil || parsedLongitude == nil || isCalculating)
                        if isCalculating { ProgressView().controlSize(.small) }
                    }
                }

                PageSection(title: "Sky Events") {
                    LabeledContent("Moon Phase") {
                        Text("\(moonPhase.phaseName) (\(Int(moonPhase.illuminatedFraction * 100))% illuminated)")
                    }
                    if hasCalculated {
                        if conjunctions.isEmpty {
                            Text("No planet/Moon conjunctions within a week of this date.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(conjunctions) { conjunction in
                                Text("\(conjunction.bodyA) – \(conjunction.bodyB): \(String(format: "%.1f", conjunction.separationDegrees))° apart on \(Self.dateFormatter.string(from: conjunction.date))")
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text("Planet/Moon conjunctions within a week of this date show up after you find what's visible.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasCalculated {
                    PageSection(title: "Planets & Moon Tonight") {
                        if planetResults.isEmpty {
                            Text("No planets or the Moon clear \(Int(minAltitude))° tonight from this location.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(planetResults) { planet in
                                planetRow(planet)
                                Divider()
                            }
                        }
                    }
                }

                if hasCalculated {
                    PageSection(title: "\(results.count) Object\(results.count == 1 ? "" : "s") Above \(Int(minAltitude))°") {
                        if results.isEmpty {
                            Text("Nothing in the catalog clears that altitude on this night from this location — try a lower minimum altitude or a different date.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("Search by name…", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .padding(.bottom, 4)

                            HStack {
                                Picker("Sort by", selection: $sortField) {
                                    ForEach(SortField.allCases) { field in Text(field.rawValue).tag(field) }
                                }
                                .frame(width: 220)
                                Button {
                                    sortAscending.toggle()
                                } label: {
                                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                }
                                .help(sortAscending ? "Ascending" : "Descending")

                                Picker("Type", selection: $typeFilter) {
                                    Text("All Types").tag(String?.none)
                                    ForEach(availableTypes, id: \.self) { type in Text(type).tag(String?.some(type)) }
                                }
                                .frame(width: 220)
                                Spacer()
                            }
                            .padding(.bottom, 4)

                            ForEach(displayedResults) { result in
                                resultRow(result)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("What to See")
        .sheet(item: $addingToProjectObject) { object in
            AddSkyObjectToProjectSheet(candidates: cameraManager.projectsLibrary.activeProjects) { project in
                let session = Session.newSession(name: object.displayName, goal: "Observe \(object.displayName)", plannedObjects: [object.displayName])
                if let updated = try? cameraManager.projectsLibrary.addSession(session, to: project) {
                    onOpenSession(updated, session)
                }
            }
        }
        .sheet(item: $launchingCaptureObject) { object in
            LaunchCaptureForSkyObjectSheet(candidates: sessionCandidates) { candidate in
                cameraManager.setActive(project: candidate.project, session: candidate.session)
            }
        }
        .sheet(item: $detailSubject) { subject in
            SkyVisibilityObjectDetailView(
                title: subject.title, subtitle: subject.subtitle, symbolName: subject.symbolName,
                riseTime: subject.riseTime, peakTime: subject.peakTime, setTime: subject.setTime,
                skyCoordinates: subject.skyCoordinates,
                onDismiss: { detailSubject = nil }
            )
        }
    }

    private var sessionCandidates: [SkyObjectSessionCandidate] {
        cameraManager.projectsLibrary.activeProjects.flatMap { project in
            project.sessions.map { SkyObjectSessionCandidate(project: project, session: $0) }
        }
    }

    @ViewBuilder
    private func planetRow(_ planet: SkyVisibilityCalculator.PlanetResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: planet.name == "Moon" ? "moon.fill" : "circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(planet.name).font(.headline)
                Text(riseSetSummary(rise: planet.riseTime, peak: planet.timeOfMaxAltitude, set: planet.setTime, peakAltitude: planet.maxAltitudeDegrees))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let altitudeNow = altitudeNowText(planet: planet) {
                    Text(altitudeNow).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let curve = planetCurves[planet.name] {
                altitudeChart(curve)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            detailSubject = DetailSubject(
                title: planet.name, subtitle: "Solar system body",
                symbolName: planet.name == "Moon" ? "moon.fill" : "circle.fill",
                riseTime: planet.riseTime, peakTime: planet.timeOfMaxAltitude, setTime: planet.setTime,
                skyCoordinates: nil
            )
        }
    }

    /// A compact altitude-vs-time sparkline for one result row — time on the x-axis, altitude on
    /// y, plus a vertical rule marking the currently-picked "Date & Time" so it's obvious at a
    /// glance where "now" falls on the object's own rise/set curve.
    @ViewBuilder
    private func altitudeChart(_ samples: [SkyVisibilityCalculator.AltitudeSample]) -> some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.time), y: .value("Altitude", sample.altitudeDegrees))
            }
            RuleMark(y: .value("Horizon", 0)).foregroundStyle(.secondary.opacity(0.4))
            RuleMark(x: .value("Now", date)).foregroundStyle(.orange.opacity(0.7))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: 140, height: 40)
    }

    private func riseSetSummary(rise: Date?, peak: Date, set: Date?, peakAltitude: Double) -> String {
        let riseText = rise.map(Self.timeFormatter.string) ?? "already up"
        let setText = set.map(Self.timeFormatter.string) ?? "still up at dawn"
        return "Rises \(riseText), peaks at \(Int(peakAltitude))° around \(Self.timeFormatter.string(from: peak)), \(set == nil ? setText : "sets \(setText)")"
    }

    /// The reason changing the "Date & Time" field's *time* component (not just its date) does
    /// something visible — the peak/rise/set fields above are all about tonight's dark window as a
    /// whole, unaffected by the exact hour picked, but this reads the object's real altitude at
    /// that exact moment.
    private func altitudeNowText(raDegrees: Double, decDegrees: Double) -> String? {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return nil }
        let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
            raDegrees: raDegrees, decDegrees: decDegrees, latitudeDegrees: latitude, longitudeDegrees: longitude, on: date
        )
        return "Altitude at \(Self.timeFormatter.string(from: date)): \(Int(altitude))°"
    }

    private func altitudeNowText(planet: SkyVisibilityCalculator.PlanetResult) -> String? {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return nil }
        let position: (raDegrees: Double, decDegrees: Double)
        if planet.name == "Moon" {
            let moon = PlanetaryPositionCalculator.moonPosition(on: date).equatorial
            position = (moon.rightAscensionDegrees, moon.declinationDegrees)
        } else if let matched = PlanetaryPositionCalculator.Planet(rawValue: planet.name) {
            let equatorial = PlanetaryPositionCalculator.position(of: matched, on: date)
            position = (equatorial.rightAscensionDegrees, equatorial.declinationDegrees)
        } else {
            return nil
        }
        let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
            raDegrees: position.raDegrees, decDegrees: position.decDegrees,
            latitudeDegrees: latitude, longitudeDegrees: longitude, on: date
        )
        return "Altitude at \(Self.timeFormatter.string(from: date)): \(Int(altitude))°"
    }

    @ViewBuilder
    private func resultRow(_ result: SkyVisibilityCalculator.Result) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // A representative type icon, not a real photo of this specific object — see this
            // file's own top-of-file doc comment for why an actual per-object thumbnail isn't
            // something this app can offer without either bundling a large image set or adding a
            // network dependency it deliberately doesn't have.
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: result.object.symbolName).font(.title2).foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.object.displayName).font(.headline)
                Text("\(result.object.friendlyTypeName) · mag \(String(format: "%.1f", result.magnitudeOrPlaceholder))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(riseSetSummary(rise: result.riseTime, peak: result.timeOfMaxAltitude, set: result.setTime, peakAltitude: result.maxAltitudeDegrees))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let altitudeNow = altitudeNowText(raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees) {
                    Text(altitudeNow).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let curve = resultCurves[result.id] {
                altitudeChart(curve)
            }
            Menu {
                Button("New Project…") {
                    var project = Project.newProject(name: result.object.displayName, goal: "Observe \(result.object.displayName)")
                    let session = Session.newSession(name: result.object.displayName, goal: "Observe \(result.object.displayName)", plannedObjects: [result.object.displayName])
                    project.sessions = [session]
                    if (try? cameraManager.projectsLibrary.save(project)) != nil {
                        onCreateProject(project)
                    }
                }
                Button("Add Session to Existing Project…") { addingToProjectObject = result.object }
                    .disabled(cameraManager.projectsLibrary.activeProjects.isEmpty)
                Button("Launch Capture for Existing Session…") { launchingCaptureObject = result.object }
                    .disabled(sessionCandidates.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            detailSubject = DetailSubject(
                title: result.object.displayName,
                subtitle: "\(result.object.friendlyTypeName) · magnitude \(String(format: "%.1f", result.magnitudeOrPlaceholder))",
                symbolName: result.object.symbolName,
                riseTime: result.riseTime, peakTime: result.timeOfMaxAltitude, setTime: result.setTime,
                skyCoordinates: (result.object.raDegrees, result.object.decDegrees)
            )
        }
    }

    private func calculate() async {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return }
        isCalculating = true
        let target = catalog
        let selectedDate = date
        let minAlt = minAltitude
        let (computedResults, computedConjunctions, computedPlanets, computedResultCurves, computedPlanetCurves) = await Task.detached(priority: .userInitiated) { () -> ([SkyVisibilityCalculator.Result], [SkyEventsCalculator.Conjunction], [SkyVisibilityCalculator.PlanetResult], [String: [SkyVisibilityCalculator.AltitudeSample]], [String: [SkyVisibilityCalculator.AltitudeSample]]) in
            let visible = SkyVisibilityCalculator.visibleObjects(
                in: target, on: selectedDate, latitudeDegrees: latitude, longitudeDegrees: longitude, minAltitudeDegrees: minAlt
            )
            let calendar = Calendar(identifier: .gregorian)
            let windowStart = calendar.date(byAdding: .day, value: -7, to: selectedDate) ?? selectedDate
            let windowEnd = calendar.date(byAdding: .day, value: 7, to: selectedDate) ?? selectedDate
            let events = SkyEventsCalculator.conjunctions(in: windowStart...windowEnd)
            let planets = SkyVisibilityCalculator.visiblePlanets(
                on: selectedDate, latitudeDegrees: latitude, longitudeDegrees: longitude, minAltitudeDegrees: minAlt
            )

            var resultCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]
            for result in visible {
                resultCurves[result.id] = SkyVisibilityCalculator.altitudeCurve(
                    raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees,
                    latitudeDegrees: latitude, longitudeDegrees: longitude, on: selectedDate
                )
            }
            var planetCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]
            for planet in planets {
                let position: (raDegrees: Double, decDegrees: Double)
                if planet.name == "Moon" {
                    let moon = PlanetaryPositionCalculator.moonPosition(on: selectedDate).equatorial
                    position = (moon.rightAscensionDegrees, moon.declinationDegrees)
                } else if let matched = PlanetaryPositionCalculator.Planet(rawValue: planet.name) {
                    let equatorial = PlanetaryPositionCalculator.position(of: matched, on: selectedDate)
                    position = (equatorial.rightAscensionDegrees, equatorial.declinationDegrees)
                } else {
                    continue
                }
                planetCurves[planet.name] = SkyVisibilityCalculator.altitudeCurve(
                    raDegrees: position.raDegrees, decDegrees: position.decDegrees,
                    latitudeDegrees: latitude, longitudeDegrees: longitude, on: selectedDate
                )
            }

            return (visible, events, planets, resultCurves, planetCurves)
        }.value
        results = computedResults
        conjunctions = computedConjunctions
        planetResults = computedPlanets
        resultCurves = computedResultCurves
        planetCurves = computedPlanetCurves
        isCalculating = false
        hasCalculated = true
    }

    private var moonPhase: SkyEventsCalculator.MoonPhase { SkyEventsCalculator.moonPhase(on: date) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private extension SkyVisibilityCalculator.Result {
    /// `SkyCatalogObject.magnitude` is always present, but naming it through this small shim
    /// keeps the view's own display logic reading as "whatever we have to show," not tied to the
    /// catalog model's exact field name if that ever changes shape.
    var magnitudeOrPlaceholder: Double { object.magnitude }
}

struct SkyObjectSessionCandidate: Identifiable {
    let project: Project
    let session: Session
    var id: Session.ID { session.id }
}

private struct AddSkyObjectToProjectSheet: View {
    let candidates: [Project]
    var onAdd: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Session to Project").font(.headline).padding()
            Divider()
            if candidates.isEmpty {
                Text("No projects yet — create one first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(candidates) { project in
                    Button {
                        onAdd(project)
                        dismiss()
                    } label: {
                        Text(project.name.isEmpty ? "Untitled Project" : project.name)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}

private struct LaunchCaptureForSkyObjectSheet: View {
    let candidates: [SkyObjectSessionCandidate]
    var onLaunch: (SkyObjectSessionCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Launch Capture for Session").font(.headline).padding()
            Divider()
            if candidates.isEmpty {
                Text("No sessions yet — create a project and session first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(candidates) { candidate in
                    Button {
                        onLaunch(candidate)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.session.name)
                            Text(candidate.project.name.isEmpty ? "Untitled Project" : candidate.project.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}
