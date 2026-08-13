import SwiftUI

/// The iMovie-style "library" window for the Projects feature: a three-column browser —
/// projects, that project's sessions, the selected session's own detail/timeline — presented as
/// a sheet from `ContentView` (this app is deliberately single-window; see `SkyformacApp`'s doc
/// comments) rather than a second `Scene`.
struct ProjectsBrowserView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedProjectID: Project.ID?
    @State private var selectedSessionID: Session.ID?
    @State private var showArchived = false

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
                selection: $selectedProjectID, library: library
            )
        } content: {
            if let project = selectedProject {
                ProjectDetailPane(
                    project: project, cameraManager: cameraManager, selectedSessionID: $selectedSessionID
                )
            } else {
                ContentUnavailableView("No Project Selected", systemImage: "folder")
            }
        } detail: {
            if let project = selectedProject, let session = selectedSession {
                SessionDetailPane(project: project, session: session, cameraManager: cameraManager)
            } else {
                ContentUnavailableView("No Session Selected", systemImage: "calendar")
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            library.ensureAtLeastOneProjectExists()
            if selectedProjectID == nil { selectedProjectID = library.projects.first?.id }
        }
    }
}

private struct ProjectSidebarView: View {
    let projects: [Project]
    @Binding var searchText: String
    @Binding var showArchived: Bool
    @Binding var selection: Project.ID?
    let library: ProjectsLibrary

    var body: some View {
        List(selection: $selection) {
            ForEach(projects) { project in
                ProjectRow(project: project).tag(project.id)
            }
        }
        .searchable(text: $searchText, prompt: "Search goal, objects, tags…")
        .toolbar {
            ToolbarItem {
                Toggle("Show Archived", systemImage: "archivebox", isOn: $showArchived)
            }
            ToolbarItem {
                Button("New Project", systemImage: "plus") {
                    let project = library.createProject()
                    selection = project.id
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name.isEmpty ? "Untitled Project" : project.name)
                .font(.headline)
                .foregroundStyle(project.name.isEmpty ? .secondary : .primary)
            if !project.goal.isEmpty {
                Text(project.goal).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .opacity(project.isArchived ? 0.5 : 1)
    }
}
