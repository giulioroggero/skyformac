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
        purgeExpiredSoftDeletes()
    }

    func reload() {
        projects = store.loadAllProjects().sorted { $0.createdDate > $1.createdDate }
    }

    /// Every project neither soft-deleted — what the Home page (further filtered there by
    /// archived state) and search actually draw from; a deleted project only ever shows on the
    /// Recently Deleted page.
    var activeProjects: [Project] { projects.filter { $0.deletedAt == nil } }

    /// Soft-deleted but still within (or exactly at) their 30-day grace period — not yet purged
    /// from disk. What the Recently Deleted page shows.
    var deletedProjects: [Project] { projects.filter { $0.deletedAt != nil } }

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
    /// For a named project, the disk write happens *before* `replace(_:)` — so a failure (a full
    /// disk, a permissions issue) throws without leaving a "ghost" project in memory that only
    /// ever existed for the rest of this run and was never actually saved.
    func save(_ project: Project) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            replace(project)
            return
        }
        try store.save(project)
        replace(project)
    }

    /// Marks `project` deleted — kept on disk for a 30-day grace period
    /// (`Project.gracePeriodExpirationDate`) rather than removed immediately, so a mistaken
    /// delete is recoverable via `restore(_:)`. An unnamed project was never on disk in the first
    /// place (see `save(_:)`), so there's nothing to keep around for a grace period — it's just
    /// removed outright, the same as the old immediate-delete behavior for that one case.
    func softDelete(_ project: Project) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            projects.removeAll { $0.id == project.id }
            return
        }
        var updated = project
        updated.deletedAt = Date()
        try store.save(updated)
        replace(updated)
    }

    /// Undoes `softDelete(_:)` — clears `deletedAt` so `project` shows up as a normal project
    /// again, indistinguishable from one that was never deleted.
    func restore(_ project: Project) throws {
        var updated = project
        updated.deletedAt = nil
        try store.save(updated)
        replace(updated)
    }

    /// Actually removes `project`'s folder from disk — no grace period, no undo. Used both for
    /// "Delete Permanently" on an already soft-deleted project, and by
    /// `purgeExpiredSoftDeletes()` once a soft delete's grace period has genuinely elapsed.
    func permanentlyDelete(_ project: Project) throws {
        if !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try store.delete(project)
        }
        projects.removeAll { $0.id == project.id }
    }

    /// Permanently deletes every currently soft-deleted project regardless of how much of its own
    /// grace period remains — the Recently Deleted page's own "Delete All Permanently" action.
    func permanentlyDeleteAllDeleted() {
        for project in deletedProjects {
            try? permanentlyDelete(project)
        }
    }

    /// Sweeps every soft-deleted project whose grace period has actually elapsed and permanently
    /// deletes it. Called once at launch (`init`) — the closest this single-user, no-background-
    /// scheduling app gets to a real "empty the trash after 30 days" timer; a project deleted
    /// while the app isn't running still gets purged the next time it launches; one just gets
    /// purged the moment its 30 days are up, whichever comes first is checked at.
    func purgeExpiredSoftDeletes() {
        let now = Date()
        for project in deletedProjects {
            if let expiration = project.gracePeriodExpirationDate, expiration <= now {
                try? permanentlyDelete(project)
            }
        }
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

    /// Removes one capture (its file, thumbnail, and `CaptureRecord`) from a session within
    /// `project` — the Timeline's own "Delete" action, for reclaiming disk space one capture at a
    /// time without deleting the whole session.
    func deleteCapture(_ captureID: UUID, fromSessionID sessionID: UUID, in project: Project) throws {
        var updated = project
        try store.deleteCapture(captureID, fromSessionID: sessionID, in: &updated)
        replace(updated)
    }

    @discardableResult
    func addElaboratedImage(
        fileName: String, sourceSessionIDs: [UUID], sourceCaptureID: UUID?, recipe: ElaborationRecipe? = nil,
        toolLabel: String? = nil, to project: Project
    ) throws -> ElaboratedImage {
        var updated = project
        let image = try store.addElaboratedImage(
            fileName: fileName, sourceSessionIDs: sourceSessionIDs, sourceCaptureID: sourceCaptureID,
            recipe: recipe, toolLabel: toolLabel, to: &updated
        )
        replace(updated)
        return image
    }

    func deleteElaboratedImage(_ imageID: UUID, in project: Project) throws {
        var updated = project
        try store.deleteElaboratedImage(imageID, in: &updated)
        replace(updated)
    }

    /// Moves a session from one project to another — its on-disk folder (`session.json`, every
    /// capture file, `Thumbnails/`) physically relocates to sit under the destination project's
    /// own folder instead, via `ProjectStore.moveSession`, so nothing about the move is just an
    /// in-memory relabeling. Both projects' in-memory copies are replaced afterward.
    func moveSession(_ sessionID: UUID, from sourceProject: Project, to destinationProject: Project) throws {
        var source = sourceProject
        var destination = destinationProject
        try store.moveSession(sessionID, from: &source, to: &destination)
        replace(source)
        replace(destination)
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
