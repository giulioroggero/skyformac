import SwiftUI

/// The Projects browser's middle column: one project's own metadata (name/goal/tags/location/
/// notes) plus the list of its sessions. Every edit calls `ProjectsLibrary.save` directly — see
/// that type's doc comment for why an unnamed project's edits never hit disk until it's named.
struct ProjectDetailPane: View {
    let project: Project
    var cameraManager: CameraManager
    @Binding var selectedSessionID: Session.ID?

    @State private var name: String
    @State private var goal: String
    @State private var newTag = ""
    @State private var newNote = ""
    @State private var isPlanningProject = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    init(project: Project, cameraManager: CameraManager, selectedSessionID: Binding<Session.ID?>) {
        self.project = project
        self.cameraManager = cameraManager
        self._selectedSessionID = selectedSessionID
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
                    SessionRow(project: project, session: session, cameraManager: cameraManager)
                        .tag(session.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedSessionID = session.id }
                        .listRowBackground(selectedSessionID == session.id ? Color.accentColor.opacity(0.15) : nil)
                        .contextMenu {
                            Button(session.isArchived ? "Unarchive" : "Archive") {
                                try? library.setArchived(!session.isArchived, forSessionID: session.id, in: project)
                            }
                            Button("Delete", role: .destructive) {
                                try? library.deleteSession(session.id, in: project)
                                if selectedSessionID == session.id { selectedSessionID = nil }
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
        let session = Session.newSession(name: "New Session")
        if let updated = try? library.addSession(session, to: project) {
            selectedSessionID = updated.sessions.first(where: { $0.id == session.id })?.id
        }
    }
}

private struct SessionRow: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager

    private var isActive: Bool { cameraManager.activeSession?.id == session.id }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.name)
                    if isActive {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.caption)
                    }
                }
                .font(.headline)
                if !session.plannedObjects.isEmpty {
                    Text(session.plannedObjects.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(session.captures.count)").font(.caption).foregroundStyle(.tertiary)
            Button(isActive ? "Active" : "Set Active") {
                cameraManager.setActive(project: project, session: session)
            }
            .disabled(isActive)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .opacity(session.isArchived ? 0.5 : 1)
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
                    cameraManager.setActive(project: project, session: session)
                    cameraManager.useCurrentLocationForActiveSession()
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
                    cameraManager.setActive(project: project, session: session)
                    cameraManager.setManualLocationForActiveSession(
                        latitude: lat, longitude: lon, name: nameText.isEmpty ? nil : nameText
                    )
                    isEnteringManually = false
                }
            }
            .padding()
            .frame(width: 220)
        }
    }
}
