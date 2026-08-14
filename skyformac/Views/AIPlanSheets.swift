import SwiftUI

/// "Ask AI to plan a project" — a one-line goal in (e.g. "the nicest Messier objects visible in
/// August from Orta San Giulio"), a name + goal + a full set of suggested sessions out
/// (`OllamaPlanner.planProject`, one session per object when the goal implies a list of them),
/// which the user reviews before anything is created; nothing is added to the project until
/// "Create Sessions" is pressed. The model can also come back asking a single clarifying question
/// instead of a plan — shown with its own answer field, looping back into another `planProject`
/// call with the answer folded in, until it actually produces a plan to review.
struct AIPlanProjectSheet: View {
    let project: Project
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var goalText: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var suggestion: OllamaPlanner.ProjectPlanSuggestion?
    @State private var pendingQuestion: String?
    @State private var answerText = ""
    /// Every question/answer round folded into the next `planProject` call's own context, on top
    /// of the project's location/current-date baseline — so the model doesn't ask the same thing
    /// twice and actually incorporates what it's told.
    @State private var accumulatedContext = ""

    init(project: Project, cameraManager: CameraManager) {
        self.project = project
        self.cameraManager = cameraManager
        self._goalText = State(initialValue: project.goal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask AI to Plan This Project").font(.headline)
            // A real free-text area, not a single line — a good project goal ("the nicest
            // Messier objects visible in August from Orta San Giulio, one session each") is often
            // a full sentence or more, and a one-line field made that awkward to review before
            // sending.
            TextField("Goal", text: $goalText, prompt: Text("e.g. the nicest Messier objects visible in August from Orta San Giulio"), axis: .vertical)
                .lineLimit(3...8)
                .disabled(pendingQuestion != nil)

            if isLoading {
                ProgressView("Asking Ollama…")
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            } else if let pendingQuestion {
                VStack(alignment: .leading, spacing: 6) {
                    Label(pendingQuestion, systemImage: "questionmark.circle").font(.callout)
                    TextField("Your answer", text: $answerText, axis: .vertical).onSubmit { Task { await answerQuestion() } }
                }
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
                if pendingQuestion != nil {
                    Button("Answer") { Task { await answerQuestion() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                } else {
                    Button("Ask") { Task { await ask() } }
                        .disabled(goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    if suggestion != nil {
                        Button("Create Sessions") { createSessions() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding()
        .frame(width: 440, height: 440)
    }

    private func ask() async {
        isLoading = true
        errorMessage = nil
        pendingQuestion = nil
        defer { isLoading = false }
        do {
            let response = try await cameraManager.ollamaPlanner.planProject(
                goal: goalText, notes: fullContext()
            )
            switch response {
            case .plan(let plan):
                suggestion = plan
            case .needsMoreInfo(let question):
                pendingQuestion = question
                answerText = ""
            }
        } catch let error as OllamaError {
            AppLog.shared.log("Ask AI to Plan: \(error.userFacingMessage)")
            errorMessage = error.userFacingMessage
        } catch {
            AppLog.shared.log("Ask AI to Plan: couldn't reach Ollama. (\(String(describing: error)))")
            errorMessage = "Couldn't get a plan from Ollama — make sure it's running locally. (\(String(describing: error)))"
        }
    }

    private func answerQuestion() async {
        guard let question = pendingQuestion else { return }
        let trimmedAnswer = answerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty else { return }
        accumulatedContext += "Q: \(question)\nA: \(trimmedAnswer)\n"
        pendingQuestion = nil
        await ask()
    }

    /// The project's own location and today's date, plus every clarifying answer collected so
    /// far — automatic context the user shouldn't have to type into the goal by hand, on top of
    /// whatever they actually did type.
    private func fullContext() -> String {
        var lines: [String] = []
        if let location = project.location {
            lines.append("Observing location: \(location.displayName).")
        }
        lines.append("Today's date: \(Date().formatted(date: .long, time: .omitted)).")
        if !accumulatedContext.isEmpty {
            lines.append(accumulatedContext)
        }
        return lines.joined(separator: " ")
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
            TextField("Goal", text: $goalText, prompt: Text("e.g. see M13, M57, Saturn"), axis: .vertical)
                .lineLimit(3...8)

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
        .frame(width: 380, height: 340)
    }

    private func ask() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            suggestion = try await cameraManager.ollamaPlanner.planSession(goal: goalText)
        } catch let error as OllamaError {
            AppLog.shared.log("Ask AI to Plan: \(error.userFacingMessage)")
            errorMessage = error.userFacingMessage
        } catch {
            AppLog.shared.log("Ask AI to Plan: couldn't reach Ollama. (\(String(describing: error)))")
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

/// "Use AI to write a description/annotation leveraging the information gathered during the
/// sessions" — grounded in `context` (built by `AIDescriptionContext.forProject`/`forSession`
/// from what was actually planned/captured, not invented), shown editable before being used
/// either as the project's/session's own Aim, or appended as a dated note — the caller decides
/// which by supplying `onSetAim`/`onAddNote`, so this one sheet serves both `ProjectDetailPane`
/// and `SessionDetailPane` rather than two near-identical ones.
struct AIDescribeSheet: View {
    let title: String
    let context: String
    var cameraManager: CameraManager
    var onSetAim: (String) -> Void
    var onAddNote: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var generatedText = ""
    @State private var hasGenerated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("Writes a description grounded in what this actually planned and captured — nothing invented.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView("Asking Ollama…")
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            } else if hasGenerated {
                TextEditor(text: $generatedText)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if !hasGenerated {
                    Button("Generate") { Task { await generate() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                } else {
                    Button("Regenerate") { Task { await generate() } }.disabled(isLoading)
                    Button("Add as Note") { onAddNote(generatedText); dismiss() }
                        .disabled(generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Set as Aim") { onSetAim(generatedText); dismiss() }
                        .buttonStyle(.borderedProminent)
                        .disabled(generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding()
        .frame(width: 460, height: 360)
        .task { await generate() }
    }

    private func generate() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            generatedText = try await cameraManager.ollamaPlanner.summarize(context: context)
            hasGenerated = true
        } catch let error as OllamaError {
            AppLog.shared.log("Ask AI to Describe: \(error.userFacingMessage)")
            errorMessage = error.userFacingMessage
        } catch {
            AppLog.shared.log("Ask AI to Describe: couldn't reach Ollama. (\(String(describing: error)))")
            errorMessage = "Couldn't get a description from Ollama — make sure it's running locally. (\(String(describing: error)))"
        }
    }
}
