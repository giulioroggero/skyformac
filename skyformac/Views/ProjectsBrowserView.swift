import SwiftUI

/// Where a push inside the Projects browser's `NavigationStack` can go. Routes carry IDs, not
/// `Project`/`Session` values — those are plain structs, not stable references, so each
/// destination re-fetches the current value from `CameraManager.projectsLibrary` on every body
/// evaluation instead of holding a snapshot that could go stale (a rename two pages back, say).
private enum ProjectsRoute: Hashable {
    case projectsList
    case project(Project.ID)
    case sessionHistory(Project.ID, Session.ID)
    case capture(Project.ID, Session.ID, CaptureRecord.ID)
    case archived
    case recentlyDeleted
    case equipment(startsCreating: Bool)
    case equipmentSystem(EquipmentSystem.ID)
    case insights
}

/// The iMovie-style library for the Projects feature and — since `RootView` shows this whenever
/// no session is running — the app's actual main-window content until one is. A plain drill-down
/// stack of full-width pages (no side margins — see `PageSection`), not a persistent multi-column
/// browser: **Home** (every project), **Project Detail** (one project's own metadata plus its
/// session list — `ProjectDetailPane`), **Session** (one session's history/timeline —
/// `SessionDetailPane`), and **Capture** (one timeline thumbnail's own full-size preview/info —
/// `CaptureDetailPage`), matching the project → session → session-execution hierarchy this
/// feature is built around. Running a session is the one thing that leaves this stack entirely,
/// switching the whole window to `ContentView` instead (see `RootView`). Creating a project is
/// the other exception — the one modal in the feature (`NewProjectSheet`).
struct ProjectsBrowserView: View {
    var cameraManager: CameraManager

    @State private var path: [ProjectsRoute] = []
    @State private var isShowingNewProjectSheet = false
    @State private var isShowingQuickStartSheet = false
    @State private var searchText = ""
    @State private var filter = ProjectFilterState()

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    /// Never includes archived or deleted projects — those have their own dedicated pages
    /// (`ArchivedProjectsPage`/`RecentlyDeletedPage`) precisely so the Home page itself always
    /// just shows what's actually active, the same way archiving/deleting mail or files works.
    private var visibleProjects: [Project] {
        let base = library.activeProjects.filter { !$0.isArchived }
        let filtered: [Project]
        if !searchText.isEmpty || filter.isActive {
            let matchingIDs = Set(ProjectSearch.search(
                base, text: searchText, dateRange: filter.dateRange,
                tag: filter.tag, equipmentSystemID: filter.equipmentSystemID, object: filter.object
            ).map(\.project.id))
            filtered = base.filter { matchingIDs.contains($0.id) }
        } else {
            filtered = base
        }
        // Favorites first — "keep them on top" — see `favoritesFirst(_:isFavorite:)`'s own doc
        // comment for why this is a shared top-level helper, not a private one-off here.
        return favoritesFirst(filtered, isFavorite: \.isFavorite)
    }

    /// Computed in a plain (non-`@ViewBuilder`) method rather than inline in `destination(for:)`
    /// — that function's own `@ViewBuilder` attribute applies its result-building transform to
    /// *every* `if`/`var` statement in its body, not just the final view expression, so ordinary
    /// "compute these two optional closures first" imperative code doesn't type-check there at
    /// all. A plain function call is just a normal expression, so it's unaffected.
    private func projectSiblingNavigation(around projectID: Project.ID) -> (previous: (() -> Void)?, next: (() -> Void)?) {
        let siblings = favoritesFirst(library.activeProjects.filter { !$0.isArchived }, isFavorite: \.isFavorite)
        guard let index = siblings.firstIndex(where: { $0.id == projectID }) else { return (nil, nil) }
        let previousID = index > 0 ? siblings[index - 1].id : nil
        let nextID = index + 1 < siblings.count ? siblings[index + 1].id : nil
        return (
            previousID.map { id in { path[path.count - 1] = .project(id) } },
            nextID.map { id in { path[path.count - 1] = .project(id) } }
        )
    }

