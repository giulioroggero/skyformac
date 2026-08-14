import SwiftUI

/// The Projects browser's "Project Detail" page — pushed onto the browser's `NavigationStack`
/// when a project is tapped on the Home page. A plain full-width `ScrollView`, not a `Form` (see
/// `PageSection`), same as the Session/Capture pages. Shows the project's own metadata (name/
/// goal/tags/location/notes) plus its session list; tapping a session always pushes on to
/// `onShowSessionHistory`'s Session page — the camera view only opens via an explicit
/// "Run"/"Resume" button, never just by tapping a row. Every edit calls `ProjectsLibrary.save`
/// directly — see that type's doc comment for why an unnamed project's edits never hit disk
/// until it's named.
struct ProjectDetailPane: View {
    let project: Project
    var cameraManager: CameraManager
    var onShowSessionHistory: (Session) -> Void
    /// Pops back to the Home page (or wherever this page was pushed from).
    var onBack: () -> Void
    /// Called after this project is deleted (soft-deleted, per `ProjectsLibrary.softDelete(_:)`)
    /// from its own Danger Zone section — there's nothing left to show here, so the caller
    /// (`ProjectsBrowserView`) pops all the way back to Home rather than leaving this page
    /// displayed for a project that no longer shows up anywhere except Recently Deleted.
    var onProjectDeleted: () -> Void

