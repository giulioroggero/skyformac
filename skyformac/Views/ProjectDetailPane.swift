import SwiftUI

/// The Projects browser's "Project Detail" page — pushed onto the browser's `NavigationStack`
/// when a project is tapped on the Home page. Shows the project's own metadata (name/goal/tags/
/// location/notes) plus its session list; tapping a session always pushes on to
/// `onShowSessionHistory`'s Session page — the camera view only opens via an explicit
/// "Run"/"Resume" button, never just by tapping a row. Every edit calls `ProjectsLibrary.save`
/// directly — see that type's doc comment for why an unnamed project's edits never hit disk
/// until it's named.
struct ProjectDetailPane: View {
    let project: Project
    var cameraManager: CameraManager
    var onShowSessionHistory: (Session) -> Void

    @State private var name: String
    @State private var goal: String
    @State private var newTag = ""
    @State private var newNote = ""
    @State private var isPlanningProject = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    init(project: Project, cameraManager: CameraManager, onShowSessionHistory: @escaping (Session) -> Void) {
        self.project = project
        self.cameraManager = cameraManager
        self.onShowSessionHistory = onShowSessionHistory
        self._name = State(initialValue: project.name)
        self._goal = State(initialValue: project.goal)
    }

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $name, prompt: Text("Untitled Project"))
                    .onSubmit(save)
                    .onChange(of: name) { _, _ in save() }
                TextField("Goal", text: $goal, prompt: Text("What are you trying to observe or achieve?"), axis: .vertical)
                    .onChange(of: goal) { _, _ in save() }
                LocationEditorView(project: project, session: nil, cameraManager: cameraManager)
            }

            Section("Stats") {
                StatsGridView(stats: projectStats)
            }

            Section("Tags") {
                TagsEditorView(tags: project.tags) { tags in
                    var updated = project
                    updated.tags = tags
                    try? library.save(updated)
                }
            }

            Section("Notes") {
                NotesEditorView(notes: project.notes) { notes in
                    var updated = project
                    updated.notes = notes
                    try? library.save(updated)
                }
            }

            Section {
                ForEach(project.sessions) { session in
                    SessionCard(project: project, session: session, cameraManager: cameraManager, store: cameraManager.projectStore)
                        .contentShape(Rectangle())
                        // Tapping a session always opens its own Session page (detail/history) —
                        // the camera view only ever opens via an explicit "Run"/"Resume"/"Run
                        // This Session" button (on the card itself, or on the Session page),
                        // never just by tapping the row.
                        .onTapGesture { onShowSessionHistory(session) }
                        .contextMenu {
                            Button(session.isArchived ? "Unarchive" : "Archive") {
                                try? library.setArchived(!session.isArchived, forSessionID: session.id, in: project)
                            }
                            Button("Delete", role: .destructive) {
                                try? library.deleteSession(session.id, in: project)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningProject = true }
                    Button("Add Session", systemImage: "plus") { addSession() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name.isEmpty ? "Untitled Project" : project.name)
        .sheet(isPresented: $isPlanningProject) {
            AIPlanProjectSheet(project: project, cameraManager: cameraManager)
        }
    }

    private func save() {
        var updated = project
        updated.name = name
        updated.goal = goal
        try? library.save(updated)
    }

    private func addSession() {
        try? library.addSession(Session.newSession(name: "New Session"), to: project)
    }

    /// Sessions count (split active/archived) plus a per-kind capture breakdown — "how much has
    /// actually happened on this project," not just its name and goal.
    private var projectStats: [StatItem] {
        var stats = [
            StatItem(label: "Sessions", value: "\(project.sessions.count)"),
            StatItem(label: "Archived", value: "\(project.archivedSessionsCount)"),
            StatItem(label: "Captures", value: "\(project.totalCaptureCount)"),
        ]
        if let first = project.firstActivityDate {
            stats.append(StatItem(label: "First Activity", value: first.formatted(date: .abbreviated, time: .omitted)))
        }
        stats.append(StatItem(label: "Last Activity", value: project.lastActivityDate.formatted(date: .abbreviated, time: .omitted)))
        for kind in CaptureRecord.Kind.allCases {
            if let count = project.captureCountByKind[kind] {
                stats.append(StatItem(label: kind.displayName, value: "\(count)"))
            }
        }
        return stats
    }
}

/// A session as shown in the Project Detail page's session list — a cover thumbnail (its own
/// most recent capture, if any), status, aim, objects, and when it ran, instead of just a name
/// and a capture count.
private struct SessionCard: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager
    let store: ProjectStore

    private var isActive: Bool { cameraManager.activeSession?.id == session.id }
    private var hasRun: Bool { !session.captures.isEmpty }
    private var thumbnailURL: URL? { store.mostRecentThumbnailURL(for: session, in: project) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, height: 60)
            .clipped()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.name).font(.headline)
                    if isActive {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.caption)
                    }
                    statusBadge
                }
                if !session.goal.isEmpty {
                    Text(session.goal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !session.plannedObjects.isEmpty {
                    Text(session.plannedObjects.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let planned = session.plannedDate {
                        Label(planned.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    } else if let last = session.lastCaptureDate {
                        Label(last.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    }
                    Label("\(session.captures.count)", systemImage: "camera")
                    if let location = session.location ?? project.location {
                        Label(location.displayName, systemImage: "location").lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }

            Spacer()

            Button(isActive ? "Running" : (hasRun ? "Resume" : "Run"), systemImage: "play.fill") {
                cameraManager.setActive(project: project, session: session)
            }
            .disabled(isActive)
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
        .opacity(session.isArchived ? 0.5 : 1)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if session.isArchived {
            Text("Archived")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        } else if !hasRun {
            Text("Not Run Yet")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

/// One label/value pair in a `StatsGridView` — `label` doubles as the `ForEach` identity, since
/// every stat shown at once (project- or session-level) always has a distinct one.
struct StatItem: Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

/// A titled block used by full-width pages (Session, Capture) instead of a `Form`'s `Section` —
/// `Form`/`.formStyle(.grouped)` centers/constrains its content on macOS, which is exactly the
/// side-margin look those pages need to *not* have. `title` is optional for a trailing section
/// (like a page's own destructive actions) that doesn't need a heading.
struct PageSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.headline)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A compact grid of label/value pairs — shared by the Project Detail and Session History
/// pages' Stats sections, so "how much has actually happened" always looks the same regardless
/// of which level it's summarizing.
struct StatsGridView: View {
    let stats: [StatItem]
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.value).font(.headline)
                    Text(stat.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Free-text tag entry — a plain `TextField` + "Add" instead of anything fancier, since
/// `Project.tags`/`Session.tags` are just `[String]` and don't need more.
struct TagsEditorView: View {
    let tags: [String]
    var onChange: ([String]) -> Void
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading) {
            if !tags.isEmpty {
                WrapHStack(tags) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.caption)
                        Button {
                            onChange(tags.filter { $0 != tag })
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
            }
            HStack {
                TextField("Add tag", text: $newTag)
                    .onSubmit {
                        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
                        onChange(tags + [trimmed])
                        newTag = ""
                    }
            }
        }
    }
}

/// A simple left-to-right wrapping row — `HStack` alone clips instead of wrapping, and this app
/// has no other tag-cloud UI to reuse, so a minimal `Layout` is cheaper than a dependency.
struct WrapHStack<Content: View>: View {
    let items: [String]
    @ViewBuilder var content: (String) -> Content

    init(_ items: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        FlowLayout {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

private struct FlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                totalHeight += rowHeight + 4
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + 4
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: width.isFinite ? width : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + 4
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + 4
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A chronological list of free-text `Annotation`s — the "user can annotate sessions and
/// projects" requirement — plus a field to add a new one dated now.
struct NotesEditorView: View {
    let notes: [Annotation]
    var onChange: ([Annotation]) -> Void
    @State private var newNoteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes.sorted(by: { $0.date > $1.date })) { note in
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.text)
                    Text(note.date, format: .dateTime).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack {
                TextField("Add a note…", text: $newNoteText, axis: .vertical)
                Button("Add") {
                    let trimmed = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onChange(notes + [Annotation(date: currentDate(), text: trimmed)])
                    newNoteText = ""
                }
                .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func currentDate() -> Date { Date() }
}

/// Shared by both the project- and session-level location section: shows the current
/// `GeoLocation` (if any) and buttons for GPS vs. hand-entered coordinates.
struct LocationEditorView: View {
    let project: Project
    let session: Session?
    var cameraManager: CameraManager

    @State private var isEnteringManually = false
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var nameText = ""

    private var currentLocation: GeoLocation? { session?.location ?? project.location }

    var body: some View {
        LabeledContent("Location") {
            HStack {
                Text(currentLocation?.displayName ?? "Not set").foregroundStyle(currentLocation == nil ? .secondary : .primary)
                Spacer()
                Button("Use Current Location", systemImage: "location") {
                    cameraManager.useCurrentLocation(for: project, session: session)
                }
                Button("Enter Manually…", systemImage: "pin") { isEnteringManually = true }
            }
        }
        .popover(isPresented: $isEnteringManually) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter Coordinates").font(.headline)
                TextField("Latitude", text: $latitudeText)
                TextField("Longitude", text: $longitudeText)
                TextField("Name (optional)", text: $nameText)
                Button("Save") {
                    guard let lat = Double(latitudeText), let lon = Double(longitudeText) else { return }
                    cameraManager.setManualLocation(
                        for: project, session: session, latitude: lat, longitude: lon, name: nameText.isEmpty ? nil : nameText
                    )
                    isEnteringManually = false
                }
            }
            .padding()
            .frame(width: 220)
        }
    }
}