    private func sessionSiblingNavigation(in project: Project, around sessionID: Session.ID) -> (previous: (() -> Void)?, next: (() -> Void)?) {
        let siblings = favoritesFirst(project.sessions, isFavorite: \.isFavorite)
        guard let index = siblings.firstIndex(where: { $0.id == sessionID }) else { return (nil, nil) }
        let previousID = index > 0 ? siblings[index - 1].id : nil
        let nextID = index + 1 < siblings.count ? siblings[index + 1].id : nil
        let projectID = project.id
        return (
            previousID.map { id in { path[path.count - 1] = .sessionHistory(projectID, id) } },
            nextID.map { id in { path[path.count - 1] = .sessionHistory(projectID, id) } }
        )
    }

    /// Newest first — matches `TimelineStripView`'s own display order.
    private func captureSiblingNavigation(
        projectID: Project.ID, sessionID: Session.ID, session: Session, around captureID: CaptureRecord.ID
    ) -> (previous: (() -> Void)?, next: (() -> Void)?) {
        let siblings = session.captures.sorted { $0.date > $1.date }
        guard let index = siblings.firstIndex(where: { $0.id == captureID }) else { return (nil, nil) }
        let previousID = index > 0 ? siblings[index - 1].id : nil
        let nextID = index + 1 < siblings.count ? siblings[index + 1].id : nil
        return (
            previousID.map { id in { path[path.count - 1] = .capture(projectID, sessionID, id) } },
            nextID.map { id in { path[path.count - 1] = .capture(projectID, sessionID, id) } }
        )
    }

    private var insightsData: InsightsData {
        InsightsData.build(
            projects: library.activeProjects, equipmentSystems: cameraManager.equipmentLibrary.systems,
            knownObjects: ObservedObjectCatalog.allKnownObjectNames(projects: library.activeProjects), now: Date()
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            DashboardHomeView(
                cameraManager: cameraManager, projects: library.activeProjects.filter { !$0.isArchived },
                insights: insightsData,
                onOpenProjects: { path.append(.projectsList) },
                onSelectProject: { path.append(.project($0.id)) },
                onOpenSession: { project, session in path.append(contentsOf: [.project(project.id), .sessionHistory(project.id, session.id)]) },
                onNewProject: { isShowingNewProjectSheet = true },
                onQuickStart: { isShowingQuickStartSheet = true },
                onShowEquipment: { path.append(.equipment(startsCreating: false)) },
                onShowInsights: { path.append(.insights) },
                onShowSettings: { cameraManager.isSettingsPresented = true }
            )
            .navigationDestination(for: ProjectsRoute.self) { route in
                destination(for: route)
            }
        }
        .sheet(isPresented: $isShowingNewProjectSheet) {
            NewProjectSheet(cameraManager: cameraManager) { project in
                path = [.project(project.id)]
            }
        }
        .sheet(isPresented: $isShowingQuickStartSheet) {
            QuickStartSheet(cameraManager: cameraManager)
        }
        .onAppear {
            // Reopening the browser (via "End Session", say) lands back exactly where that
            // session was running from — the same project's detail page, and (via
            // `lastEndedSessionID`) that same session's now-updated history — rather than the
            // top of the whole project list.
            if let project = cameraManager.activeProject {
                path = [.project(project.id)]
                if let lastEnded = cameraManager.lastEndedSessionID {
                    path.append(.sessionHistory(project.id, lastEnded))
                    cameraManager.lastEndedSessionID = nil
                }
            }
            if cameraManager.isCreatingNewProjectRequested {
                cameraManager.isCreatingNewProjectRequested = false
                isShowingNewProjectSheet = true
            }
            if cameraManager.isQuickStartRequested {
                cameraManager.isQuickStartRequested = false
                isShowingQuickStartSheet = true
            }
            consumePendingNavigationRequests()
        }
        // `onAppear` alone only fires when this whole view (re)appears — i.e. coming back from
        // camera mode. "Show All Projects"/"Equipment" can just as easily be picked from the menu
        // bar while the browser is already showing (browsing a project's own detail page, say), so
        // these also need an `onChange` path to actually take effect in that case.
        .onChange(of: cameraManager.isShowingAllProjectsRequested) { _, _ in consumePendingNavigationRequests() }
        .onChange(of: cameraManager.isShowingEquipmentRequested) { _, _ in consumePendingNavigationRequests() }
        .onChange(of: cameraManager.isAddingNewEquipmentRequested) { _, _ in consumePendingNavigationRequests() }
        // This browser's own minWidth combines with the AI sidebar's default width (320, plus a
        // 6pt resize handle) to become the WHOLE WINDOW's effective minimum width, since RootView
        // lays both out side by side in one HStack — 820 previously meant a forced minimum of
        // 1146pt. On a screen smaller than that (a modest external display, an older/smaller
        // laptop screen, or — how this was actually caught — a CI runner's 1024×768 virtual
        // display), the window is forced partially off-screen, taking the trailing toolbar
        // button and the rightmost "Common Tasks" tiles out of reach entirely, not just visually
        // cramped. 600 (a total of 926pt with the sidebar) comfortably fits a 1024pt-wide screen.
        .frame(minWidth: 600, minHeight: 600)
    }