    @State private var name: String
    @State private var goal: String
    @State private var newTag = ""
    @State private var newNote = ""
    @State private var isPlanningProject = false
    @State private var isDescribingProject = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    init(
        project: Project, cameraManager: CameraManager, onShowSessionHistory: @escaping (Session) -> Void,
        onBack: @escaping () -> Void, onProjectDeleted: @escaping () -> Void
    ) {
        self.project = project
        self.cameraManager = cameraManager
        self.onShowSessionHistory = onShowSessionHistory
        self.onBack = onBack
        self.onProjectDeleted = onProjectDeleted
        self._name = State(initialValue: project.name)
        self._goal = State(initialValue: project.goal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Project") {
                    HStack {
                        TextField("Name", text: $name, prompt: Text("Untitled Project"))
                            .onSubmit(save)
                            .onChange(of: name) { _, _ in save() }
                        FavoriteToggleButton(isFavorite: project.isFavorite) {
                            var updated = project
                            updated.isFavorite.toggle()
                            try? library.save(updated)
                        }
                        RatingView(rating: project.rating) { newRating in
                            var updated = project
                            updated.rating = newRating
                            try? library.save(updated)
                        }
                    }
                    HStack(alignment: .top) {
                        TextField("Goal", text: $goal, prompt: Text("What are you trying to observe or achieve?"), axis: .vertical)
                            .onChange(of: goal) { _, _ in save() }
                        Button("Ask AI to Describe…", systemImage: "sparkles") { isDescribingProject = true }
                            .help("Write a description grounded in what this project has actually planned and captured")
                    }
                    LocationEditorView(project: project, session: nil, cameraManager: cameraManager)
                }

                PageSection(title: "Stats") {
                    StatsGridView(stats: projectStats)
                }

                PageSection(title: "Equipment") {
                    Picker("System", selection: Binding(
                        get: { project.equipmentSystemID },
                        set: { newValue in
                            var updated = project
                            updated.equipmentSystemID = newValue
                            try? library.save(updated)
                        }
                    )) {
                        Text("None").tag(UUID?.none)
                        ForEach(cameraManager.equipmentLibrary.systems) { system in
                            Text(system.name).tag(UUID?.some(system.id))
                        }
                    }
                    Text("Sessions use this by default — each one can override it individually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PageSection(title: "Tags") {
                    TagsEditorView(tags: project.tags) { tags in
                        var updated = project
                        updated.tags = tags
                        try? library.save(updated)
                    }
                }

                PageSection(title: "Notes") {
                    NotesEditorView(notes: project.notes) { notes in
                        var updated = project
                        updated.notes = notes
                        try? library.save(updated)
                    }
                }

                PageSection {
                    HStack {
                        Text("Sessions").font(.headline)
                        Spacer()
                        Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningProject = true }
                        Button("Add Session", systemImage: "plus") { addSession() }
                    }
                    // Favorites first — "keep them on top" — ties broken by each session's own
                    // existing order otherwise (a stable sort, so non-favorites don't get
                    // needlessly reshuffled amongst themselves).
                    ForEach(favoritesFirst(project.sessions)) { session in
                        SessionCard(project: project, session: session, cameraManager: cameraManager, store: cameraManager.projectStore)
                            .contentShape(Rectangle())
                            // Tapping a session always opens its own Session page (detail/history)
                            // — the camera view only ever opens via an explicit "Run"/"Resume"/
                            // "Run This Session" button (on the card itself, or on the Session
                            // page), never just by tapping the row.
                            .onTapGesture { onShowSessionHistory(session) }
                            .contextMenu {
                                Button(session.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                                    var updated = session
                                    updated.isFavorite.toggle()
                                    applyAndSaveSession(updated)
                                }
                                Button(session.isArchived ? "Unarchive" : "Archive") {
                                    try? library.setArchived(!session.isArchived, forSessionID: session.id, in: project)
                                }
                                Button("Delete", role: .destructive) {
                                    try? library.deleteSession(session.id, in: project)
                                }
                            }
                        if session.id != project.sessions.last?.id {
                            Divider()
                        }
                    }
                }

                PageSection {
                    HStack {
                        Button(project.isArchived ? "Unarchive Project" : "Archive Project", systemImage: "archivebox") {
                            try? library.setArchived(!project.isArchived, for: project)
                        }
                        Button("Delete Project", systemImage: "trash", role: .destructive) {
                            try? library.softDelete(project)
                            onProjectDeleted()
                        }
                        .help("Kept for 30 days in Recently Deleted before being removed for good — you can undo this")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(project.name.isEmpty ? "Untitled Project" : project.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: onBack)
            }
        }
        // `name`/`goal` are local `@State` (so typing doesn't fight `save()` on every keystroke),
        // which otherwise goes stale the moment something *external* to this page's own text
        // fields changes them — Ask AI to Plan filling in an empty name/goal, or Ask AI to
        // Describe setting the goal as this project's Aim.
        .onChange(of: project) { _, updated in
            name = updated.name
            goal = updated.goal
        }
        .sheet(isPresented: $isPlanningProject) {
            AIPlanProjectSheet(project: project, cameraManager: cameraManager)
        }
        .sheet(isPresented: $isDescribingProject) {
            AIDescribeSheet(
                title: "Ask AI to Describe This Project",
                context: AIDescriptionContext.forProject(project) { cameraManager.equipmentLibrary.system(withID: $0)?.name },
                cameraManager: cameraManager,
                onSetAim: { text in
                    var updated = project
                    updated.goal = text
                    try? library.save(updated)
                },
                onAddNote: { text in
                    var updated = project
                    updated.notes.append(Annotation(date: Date(), text: text))
                    try? library.save(updated)
                }
            )
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

    private func applyAndSaveSession(_ updatedSession: Session) {
        var updatedProject = project
        guard let index = updatedProject.sessions.firstIndex(where: { $0.id == updatedSession.id }) else { return }
        updatedProject.sessions[index] = updatedSession
        try? library.save(updatedProject)
    }

    /// Stable sort — `sorted(by:)` preserves the relative order of elements that compare equal,
    /// so sessions that are both favorites (or both not) keep whatever order they were already in
    /// instead of getting shuffled just because a sort ran.
    private func favoritesFirst(_ sessions: [Session]) -> [Session] {
        sessions.sorted { $0.isFavorite && !$1.isFavorite }
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
                    if session.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                    }
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
                    if let location = session.effectiveLocation(inProject: project) {
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

/// A row of 5 tappable stars — "allow the user to vote project, sessions, task" — shared by the
/// Project, Session, and Capture pages so rating always looks and behaves the same regardless of
/// level. Tapping the same star the rating is already at clears it back to `.unrated`, the usual
/// "tap to toggle off" convention star ratings use, rather than getting stuck unable to go below 1
/// once first set.
struct RatingView: View {
    let rating: Rating
    var onChange: (Rating) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...Rating.range.upperBound, id: \.self) { star in
                Button {
                    onChange(star == rating ? .unrated : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A single-star favorite toggle — "add favorite section for projects and sessions in order to
/// keep them on top" — deliberately a different affordance from `RatingView`'s row of 5, so the
/// two distinct concepts (how good this was vs. whether to pin it) never look like the same
/// control at a glance.
struct FavoriteToggleButton: View {
    let isFavorite: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isFavorite ? "star.circle.fill" : "star.circle")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }
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

    /// A real `Table`, not a fixed-width grid — its columns fill the section's full width by
    /// default and the user can still drag either one wider (macOS `Table` columns are
    /// user-resizable out of the box), so a long value never gets clipped the way a capped-width
    /// grid cell would.
    var body: some View {
        Table(stats) {
            TableColumn("Label") { stat in
                Text(stat.label).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 140, max: 220)
            TableColumn("Value") { stat in
                Text(stat.value)
            }
            .width(min: 160, ideal: 320)
        }
        .frame(height: CGFloat(max(stats.count, 1)) * 28 + 32)
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
