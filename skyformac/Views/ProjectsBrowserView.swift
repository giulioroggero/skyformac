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
                activeProjectID: cameraManager.activeProject?.id,
                onSelectProject: { path.append(.project($0.id)) },
                onNewProject: { isShowingNewProjectSheet = true }
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

/// The Projects browser's Home page — every project, full window, nothing else. Tapping one
/// pushes its Project Detail page onto the stack.
private struct ProjectsHomeView: View {
    let projects: [Project]
    @Binding var searchText: String
    @Binding var showArchived: Bool
    let activeProjectID: Project.ID?
    var onSelectProject: (Project) -> Void
    var onNewProject: () -> Void

    var body: some View {
        List {
            ForEach(projects) { project in
                ProjectRow(project: project, isOpen: project.id == activeProjectID)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectProject(project) }
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
                Toggle("Show Archived", systemImage: "archivebox", isOn: $showArchived)
            }
            ToolbarItem {
                Button("New Project…", systemImage: "plus", action: onNewProject)
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let isOpen: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name.isEmpty ? "Untitled Project" : project.name)
                    .font(.headline)
                if !project.goal.isEmpty {
                    Text(project.goal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if isOpen {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.caption)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .opacity(project.isArchived ? 0.5 : 1)
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