    /// "Project → Show All Projects" / "Equipment → View" / "Equipment → Add New" — each just sets
    /// a `CameraManager` flag (so the menu bar doesn't need to know this view's private
    /// `NavigationStack` exists at all) that this consumes and clears here, replacing the whole
    /// path rather than appending — these should jump straight there regardless of whatever page
    /// was showing before, not stack on top of it.
    private func consumePendingNavigationRequests() {
        if cameraManager.isShowingAllProjectsRequested {
            cameraManager.isShowingAllProjectsRequested = false
            path = [.projectsList]
        }
        if cameraManager.isShowingEquipmentRequested {
            cameraManager.isShowingEquipmentRequested = false
            path = [.equipment(startsCreating: false)]
        }
        if cameraManager.isAddingNewEquipmentRequested {
            cameraManager.isAddingNewEquipmentRequested = false
            path = [.equipment(startsCreating: true)]
        }
    }

    @ViewBuilder
    private func destination(for route: ProjectsRoute) -> some View {
        switch route {
        case .projectsList:
            ProjectsHomeView(
                projects: visibleProjects, searchText: $searchText, filter: $filter,
                activeProjectID: cameraManager.activeProject?.id, store: cameraManager.projectStore,
                equipmentLibrary: cameraManager.equipmentLibrary, allProjects: library.activeProjects,
                onSelectProject: { path.append(.project($0.id)) },
                onNewProject: { isShowingNewProjectSheet = true },
                onQuickStart: { isShowingQuickStartSheet = true },
                onShowArchived: { path.append(.archived) },
                onShowRecentlyDeleted: { path.append(.recentlyDeleted) },
                onShowEquipment: { path.append(.equipment(startsCreating: false)) },
                onBulkArchive: { ids in
                    for id in ids {
                        guard let project = library.projects.first(where: { $0.id == id }) else { continue }
                        try? library.setArchived(true, for: project)
                    }
                },
                onBulkDelete: { ids in
                    for id in ids {
                        guard let project = library.projects.first(where: { $0.id == id }) else { continue }
                        try? library.softDelete(project)
                    }
                },
                onToggleFavorite: { project in
                    var updated = project
                    updated.isFavorite.toggle()
                    try? library.save(updated)
                },
                onSelectSession: { project, session in
                    path.append(contentsOf: [.project(project.id), .sessionHistory(project.id, session.id)])
                }
            )
        case .project(let projectID):
            if let project = library.projects.first(where: { $0.id == projectID }) {
                let nav = projectSiblingNavigation(around: projectID)
                ProjectDetailPane(
                    project: project, cameraManager: cameraManager,
                    onShowSessionHistory: { session in path.append(.sessionHistory(projectID, session.id)) },
                    onBack: { path.removeLast() },
                    onHome: { path.removeAll() },
                    onProjectDeleted: { path.removeAll() },
                    onPreviousProject: nav.previous,
                    onNextProject: nav.next
                )
            } else {
                ContentUnavailableView("Project No Longer Exists", systemImage: "folder")
            }
        case .sessionHistory(let projectID, let sessionID):
            if let project = library.projects.first(where: { $0.id == projectID }),
               let session = project.sessions.first(where: { $0.id == sessionID }) {
                let nav = sessionSiblingNavigation(in: project, around: sessionID)
                SessionDetailPane(
                    project: project, session: session, cameraManager: cameraManager,
                    onBack: { path.removeLast() },
                    onHome: { path.removeAll() },
                    onSelectCapture: { capture in path.append(.capture(projectID, sessionID, capture.id)) },
                    onSessionCreated: { newSession in path.append(.sessionHistory(projectID, newSession.id)) },
                    onPreviousSession: nav.previous,
                    onNextSession: nav.next
                )
            } else {
                ContentUnavailableView("Session No Longer Exists", systemImage: "calendar")
            }
        case .capture(let projectID, let sessionID, let captureID):
            if let project = library.projects.first(where: { $0.id == projectID }),
               let session = project.sessions.first(where: { $0.id == sessionID }),
               let capture = session.captures.first(where: { $0.id == captureID }) {
                let nav = captureSiblingNavigation(projectID: projectID, sessionID: sessionID, session: session, around: captureID)
                CaptureDetailPage(
                    project: project, session: session, capture: capture, cameraManager: cameraManager,
                    onBack: { path.removeLast() },
                    onHome: { path.removeAll() },
                    onPreviousCapture: nav.previous,
                    onNextCapture: nav.next
                )
            } else {
                ContentUnavailableView("Capture No Longer Exists", systemImage: "photo")
            }
        case .archived:
            ArchivedProjectsPage(
                projects: library.activeProjects.filter(\.isArchived),
                onSelect: { path.append(.project($0.id)) },
                onUnarchive: { try? library.setArchived(false, for: $0) }
            )
        case .recentlyDeleted:
            RecentlyDeletedPage(
                projects: library.deletedProjects,
                onRestore: { try? library.restore($0) },
                onDeletePermanently: { try? library.permanentlyDelete($0) },
                onDeleteAllPermanently: { library.permanentlyDeleteAllDeleted() }
            )
        case .equipment(let startsCreating):
            EquipmentPage(
                library: cameraManager.equipmentLibrary,
                onSelect: { system in path.append(.equipmentSystem(system.id)) },
                startsCreatingSystem: startsCreating
            )
        case .equipmentSystem(let systemID):
            if let system = cameraManager.equipmentLibrary.system(withID: systemID) {
                EquipmentSystemEditorPage(
                    system: system, library: cameraManager.equipmentLibrary,
                    onBack: { path.removeLast() }
                )
            } else {
                ContentUnavailableView("Equipment System No Longer Exists", systemImage: "wrench.and.screwdriver")
            }
        case .insights:
            InsightsView(data: insightsData, onBack: { path.removeLast() })
        }
    }
}

