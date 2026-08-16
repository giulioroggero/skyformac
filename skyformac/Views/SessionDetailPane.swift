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
    /// Pushes the newly-created session's own page — see "New Session Like This…" below.
    var onSessionCreated: (Session) -> Void
    /// Steps to the previous/next session within this same project, in the order
    /// `ProjectDetailPane`'s own session cards show them (favorites first). `nil` — not a no-op
    /// closure — when this is the first/last session, so the toolbar button is hidden entirely.
    var onPreviousSession: (() -> Void)?
    var onNextSession: (() -> Void)?

    @State private var name: String
    @State private var goal: String
    @State private var plannedObjectsText: String
    @State private var hasPlannedDate: Bool
    @State private var plannedDate: Date
    @State private var isPlanningSession = false
    @State private var isCreatingSessionFromThis = false
    @State private var isDescribingSession = false
    @State private var isMovingToProject = false
    @State private var moveErrorMessage: String?
    @State private var isElaborating = false
    @State private var isPromptingSirilSettings = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }
    /// "Move to Project…"'s own candidate list — every other active project, alphabetically;
    /// excludes the current one (nothing to move to) and archived/deleted projects (not
    /// realistically where anyone wants to relocate a session they're actively looking at).
    private var otherProjects: [Project] {
        library.activeProjects
            .filter { $0.id != project.id && !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(
        project: Project, session: Session, cameraManager: CameraManager,
        onBack: @escaping () -> Void, onSelectCapture: @escaping (CaptureRecord) -> Void,
        onSessionCreated: @escaping (Session) -> Void,
        onPreviousSession: (() -> Void)? = nil, onNextSession: (() -> Void)? = nil
    ) {
        self.project = project
        self.session = session
        self.cameraManager = cameraManager
        self.onBack = onBack
        self.onSelectCapture = onSelectCapture
        self.onSessionCreated = onSessionCreated
        self.onPreviousSession = onPreviousSession
        self.onNextSession = onNextSession
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
                    HStack {
                        TextField("Name", text: $name).onChange(of: name) { _, _ in save() }
                        FavoriteToggleButton(isFavorite: session.isFavorite) {
                            var updated = session
                            updated.isFavorite.toggle()
                            applyAndSave(updated)
                        }
                        RatingView(rating: session.rating) { newRating in
                            var updated = session
                            updated.rating = newRating
                            applyAndSave(updated)
                        }
                    }
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
                        Button("Run This Session", systemImage: "play.fill") {
                            cameraManager.setActive(project: project, session: session)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help(session.captures.isEmpty ? "Starts this session — switches the main window to the camera view" : "Resumes capturing into this session")
                        Spacer()
                        Button("Recall Parameters…", systemImage: "clock.arrow.circlepath") {
                            cameraManager.isRecallParametersPresented = true
                        }
                        .help("Reuse the camera parameters from a previous action to speed up setting this one up")
                        Button("New Session Like This…", systemImage: "plus.square.on.square") {
                            isCreatingSessionFromThis = true
                        }
                        .help("Create a new session with this one's goal, objects, location, and equipment — without any of its captures")
                        Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningSession = true }
                        Button("Ask AI to Describe…", systemImage: "text.quote") { isDescribingSession = true }
                            .help("Write a description grounded in what this session has actually planned and captured")
                    }
                }

                PageSection(title: "History") {
                    StatsGridView(stats: historyStats)
                }

                PageSection(title: "Equipment") {
                    Picker("System", selection: Binding(
                        get: { session.equipmentSystemID },
                        set: { newValue in
                            var updated = session
                            updated.equipmentSystemID = newValue
                            applyAndSave(updated)
                        }
                    )) {
                        Text("Inherit from Project\(inheritedEquipmentSuffix)").tag(UUID?.none)
                        ForEach(cameraManager.equipmentLibrary.systems) { system in
                            Text(system.name).tag(UUID?.some(system.id))
                        }
                    }
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
                        cameraManager: cameraManager,
                        onSelect: onSelectCapture,
                        onDelete: { capture in
                            try? library.deleteCapture(capture.id, fromSessionID: session.id, in: project)
                        }
                    )
                }

                PageSection {
                    HStack {
                        Button("Elaborate Session…", systemImage: "wand.and.stars") { startElaborating() }
                            .disabled(elaborationSource == nil)
                            .help(elaborationSource == nil
                                ? "Nothing to elaborate — needs at least one FITS or SER capture in this session."
                                : "Send this session's captures to Siril for stacking/registration/stretching.")
                        Button("Archive Session", systemImage: "archivebox") {
                            try? library.setArchived(true, forSessionID: session.id, in: project)
                        }
                        Button("Move to Project…", systemImage: "folder") { isMovingToProject = true }
                            .disabled(otherProjects.isEmpty)
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
            ToolbarItemGroup {
                if let onPreviousSession {
                    Button("Previous Session", systemImage: "chevron.up", action: onPreviousSession)
                }
                if let onNextSession {
                    Button("Next Session", systemImage: "chevron.down", action: onNextSession)
                }
            }
        }
        // Same reasoning as `ProjectDetailPane`'s own `.onChange(of: project)` — local `@State`
        // for name/goal otherwise goes stale the moment something external (Ask AI to Plan, Ask
        // AI to Describe) changes them.
        .onChange(of: session) { _, updated in
            name = updated.name
            goal = updated.goal
        }
        .sheet(isPresented: $isPlanningSession) {
            AIPlanSessionSheet(project: project, session: session, cameraManager: cameraManager)
        }
        .sheet(isPresented: $isMovingToProject) {
            MoveSessionToProjectSheet(candidates: otherProjects) { destination in
                do {
                    try library.moveSession(session.id, from: project, to: destination)
                    // The session no longer belongs to `project` — this page's own route is now
                    // stale, so pop back to the (still-valid) Project page rather than keep
                    // showing a session that isn't there anymore. Only reached on success — a
                    // failed move must not navigate away as though it worked.
                    onBack()
                } catch {
                    moveErrorMessage = error.localizedDescription
                }
            }
        }
        .alert("Couldn't Move Session", isPresented: Binding(
            get: { moveErrorMessage != nil },
            set: { isPresented in if !isPresented { moveErrorMessage = nil } }
        ), presenting: moveErrorMessage) { _ in
            Button("OK") { moveErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $isCreatingSessionFromThis) {
            NewSessionFromExistingSheet(session: session) { name, plannedDate in
                let newSession = session.duplicatedForReuse(name: name, plannedDate: plannedDate)
                if let updated = try? library.addSession(newSession, to: project),
                   let created = updated.sessions.first(where: { $0.id == newSession.id }) {
                    onSessionCreated(created)
                }
            }
        }
        .sheet(isPresented: $isDescribingSession) {
            AIDescribeSheet(
                title: "Ask AI to Describe This Session",
                context: AIDescriptionContext.forSession(session, project: project) { cameraManager.equipmentLibrary.system(withID: $0)?.name },
                cameraManager: cameraManager,
                onSetAim: { text in
                    var updated = session
                    updated.goal = text
                    applyAndSave(updated)
                },
                onAddNote: { text in
                    var updated = session
                    updated.notes.append(Annotation(date: Date(), text: text))
                    applyAndSave(updated)
                }
            )
        }
        .sheet(isPresented: $isPromptingSirilSettings) {
            SirilDisabledPrompt(onOpenSettings: { cameraManager.isSettingsPresented = true })
        }
        .sheet(isPresented: $isElaborating) {
            if let (source, target) = elaborationSource {
                ElaborateSheet(
                    source: source,
                    suggestedRecipe: SirilElaborationService.resolveRecipe(for: source, target: target),
                    sourceDescription: "Elaborating this session's captures (\(session.name))."
                ) { recipe in
                    try await cameraManager.elaborate(
                        source: source, recipe: recipe, sourceSessionIDs: [session.id],
                        sourceCaptureID: nil, project: project
                    )
                }
            }
        }
    }

    /// `nil` when this session has nothing Siril can process — see
    /// `CameraManager.elaborationSource(for:project:)`.
    private var elaborationSource: (SirilElaborationService.Source, AcquisitionTarget?)? {
        cameraManager.elaborationSource(for: session, project: project)
    }

    private func startElaborating() {
        if AppSettings.isSirilIntegrationEnabled {
            isElaborating = true
        } else {
            isPromptingSirilSettings = true
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
        if let location = session.effectiveLocation(inProject: project) {
            stats.append(StatItem(label: "Position", value: location.displayName))
        }
        stats.append(StatItem(label: "Aim", value: session.goal.isEmpty ? "—" : session.goal))
        stats.append(StatItem(label: "Objects", value: session.plannedObjects.isEmpty ? "—" : session.plannedObjects.joined(separator: ", ")))
        let equipmentName = cameraManager.equipmentLibrary.system(withID: session.effectiveEquipmentSystemID(inProject: project))?.name
        stats.append(StatItem(label: "Equipment", value: equipmentName ?? "None"))
        return stats
    }

    /// Shown next to "Inherit from Project" in the Equipment picker so the resolved system is
    /// visible without having to go check the project's own page — "" when there's nothing to
    /// inherit, rather than a confusing "(None)" suffix.
    private var inheritedEquipmentSuffix: String {
        guard let name = cameraManager.equipmentLibrary.system(withID: project.equipmentSystemID)?.name else { return "" }
        return " (\(name))"
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
        let diskUsage = cameraManager.projectStore.diskUsage(for: session, in: project)
        stats.append(StatItem(label: "Disk Usage", value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file)))
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

/// "New Session Like This…" — just a name (and optional planned date) for the reused copy;
/// everything else (goal, objects, location, tags, equipment) already carries over via
/// `Session.duplicatedForReuse(name:plannedDate:)`, so this sheet stays as small as
/// `NewProjectSheet`'s own "just the name" scope.
private struct NewSessionFromExistingSheet: View {
    let session: Session
    var onCreate: (String, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hasPlannedDate = false
    @State private var plannedDate = Date()

    init(session: Session, onCreate: @escaping (String, Date?) -> Void) {
        self.session = session
        self.onCreate = onCreate
        self._name = State(initialValue: "\(session.name) (Copy)")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Session Like \"\(session.name)\"").font(.headline)
            Text("Reuses its goal, objects, location, and equipment — starts with no captures.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("Session name")).onSubmit(create)
            Toggle("Planned Date", isOn: $hasPlannedDate)
            if hasPlannedDate {
                DatePicker("Date & Time", selection: $plannedDate, displayedComponents: [.date, .hourAndMinute])
            }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 360, height: 220)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName, hasPlannedDate ? plannedDate : nil)
        dismiss()
    }
}

/// "Move to Project…" — a plain pick-one list rather than a full project browser, since the
/// only decision here is *which* project, not any of that project's own details.
private struct MoveSessionToProjectSheet: View {
    let candidates: [Project]
    var onMove: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move Session to Project").font(.headline).padding()
            Divider()
            List(candidates) { candidate in
                Button {
                    onMove(candidate)
                    dismiss()
                } label: {
                    HStack {
                        Text(candidate.name.isEmpty ? "Untitled Project" : candidate.name)
                        Spacer()
                        Text("\(candidate.sessions.count) session\(candidate.sessions.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
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
