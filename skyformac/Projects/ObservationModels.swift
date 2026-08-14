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

    /// `nil` for an out-of-range latitude/longitude — the one thing free-text manual entry can
    /// get wrong that GPS never would, so it's validated here rather than trusted at the UI layer.
    static func manual(latitude: Double, longitude: Double, name: String?) -> GeoLocation? {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return GeoLocation(latitude: latitude, longitude: longitude, name: name, source: .manual)
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
    enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case fits, png, tiff, serVideo, recording

        var icon: String {
            switch self {
            case .fits: return "doc.badge.gearshape"
            case .png, .tiff: return "photo"
            case .serVideo: return "film"
            case .recording: return "record.circle"
            }
        }

        /// What the Stats section labels each count with — `rawValue` alone reads fine for most
        /// (`fits`, `png`, `tiff`) but not the camelCase ones.
        var displayName: String {
            switch self {
            case .fits: return "FITS"
            case .png: return "PNG"
            case .tiff: return "TIFF"
            case .serVideo: return "SER Video"
            case .recording: return "Recording"
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
    /// What was actually being observed — a snapshot of the owning session's own
    /// `plannedObjects.first` at the moment of capture, kept here too (not just derived from the
    /// session) so this record still says what it was even if the session's plan changes later,
    /// and so `InsightsView`/search can group/filter every capture across every session by object
    /// without re-walking each one's session for it.
    var object: String?
    /// Where this was actually taken from — a snapshot of the session's (or its project's)
    /// effective location at capture time, for the same "still true even if it changes later"
    /// reason as `object` above.
    var location: GeoLocation?
    /// The equipment system actually in use at capture time — a snapshot of
    /// `Session.effectiveEquipmentSystemID(inProject:)`, not a live reference, since a session's
    /// (or its project's) assigned system can change afterwards without this record's own history
    /// changing with it.
    var equipmentSystemID: UUID?
    /// Every camera/acquisition parameter actually in effect for this one action — gain,
    /// exposure, ROI, Live Stack/Lucky Imaging mode and their own sub-settings — reusing
    /// `AcquisitionPreset` rather than a second parallel "capture parameters" type, since it
    /// already models exactly this shape (see `CameraManager.currentAcquisitionPreset(name:)`).
    /// This is what "recall the parameters from a previous action" (`applyAcquisitionPreset`)
    /// and the Insights page's "most common parameters" both read from.
    var preset: AcquisitionPreset?
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
    /// `nil` means "inherit the project's own equipment system" (`Project.equipmentSystemID`) —
    /// set explicitly to override it for just this one session (a borrowed camera, a different
    /// scope for the night, whatever changed). See `effectiveEquipmentSystemID(inProject:)`.
    var equipmentSystemID: UUID?
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
            equipmentSystemID: nil, folderName: makeFolderName(name: name, id: id)
        )
    }

    /// What this session's equipment actually is once inheritance is resolved — its own override
    /// if it has one, otherwise `project`'s own assignment, otherwise `nil` (nothing assigned at
    /// either level).
    func effectiveEquipmentSystemID(inProject project: Project) -> UUID? {
        equipmentSystemID ?? project.equipmentSystemID
    }

    /// This session's own location if it has one, otherwise its project's — the same inheritance
    /// shape `effectiveEquipmentSystemID(inProject:)` uses, factored out here since three separate
    /// views were each already writing `session.location ?? project.location` by hand.
    func effectiveLocation(inProject project: Project) -> GeoLocation? {
        location ?? project.location
    }

    /// A fresh session that reuses everything about how `self` is set up — goal, planned
    /// objects, location, tags, and equipment — but starts with a clean slate otherwise: no
    /// captures, no notes, a new id/folder, and `name`/`plannedDate` supplied by the caller
    /// rather than copied, since "reuse this session's setup for a new outing" always means a
    /// new date and (usually) a new name, not the old session's own. What "create a new session
    /// reusing an existing one, without its actions" actually does.
    func duplicatedForReuse(name: String, plannedDate: Date? = nil) -> Session {
        var copy = Session.newSession(name: name, goal: goal, plannedObjects: plannedObjects, plannedDate: plannedDate)
        copy.location = location
        copy.tags = tags
        copy.equipmentSystemID = equipmentSystemID
        return copy
    }

    /// `nil` for a session with no captures yet — the History section shows "Never run" instead
    /// of a range starting nowhere.
    var firstCaptureDate: Date? { captures.map(\.date).min() }

    /// The same date `Project.lastActivityDate` uses for this one session specifically.
    var lastCaptureDate: Date? { captures.map(\.date).max() }

    /// How long capturing actually spanned, start to finish — `nil` with fewer than two captures
    /// (a single capture, or none, has no meaningful duration to show).
    var duration: TimeInterval? {
        guard let first = firstCaptureDate, let last = lastCaptureDate, last > first else { return nil }
        return last.timeIntervalSince(first)
    }

    /// How many captures of each kind — what the Stats section actually breaks down, rather than
    /// just a single total.
    var captureCountByKind: [CaptureRecord.Kind: Int] {
        Dictionary(grouping: captures, by: \.kind).mapValues(\.count)
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
    /// `nil` for a normal project. Set by `ProjectsLibrary.softDelete(_:)` — the project (and its
    /// folder) stays on disk for a 30-day grace period (`gracePeriodExpirationDate`) rather than
    /// being removed immediately, so a mistaken delete is recoverable via `restore(_:)`. Missing
    /// entirely from a `project.json` written before this field existed, which decodes the same
    /// as `nil` (Swift's synthesized `Decodable` treats a missing key for an `Optional` property
    /// as absent, not an error) — an old project is never treated as deleted just because it
    /// predates this feature.
    var deletedAt: Date?
    /// The named `EquipmentSystem` (`EquipmentLibrary`) this project's sessions use by default —
    /// `nil` means none assigned. A session can override this for itself via its own
    /// `equipmentSystemID`; see `Session.effectiveEquipmentSystemID(inProject:)`.
    var equipmentSystemID: UUID?
    /// Stable, folder-safe name for this project's own directory — see `Session.makeFolderName`'s
    /// doc comment for the identical reasoning (decoupled from `name` so renaming never moves
    /// anything on disk).
    var folderName: String

    var isDeleted: Bool { deletedAt != nil }

    /// When a soft-deleted project's 30-day grace period actually ends — `nil` for a project
    /// that isn't deleted at all. `ProjectsLibrary.purgeExpiredSoftDeletes()` is what actually
    /// acts on this.
    var gracePeriodExpirationDate: Date? {
        guard let deletedAt else { return nil }
        return Calendar.current.date(byAdding: .day, value: 30, to: deletedAt)
    }

    /// Every object planned across every session, deduplicated — what search actually matches
    /// against for "observed objects," alongside each session's own `plannedObjects`.
    var allPlannedObjects: [String] {
        Array(Set(sessions.flatMap(\.plannedObjects))).sorted()
    }

    /// Every capture across every session — what the Home page's card/table shows as "how much
    /// has actually happened" alongside the raw session count.
    var totalCaptureCount: Int {
        sessions.reduce(0) { $0 + $1.captures.count }
    }

    /// The most recent moment anything happened on this project — the latest capture date across
    /// every session, falling back to `createdDate` for one with no captures yet at all. Used to
    /// sort/show "last activity" on the Home page instead of everything just sitting in creation
    /// order forever.
    var lastActivityDate: Date {
        sessions.flatMap(\.captures).map(\.date).max() ?? createdDate
    }

    /// The earliest anything happened — `nil` for a project with no captures at all yet (unlike
    /// `lastActivityDate`, there's no sensible single-date fallback for "first," since
    /// `createdDate` would just always equal it for a project that's never captured anything).
    var firstActivityDate: Date? {
        sessions.flatMap(\.captures).map(\.date).min()
    }

    /// How many captures of each kind across every session — the Stats section's breakdown,
    /// `totalCaptureCount`'s components.
    var captureCountByKind: [CaptureRecord.Kind: Int] {
        Dictionary(grouping: sessions.flatMap(\.captures), by: \.kind).mapValues(\.count)
    }

    var activeSessionsCount: Int { sessions.filter { !$0.isArchived }.count }
    var archivedSessionsCount: Int { sessions.filter(\.isArchived).count }

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
            location: nil, tags: [], notes: [], sessions: [], isArchived: false, deletedAt: nil,
            equipmentSystemID: nil, folderName: makeFolderName(name: name, id: id)
        )
    }
}