/// The Home page's search facets beyond free text — every one optional/inactive by default, so
/// this never changes what shows unless the user actually picks something.
struct ProjectFilterState: Equatable {
    var tag: String?
    var object: String?
    var equipmentSystemID: UUID?
    var hasDateRange = false
    var startDate = Date()
    var endDate = Date()

    var dateRange: ClosedRange<Date>? {
        guard hasDateRange, startDate <= endDate else { return nil }
        return startDate...endDate
    }

    var isActive: Bool { tag != nil || object != nil || equipmentSystemID != nil || hasDateRange }

    mutating func clear() {
        self = ProjectFilterState()
    }
}

/// The Archived Projects page — every archived (but not deleted) project, tappable to open its
/// own Project Detail page like any other project; "Unarchive" restores it to the Home page.
private struct ArchivedProjectsPage: View {
    let projects: [Project]
    var onSelect: (Project) -> Void
    var onUnarchive: (Project) -> Void

    var body: some View {
        List {
            ForEach(projects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name.isEmpty ? "Untitled Project" : project.name).font(.headline)
                        Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unarchive", systemImage: "archivebox") { onUnarchive(project) }
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect(project) }
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView("No Archived Projects", systemImage: "archivebox")
            }
        }
        .navigationTitle("Archived Projects")
    }
}

/// The Recently Deleted page — every soft-deleted project still within its 30-day grace period.
/// Deliberately not tappable into its own Project Detail page (unlike `ArchivedProjectsPage`) —
/// a deleted project isn't something to keep editing, just restore or purge for good.
private struct RecentlyDeletedPage: View {
    let projects: [Project]
    var onRestore: (Project) -> Void
    var onDeletePermanently: (Project) -> Void
    var onDeleteAllPermanently: () -> Void

    var body: some View {
        List {
            ForEach(projects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name.isEmpty ? "Untitled Project" : project.name).font(.headline)
                        if let expiration = project.gracePeriodExpirationDate {
                            Text("Deleted permanently \(expiration.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Restore", systemImage: "arrow.uturn.backward") { onRestore(project) }
                    Button("Delete Permanently", systemImage: "trash", role: .destructive) { onDeletePermanently(project) }
                }
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView("Nothing Recently Deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            ToolbarItem {
                Button("Delete All Permanently", systemImage: "trash.fill", role: .destructive, action: onDeleteAllPermanently)
                    .disabled(projects.isEmpty)
            }
        }
    }
}

