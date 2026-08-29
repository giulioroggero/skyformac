import Foundation

/// One line of the sidebar assistant's conversation — `role` distinguishes which side of the
/// chat wrote it, the same shape any chat UI needs. `Codable` so a whole conversation can be
/// persisted as part of an `AIChatSession`.
struct AssistantMessage: Identifiable, Equatable, Sendable, Codable {
    enum Role: Equatable, Sendable, Codable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
}

/// One saved AI conversation — "the user can create a new AI session and see the history,
/// recalling and continuing a conversation." Persisted by `AIChatLibrary` as one JSON file per
/// session, the same "small dataset, no database needed" shape `EquipmentSystem` already uses.
struct AIChatSession: Identifiable, Equatable, Sendable, Codable {
    var id = UUID()
    var title: String
    var createdDate: Date
    var updatedDate: Date
    var messages: [AssistantMessage]

    /// `firstMessageText` (the conversation's first user message, if any yet) seeds an
    /// auto-title — "Messier Marathon suggestions…" reads far better in a history list than
    /// "New Chat 1", "New Chat 2". Renaming later (`AIChatLibrary.rename(_:to:)`) always wins
    /// over this.
    static func newSession(firstMessageText: String? = nil) -> AIChatSession {
        let now = Date()
        return AIChatSession(title: autoTitle(from: firstMessageText), createdDate: now, updatedDate: now, messages: [])
    }

    static func autoTitle(from text: String?) -> String {
        guard let text else { return "New Chat" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New Chat" }
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
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
    /// Starts or stops Live Stack — needs a connected camera; see
    /// `CameraManager.confirmAssistantAction()`.
    case setLiveStacking(enabled: Bool)
    /// Starts a Lucky Imaging burst of `frameCount` frames — needs a connected camera.
    case startLuckyImagingBurst(frameCount: Int)
    /// Stacks the sharpest `fraction` (0...1) of an already-completed Lucky Imaging burst — needs
    /// one in progress/complete (`CameraManager.luckyImagingSession != nil`).
    case stackLuckyImagingBest(fraction: Double)
    /// Creates a new, empty equipment rig by name — mirrors `.createProject`'s own shape.
    case createEquipmentSystem(name: String)
}

/// A proposed action plus the plain-English explanation shown alongside its Approve/Reject
/// buttons — kept as one struct (rather than two separate optionals on `CameraManager`) so a
/// pending action and its explanation can never end up out of sync with each other.
struct AssistantPendingAction: Equatable, Sendable {
    var action: AssistantAction
    var message: String
}
