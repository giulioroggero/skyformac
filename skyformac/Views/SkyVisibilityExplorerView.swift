import SwiftUI

/// "A database of sky objects with what can be seen in a certain period of time, at what
/// lat/long. Starting from that the user can create a new project, or a session in an existing
/// project, or launch a capture for an existing session." — scans the bundled Messier/Caldwell/
/// NGC catalog (`SkyCatalog`) against `SkyVisibilityCalculator` for a chosen night/location, and
/// turns any result directly into one of those three actions.
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

    private var parsedLatitude: Double? { Double(latitudeText) }
    private var parsedLongitude: Double? { Double(longitudeText) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Where and When") {
                    LabeledContent("Date") {
                        DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                    }
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

                if hasCalculated {
                    PageSection(title: "\(results.count) Object\(results.count == 1 ? "" : "s") Above \(Int(minAltitude))°") {
                        if results.isEmpty {
                            Text("Nothing in the catalog clears that altitude on this night from this location — try a lower minimum altitude or a different date.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(results) { result in
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
    }

    private var sessionCandidates: [SkyObjectSessionCandidate] {
        cameraManager.projectsLibrary.activeProjects.flatMap { project in
            project.sessions.map { SkyObjectSessionCandidate(project: project, session: $0) }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SkyVisibilityCalculator.Result) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.object.displayName).font(.headline)
                Text("\(result.object.objectType) · mag \(String(format: "%.1f", result.magnitudeOrPlaceholder))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Peaks at \(Int(result.maxAltitudeDegrees))° around \(Self.timeFormatter.string(from: result.timeOfMaxAltitude))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
    }

    private func calculate() async {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return }
        isCalculating = true
        let target = catalog
        let selectedDate = date
        let minAlt = minAltitude
        let computed = await Task.detached(priority: .userInitiated) {
            SkyVisibilityCalculator.visibleObjects(
                in: target, on: selectedDate, latitudeDegrees: latitude, longitudeDegrees: longitude, minAltitudeDegrees: minAlt
            )
        }.value
        results = computed
        isCalculating = false
        hasCalculated = true
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
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