/// Thumbnail cards vs. a data-dense table — both list the same projects, just traded off between
/// "recognize it by its cover image" (the iMovie-style default) and "compare a lot of projects by
/// their actual numbers at once."
private enum ProjectsHomeViewMode: String {
    case thumbnail
    case table
    case atlas
}

/// The Projects browser's Home page — every project, full window, nothing else. Tapping one
/// pushes its Project Detail page onto the stack.
private struct ProjectsHomeView: View {
    let projects: [Project]
    @Binding var searchText: String
    @Binding var filter: ProjectFilterState
    let activeProjectID: Project.ID?
    let store: ProjectStore
    let equipmentLibrary: EquipmentLibrary
    /// Every active (non-archived, non-deleted) project, unfiltered — what the Filters popover's
    /// tag/object pickers draw their choices from, since those choices should reflect everything
    /// that exists, not just whatever the current filter/search already narrowed `projects` to.
    let allProjects: [Project]
    var onSelectProject: (Project) -> Void
    var onNewProject: () -> Void
    var onQuickStart: () -> Void
    var onShowArchived: () -> Void
    var onShowRecentlyDeleted: () -> Void
    var onShowEquipment: () -> Void
    /// Archives/soft-deletes every project whose ID is in the set — the Home page's own bulk
    /// actions, so multi-select doesn't need its own dedicated Archive/Delete implementation
    /// beyond looping the existing single-project ones the Project Detail page already uses.
    var onBulkArchive: (Set<Project.ID>) -> Void
    var onBulkDelete: (Set<Project.ID>) -> Void
    var onToggleFavorite: (Project) -> Void
    var onSelectSession: (Project, Session) -> Void

    @State private var isShowingFilters = false
    /// Shared by both view modes so switching between Thumbnails/Table mid-selection doesn't lose
    /// it — a `Table`'s own multi-select (click, ⌘-click, shift-click) already writes into this
    /// directly; the thumbnail grid only reads/writes it while `isSelecting` is on, since a plain
    /// tap there normally opens the project instead.
    @State private var selectedIDs: Set<Project.ID> = []
    @State private var isSelecting = false

    /// Persisted like `ControlsPanelView`'s own sidebar-tab choice — a view mode picked once
    /// shouldn't reset back to the default every relaunch — but thumbnail is what a fresh install
    /// (no stored value yet) actually shows.
    @AppStorage("projectsHomeViewMode") private var viewModeRaw = ProjectsHomeViewMode.thumbnail.rawValue
    private var viewMode: ProjectsHomeViewMode { ProjectsHomeViewMode(rawValue: viewModeRaw) ?? .thumbnail }

