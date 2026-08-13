import Foundation

/// A physical observing location — either the device's own GPS fix (`CoreLocationProvider`) or
/// hand-entered when GPS isn't available/wanted (a fixed backyard setup, entered once and reused,
/// or an indoor/test session with no real sky location at all). Kept on both `Project` and
/// `Session` independently, since a project can span multiple sites (a trip) even if most
/// projects' sessions all share the same one (a home setup).
struct GeoLocation: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case gps
        case manual
    }

    var latitude: Double
    var longitude: Double
    /// A human label — "Backyard", "Dark Sky Site", a town name — shown instead of raw
    /// coordinates wherever there's room to. `nil` when the user never bothered naming it.
    var name: String?
    var source: Source

    var displayName: String {
        name ?? String(format: "%.4f, %.4f", latitude, longitude)
    }
}

/// A timestamped free-text note on a `Project` or `Session` — what "annotate sessions and
/// projects" actually stores. Kept as a list rather than one big notes string so the timeline
/// can place each note at the moment it was actually written, not just show one blob with no
/// sense of when any of it happened.
struct Annotation: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var text: String
}

/// One capture (an exported FITS/PNG/TIFF frame, a live-stacked image, an SER/continuous
/// recording) folded into a session's own timeline — `CameraManager` appends one of these
/// automatically whenever a capture happens while a session is active (see
/// `ProjectStore.recordCapture`), rather than requiring the user to manually log anything.
/// `fileName`/`thumbnailFileName` are relative to the *session's* own folder
/// (`ProjectStore.sessionFolderURL`), not absolute paths — a project moved or copied to another
/// machine (or just renamed on disk) still resolves correctly as long as the relative layout
/// underneath it stays intact.
struct CaptureRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fits, png, tiff, serVideo, recording

        var icon: String {
            switch self {
            case .fits: return "doc.badge.gearshape"
            case .png, .tiff: return "photo"
            case .serVideo: return "film"
            case .recording: return "record.circle"
            }
        }
    }

    var id = UUID()
    var date: Date
    var fileName: String
    /// `nil` when a thumbnail couldn't be generated (an unreadable frame, a disk error) — the
    /// timeline just shows a generic icon for that entry instead of failing to display at all.
    var thumbnailFileName: String?
    var kind: Kind
    var note: String?
}

/// One observing session within a `Project` — "see M13, M57, Saturn" tonight, for example.
/// Everything captured while this session is the active one (`CameraManager.activeSession`)
/// lands in this session's own folder (`ProjectStore.sessionFolderURL`) and gets appended to
/// `captures` automatically.
struct Session: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// What this session is actually for — "Photograph M13 and M57 under new moon," e.g. Free
    /// text, not constrained to a fixed target list, since a real session's goal is often more
    /// specific than just "which objects" (seeing test, polar alignment practice, etc.).
    var goal: String
    /// Objects this session plans to observe — free-text (not tied to `AcquisitionTarget`, which
    /// only covers this app's own curated planetary/deep-sky list) so a target outside that list
    /// (a comet, a double star, anything) can still be planned for and searched by.
    var plannedObjects: [String]
    /// When this session is actually planned/expected to happen — `nil` for one logged after the
    /// fact with no advance plan. `createdDate` (below) is when the session record itself was
    /// created, which can differ (planned days ahead, or created retroactively).
    var plannedDate: Date?
    var createdDate: Date
    var location: GeoLocation?
    var tags: [String]
    var notes: [Annotation]
    var captures: [CaptureRecord]
    var isArchived: Bool
    /// Stable, folder-safe name for this session's own directory (a subfolder of its project's
    /// own folder) — computed once at creation (see `newSession` factories) and never recomputed
    /// from `name`, so renaming a session later never requires also renaming/moving anything on
    /// disk.
    var folderName: String

    static func makeFolderName(name: String, id: UUID) -> String {
        let sanitized = ProjectStore.sanitizeForFilename(name)
        return sanitized.isEmpty ? String(id.uuidString.prefix(8)) : "\(sanitized)-\(id.uuidString.prefix(8))"
    }

    /// A fresh, empty session — `name` defaults to a date-stamped placeholder (matching this
    /// app's existing "sensible default, freely renamable" pattern elsewhere) rather than forcing
    /// the user to type something before a session can even exist yet.
    static func newSession(name: String, goal: String = "", plannedObjects: [String] = [], plannedDate: Date? = nil) -> Session {
        let id = UUID()
        return Session(
            id: id, name: name, goal: goal, plannedObjects: plannedObjects, plannedDate: plannedDate,
            createdDate: Date(), location: nil, tags: [], notes: [], captures: [], isArchived: false,
            folderName: makeFolderName(name: name, id: id)
        )
    }
}

/// A set of observation sessions grouped by a goal — a week of "Messier marathon" nights, a trip
/// to a dark-sky site, or just "everything under this backyard setup this season." Owns its own
/// folder (`ProjectStore.projectFolderURL`) containing one subfolder per `Session`.
struct Project: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var goal: String
    var plannedStartDate: Date?
    var plannedEndDate: Date?
    var createdDate: Date
    var location: GeoLocation?
    var tags: [String]
    var notes: [Annotation]
    var sessions: [Session]
    var isArchived: Bool
    /// Stable, folder-safe name for this project's own directory — see `Session.makeFolderName`'s
    /// doc comment for the identical reasoning (decoupled from `name` so renaming never moves
    /// anything on disk).
    var folderName: String

    /// Every object planned across every session, deduplicated — what search actually matches
    /// against for "observed objects," alongside each session's own `plannedObjects`.
    var allPlannedObjects: [String] {
        Array(Set(sessions.flatMap(\.plannedObjects))).sorted()
    }

    /// Stable, folder-safe project directory name — see `Session.makeFolderName`'s doc comment
    /// for the identical reasoning (decoupled from `name`, computed once, never recomputed).
    static func makeFolderName(name: String, id: UUID) -> String {
        let sanitized = ProjectStore.sanitizeForFilename(name)
        return sanitized.isEmpty ? String(id.uuidString.prefix(8)) : "\(sanitized)-\(id.uuidString.prefix(8))"
    }

    static func newProject(name: String, goal: String = "") -> Project {
        let id = UUID()
        return Project(
            id: id, name: name, goal: goal, plannedStartDate: nil, plannedEndDate: nil, createdDate: Date(),
            location: nil, tags: [], notes: [], sessions: [], isArchived: false,
            folderName: makeFolderName(name: name, id: id)
        )
    }

    /// Untitled, empty, and not yet written to disk — what `ContentView`/`ProjectsBrowserView`
    /// hands the user on first launch with zero saved projects, per the "she can decide to save
    /// it giving a name" flow. Naming and saving it for the first time is what actually creates
    /// its folder — see `ProjectStore.save`.
    static func newUntitled() -> Project {
        newProject(name: "")
    }
}
