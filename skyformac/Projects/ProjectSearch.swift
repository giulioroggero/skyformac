import Foundation

/// Free-text + date-range search across every `Project`/`Session` this app knows about — the
/// counterpart to the tags/labels already on both (`Project.tags`/`Session.tags`, plain array
/// mutation, no dedicated API needed): the thing that actually makes hundreds of past sessions
/// navigable instead of just archived. Text matching is case-insensitive substring, not
/// tokenized/ranked — plenty for one person's own observing history, no need for a real search
/// index.
enum ProjectSearch {
    /// One matching project, or one matching session (with the project it belongs to, so a result
    /// can always be opened straight to its place in the browser).
    struct Result: Identifiable {
        var id: UUID { session?.id ?? project.id }
        var project: Project
        var session: Session?
    }

    /// Every project (as a `Result` with `session == nil`) and every session across every
    /// project (`session` set) whose text matches `text` — a case-insensitive substring against
    /// name, goal, tags, planned/observed objects, and annotation text — and whose own date
    /// (planned date if set, else when it was created) falls inside `dateRange`, if given. An
    /// empty `text` matches everything, so callers can reuse this for a pure date-range filter.
    static func search(_ projects: [Project], text: String, dateRange: ClosedRange<Date>? = nil) -> [Result] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [Result] = []
        for project in projects {
            let projectDate = project.plannedStartDate ?? project.createdDate
            if matches(needle, in: project), dateRange.map({ $0.contains(projectDate) }) ?? true {
                results.append(Result(project: project, session: nil))
            }
            for session in project.sessions {
                let sessionDate = session.plannedDate ?? session.createdDate
                if matches(needle, in: session), dateRange.map({ $0.contains(sessionDate) }) ?? true {
                    results.append(Result(project: project, session: session))
                }
            }
        }
        return results
    }

    private static func matches(_ needle: String, in project: Project) -> Bool {
        guard !needle.isEmpty else { return true }
        let haystack = [project.name, project.goal] + project.tags + project.allPlannedObjects + project.notes.map(\.text)
        return haystack.contains { $0.lowercased().contains(needle) }
    }

    private static func matches(_ needle: String, in session: Session) -> Bool {
        guard !needle.isEmpty else { return true }
        let haystack = [session.name, session.goal] + session.tags + session.plannedObjects + session.notes.map(\.text)
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}