    var body: some View {
        VStack(spacing: 0) {
            if !selectedIDs.isEmpty {
                bulkActionBar
            }
            Group {
                switch viewMode {
                case .thumbnail:
                    ProjectsThumbnailGrid(
                        projects: projects, activeProjectID: activeProjectID, store: store,
                        isSelecting: isSelecting, selectedIDs: $selectedIDs,
                        onSelect: onSelectProject, onNewProject: onNewProject, onQuickStart: onQuickStart,
                        onToggleFavorite: onToggleFavorite
                    )
                case .table:
                    ProjectsTableView(
                        projects: projects, activeProjectID: activeProjectID, store: store, selectedIDs: $selectedIDs,
                        onSelect: onSelectProject
                    )
                case .atlas:
                    // Its own dedicated date/project/object filters, independent of the page's
                    // Filters popover — operates over every active project, not just whatever
                    // that popover/search already narrowed `projects` down to.
                    AtlasView(projects: allProjects, onSelectSession: onSelectSession)
                }
            }
            .overlay {
                // Atlas has its own empty-state messaging (`AtlasView`'s "No Placeable Sessions")
                // scoped to *placeable* sessions specifically, not "no projects at all" — showing
                // this one on top of it as well would be redundant/confusing.
                if viewMode != .atlas && projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects Yet", systemImage: "folder",
                        description: Text("Create a project to get started.")
                    )
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search goal, objects, tags…")
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $viewModeRaw) {
                    Label("Thumbnails", systemImage: "square.grid.2x2").tag(ProjectsHomeViewMode.thumbnail.rawValue)
                    Label("Table", systemImage: "tablecells").tag(ProjectsHomeViewMode.table.rawValue)
                    Label("Atlas", systemImage: "map").tag(ProjectsHomeViewMode.atlas.rawValue)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
            }
            ToolbarItem {
                // Only the thumbnail grid needs an explicit mode toggle — a `Table` already
                // supports multi-select natively via click/⌘-click/shift-click without one.
                Button(isSelecting ? "Done Selecting" : "Select", systemImage: isSelecting ? "checkmark.circle.fill" : "checkmark.circle") {
                    isSelecting.toggle()
                    if !isSelecting { selectedIDs.removeAll() }
                }
                .help("Select multiple projects for bulk actions (archive, delete)")
            }
            ToolbarItem {
                Button("Filters", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                    isShowingFilters = true
                }
                .help("Filter by tag, observed object, equipment, or date range")
                .popover(isPresented: $isShowingFilters) {
                    FiltersPopoverView(filter: $filter, allProjects: allProjects, equipmentLibrary: equipmentLibrary)
                }
            }
            ToolbarItem {
                Button("Equipment", systemImage: "wrench.and.screwdriver", action: onShowEquipment)
                    .help("Manage cameras, mounts, optical tubes, and other gear as named systems")
            }
            ToolbarItem {
                Button("Archived", systemImage: "archivebox", action: onShowArchived)
                    .help("Projects you've archived — still around, just out of the way")
            }
            ToolbarItem {
                Button("Recently Deleted", systemImage: "trash", action: onShowRecentlyDeleted)
                    .help("Deleted projects still within their 30-day grace period — restore or delete them for good")
            }
            ToolbarItem {
                Button("Quick Start…", systemImage: "bolt.fill", action: onQuickStart)
                    .help("Pick a common target (a planet, the Moon, a Messier object) — creates a project and session for it and opens the camera view")
            }
            ToolbarItem {
                Button("New Project…", systemImage: "plus", action: onNewProject)
            }
        }
    }

    /// Shown above the grid/table the moment anything's selected — "N selected," Archive/Delete
    /// acting on the whole set at once, and Clear. `Delete` still only soft-deletes (30-day grace
    /// period), same as a single project's own Danger Zone — bulk selection doesn't get a
    /// shortcut around that safety net.
    private var bulkActionBar: some View {
        HStack {
            Text("\(selectedIDs.count) selected").font(.subheadline)
            Spacer()
            Button("Archive", systemImage: "archivebox") {
                onBulkArchive(selectedIDs)
                selectedIDs.removeAll()
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                onBulkDelete(selectedIDs)
                selectedIDs.removeAll()
            }
            Button("Clear") { selectedIDs.removeAll() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background.secondary)
    }
}

/// The Home page toolbar's Filters popover — tag, observed object, equipment system, and a date
/// range, each independently optional; combined with free-text search (all AND'd together) via
/// `ProjectSearch.search`.
private struct FiltersPopoverView: View {
    @Binding var filter: ProjectFilterState
    let allProjects: [Project]
    let equipmentLibrary: EquipmentLibrary

    private var knownTags: [String] {
        Array(Set(allProjects.flatMap(\.tags) + allProjects.flatMap { $0.sessions.flatMap(\.tags) })).sorted()
    }

    private var knownObjects: [String] {
        ObservedObjectCatalog.allKnownObjectNames(projects: allProjects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters").font(.headline)

            Picker("Tag", selection: $filter.tag) {
                Text("Any").tag(String?.none)
                ForEach(knownTags, id: \.self) { tag in
                    Text(tag).tag(String?.some(tag))
                }
            }

            Picker("Object", selection: $filter.object) {
                Text("Any").tag(String?.none)
                ForEach(knownObjects, id: \.self) { object in
                    Text(object).tag(String?.some(object))
                }
            }

            Picker("Equipment", selection: $filter.equipmentSystemID) {
                Text("Any").tag(UUID?.none)
                ForEach(equipmentLibrary.systems) { system in
                    Text(system.name).tag(UUID?.some(system.id))
                }
            }

            Toggle("Date Range", isOn: $filter.hasDateRange)
            if filter.hasDateRange {
                DatePicker("From", selection: $filter.startDate, displayedComponents: .date)
                DatePicker("To", selection: $filter.endDate, displayedComponents: .date)
            }

            Button("Clear Filters") { filter.clear() }
                .disabled(!filter.isActive)
        }
        .padding()
        .frame(width: 280)
    }
}

