import Foundation

/// One line of the sidebar assistant's conversation — `role` distinguishes which side of the
/// chat wrote it, the same shape any chat UI needs.
struct AssistantMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
}

/// Something the assistant wants to actually change, rather than just answer — always shown to
/// the user for approval first (`CameraManager.assistantPendingAction`), never applied on its
/// own. Deliberately a small, closed set of concrete operations (not "run arbitrary code") so
/// every possible action is exactly as safe/reviewable as the equivalent manual button already
/// is elsewhere in the app (New Project, New Session, applying an `AcquisitionPreset`).
enum AssistantAction: Equatable, Sendable {
    case createProject(name: String, goal: String)
    /// `projectName` matches an existing project case-insensitively if one exists; otherwise a
    /// new project by that name is created first — see `CameraManager.confirmAssistantAction()`.
    case createSession(projectName: String, sessionName: String, goal: String, plannedObjects: [String])
    /// Any subset of these may be `nil` — the assistant only proposes changing what it actually
    /// has an opinion on, leaving the rest of the current setup untouched.
    case applyCameraSettings(gain: Int?, exposureSeconds: Double?, mode: AcquisitionMode?)
}

/// A proposed action plus the plain-English explanation shown alongside its Approve/Reject
/// buttons — kept as one struct (rather than two separate optionals on `CameraManager`) so a
/// pending action and its explanation can never end up out of sync with each other.
struct AssistantPendingAction: Equatable, Sendable {
    var action: AssistantAction
    var message: String
}
