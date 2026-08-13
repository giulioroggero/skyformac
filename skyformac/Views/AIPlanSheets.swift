import SwiftUI

/// "Ask AI to plan a project" — a one-line goal in, a name + goal + a full set of suggested
/// sessions out (`OllamaPlanner.planProject`), which the user reviews before anything is created;
/// nothing is added to the project until "Create Sessions" is pressed.
struct AIPlanProjectSheet: View {
    let project: Project
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var goalText: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var suggestion: OllamaPlanner.ProjectPlanSuggestion?

    init(project: Project, cameraManager: CameraManager) {
        self.project = project
        self.cameraManager = cameraManager
        self._goalText = State(initialValue: project.goal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask AI to Plan This Project").font(.headline)
            TextField("Goal", text: $goalText, prompt: Text("e.g. see as many Messier objects as possible this spring"))

            if isLoading {
                ProgressView("Asking Ollama…")
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            } else if let suggestion {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.name).font(.title3.bold())
                        Text(suggestion.goal).foregroundStyle(.secondary)
                        ForEach(Array(suggestion.sessions.enumerated()), id: \.offset) { _, session in
                            VStack(alignment: .leading) {
                                Text(session.name).font(.headline)
                                Text(session.goal).font(.caption).foregroundStyle(.secondary)
                                Text(session.plannedObjects.joined(separator: ", ")).font(.caption2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Ask") { Task { await ask() } }
                    .disabled(goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                if suggestion != nil {
                    Button("Create Sessions") { createSessions() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(width: 420, height: 380)
    }

    private func ask() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            suggestion = try await cameraManager.ollamaPlanner.planProject(goal: goalText)
        } catch {
            errorMessage = "Couldn't get a plan from Ollama — make sure it's running locally. (\(String(describing: error)))"
        }
    }

    private func createSessions() {
        guard let suggestion else { return }
        var updated = project
        if updated.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.name = suggestion.name }
        if updated.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { updated.goal = suggestion.goal }
        for planned in suggestion.sessions {
            updated.sessions.insert(
                Session.newSession(name: planned.name, goal: planned.goal, plannedObjects: planned.plannedObjects), at: 0
            )
        }
        try? cameraManager.projectsLibrary.save(updated)
        dismiss()
    }
}

/// Same idea as `AIPlanProjectSheet`, but for a single session — "Apply" overwrites this
/// session's own name/goal/planned objects with the suggestion (after the user has seen it).
struct AIPlanSessionSheet: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var goalText: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var suggestion: OllamaPlanner.SessionPlanSuggestion?

    init(project: Project, session: Session, cameraManager: CameraManager) {
        self.project = project
        self.session = session
        self.cameraManager = cameraManager
        self._goalText = State(initialValue: session.goal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask AI to Plan This Session").font(.headline)
            TextField("Goal", text: $goalText, prompt: Text("e.g. see M13, M57, Saturn"))

            if isLoading {
                ProgressView("Asking Ollama…")
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            } else if let suggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggestion.name).font(.title3.bold())
                    Text(suggestion.goal).foregroundStyle(.secondary)
                    Text(suggestion.plannedObjects.joined(separator: ", "))
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Ask") { Task { await ask() } }
                    .disabled(goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                if suggestion != nil {
                    Button("Apply") { apply() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(width: 380, height: 300)
    }

    private func ask() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            suggestion = try await cameraManager.ollamaPlanner.planSession(goal: goalText)
        } catch {
            errorMessage = "Couldn't get a plan from Ollama — make sure it's running locally. (\(String(describing: error)))"
        }
    }

    private func apply() {
        guard let suggestion else { return }
        var updatedProject = project
        guard let index = updatedProject.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        updatedProject.sessions[index].name = suggestion.name
        updatedProject.sessions[index].goal = suggestion.goal
        updatedProject.sessions[index].plannedObjects = suggestion.plannedObjects
        try? cameraManager.projectsLibrary.save(updatedProject)
        dismiss()
    }
}
