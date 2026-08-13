import SwiftUI

/// Where a push inside the Projects browser's `NavigationStack` can go. Routes carry IDs, not
/// `Project`/`Session` values — those are plain structs, not stable references, so each
/// destination re-fetches the current value from `CameraManager.projectsLibrary` on every body
/// evaluation instead of holding a snapshot that could go stale (a rename two pages back, say).
private enum ProjectsRoute: Hashable {
    case project(Project.ID)
    case sessionHistory(Project.ID, Session.ID)
}

/// The iMovie-style library for the Projects feature and — since `RootView` shows this whenever
/// no session is running — the app's actual main-window content until one is. A plain drill-down
/// stack of pages, not a persistent multi-column browser: **Home** (every project), **Project
/// Detail** (one project's own metadata plus its session list — `ProjectDetailPane`), and
/// **Session History** (one already-run session's timeline — `SessionDetailPane`), matching the
/// project → session → session-execution hierarchy this feature is built around. Running a
/// session is the one thing that leaves this stack entirely, switching the whole window to
/// `ContentView` instead (see `RootView`). Creating a project is the other exception — the one
/// modal in the feature (`NewProjectSheet`).
struct ProjectsBrowserView: View {
    var cameraManager: CameraManager

    @State private var path: [ProjectsRoute] = []
    @State private var isShowingNewProjectSheet = false
    @State private var isShowingQuickStartSheet = false
    @State private var searchText = ""
    @State private var showArchived = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    private var visibleProjects: [Project] {
        let base = library.projects.filter { showArchived || !$0.isArchived }
        guard !searchText.isEmpty else { return base }
        let matchingIDs = Set(ProjectSearch.search(base, text: searchText).map(\.project.id))
        return base.filter { matchingIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ProjectsHomeView(
                projects: visibleProjects, searchText: $searchText, showArchived: $showArchived,
                activeProjectID: cameraManager.activeProject?.id, store: cameraManager.projectStore,
                onSelectProject: { path.append(.project($0.id)) },
                onNewProject: { isShowingNewProjectSheet = true },
                onQuickStart: { isShowingQuickStartSheet = true }
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
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    @ViewBuilder
    private func destination(for route: ProjectsRoute) -> some View {
        switch route {
        case .project(let projectID):
            if let project = library.projects.first(where: { $0.id == projectID }) {
                ProjectDetailPane(
                    project: project, cameraManager: cameraManager,
                    onShowSessionHistory: { session in path.append(.sessionHistory(projectID, session.id)) }
                )
            } else {
                ContentUnavailableView("Project No Longer Exists", systemImage: "folder")
            }
        case .sessionHistory(let projectID, let sessionID):
            if let project = library.projects.first(where: { $0.id == projectID }),
               let session = project.sessions.first(where: { $0.id == sessionID }) {
                SessionDetailPane(project: project, session: session, cameraManager: cameraManager)
            } else {
                ContentUnavailableView("Session No Longer Exists", systemImage: "calendar")
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
}

/// The Projects browser's Home page — every project, full window, nothing else. Tapping one
/// pushes its Project Detail page onto the stack.
private struct ProjectsHomeView: View {
    let projects: [Project]
    @Binding var searchText: String
    @Binding var showArchived: Bool
    let activeProjectID: Project.ID?
    let store: ProjectStore
    var onSelectProject: (Project) -> Void
    var onNewProject: () -> Void
    var onQuickStart: () -> Void

    /// Persisted like `ControlsPanelView`'s own sidebar-tab choice — a view mode picked once
    /// shouldn't reset back to the default every relaunch — but thumbnail is what a fresh install
    /// (no stored value yet) actually shows.
    @AppStorage("projectsHomeViewMode") private var viewModeRaw = ProjectsHomeViewMode.thumbnail.rawValue
    private var viewMode: ProjectsHomeViewMode { ProjectsHomeViewMode(rawValue: viewModeRaw) ?? .thumbnail }

    var body: some View {
        Group {
            switch viewMode {
            case .thumbnail:
                ProjectsThumbnailGrid(projects: projects, activeProjectID: activeProjectID, store: store, onSelect: onSelectProject)
            case .table:
                ProjectsTableView(projects: projects, activeProjectID: activeProjectID, onSelect: onSelectProject)
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView(
                    "No Projects Yet", systemImage: "folder",
                    description: Text("Create a project to get started.")
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search goal, objects, tags…")
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $viewModeRaw) {
                    Label("Thumbnails", systemImage: "square.grid.2x2").tag(ProjectsHomeViewMode.thumbnail.rawValue)
                    Label("Table", systemImage: "tablecells").tag(ProjectsHomeViewMode.table.rawValue)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
            }
            ToolbarItem {
                Toggle("Show Archived", systemImage: "archivebox", isOn: $showArchived)
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
}

/// The default view: a grid of cards, each with a cover thumbnail (the project's single most
/// recent capture with one — see `ProjectStore.mostRecentThumbnailURL`) and its key stats.
private struct ProjectsThumbnailGrid: View {
    let projects: [Project]
    let activeProjectID: Project.ID?
    let store: ProjectStore
    var onSelect: (Project) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(projects) { project in
                    ProjectCard(project: project, isOpen: project.id == activeProjectID, store: store)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(project) }
                }
            }
            .padding(16)
        }
    }
}

private struct ProjectCard: View {
    let project: Project
    let isOpen: Bool
    let store: ProjectStore

    private var thumbnailURL: URL? { store.mostRecentThumbnailURL(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
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
            }
            .frame(height: 130)
            .clipped()

            Text(project.name.isEmpty ? "Untitled Project" : project.name)
                .font(.headline)
                .lineLimit(1)
            if !project.goal.isEmpty {
                Text(project.goal).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack(spacing: 10) {
                Label("\(project.sessions.count)", systemImage: "calendar").help("Sessions")
                Label("\(project.totalCaptureCount)", systemImage: "camera").help("Captures")
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
    var onSelect: (Project) -> Void

    @State private var selection: Project.ID?
    @State private var sortOrder = [KeyPathComparator(\Project.name)]

    private var sortedProjects: [Project] {
        projects.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedProjects, selection: $selection, sortOrder: $sortOrder) {
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
