import SwiftUI

/// The Projects browser's Session page: one session's metadata, its capture timeline, and the
/// controls that make it the active recording destination (`CameraManager.activeSession`). A
/// plain full-width `ScrollView`, not a `Form` — a `Form`'s `.formStyle(.grouped)` centers/caps
/// its content width on macOS, which this page deliberately doesn't want (see `PageSection`).
struct SessionDetailPane: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager
    /// Pops back to this session's own Project page — the toolbar's explicit "Back to Project"
    /// button, since the drill-down hierarchy this feature is built around means "up" always has
    /// one specific, nameable destination, not just "whatever's previous."
    var onBack: () -> Void
    /// Pushes the tapped timeline thumbnail's own full-width Capture page.
    var onSelectCapture: (CaptureRecord) -> Void

    @State private var name: String
    @State private var goal: String
    @State private var plannedObjectsText: String
    @State private var hasPlannedDate: Bool
    @State private var plannedDate: Date
    @State private var isPlanningSession = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }
    private var isActive: Bool { cameraManager.activeSession?.id == session.id }

    init(
        project: Project, session: Session, cameraManager: CameraManager,
        onBack: @escaping () -> Void, onSelectCapture: @escaping (CaptureRecord) -> Void
    ) {
        self.project = project
        self.session = session
        self.cameraManager = cameraManager
        self.onBack = onBack
        self.onSelectCapture = onSelectCapture
        self._name = State(initialValue: session.name)
        self._goal = State(initialValue: session.goal)
        self._plannedObjectsText = State(initialValue: session.plannedObjects.joined(separator: ", "))
        self._hasPlannedDate = State(initialValue: session.plannedDate != nil)
        self._plannedDate = State(initialValue: session.plannedDate ?? Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Session") {
                    TextField("Name", text: $name).onChange(of: name) { _, _ in save() }
                    TextField("Aim", text: $goal, prompt: Text("What is this session for?"), axis: .vertical)
                        .onChange(of: goal) { _, _ in save() }
                    TextField("Objects (comma separated)", text: $plannedObjectsText, prompt: Text("M13, M57, Saturn"))
                        .onChange(of: plannedObjectsText) { _, _ in savePlannedObjects() }
                    Toggle("Planned Date", isOn: $hasPlannedDate)
                        .onChange(of: hasPlannedDate) { _, isOn in savePlannedDate(isOn ? plannedDate : nil) }
                    if hasPlannedDate {
                        DatePicker("Date & Time", selection: $plannedDate, displayedComponents: [.date, .hourAndMinute])
                            .onChange(of: plannedDate) { _, new in savePlannedDate(new) }
                    }
                    LocationEditorView(project: project, session: session, cameraManager: cameraManager)
                    HStack {
                        Button(isActive ? "Running Now" : "Run This Session", systemImage: "play.fill") {
                            cameraManager.setActive(project: project, session: session)
                        }
                        .disabled(isActive)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help(session.captures.isEmpty ? "Starts this session — switches the main window to the camera view" : "Resumes capturing into this session")
                        Spacer()
                        Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningSession = true }
                    }
                }

                PageSection(title: "History") {
                    StatsGridView(stats: historyStats)
                }

                if !session.captures.isEmpty {
                    PageSection(title: "Stats") {
                        StatsGridView(stats: captureStats)
                    }
                }

                PageSection(title: "Tags") {
                    TagsEditorView(tags: session.tags) { tags in
                        var updated = session
                        updated.tags = tags
                        applyAndSave(updated)
                    }
                }

                PageSection(title: "Notes") {
                    NotesEditorView(notes: session.notes) { notes in
                        var updated = session
                        updated.notes = notes
                        applyAndSave(updated)
                    }
                }

                PageSection(title: "Timeline") {
                    TimelineStripView(
                        project: project, session: session, store: cameraManager.projectStore,
                        onSelect: onSelectCapture
                    )
                }

                PageSection {
                    HStack {
                        Button("Archive Session", systemImage: "archivebox") {
                            try? library.setArchived(true, forSessionID: session.id, in: project)
                        }
                        Button("Delete Session", systemImage: "trash", role: .destructive) {
                            try? library.deleteSession(session.id, in: project)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(project.name.isEmpty ? "Untitled Project" : project.name) — \(session.name)")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Project", systemImage: "chevron.left", action: onBack)
            }
        }
        .sheet(isPresented: $isPlanningSession) {
            AIPlanSessionSheet(project: project, session: session, cameraManager: cameraManager)
        }
    }

    private func save() {
        var updated = session
        updated.name = name
        updated.goal = goal
        applyAndSave(updated)
    }

    private func savePlannedObjects() {
        var updated = session
        updated.plannedObjects = plannedObjectsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        applyAndSave(updated)
    }

    private func savePlannedDate(_ date: Date?) {
        var updated = session
        updated.plannedDate = date
        applyAndSave(updated)
    }

    private func applyAndSave(_ updatedSession: Session) {
        var updatedProject = project
        guard let index = updatedProject.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        updatedProject.sessions[index] = updatedSession
        try? library.save(updatedProject)
    }

    /// The historical record this page is actually for — when it was planned/created/captured,
    /// where, and what for — using the same vocabulary ("Aim," "Objects," "Position") the rest of
    /// the Projects feature does, not just the raw model field names.
    private var historyStats: [StatItem] {
        var stats = [StatItem(label: "Created", value: session.createdDate.formatted(date: .abbreviated, time: .shortened))]
        if let planned = session.plannedDate {
            stats.append(StatItem(label: "Planned", value: planned.formatted(date: .abbreviated, time: .shortened)))
        }
        if let first = session.firstCaptureDate {
            stats.append(StatItem(label: "First Capture", value: first.formatted(date: .abbreviated, time: .shortened)))
        }
        if let last = session.lastCaptureDate {
            stats.append(StatItem(label: "Last Capture", value: last.formatted(date: .abbreviated, time: .shortened)))
        }
        if let duration = session.duration, let formatted = Self.durationFormatter.string(from: duration) {
            stats.append(StatItem(label: "Duration", value: formatted))
        }
        if let location = session.location ?? project.location {
            stats.append(StatItem(label: "Position", value: location.displayName))
        }
        stats.append(StatItem(label: "Aim", value: session.goal.isEmpty ? "—" : session.goal))
        stats.append(StatItem(label: "Objects", value: session.plannedObjects.isEmpty ? "—" : session.plannedObjects.joined(separator: ", ")))
        return stats
    }

    /// How much has actually been captured, broken down by kind — hidden entirely for a session
    /// with nothing yet, since an all-zero breakdown says nothing useful.
    private var captureStats: [StatItem] {
        var stats = [StatItem(label: "Total Captures", value: "\(session.captures.count)")]
        for kind in CaptureRecord.Kind.allCases {
            if let count = session.captureCountByKind[kind] {
                stats.append(StatItem(label: kind.displayName, value: "\(count)"))
            }
        }
        return stats
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
