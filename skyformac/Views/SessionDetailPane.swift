import SwiftUI

/// The Projects browser's rightmost column: one session's metadata, its capture timeline, and
/// the controls that make it the active recording destination (`CameraManager.activeSession`).
struct SessionDetailPane: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager

    @State private var name: String
    @State private var goal: String
    @State private var plannedObjectsText: String
    @State private var isPlanningSession = false

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }
    private var isActive: Bool { cameraManager.activeSession?.id == session.id }

    init(project: Project, session: Session, cameraManager: CameraManager) {
        self.project = project
        self.session = session
        self.cameraManager = cameraManager
        self._name = State(initialValue: session.name)
        self._goal = State(initialValue: session.goal)
        self._plannedObjectsText = State(initialValue: session.plannedObjects.joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("Session") {
                TextField("Name", text: $name).onChange(of: name) { _, _ in save() }
                TextField("Goal", text: $goal, axis: .vertical).onChange(of: goal) { _, _ in save() }
                TextField("Planned objects (comma separated)", text: $plannedObjectsText)
                    .onChange(of: plannedObjectsText) { _, _ in savePlannedObjects() }
                LocationEditorView(project: project, session: session, cameraManager: cameraManager)
                HStack {
                    Button(isActive ? "Running Now" : "Run This Session", systemImage: "record.circle") {
                        cameraManager.setActive(project: project, session: session)
                    }
                    .disabled(isActive)
                    .help(session.captures.isEmpty ? "Starts this session — switches the main window to the camera view" : "Resumes capturing into this session")
                    Spacer()
                    Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningSession = true }
                }
            }

            Section("Tags") {
                TagsEditorView(tags: session.tags) { tags in
                    var updated = session
                    updated.tags = tags
                    applyAndSave(updated)
                }
            }

            Section("Notes") {
                NotesEditorView(notes: session.notes) { notes in
                    var updated = session
                    updated.notes = notes
                    applyAndSave(updated)
                }
            }

            Section("Timeline") {
                TimelineStripView(project: project, session: session, store: cameraManager.projectStore)
            }

            Section {
                Button("Archive Session", systemImage: "archivebox") {
                    try? library.setArchived(true, forSessionID: session.id, in: project)
                }
                Button("Delete Session", systemImage: "trash", role: .destructive) {
                    try? library.deleteSession(session.id, in: project)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(project.name.isEmpty ? "Untitled Project" : project.name) — \(session.name)")
        .sheet(isPresented: $isPlanningSession) {
            AIPlanSessionSheet(project: project, session: session, cameraManager: cameraManager)
        }
    }

    private func save() {
        var updated = session
        updated.name = name
        updated.goal = goal
        applyAndSave(updated)
    }

    private func savePlannedObjects() {
        var updated = session
        updated.plannedObjects = plannedObjectsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        applyAndSave(updated)
    }

    private func applyAndSave(_ updatedSession: Session) {
        var updatedProject = project
        guard let index = updatedProject.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        updatedProject.sessions[index] = updatedSession
        try? library.save(updatedProject)
    }

}
