import Foundation
import Observation

/// The in-memory list of every `Project` the Projects browser shows, backed by `ProjectStore`.
/// Centralizing CRUD here (rather than having views juggle `inout Project` across an array
/// themselves) is what makes the "empty project exists only in memory until named" first-run
/// flow possible: `save(_:)` simply declines to touch disk for an unnamed project, so creating
/// one costs nothing and never litters `ProjectStore.rootDirectory` with an "Untitled" folder
/// the user never asked for.
@Observable
@MainActor
final class ProjectsLibrary {
    let store: ProjectStore
    private(set) var projects: [Project] = []

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        reload()
    }

    func reload() {
        projects = store.loadAllProjects().sorted { $0.createdDate > $1.createdDate }
    }

    /// Adds a new, purely in-memory project. `NewProjectSheet` is the only caller — it always
    /// passes a non-empty `name`, so the very next `save(_:)` call (which it also makes) persists
    /// it immediately; `createProject`/`save` stay separate calls anyway so tests can create
    /// without touching disk when that's all they need.
    @discardableResult
    func createProject(name: String = "", goal: String = "") -> Project {
        let project = Project.newProject(name: name, goal: goal)
        projects.insert(project, at: 0)
        return project
    }

    /// Persists `project` — but only once it has a real name; an unnamed project is updated in
    /// memory (so its edits, like a newly-added session, aren't lost) without ever touching disk.
    func save(_ project: Project) throws {
        replace(project)
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try store.save(project)
    }

    /// Deletes `project` — from disk too, if it was ever actually saved there.
    func delete(_ project: Project) throws {
        if !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.delete(project)
        }
        projects.removeAll { $0.id == project.id }
    }

    func setArchived(_ isArchived: Bool, for project: Project) throws {
        var updated = project
        try store.setArchived(isArchived, for: &updated)
        replace(updated)
    }

    func setArchived(_ isArchived: Bool, forSessionID sessionID: UUID, in project: Project) throws {
        var updated = project
        try store.setArchived(isArchived, forSessionID: sessionID, in: &updated)
        replace(updated)
    }

    func deleteSession(_ sessionID: UUID, in project: Project) throws {
        var updated = project
        try store.deleteSession(sessionID, in: &updated)
        replace(updated)
    }

    /// Adds `session` to `project` and saves — the one entry point both the "new session" button
    /// and the AI planner's "create the sessions it suggested" flow go through.
    @discardableResult
    func addSession(_ session: Session, to project: Project) throws -> Project {
        var updated = project
        updated.sessions.insert(session, at: 0)
        try save(updated)
        return updated
    }

    /// For callers (like `CameraManager.recordActiveSessionCapture`) that already persisted
    /// `project` themselves via `store` directly — updates the in-memory copy the browser shows
    /// without writing `project.json` a second time.
    func syncInMemory(_ project: Project) {
        replace(project)
    }

    private func replace(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
    }
}
