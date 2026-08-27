import AppKit
import SwiftUI

/// A project's own Sessions list, same "recognize it visually" vs. "compare a lot of them by
/// their actual numbers" tradeoff as `ProjectsBrowserView`'s Thumbnails/Table toggle for
/// projects — cards for browsing, a table for seeing disk usage/capture counts side by side and
/// multi-selecting for bulk actions.
private enum SessionsViewMode: String {
    case cards
    case table
}

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
    /// Pushes straight to one specific capture's own page — the Timeline section's own thumbnails
    /// are mixed across every session in this project, so (unlike `onShowSessionHistory`) it needs
    /// to carry which session the tapped capture actually belongs to.
    var onSelectCapture: (Session, CaptureRecord) -> Void
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
    /// Persisted like `ProjectsBrowserView`'s own Thumbnails/Table toggle — a view mode picked
    /// once shouldn't reset back to the default every relaunch.
    @AppStorage("projectSessionsViewMode") private var sessionsViewModeRaw = SessionsViewMode.cards.rawValue
    private var sessionsViewMode: SessionsViewMode { SessionsViewMode(rawValue: sessionsViewModeRaw) ?? .cards }
    /// A `Table`'s own selection — multi-select out of the box (click/⌘-click/shift-click) with
    /// a `Set` binding, same as `ProjectsBrowserView`'s own project table.
    @State private var selectedSessionIDs: Set<Session.ID> = []

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    init(
        project: Project, cameraManager: CameraManager, onShowSessionHistory: @escaping (Session) -> Void,
        onSelectCapture: @escaping (Session, CaptureRecord) -> Void,
        onBack: @escaping () -> Void, onHome: @escaping () -> Void, onProjectDeleted: @escaping () -> Void,
        onPreviousProject: (() -> Void)? = nil, onNextProject: (() -> Void)? = nil
    ) {
        self.project = project
        self.cameraManager = cameraManager
        self.onShowSessionHistory = onShowSessionHistory
        self.onSelectCapture = onSelectCapture
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
                        Picker("View", selection: $sessionsViewModeRaw) {
                            Label("Cards", systemImage: "list.bullet").tag(SessionsViewMode.cards.rawValue)
                            Label("Table", systemImage: "tablecells").tag(SessionsViewMode.table.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .frame(width: 90)
                        Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningProject = true }
                        Button("Add Session", systemImage: "plus") { addSession() }
                    }

                    if !selectedSessionIDs.isEmpty {
                        sessionsBulkActionBar
                    }

                    switch sessionsViewMode {
                    case .cards:
                        // Favorites first — "keep them on top" — ties broken by each session's
                        // own existing order otherwise (a stable sort, so non-favorites don't get
                        // needlessly reshuffled amongst themselves).
                        ForEach(favoritesFirst(project.sessions, isFavorite: \.isFavorite)) { session in
                            SessionCard(project: project, session: session, cameraManager: cameraManager, store: cameraManager.projectStore)
                                .contentShape(Rectangle())
                                // Tapping a session always opens its own Session page (detail/
                                // history) — the camera view only ever opens via an explicit
                                // "Run"/"Resume"/"Run This Session" button (on the card itself,
                                // or on the Session page), never just by tapping the row.
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
                    case .table:
                        // The data-dense alternative — every session's disk usage/capture count/
                        // last-activity side by side, sortable, with native multi-select for the
                        // bulk action bar above instead of one context menu at a time.
                        SessionsTableView(
                            project: project, store: cameraManager.projectStore, selectedIDs: $selectedSessionIDs,
                            onSelect: onShowSessionHistory
                        )
                        .frame(minHeight: 240, idealHeight: 360)
                    }
                }

                // Row 4: Timeline (every capture across every session in this project, merged
                // chronologically) — reuses `ObservationTimelineView` scoped to just this one
                // project (a single-element `projects` array) rather than `ActivityTimelineChart`,
                // a Swift Charts scatter plot that was never actually built to show thumbnails or
                // support tapping a capture, and had a real zoom bug besides (zooming always
                // narrowed toward the full range's static midpoint, which usually landed in an
                // empty gap between sessions for a realistically bursty observing history).
                PageSection(title: "Timeline") {
                    ObservationTimelineView(
                        projects: [project], cameraManager: cameraManager,
                        onSelect: { _, session, capture in onSelectCapture(session, capture) }
                    )
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

    /// Shown above the session list the moment the table's selection is non-empty — "N
    /// selected," Archive/Delete acting on the whole set at once, and Clear. Loops the existing
    /// single-session `ProjectsLibrary` calls (the same ones the card view's own context menu
    /// uses) rather than needing a dedicated bulk API.
    private var sessionsBulkActionBar: some View {
        HStack {
            Text("\(selectedSessionIDs.count) selected").font(.subheadline)
            Spacer()
            Button("Archive", systemImage: "archivebox") {
                for id in selectedSessionIDs {
                    try? library.setArchived(true, forSessionID: id, in: project)
                }
                selectedSessionIDs.removeAll()
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                for id in selectedSessionIDs {
                    try? library.deleteSession(id, in: project)
                }
                selectedSessionIDs.removeAll()
            }
            Button("Clear") { selectedSessionIDs.removeAll() }
        }
        .padding(.vertical, 6)
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

/// The data-dense alternative to `SessionCard` — every session in this project as a table row,
/// sortable by any column, for comparing disk usage/capture counts side by side and
/// multi-selecting for the bulk action bar above (`ProjectDetailPane.sessionsBulkActionBar`)
/// instead of one context menu at a time. Mirrors `ProjectsBrowserView`'s own `ProjectsTableView`
/// for projects.
private struct SessionsTableView: View {
    let project: Project
    let store: ProjectStore
    /// A `Table`'s own selection is multi-select out of the box with a `Set` binding (click,
    /// ⌘-click, shift-click) — no separate "select mode" needed the way `SessionCard`'s plain
    /// taps do, since a single click here already just selects rather than opening.
    @Binding var selectedIDs: Set<Session.ID>
    var onSelect: (Session) -> Void

    @State private var sortOrder = [KeyPathComparator(\Session.name)]

    private var sortedSessions: [Session] {
        project.sessions.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedSessions, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { session in
                HStack(spacing: 4) {
                    if session.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption2)
                    }
                    Text(session.name)
                        .opacity(session.isArchived ? 0.5 : 1)
                }
            }
            TableColumn("Goal", value: \.goal)
            TableColumn("Captures") { Text("\($0.captures.count)") }
                .width(70)
            TableColumn("Disk Usage") { session in
                Text(ByteCountFormatter.string(fromByteCount: store.diskUsage(for: session, in: project), countStyle: .file))
            }
            .width(90)
            TableColumn("Location") { Text($0.effectiveLocation(inProject: project)?.displayName ?? "—") }
            TableColumn("Tags") { Text($0.tags.joined(separator: ", ")) }
            TableColumn("Last Activity") { session in
                if let date = session.firstCaptureDate ?? session.plannedDate {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("—")
                }
            }
        }
        .contextMenu(forSelectionType: Session.ID.self) { _ in
            // No per-row menu items yet — Favorite/Archive/Delete live on the card view's own
            // context menu, and the bulk action bar above covers Archive/Delete for a selection.
        } primaryAction: { ids in
            guard let id = ids.first, let session = project.sessions.first(where: { $0.id == id }) else { return }
            onSelect(session)
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

/// A named, collapsible group of `PageSection`s (or `PageSection`-containing rows) — first built
/// for the Dashboard, whose 7 independently-stacked sections left a returning user with a full
/// history scrolling past every one of them at once with nothing to group or collapse; the same
/// density issue showed up on the Session page once it had grown 9 sections of its own. A plain
/// `DisclosureGroup` rather than another `PageSection` wrapping the ones already there — the
/// point is fewer independently-scannable top-level cards, not one more card nested around the
/// ones already there. Defaults to expanded (`isExpanded`'s own binding decides, not this view) —
/// nothing is hidden by using this, only organized; collapsing is a per-caller-state option for a
/// user who wants less scrolling.
struct PageSectionCluster<Content: View>: View {
    var title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Text(title).font(.title3.bold())
        }
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

/// The "hand off to an external app" menu — GraXpert/StarNet/PixInsight, plus a Siril
/// "Re-elaborate…" for a Siril-originated result — shared by an elaborated image's own context
/// menu, its full-screen preview's "More" menu, and its Info sheet's button row. Extracted once
/// `Menu("Third-Party Tools")`'s own content had been copy-pasted three times across this file: a
/// real risk of the three drifting out of sync (a fifth tool added to one but not the others),
/// not a case where the duplication itself read badly. Each call site still supplies its own
/// action closures — one closes a detached window first, one doesn't have one to close, and the
/// Info sheet's own closures come from its caller — so this only unifies the menu's *shape*, not
/// what each button actually does.
private struct ThirdPartyToolsMenu: View {
    var canReElaborate: Bool
    var onReElaborate: () -> Void
    var onSendToGraXpert: () -> Void
    var onSendToStarNet: () -> Void
    var onOpenInPixInsight: () -> Void

    var body: some View {
        Menu("Third-Party Tools") {
            if canReElaborate {
                Button("Re-elaborate in Siril…", systemImage: "arrow.clockwise", action: onReElaborate)
            }
            Button("Send to GraXpert…", systemImage: "sparkles", action: onSendToGraXpert)
            Button("Remove Stars (StarNet)…", systemImage: "star.slash", action: onSendToStarNet)
            Button("Open in PixInsight…", systemImage: "arrow.up.forward.app", action: onOpenInPixInsight)
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
    /// "The edit/preview windows can be moved across the screen and resized" — see
    /// `CaptureDetailPage`'s identical property doc comment for why these are
    /// `DetachedContentWindowController?` rather than the three `Bool`s + `.sheet`s they used to
    /// be. `redoingFromOriginalWindowController`: "post-process more…starting from the original
    /// with the settings used" — re-runs Planetary Post-Processing from scratch on the actual
    /// `.ser` this result was stacked from, seeded with the settings that produced it
    /// (`image.planetarySettings`). `editingImageWindowController`: the other half — "post
    /// elaborate the photo as png with all controls" — runs the already-finished PNG through Edit
    /// Image's own controls, exactly like editing any other PNG capture.
    @State private var viewingFullScreenWindowController: DetachedContentWindowController?
    @State private var redoingFromOriginalWindowController: DetachedContentWindowController?
    @State private var editingImageWindowController: DetachedContentWindowController?

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

    /// "Redo from Original…" needs the actual `.ser` this result was stacked from — only
    /// resolvable when the source capture still exists and is itself a `.ser` (the only input
    /// kind Planetary Post-Processing accepts); `nil` hides the action rather than offering
    /// something that can't actually run (a deleted source, or a result that never came from a
    /// `.ser` in the first place — a whole-session elaboration, or an Edit Image/Siril/GraXpert
    /// result).
    private var originalSERCaptureURL: URL? {
        guard let sourceSession, let sourceCapture, sourceCapture.kind == .serVideo else { return nil }
        return cameraManager.projectStore.sessionFolderURL(for: sourceSession, in: project)
            .appendingPathComponent(sourceCapture.fileName)
    }

    /// "All the right-click menu items on post processed images must be visible also in preview
    /// of the image" — the same actions `.contextMenu` above offers, reachable from
    /// `FullScreenImageViewer`'s own "More" menu too. Each action closes the preview's own window
    /// first (unlike the context menu's own actions, which don't have one open in the first
    /// place) so it doesn't linger behind whatever it opens.
    @ViewBuilder
    private var fullScreenMoreMenuItems: some View {
        // Skyformac's own tools first, "Edit Image…" foremost — the action someone opening this
        // preview reaches for most.
        Button("Edit Image…", systemImage: "slider.horizontal.3") { viewingFullScreenWindowController?.close(); openEditingImageWindow() }
        if originalSERCaptureURL != nil {
            Button("Redo from Original…", systemImage: "arrow.counterclockwise") { viewingFullScreenWindowController?.close(); openRedoFromOriginalWindow() }
        }
        Divider()
        Button("Info…", systemImage: "info.circle") { viewingFullScreenWindowController?.close(); isShowingDetail = true }
        Button("Show in Finder") { viewingFullScreenWindowController?.close(); NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") { viewingFullScreenWindowController?.close(); AstroBinPublisher.publish(fileURL) }
        Divider()
        ThirdPartyToolsMenu(
            canReElaborate: image.recipe != nil && reElaborationSource != nil,
            onReElaborate: { viewingFullScreenWindowController?.close(); isReElaborating = true },
            onSendToGraXpert: { viewingFullScreenWindowController?.close(); startSendingToGraXpert() },
            onSendToStarNet: { viewingFullScreenWindowController?.close(); startSendingToStarNet() },
            onOpenInPixInsight: { try? PixInsightAppLauncher.open(fileURL) }
        )
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { viewingFullScreenWindowController?.close(); isConfirmingDelete = true }
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
        // Tapping opens the same full-screen zoom viewer "Open" uses everywhere else in the app
        // (`FullScreenImageViewer`) — metadata/Delete/Re-elaborate move to the context menu's
        // "Info…", which still opens the old detail sheet below.
        .onTapGesture { openFullScreenViewer() }
        .contextMenu {
            // Skyformac's own tools first, "Edit Image…" foremost — mirrors
            // `fullScreenMoreMenuItems`'s ordering below.
            Button("Edit Image…", systemImage: "slider.horizontal.3") { openEditingImageWindow() }
            if originalSERCaptureURL != nil {
                Button("Redo from Original…", systemImage: "arrow.counterclockwise") { openRedoFromOriginalWindow() }
            }
            Divider()
            Button("Info…", systemImage: "info.circle") { isShowingDetail = true }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") { AstroBinPublisher.publish(fileURL) }
            Button("Delete…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            Divider()
            // Every hand-off to an external app in one place — "Re-elaborate" re-runs this
            // result through Siril specifically (only ever offered for a Siril-originated
            // result, `image.recipe != nil`), so it belongs alongside GraXpert/StarNet/
            // PixInsight, not next to Skyformac's own Info/Show in Finder/Delete above.
            ThirdPartyToolsMenu(
                canReElaborate: image.recipe != nil && reElaborationSource != nil,
                onReElaborate: { isReElaborating = true },
                onSendToGraXpert: { startSendingToGraXpert() },
                onSendToStarNet: { startSendingToStarNet() },
                onOpenInPixInsight: { try? PixInsightAppLauncher.open(fileURL) }
            )
        }
        .sheet(isPresented: $isShowingDetail) {
            ElaboratedImageDetailSheet(
                image: image, fileURL: fileURL, sourceDescription: sourceDescription, diskSizeText: diskSizeText,
                canReElaborate: image.recipe != nil && reElaborationSource != nil,
                canRedoFromOriginal: originalSERCaptureURL != nil,
                // Closes this sheet first, not just alongside — `isConfirmingDelete`'s
                // `.confirmationDialog` and `isReElaborating`'s `.sheet` are both attached to the
                // card underneath, which a still-open sheet would otherwise block from showing.
                onRedoFromOriginal: { isShowingDetail = false; openRedoFromOriginalWindow() },
                onEditImage: { isShowingDetail = false; openEditingImageWindow() },
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

    /// `FullScreenImageViewer`'s "Set as Thumbnail" for an elaborated image — project-scoped
    /// (not session-scoped): an elaborated image can come from a whole session or span multiple
    /// sources (`sourceSessionIDs`), so the project — the one thing every elaborated image
    /// unambiguously belongs to — is the natural cover-image target, matching
    /// `ProjectDetailPane`'s own `CoverThumbnailEditor`.
    private func setProjectThumbnailFromThisImage() {
        guard let name = try? cameraManager.projectStore.importCustomThumbnail(from: fileURL, for: project) else { return }
        var updated = project
        updated.customThumbnailFileName = name
        try? cameraManager.projectsLibrary.save(updated)
    }

    private func openFullScreenViewer() {
        guard let nsImage = NSImage(contentsOf: fileURL) else { return }
        viewingFullScreenWindowController = DetachedContentWindowController(
            title: image.displayLabel, contentSize: NSSize(width: 1100, height: 800), minSize: NSSize(width: 960, height: 700),
            onClose: { viewingFullScreenWindowController = nil }
        ) {
            FullScreenImageViewer(
                image: nsImage, fileURL: fileURL, onSetAsThumbnail: setProjectThumbnailFromThisImage,
                moreMenuItems: { AnyView(fullScreenMoreMenuItems) },
                onDismiss: { viewingFullScreenWindowController?.close() }
            )
        }
        viewingFullScreenWindowController?.showWindow(nil)
    }

    private func openRedoFromOriginalWindow() {
        guard let originalSERCaptureURL else { return }
        redoingFromOriginalWindowController = DetachedContentWindowController(
            title: "Planetary Post-Processing — \(originalSERCaptureURL.lastPathComponent)", contentSize: PlanetaryPostProcessingView.fullScreenSize,
            minSize: PlanetaryPostProcessingView.minWindowSize,
            onClose: { redoingFromOriginalWindowController = nil }
        ) {
            PlanetaryPostProcessingView(
                sourceURLs: [originalSERCaptureURL],
                sourceDescription: "Redoing \(originalSERCaptureURL.lastPathComponent) from the original.",
                onSave: { cgImage, title, notes, settings in
                    try cameraManager.savePlanetaryPostProcessingResult(
                        cgImage, sourceSessionIDs: image.sourceSessionIDs, sourceCaptureID: image.sourceCaptureID,
                        project: project, title: title, notes: notes, settings: settings
                    )
                },
                onOverwrite: { cgImage, existing, title, notes, settings in
                    try cameraManager.overwritePlanetaryPostProcessingResult(
                        cgImage, existing: existing, project: project, title: title, notes: notes, settings: settings
                    )
                },
                resolveGraXpertInputURL: { resultImage in
                    cameraManager.projectStore.elaboratedImagesFolderURL(for: project).appendingPathComponent(resultImage.fileName)
                },
                onSendToGraXpert: { inputURL, operation, parameters, onLog in
                    try await cameraManager.sendToGraXpert(
                        inputURL: inputURL, operation: operation, sourceSessionIDs: image.sourceSessionIDs,
                        sourceCaptureID: image.sourceCaptureID, project: project, parameters: parameters, onLog: onLog
                    )
                },
                onOpenGraXpertSettings: { cameraManager.isSettingsPresented = true },
                initialSettings: image.planetarySettings,
                onDismiss: { redoingFromOriginalWindowController?.close() }
            )
        }
        redoingFromOriginalWindowController?.showWindow(nil)
    }

    private func openEditingImageWindow() {
        editingImageWindowController = DetachedContentWindowController(
            title: "Edit Image — \(image.fileName)", contentSize: SingleImagePostProcessingView.fullScreenSize,
            minSize: SingleImagePostProcessingView.minWindowSize,
            onClose: { editingImageWindowController = nil }
        ) {
            SingleImagePostProcessingView(
                sourceURL: fileURL,
                sourceDescription: "Editing \(image.fileName).",
                elaboratedImagesFolderURL: cameraManager.projectStore.elaboratedImagesFolderURL(for: project),
                onSave: { cgImage in
                    try cameraManager.saveImageEditResult(
                        cgImage, sourceSessionIDs: image.sourceSessionIDs, sourceCaptureID: image.sourceCaptureID, project: project
                    )
                },
                onDismiss: { editingImageWindowController?.close() }
            )
        }
        editingImageWindowController?.showWindow(nil)
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
    let canRedoFromOriginal: Bool
    var onRedoFromOriginal: () -> Void
    var onEditImage: () -> Void
    var onReElaborate: () -> Void
    var onSendToGraXpert: () -> Void
    var onSendToStarNet: () -> Void
    var onOpenInPixInsight: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(image.title ?? image.fileName).font(.headline)
            if image.title != nil {
                Text(image.fileName).font(.caption).foregroundStyle(.secondary)
            }
            if let notes = image.notes, !notes.isEmpty {
                Text(notes).font(.callout).foregroundStyle(.secondary)
            }

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
                StatItem(label: "Tool", value: image.toolLabel ?? image.recipe?.label ?? "Elaborated"),
                StatItem(label: "Size on Disk", value: diskSizeText),
            ])
            if let settings = image.planetarySettings {
                settingsSummary(settings)
            }

            HStack {
                // Edit Image… leads, matching the card's own context menu and the full-screen
                // preview's "More" menu — the action someone opening this sheet reaches for most.
                Button("Edit Image…", systemImage: "slider.horizontal.3", action: onEditImage)
                if canRedoFromOriginal {
                    Button("Redo from Original…", systemImage: "arrow.counterclockwise", action: onRedoFromOriginal)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") { AstroBinPublisher.publish(fileURL) }
                Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                // Every hand-off to an external app grouped together — see the card's own
                // context menu doc comment for why "Re-elaborate" (Siril-only) belongs here
                // alongside GraXpert/StarNet/PixInsight rather than sitting on its own.
                ThirdPartyToolsMenu(
                    canReElaborate: canReElaborate, onReElaborate: onReElaborate, onSendToGraXpert: onSendToGraXpert,
                    onSendToStarNet: onSendToStarNet, onOpenInPixInsight: onOpenInPixInsight
                )
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// "The saving brings also all settings used to elaborate the image" — a compact readout of
    /// exactly what `PlanetaryPostProcessingView` produced this with, for a result that came from
    /// there (`nil` for anything else — Siril/GraXpert/Image Editor results have no equivalent
    /// parameter set).
    @ViewBuilder
    private func settingsSummary(_ settings: PlanetaryPostProcessor.SettingsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings Used").font(.caption.bold()).foregroundStyle(.secondary)
            Text("Kept best \(Int(settings.keepBestPercent))% · \(settings.stackMethod.rawValue) combine\(settings.roi != nil ? " · tracked a selected object" : "")\(settings.alignRGBChannels ? " · RGB channels aligned" : "")\(settings.singleShotAdjustments != nil ? " · single shot touch-up applied" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
