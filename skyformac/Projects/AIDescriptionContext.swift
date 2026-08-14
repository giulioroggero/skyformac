import Foundation

/// Builds the plain-text context `OllamaPlanner.summarize(context:)` grounds its writing in — a
/// factual dump of what a project/session actually planned and captured, not the prose itself.
/// Kept as pure functions over `Project`/`Session` (no `CameraManager`, no async) specifically so
/// "what facts do we hand the model" is unit-testable on its own, independent of ever calling
/// Ollama at all. `equipmentName` is injected as a closure rather than an `EquipmentLibrary`
/// instance for the same reason — a plain `[UUID: String]` lookup in tests, the real library's
/// `system(withID:)` in the app.
enum AIDescriptionContext {
    static func forProject(_ project: Project, equipmentName: (UUID) -> String?) -> String {
        var lines = ["Project: \(project.name.isEmpty ? "(untitled)" : project.name)"]
        if !project.goal.isEmpty { lines.append("Stated goal: \(project.goal)") }
        if let location = project.location { lines.append("Location: \(location.displayName)") }
        if !project.tags.isEmpty { lines.append("Tags: \(project.tags.joined(separator: ", "))") }
        if let equipmentID = project.equipmentSystemID, let name = equipmentName(equipmentID) {
            lines.append("Default equipment: \(name)")
        }
        let objects = project.allPlannedObjects
        if !objects.isEmpty { lines.append("Objects planned across its sessions: \(objects.joined(separator: ", "))") }
        lines.append("Total sessions: \(project.sessions.count), total captures: \(project.totalCaptureCount).")
        if project.sessions.isEmpty {
            lines.append("No sessions yet.")
        } else {
            lines.append("Sessions:")
            for session in project.sessions {
                lines.append("- " + sessionSummaryLine(session, inProject: project, equipmentName: equipmentName))
            }
        }
        return lines.joined(separator: "\n")
    }

    static func forSession(_ session: Session, project: Project, equipmentName: (UUID) -> String?) -> String {
        var lines = ["Session: \(session.name)", "Part of project: \(project.name.isEmpty ? "(untitled)" : project.name)"]
        if !session.goal.isEmpty { lines.append("Stated goal: \(session.goal)") }
        if !session.plannedObjects.isEmpty { lines.append("Planned objects: \(session.plannedObjects.joined(separator: ", "))") }
        if let location = session.effectiveLocation(inProject: project) { lines.append("Location: \(location.displayName)") }
        if let equipmentID = session.effectiveEquipmentSystemID(inProject: project), let name = equipmentName(equipmentID) {
            lines.append("Equipment: \(name)")
        }
        if session.captures.isEmpty {
            lines.append("No captures yet.")
        } else {
            lines.append("Captures: \(session.captures.count) total.")
            let capturedObjects = Set(session.captures.compactMap(\.object))
            if !capturedObjects.isEmpty {
                lines.append("Objects actually captured: \(capturedObjects.sorted().joined(separator: ", "))")
            }
            for kind in CaptureRecord.Kind.allCases {
                if let count = session.captureCountByKind[kind] {
                    lines.append("\(kind.displayName): \(count)")
                }
            }
            if let first = session.firstCaptureDate, let last = session.lastCaptureDate {
                lines.append("Captured from \(first.formatted(date: .abbreviated, time: .shortened)) to \(last.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        if !session.notes.isEmpty {
            lines.append("Existing notes: \(session.notes.map(\.text).joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    /// One line per session in a project's own context — deliberately terser than
    /// `forSession(_:project:equipmentName:)`'s own full write-up, since a project-level summary
    /// needs an overview of every session, not each one's full detail.
    private static func sessionSummaryLine(_ session: Session, inProject project: Project, equipmentName: (UUID) -> String?) -> String {
        var parts = [session.name]
        if !session.plannedObjects.isEmpty { parts.append("objects: \(session.plannedObjects.joined(separator: ", "))") }
        if !session.captures.isEmpty { parts.append("\(session.captures.count) captures") }
        if let location = session.effectiveLocation(inProject: project) { parts.append("at \(location.displayName)") }
        return parts.joined(separator: ", ")
    }
}
