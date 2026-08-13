import SwiftUI

/// The iMovie-style "library" for the Projects feature — and, since `RootView` shows this
/// whenever no session is running, the app's actual main-window content until one is: a
/// three-column browser (projects, that project's sessions, the selected session's own detail/
/// timeline). Creating a project is the one thing that still happens in a small modal
/// (`NewProjectSheet`) — everything else here is the main window itself, not a sheet.
struct ProjectsBrowserView: View {
    var cameraManager: CameraManager

    @State private var searchText = ""
    @State private var selectedProjectID: Project.ID?
    @State private var selectedSessionID: Session.ID?
    @State private var showArchived = false
    @State private var isShowingNewProjectSheet = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    private var visibleProjects: [Project] {
        let base = library.projects.filter { showArchived || !$0.isArchived }
        guard !searchText.isEmpty else { return base }
        let matchingIDs = Set(ProjectSearch.search(base, text: searchText).map(\.project.id))
        return base.filter { matchingIDs.contains($0.id) }
    }

    private var selectedProject: Project? {
        guard let selectedProjectID else { return nil }
        return library.projects.first { $0.id == selectedProjectID }
    }

    private var selectedSession: Session? {
        guard let selectedSessionID else { return nil }
        return selectedProject?.sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        NavigationSplitView {
            ProjectSidebarView(
                projects: visibleProjects, searchText: $searchText, showArchived: $showArchived,
                selection: $selectedProjectID, activeProjectID: cameraManager.activeProject?.id,
                onNewProject: { isShowingNewProjectSheet = true }
            )
        } content: {
            if let project = selectedProject {
                ProjectDetailPane(
                    project: project, cameraManager: cameraManager, selectedSessionID: $selectedSessionID
                )
            } else {
                ContentUnavailableView(
                    "No Project Selected", systemImage: "folder",
                    description: Text(library.projects.isEmpty ? "Create a project to get started." : "Select a project from the list.")
                )
            }
        } detail: {
            if let project = selectedProject, let session = selectedSession {
                SessionDetailPane(project: project, session: session, cameraManager: cameraManager)
            } else {
                ContentUnavailableView("No Session Selected", systemImage: "calendar")
            }
        }
        .navigationTitle("Skyformac Projects")
        .frame(minWidth: 980, minHeight: 620)
        .sheet(isPresented: $isShowingNewProjectSheet) {
            NewProjectSheet(cameraManager: cameraManager) { project in
                selectedProjectID = project.id
            }
        }
        .onAppear {
            if selectedProjectID == nil {
                selectedProjectID = cameraManager.activeProject?.id ?? library.projects.first?.id
            }
            if selectedSessionID == nil, let lastEnded = cameraManager.lastEndedSessionID {
                selectedSessionID = lastEnded
                cameraManager.lastEndedSessionID = nil
            }
            if cameraManager.isCreatingNewProjectRequested {
                cameraManager.isCreatingNewProjectRequested = false
                isShowingNewProjectSheet = true
            }
        }
    }
}

private struct ProjectSidebarView: View {
    let projects: [Project]
    @Binding var searchText: String
    @Binding var showArchived: Bool
    @Binding var selection: Project.ID?
    let activeProjectID: Project.ID?
    var onNewProject: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(projects) { project in
                ProjectRow(project: project, isOpen: project.id == activeProjectID).tag(project.id)
            }
        }
        .searchable(text: $searchText, prompt: "Search goal, objects, tags…")
        .toolbar {
            ToolbarItem {
                Toggle("Show Archived", systemImage: "archivebox", isOn: $showArchived)
            }
            ToolbarItem {
                Button("New Project…", systemImage: "plus", action: onNewProject)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
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
            if isOpen {
                Spacer()
                Image(systemName: "record.circle.fill").foregroundStyle(.red).font(.caption)
            }
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