/// The default view: a grid of cards, each with a cover thumbnail (the project's single most
/// recent capture with one — see `ProjectStore.mostRecentThumbnailURL`) and its key stats. Two
/// action tiles — **New Project** and **Quick Start** — lead the grid, the same size and shape as
/// every project card, so starting something new is exactly as visible as any existing project,
/// not just a small toolbar button easy to miss.
private struct ProjectsThumbnailGrid: View {
    let projects: [Project]
    let activeProjectID: Project.ID?
    let store: ProjectStore
    /// While on, tapping a card toggles it into `selectedIDs` instead of opening it — the
    /// Quick Start/New Project tiles are hidden too, since neither makes sense to "select."
    let isSelecting: Bool
    @Binding var selectedIDs: Set<Project.ID>
    var onSelect: (Project) -> Void
    var onNewProject: () -> Void
    var onQuickStart: () -> Void
    var onToggleFavorite: (Project) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                if !isSelecting {
                    ActionCard(
                        title: "Quick Start", icon: "bolt.fill", tint: .orange,
                        subtitle: "A planet, the Moon, or a deep-sky object — ready to run", action: onQuickStart
                    )
                }
                ForEach(projects) { project in
                    ProjectCard(
                        project: project, isOpen: project.id == activeProjectID, store: store,
                        showsSelectionIndicator: isSelecting, isSelected: selectedIDs.contains(project.id)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelecting {
                            if selectedIDs.contains(project.id) { selectedIDs.remove(project.id) }
                            else { selectedIDs.insert(project.id) }
                        } else {
                            onSelect(project)
                        }
                    }
                    .contextMenu {
                        Button(project.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            onToggleFavorite(project)
                        }
                    }
                }
                if !isSelecting {
                    ActionCard(title: "New Project", icon: "plus", tint: .accentColor, action: onNewProject)
                }
            }
            .padding(16)
        }
    }
}

/// A "New Project"/"Quick Start"-shaped tile — same footprint as a `ProjectCard` (so the grid
/// reads as one consistent row of tiles, not an outlier), a big tinted icon standing in for a
/// cover thumbnail, and a dashed border marking it as "start something," not an existing project.
struct ActionCard: View {
    let title: String
    let icon: String
    let tint: Color
    var subtitle: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(tint.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
                    Image(systemName: icon)
                        .font(.system(size: 36))
                        .foregroundStyle(tint)
                }
                .frame(height: 130)

