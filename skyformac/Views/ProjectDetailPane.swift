import AppKit
import Charts
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
    /// Pops back one level (to wherever this page was pushed from — Home in the common case, but
    /// "All Projects" when reached from there instead).
    var onBack: () -> Void
    /// Jumps all the way back to the Projects browser's Home page, regardless of how deep the
    /// navigation stack is — see `SessionDetailPane.onHome`'s doc comment for why this exists
    /// alongside `onBack` instead of being the same action.
    var onHome: () -> Void
    /// Called after this project is deleted (soft-deleted, per `ProjectsLibrary.softDelete(_:)`)
    /// from its own Danger Zone section — there's nothing left to show here, so the caller
    /// (`ProjectsBrowserView`) pops all the way back to Home rather than leaving this page
    /// displayed for a project that no longer shows up anywhere except Recently Deleted.
    var onProjectDeleted: () -> Void
    /// Steps to the previous/next project in `ProjectsBrowserView`'s own favorites-first
    /// ordering — `nil` (not just a no-op closure) when this is the first/last project, so the
    /// toolbar button can be hidden entirely instead of shown disabled.
    var onPreviousProject: (() -> Void)?
    var onNextProject: (() -> Void)?

    @State private var name: String
    @State private var goal: String
    @State private var isPlanningProject = false
    @State private var isDescribingProject = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    init(
        project: Project, cameraManager: CameraManager, onShowSessionHistory: @escaping (Session) -> Void,
        onBack: @escaping () -> Void, onHome: @escaping () -> Void, onProjectDeleted: @escaping () -> Void,
        onPreviousProject: (() -> Void)? = nil, onNextProject: (() -> Void)? = nil
    ) {
        self.project = project
        self.cameraManager = cameraManager
        self.onShowSessionHistory = onShowSessionHistory
        self.onBack = onBack
        self.onHome = onHome
        self.onProjectDeleted = onProjectDeleted
        self.onPreviousProject = onPreviousProject
        self.onNextProject = onNextProject
        self._name = State(initialValue: project.name)
        self._goal = State(initialValue: project.goal)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Row 1: Cover (a small, fixed-width thumbnail editor) alongside Project, which
                // takes the rest of the width — same pairing as `SessionDetailPane`'s own Cover +
                // Session Summary row.
                HStack(alignment: .top, spacing: 16) {
                    PageSection(title: "Cover") {
                        CoverThumbnailEditor(
                            currentURL: cameraManager.projectStore.mostRecentThumbnailURL(for: project),
                            hasCustom: project.customThumbnailFileName != nil,
                            onPick: { url in
                                guard let name = try? cameraManager.projectStore.importCustomThumbnail(from: url, for: project) else { return }
                                var updated = project
                                updated.customThumbnailFileName = name
                                try? library.save(updated)
                            },
                            onRemove: {
                                cameraManager.projectStore.removeCustomThumbnail(for: project)
                                var updated = project
                                updated.customThumbnailFileName = nil
                                try? library.save(updated)
                            }
                        )
                    }
                    .frame(width: 280)

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Row 2: Stats, Equipment, and Tags side by side.
                HStack(alignment: .top, spacing: 16) {
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
                        .labelsHidden()
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
                }

                // Row 3: Sessions.
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
                    ForEach(favoritesFirst(project.sessions, isFavorite: \.isFavorite)) { session in
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

                // Row 4: Timeline (activity over the project's whole lifetime).
                PageSection(title: "Timeline") {
                    ActivityTimelineChart(project: project)
                }

                // Row 5: Notes.
                PageSection(title: "Notes") {
                    NotesEditorView(notes: project.notes) { notes in
                        var updated = project
                        updated.notes = notes
                        try? library.save(updated)
                    }
                }

                if !project.elaboratedImages.isEmpty {
                    PageSection(title: "Elaborated") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(project.elaboratedImages.sorted(by: { $0.date > $1.date })) { image in
                                    ElaboratedImageCard(project: project, image: image, cameraManager: cameraManager)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }

                // Row 6: Archive, Delete.
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
        // The system's own automatic back chevron only ever pops one level, which would sit right
        // next to `onBack` doing the same thing — hidden in favor of the explicit Home/Back pair
        // below (see `SessionDetailPane`'s identical modifier for the full reasoning).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Button("Home", systemImage: "house", action: onHome)
                    Button("Back", systemImage: "chevron.left", action: onBack)
                }
            }
            ToolbarItemGroup {
                if let onPreviousProject {
                    Button("Previous Project", systemImage: "chevron.up", action: onPreviousProject)
                }
                if let onNextProject {
                    Button("Next Project", systemImage: "chevron.down", action: onNextProject)
                }
            }
            OpenAssistantToolbarItem(cameraManager: cameraManager)
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
        // This page lives on the Projects-browsing side of the app (`ContentView`'s own
        // equivalent `.sheet` only exists while a camera session is active) — same reasoning as
        // `CaptureDetailPage`'s identical sheet, for the "Elaborated" section's own cards.
        .sheet(isPresented: Binding(
            get: { cameraManager.viewingExportedFile != nil },
            set: { if !$0 { cameraManager.viewingExportedFile = nil } }
        )) {
            ExportedFileViewerView(cameraManager: cameraManager)
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
        let diskUsage = cameraManager.projectStore.diskUsage(for: project)
        stats.append(StatItem(label: "Disk Usage", value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file)))
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

    private var hasRun: Bool { !session.captures.isEmpty }
    private var thumbnailURL: URL? { store.mostRecentThumbnailURL(for: session, in: project) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnailURL, let image = ThumbnailCache.image(at: thumbnailURL) {
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
                    statusBadge
                }
                if !session.goal.isEmpty {
                    Text(session.goal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !session.plannedObjects.isEmpty {
                    Text(session.plannedObjects.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                HStack(spacing: 10) {
                    // "Show time of sessions" — a session that's actually been run shows exactly
                    // when (not just the date), plus how long it ran for; one still only planned
                    // shows its planned date and time instead — either way, a real time, not just
                    // a bare date the way this card previously showed for a planned session.
                    if let first = session.firstCaptureDate {
                        Label(first.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        if let duration = session.duration, let formatted = Self.durationFormatter.string(from: duration) {
                            Text("(\(formatted))")
                        }
                    } else if let planned = session.plannedDate {
                        Label(planned.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    }
                    Label("\(session.captures.count)", systemImage: "camera")
                    if hasRun {
                        Label(ByteCountFormatter.string(fromByteCount: store.diskUsage(for: session, in: project), countStyle: .file), systemImage: "internaldrive")
                    }
                    if let location = session.effectiveLocation(inProject: project) {
                        Label(location.displayName, systemImage: "location").lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }

            Spacer()

            Button(hasRun ? "Resume" : "Run", systemImage: "play.fill") {
                cameraManager.setActive(project: project, session: session)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
        .opacity(session.isArchived ? 0.5 : 1)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

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

/// "The user can change the thumbnail of a project and of a session. If not set use the
/// automatic created. The user can remove the custom thumbnail, in that case restore the
/// automatic created" — shared by `ProjectDetailPane` (its own project) and `SessionDetailPane`
/// (its own session), since both just need a preview of whatever `currentURL` (the *effective*
/// thumbnail — custom if set, otherwise the automatic most-recent-capture one) already resolves
/// to, plus "Change…"/"Remove Custom Thumbnail" wired to the caller's own storage.
struct CoverThumbnailEditor: View {
    let currentURL: URL?
    /// Whether a *custom* thumbnail is currently set — distinct from `currentURL` being non-`nil`,
    /// since an automatic thumbnail also has a URL but "Remove Custom Thumbnail" has nothing to do
    /// in that case (there's no custom one shadowing anything yet).
    let hasCustom: Bool
    var onPick: (URL) -> Void
    var onRemove: () -> Void

    var body: some View {
        // Two rows, not side by side — a 120×80 thumbnail squeezed next to its own caption/buttons
        // read as an afterthought in the narrower single-column width `SessionDetailPane`/
        // `ProjectDetailPane`'s own Cover + Summary row gives this; a large thumbnail on top with
        // its description and actions below reads as the cover it actually is.
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let currentURL, let image = ThumbnailCache.image(at: currentURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .clipped()

            Text(hasCustom ? "Custom thumbnail" : "Automatic — most recent capture")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Change Thumbnail…") { pickImage(onPick: onPick) }
                if hasCustom {
                    Button("Remove Custom Thumbnail", role: .destructive, action: onRemove)
                }
            }
        }
    }

    private func pickImage(onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            onPick(url)
        }
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

    /// A plain `Grid`, not a `Table` — a `Table` always creates its own internal `NSScrollView`
    /// regardless of what's given as its `.frame(height:)`, and that height had to be guessed
    /// (`rowCount * 28 + 32`, a stand-in for the real per-row height `Table` never exposes). Once
    /// a section had enough rows (Camera Settings can show up to 9), that guess fell short of the
    /// real content height and the table silently clipped/scrolled internally instead of the
    /// section just growing — "the table isn't fully visible." `Grid` sizes itself to its actual
    /// content with no height to guess at all, so this can't recur regardless of row count.
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(stats) { stat in
                GridRow(alignment: .firstTextBaseline) {
                    Text(stat.label).foregroundStyle(.secondary)
                    Text(stat.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

/// "Zoom in to all activities" — every capture across every session in the project, plotted by
/// its exact timestamp (x) against which session it belongs to (y, categorical — one swimlane per
/// session), so this doubles as "show time of sessions" at a glance: when each session actually
/// ran, and roughly how long each stayed active, without opening any of them individually.
private struct ActivityTimelineChart: View {
    let project: Project

    /// Same "zoom similar to histogram" shape used elsewhere (`HistogramView`,
    /// `ExposureField`/`GainField`) — narrows the visible date range around a snapshotted center
    /// rather than the live value, so dragging mid-zoom doesn't fight the zoom slider's own
    /// gesture recognizer over a moving domain.
    @State private var zoom: Double = 1
    @State private var zoomCenter: Date?

    /// Every session's every capture, flattened once per render (see `body`) rather than read as
    /// a computed property from several places — that used to re-flatten the whole project on
    /// every access (the empty check, the session count, the chart data, and transitively again
    /// via `fullRange`/`visibleRange`), including on every frame of dragging the zoom slider.
    private var entries: [(session: String, date: Date)] {
        project.sessions.flatMap { session in session.captures.map { (session.name, $0.date) } }
    }

    private static func fullRange(for entries: [(session: String, date: Date)]) -> ClosedRange<Date> {
        let dates = entries.map(\.date)
        guard let earliest = dates.min(), let latest = dates.max() else {
            let now = Date()
            return now...now.addingTimeInterval(3600)
        }
        // A single capture (or several at the exact same instant) still needs a real, non-empty
        // range for `chartXScale`/zoom math to operate over.
        return earliest < latest ? earliest...latest : earliest...earliest.addingTimeInterval(1800)
    }

    private func visibleRange(fullRange: ClosedRange<Date>) -> ClosedRange<Date> {
        guard zoom > 1 else { return fullRange }
        let center = zoomCenter ?? Self.midpoint(of: fullRange)
        let fullWidth = fullRange.upperBound.timeIntervalSince(fullRange.lowerBound)
        let halfWidth = fullWidth / zoom / 2
        let lower = max(fullRange.lowerBound, center.addingTimeInterval(-halfWidth))
        let upper = min(fullRange.upperBound, center.addingTimeInterval(halfWidth))
        return lower < upper ? lower...upper : fullRange
    }

    private static func midpoint(of range: ClosedRange<Date>) -> Date {
        range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
    }

    var body: some View {
        let entries = self.entries
        if entries.isEmpty {
            Text("Nothing captured yet.").font(.caption).foregroundStyle(.secondary)
        } else {
            let sessionCount = Set(entries.map(\.session)).count
            let fullRange = Self.fullRange(for: entries)
            VStack(alignment: .leading, spacing: 6) {
                Chart(entries, id: \.date) { entry in
                    PointMark(x: .value("Time", entry.date), y: .value("Session", entry.session))
                }
                .chartXScale(domain: visibleRange(fullRange: fullRange))
                .frame(height: CGFloat(min(max(sessionCount, 1), 8)) * 24 + 40)
                HStack(spacing: 6) {
                    Image(systemName: "plus.magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $zoom, in: 1...50)
                    if zoom > 1 {
                        Button("Reset") { zoom = 1; zoomCenter = nil }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
                .onChange(of: zoom) { _, _ in
                    if zoomCenter == nil { zoomCenter = Self.midpoint(of: fullRange) }
                }
            }
        }
    }
}

/// One `SirilElaborationService` result on the Project page's "Elaborated" section — tapping it
/// opens `ExportedFileViewerView` (the same viewer FITS/PNG/TIFF exports already use), since the
/// result is itself just a `.tif` file. "Info…" shows what actually produced it (source, recipe,
/// size on disk) and offers "Re-elaborate…" to run it again with different parameters — a new,
/// separate entry alongside this one, not a replacement, so both remain comparable.
struct ElaboratedImageCard: View {
    let project: Project
    let image: ElaboratedImage
    var cameraManager: CameraManager

    @State private var isConfirmingDelete = false
    @State private var isShowingDetail = false
    @State private var isReElaborating = false
    @State private var isSendingToGraXpert = false
    @State private var isPromptingGraXpertSettings = false
    @State private var isSendingToStarNet = false
    @State private var isPromptingStarNetSettings = false

    private var fileURL: URL {
        cameraManager.projectStore.elaboratedImagesFolderURL(for: project).appendingPathComponent(image.fileName)
    }

    /// The session this came from — almost always exactly one entry in `sourceSessionIDs` (see
    /// that field's own doc comment); `nil` only if that session's since been deleted.
    private var sourceSession: Session? {
        image.sourceSessionIDs.first.flatMap { id in project.sessions.first { $0.id == id } }
    }

    private var sourceCapture: CaptureRecord? {
        guard let captureID = image.sourceCaptureID, let session = sourceSession else { return nil }
        return session.captures.first { $0.id == captureID }
    }

    private var sourceDescription: String {
        guard let sourceSession else { return "Source session no longer exists" }
        if let sourceCapture {
            return "\(sourceSession.name) — \(sourceCapture.fileName)"
        }
        return "\(sourceSession.name) (whole session)"
    }

    private var diskSizeText: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Re-derives the same `SirilElaborationService.Source` the original elaboration used, from
    /// this entry's own `sourceSessionIDs`/`sourceCaptureID` — `nil` if the session or capture it
    /// pointed to has since been deleted, in which case there's nothing left to re-run.
    private var reElaborationSource: (SirilElaborationService.Source, AcquisitionTarget?)? {
        guard let sourceSession else { return nil }
        if let captureID = image.sourceCaptureID {
            return cameraManager.elaborationSource(forCaptureID: captureID, in: sourceSession, project: project)
        }
        return cameraManager.elaborationSource(for: sourceSession, project: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let nsImage = NSImage(contentsOf: fileURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 100)
            .clipped()

            Text(image.displayLabel).font(.caption2).foregroundStyle(.secondary)
            Text(image.date, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(width: 150, alignment: .leading)
        .contentShape(Rectangle())
        // Opens the same detail sheet the context menu's "Info…" does — the plain generic
        // `ExportedFileViewerView` (what `cameraManager.openExportedFile(fileURL)` shows) has no
        // way to know this file is an elaborated image at all, so it could never offer Delete/
        // Re-elaborate/Info; a click landing there left exactly the "no info, can't delete"
        // report this replaces.
        .onTapGesture { isShowingDetail = true }
        .contextMenu {
            Button("Info…", systemImage: "info.circle") { isShowingDetail = true }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            if image.recipe != nil, reElaborationSource != nil {
                Button("Re-elaborate…", systemImage: "arrow.clockwise") { isReElaborating = true }
            }
            Menu("Further Processing") {
                Button("Send to GraXpert…", systemImage: "sparkles") { startSendingToGraXpert() }
                Button("Remove Stars (StarNet)…", systemImage: "star.slash") { startSendingToStarNet() }
                Button("Open in PixInsight…", systemImage: "arrow.up.forward.app") { try? PixInsightAppLauncher.open(fileURL) }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
        }
        .sheet(isPresented: $isShowingDetail) {
            ElaboratedImageDetailSheet(
                image: image, fileURL: fileURL, sourceDescription: sourceDescription, diskSizeText: diskSizeText,
                canReElaborate: image.recipe != nil && reElaborationSource != nil,
                // Closes this sheet first, not just alongside — `isConfirmingDelete`'s
                // `.confirmationDialog` and `isReElaborating`'s `.sheet` are both attached to the
                // card underneath, which a still-open sheet would otherwise block from showing.
                onReElaborate: { isShowingDetail = false; isReElaborating = true },
                onSendToGraXpert: { isShowingDetail = false; startSendingToGraXpert() },
                onSendToStarNet: { isShowingDetail = false; startSendingToStarNet() },
                onOpenInPixInsight: { try? PixInsightAppLauncher.open(fileURL) },
                onDelete: { isShowingDetail = false; isConfirmingDelete = true }
            )
        }
        .sheet(isPresented: $isReElaborating) {
            if let (source, _) = reElaborationSource, let recipe = image.recipe {
                ElaborateSheet(
                    source: source,
                    suggestedRecipe: recipe,
                    sourceDescription: "Re-elaborating \(sourceDescription)."
                ) { recipe, parameters, onLog in
                    try await cameraManager.elaborate(
                        source: source, recipe: recipe, sourceSessionIDs: image.sourceSessionIDs,
                        sourceCaptureID: image.sourceCaptureID, project: project, parameters: parameters, onLog: onLog
                    )
                }
            }
        }
        .sheet(isPresented: $isPromptingGraXpertSettings) {
            GraXpertDisabledPrompt(onOpenSettings: { cameraManager.isSettingsPresented = true })
        }
        .sheet(isPresented: $isSendingToGraXpert) {
            GraXpertSheet(
                inputURL: fileURL,
                sourceDescription: "Sending \(image.fileName) to GraXpert."
            ) { operation, parameters, onLog in
                try await cameraManager.sendToGraXpert(
                    inputURL: fileURL, operation: operation, sourceSessionIDs: image.sourceSessionIDs,
                    sourceCaptureID: image.sourceCaptureID, project: project, parameters: parameters, onLog: onLog
                )
            }
        }
        .sheet(isPresented: $isPromptingStarNetSettings) {
            StarNetDisabledPrompt(onOpenSettings: { cameraManager.isSettingsPresented = true })
        }
        .sheet(isPresented: $isSendingToStarNet) {
            StarNetSheet(
                inputURL: fileURL,
                sourceDescription: "Sending \(image.fileName) to StarNet."
            ) { parameters, onLog in
                try await cameraManager.sendToStarNet(
                    inputURL: fileURL, sourceSessionIDs: image.sourceSessionIDs,
                    sourceCaptureID: image.sourceCaptureID, project: project, parameters: parameters, onLog: onLog
                )
            }
        }
        .confirmationDialog(
            "Delete this elaborated image?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                try? cameraManager.projectsLibrary.deleteElaboratedImage(image.id, in: project)
            }
        } message: {
            Text("This removes the file from disk — this can't be undone.")
        }
    }

    private func startSendingToGraXpert() {
        if AppSettings.isGraXpertIntegrationEnabled {
            isSendingToGraXpert = true
        } else {
            isPromptingGraXpertSettings = true
        }
    }

    private func startSendingToStarNet() {
        if AppSettings.isStarNetIntegrationEnabled {
            isSendingToStarNet = true
        } else {
            isPromptingStarNetSettings = true
        }
    }
}

/// What tapping an `ElaboratedImageCard` opens — the image itself alongside what actually
/// produced it (source, recipe, when, size on disk) and the actions that go with it
/// (Re-elaborate, Delete), all in one place. Exists as its own sheet rather than reusing
/// `ExportedFileViewerView` (what plain FITS/PNG/TIFF exports open in) because that viewer only
/// ever knows a bare file URL — it has no way to look up which `ElaboratedImage` a file
/// corresponds to, so it could never show any of this or offer Delete/Re-elaborate at all.
private struct ElaboratedImageDetailSheet: View {
    let image: ElaboratedImage
    let fileURL: URL
    let sourceDescription: String
    let diskSizeText: String
    let canReElaborate: Bool
    var onReElaborate: () -> Void
    var onSendToGraXpert: () -> Void
    var onSendToStarNet: () -> Void
    var onOpenInPixInsight: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(image.fileName).font(.headline)

            if let nsImage = NSImage(contentsOf: fileURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Couldn't Load This Image", systemImage: "exclamationmark.triangle")
            }

            StatsGridView(stats: [
                StatItem(label: "Elaborated", value: image.date.formatted(date: .abbreviated, time: .shortened)),
                StatItem(label: "Source", value: sourceDescription),
                StatItem(label: "Recipe", value: image.displayLabel),
                StatItem(label: "Size on Disk", value: diskSizeText),
            ])

            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                Spacer()
                if canReElaborate {
                    Button("Re-elaborate…", systemImage: "arrow.clockwise", action: onReElaborate)
                }
                Menu("Further Processing") {
                    Button("Send to GraXpert…", systemImage: "sparkles", action: onSendToGraXpert)
                    Button("Remove Stars (StarNet)…", systemImage: "star.slash", action: onSendToStarNet)
                    Button("Open in PixInsight…", systemImage: "arrow.up.forward.app", action: onOpenInPixInsight)
                }
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
