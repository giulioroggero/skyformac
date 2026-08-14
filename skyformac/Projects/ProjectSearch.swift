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
    /// empty `text` matches everything, so callers can reuse this for a pure facet-only filter.
    /// `tag`/`object` are exact (case-insensitive) matches against that project's/session's own
    /// tags/planned objects — picked from a list, not typed free-text, so an exact match is what
    /// the user actually chose. `equipmentSystemID` matches a session's *effective* system
    /// (its own override, or its project's) — or, for a project-level result, the project's own.
    static func search(
        _ projects: [Project], text: String, dateRange: ClosedRange<Date>? = nil,
        tag: String? = nil, equipmentSystemID: UUID? = nil, object: String? = nil
    ) -> [Result] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [Result] = []
        for project in projects {
            let projectDate = project.plannedStartDate ?? project.createdDate
            if matches(needle, in: project), dateRange.map({ $0.contains(projectDate) }) ?? true,
               matchesExact(tag, in: project.tags), matchesExact(object, in: project.allPlannedObjects),
               matchesEquipment(equipmentSystemID, effective: project.equipmentSystemID) {
                results.append(Result(project: project, session: nil))
            }
            for session in project.sessions {
                let sessionDate = session.plannedDate ?? session.createdDate
                if matches(needle, in: session), dateRange.map({ $0.contains(sessionDate) }) ?? true,
                   matchesExact(tag, in: session.tags), matchesExact(object, in: session.plannedObjects),
                   matchesEquipment(equipmentSystemID, effective: session.effectiveEquipmentSystemID(inProject: project)) {
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

    private static func matchesExact(_ value: String?, in values: [String]) -> Bool {
        guard let value, !value.isEmpty else { return true }
        return values.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private static func matchesEquipment(_ filterID: UUID?, effective: UUID?) -> Bool {
        guard let filterID else { return true }
        return effective == filterID
    }
}

/// Every object name worth offering in the Filters popover's "Object" picker — the app's own
/// bundled Stellarium-derived catalogs (`SkyCatalog`, already extracted from the same Stellarium
/// nebula/star data this app ships with — see `docs/architecture.md`) plus the handful of
/// planets/Moon `PlanetaryPreset` covers, plus whatever free-text objects the user has actually
/// already planned across their own projects (a comet, a double star, anything not in either
/// catalog). Deduplicated and sorted so the same object never appears twice under slightly
/// different capitalization.
enum ObservedObjectCatalog {
    static func allKnownObjectNames(projects: [Project]) -> [String] {
        var names = Set<String>()
        for preset in PlanetaryPreset.allCases {
            names.insert(preset.rawValue)
        }
        for object in SkyCatalog.messierObjects {
            names.insert(object.displayName)
        }
        for object in SkyCatalog.caldwellObjects {
            names.insert(object.displayName)
        }
        for star in SkyCatalog.brightStars {
            names.insert(star.displayName)
        }
        for project in projects {
            for object in project.allPlannedObjects {
                names.insert(object)
            }
        }
        return names.sorted()
    }
}