                Text(title).font(.headline)
                Text(subtitle ?? "Start something new").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(10)
            // A fixed width — without one, each card's width is purely intrinsic (whichever of
            // title/subtitle is longer on one line), so "Equipment"/"Insights"/"Settings" (short
            // titles, varying subtitle lengths) ended up visibly narrower than "New Project"/
            // "All Projects." Every "Common Tasks" card should read as one uniform row of tiles.
            .frame(width: 180, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

struct ProjectCard: View {
    let project: Project
    let isOpen: Bool
    let store: ProjectStore
    /// Both default `false` so every other place this card is reused (the Dashboard's "Recent
    /// Projects," say) doesn't need to know selection exists at all. `showsSelectionIndicator`
    /// is the Home page's bulk-select mode being on at all (draws an empty circle so it's obvious
    /// the card is tappable-to-select); `isSelected` is this particular card's own state.
    var showsSelectionIndicator: Bool = false
    var isSelected: Bool = false

    private var thumbnailURL: URL? { store.mostRecentThumbnailURL(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnailURL, let image = ThumbnailCache.image(at: thumbnailURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                }
                if isOpen {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if showsSelectionIndicator {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .background(Circle().fill(.background))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: 130)
            .clipped()

            HStack(spacing: 4) {
                Text(project.name.isEmpty ? "Untitled Project" : project.name)
                    .font(.headline)
                    .lineLimit(1)
                if project.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                }
            }
            if !project.goal.isEmpty {
                Text(project.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack(spacing: 10) {
                Label("\(project.sessions.count)", systemImage: "calendar").help("Sessions")
                Label("\(project.totalCaptureCount)", systemImage: "camera").help("Captures")
                Label(ByteCountFormatter.string(fromByteCount: store.diskUsage(for: project), countStyle: .file), systemImage: "internaldrive")
                    .help("Disk usage")
                if let location = project.location {
                    Label(location.displayName, systemImage: "location").lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Text(project.lastActivityDate, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if !project.tags.isEmpty {
                Text(project.tags.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .opacity(project.isArchived ? 0.5 : 1)
    }
}

/// The data-dense alternative: every project as a table row, sortable by any column — for
/// comparing a lot of projects by their actual numbers rather than recognizing them by a cover
/// image.
private struct ProjectsTableView: View {
    let projects: [Project]
    let activeProjectID: Project.ID?
    let store: ProjectStore
    /// A `Table`'s own selection is multi-select out of the box with a `Set` binding (click,
    /// ⌘-click, shift-click) — no separate "select mode" needed the way the thumbnail grid's
    /// plain taps do, since a single click here already just selects rather than opening.
    @Binding var selectedIDs: Set<Project.ID>
    var onSelect: (Project) -> Void

    @State private var sortOrder = [KeyPathComparator(\Project.name)]

    private var sortedProjects: [Project] {
        projects.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedProjects, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { project in
                HStack(spacing: 4) {
                    if project.id == activeProjectID {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.caption)
                    }
                    Text(project.name.isEmpty ? "Untitled Project" : project.name)
                        .opacity(project.isArchived ? 0.5 : 1)
                }
            }
            TableColumn("Goal", value: \.goal)
            TableColumn("Sessions") { Text("\($0.sessions.count)") }
                .width(70)
            TableColumn("Captures") { Text("\($0.totalCaptureCount)") }
                .width(70)
            TableColumn("Disk Usage") { project in
                Text(ByteCountFormatter.string(fromByteCount: store.diskUsage(for: project), countStyle: .file))
            }
            .width(90)
            TableColumn("Location") { Text($0.location?.displayName ?? "—") }
            TableColumn("Tags") { Text($0.tags.joined(separator: ", ")) }
            TableColumn("Last Activity", value: \.lastActivityDate) { project in
                Text(project.lastActivityDate, format: .relative(presentation: .named))
            }
        }
        .contextMenu(forSelectionType: Project.ID.self) { _ in
            // No per-row menu items yet — Archive/Delete live on the Project Detail page instead.
        } primaryAction: { ids in
            guard let id = ids.first, let project = projects.first(where: { $0.id == id }) else { return }
            onSelect(project)
        }
    }
}

/// The one modal in the Projects feature: collects a required name (and an optional goal) before
/// creating anything — there's no more "unnamed project" that exists in the browser waiting to be
/// named later, since the project name needs to be visible everywhere from the moment it exists.
private struct NewProjectSheet: View {
    var cameraManager: CameraManager
    var onCreate: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var goal = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project").font(.headline)
            TextField("Name", text: $name, prompt: Text("e.g. Messier Marathon"))
                .onSubmit(create)
            TextField("Goal (optional)", text: $goal, prompt: Text("What are you trying to observe or achieve?"), axis: .vertical)
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
        .frame(width: 360, height: 200)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        let project = cameraManager.projectsLibrary.createProject(name: trimmedName, goal: goal)
        try? cameraManager.projectsLibrary.save(project)
        onCreate(project)
        dismiss()
    }
}

/// Home page's "Quick Start" — pick a common target (a planet, the Moon, a curated deep-sky
/// object) and skip manually creating a project/session for a one-off outing: selecting a row
/// calls `CameraManager.quickStart(with:)` (creates both, applies the target's recommended setup)
/// and dismisses straight into the camera view — see `RootView`, which switches there the moment
/// `activeSession` becomes non-`nil`. Reuses `AcquisitionTarget.all`, the same curated
/// planetary/deep-sky list the Acquisition Wizard already offers, rather than a second list.
private struct QuickStartSheet: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    private var planetaryTargets: [AcquisitionTarget] { AcquisitionTarget.all.filter { if case .planetary = $0 { true } else { false } } }
    private var deepSkyTargets: [AcquisitionTarget] { AcquisitionTarget.all.filter { if case .deepSky = $0 { true } else { false } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Quick Start").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            List {
                Section("Planets & Moon") {
                    ForEach(planetaryTargets) { target in
                        QuickStartRow(target: target) { select(target) }
                    }
                }
                Section("Deep Sky") {
                    ForEach(deepSkyTargets) { target in
                        QuickStartRow(target: target) { select(target) }
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
    }

    private func select(_ target: AcquisitionTarget) {
        cameraManager.quickStart(with: target)
        dismiss()
    }
}

private struct QuickStartRow: View {
    let target: AcquisitionTarget
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: target.icon).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name).font(.body)
                    Text(target.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
