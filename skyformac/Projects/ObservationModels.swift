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

/// A 0–5 star rating — "allow the user to vote project, sessions, task … to provide suggestions
/// for the best settings depending on the observation." `0` means "not rated," not "rated
/// worst" — there's a real difference between "the user hasn't judged this yet" and "the user
/// judged it and it was bad," and only the latter should ever feed a "what worked" suggestion.
/// A plain `Int` (not its own enum) since it's edited via a row of tappable stars and compared
/// numerically (averages, "at least 4 stars") far more often than pattern-matched.
typealias Rating = Int

extension Rating {
    static let unrated: Rating = 0
    static let range: ClosedRange<Rating> = 0...5

    /// Clamps into `0...5` — the one place a rating actually gets written (`clamped(_:)` call
    /// sites below), so a stray out-of-range value (a future UI bug, a hand-edited `project.json`)
    /// can't silently propagate into star rows expecting at most 5, or into an average that would
    /// otherwise skew from one bad value.
    ///
    /// Uses `Swift.min`/`Swift.max` explicitly — inside an extension on `Int` (which `Rating` is,
    /// via its typealias), the unqualified names resolve to `Int.min`/`Int.max` (the static
    /// properties, i.e. `Int64.min`/`Int64.max`) instead of the global comparison functions.
    static func clamped(_ value: Int) -> Rating {
        Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
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
    /// The user's own judgment of this one action/"task" — `.unrated` until they actually rate
    /// it. Feeds `AIDescriptionContext`/the AI panel's own context so "what worked" suggestions
    /// (best settings for a given object) are grounded in what the user themselves rated well,
    /// not just what they happened to capture most.
    var rating: Rating = .unrated
}

extension CaptureRecord {
    private enum CodingKeys: String, CodingKey {
        case id, date, fileName, thumbnailFileName, kind, note, object, location, equipmentSystemID, preset, rating
    }

    /// A custom decoder purely for `rating` — `Rating` is a plain (non-`Optional`) `Int`, so
    /// despite its `= .unrated` default in the struct declaration above, Codable's *synthesized*
    /// decoder still requires the key to be present (a default initial value only affects the
    /// synthesized memberwise *initializer*, not `Decodable` — only genuinely `Optional`-typed
    /// properties get the automatic "missing key decodes as nil" treatment). Without this, every
    /// `CaptureRecord` written before this field existed would fail to decode at all. Declared in
    /// an extension, not the primary struct body, specifically so it doesn't suppress the
    /// synthesized memberwise initializer every `CaptureRecord(date:fileName:kind:...)` call site
    /// (throughout the app and its tests) still relies on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        fileName = try container.decode(String.self, forKey: .fileName)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        kind = try container.decode(Kind.self, forKey: .kind)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        location = try container.decodeIfPresent(GeoLocation.self, forKey: .location)
        equipmentSystemID = try container.decodeIfPresent(UUID.self, forKey: .equipmentSystemID)
        preset = try container.decodeIfPresent(AcquisitionPreset.self, forKey: .preset)
        rating = try container.decodeIfPresent(Rating.self, forKey: .rating) ?? .unrated
    }
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
    /// The user's own judgment of how this session actually went — `.unrated` until set. See
    /// `CaptureRecord.rating`'s doc comment for what this feeds into.
    var rating: Rating = .unrated
    /// Pins this session to the top of its project's own session list — "keep them on top,"
    /// independent of `rating` (a session can be rated highly without being a "favorite" to
    /// revisit, and vice versa).
    var isFavorite = false
    /// Same idea as `Project.customThumbnailFileName` — a user-chosen cover image filename living
    /// in this session's own folder, taking priority over `ProjectStore
    /// .mostRecentThumbnailURL(for:in:)`'s automatic most-recent-capture fallback when set.
    var customThumbnailFileName: String?

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

extension Session {
    private enum CodingKeys: String, CodingKey {
        case id, name, goal, plannedObjects, plannedDate, createdDate, location, tags, notes, captures,
             isArchived, equipmentSystemID, folderName, rating, isFavorite, customThumbnailFileName
    }

    /// Same reasoning as `CaptureRecord`'s own custom decoder — `rating`/`isFavorite` are
    /// non-`Optional`, so despite their default initial values, Codable's synthesized decoder
    /// would otherwise require both keys, failing to load any `session.json` written before they
    /// existed. In an extension (not the primary struct body) so it doesn't suppress the
    /// synthesized memberwise initializer `newSession(...)` and this whole codebase's tests rely
    /// on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        goal = try container.decode(String.self, forKey: .goal)
        plannedObjects = try container.decode([String].self, forKey: .plannedObjects)
        plannedDate = try container.decodeIfPresent(Date.self, forKey: .plannedDate)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        location = try container.decodeIfPresent(GeoLocation.self, forKey: .location)
        tags = try container.decode([String].self, forKey: .tags)
        notes = try container.decode([Annotation].self, forKey: .notes)
        captures = try container.decode([CaptureRecord].self, forKey: .captures)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        equipmentSystemID = try container.decodeIfPresent(UUID.self, forKey: .equipmentSystemID)
        folderName = try container.decode(String.self, forKey: .folderName)
        rating = try container.decodeIfPresent(Rating.self, forKey: .rating) ?? .unrated
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        customThumbnailFileName = try container.decodeIfPresent(String.self, forKey: .customThumbnailFileName)
    }
}

/// Which Siril script template `SirilElaborationService` used for one `ElaboratedImage` — kept
/// alongside the result so the Project page can label it, and so a re-elaborate action can reuse
/// the same choice. See `SirilElaborationService`'s doc comment for what each recipe actually runs.
enum ElaborationRecipe: String, Codable, Sendable, Hashable, CaseIterable {
    case planetary
    case deepSky
    case singleImage

    var label: String {
        switch self {
        case .planetary: return "Planetary"
        case .deepSky: return "Deep Sky"
        case .singleImage: return "Single Image"
        }
    }
}

/// One result of sending a capture (or a whole session's stackable frames) to Siril for further
/// processing (`SirilElaborationService`) — the output file itself lives in
/// `ProjectStore.elaboratedImagesFolderURL(for:)`, this is just the catalog entry pointing at it.
/// Project-level, not session-level: "visible in a section of the project," not buried inside
/// whichever session happened to trigger it, since `sourceSessionIDs` already records that.
struct ElaboratedImage: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var fileName: String
    /// Almost always exactly one session — a `[UUID]`, not a single `UUID`, so a future "combine
    /// multiple sessions of the same target" elaboration has somewhere to record that without a
    /// model change; today's elaborate actions (from one session or one capture) each populate it
    /// with just their own owning session.
    var sourceSessionIDs: [UUID]
    /// Set when this came from "Elaborate…" on one specific capture rather than a whole session's
    /// stackable frames — `nil` for a session-level elaboration.
    var sourceCaptureID: UUID?
    var recipe: ElaborationRecipe
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
    /// The user's own judgment of the project overall — `.unrated` until set. See
    /// `CaptureRecord.rating`'s doc comment for what this feeds into.
    var rating: Rating = .unrated
    /// Pins this project to the top of the Home page's project list — "keep them on top."
    var isFavorite = false
    /// Results of sending a capture or session to Siril for further processing — see
    /// `ElaboratedImage`'s doc comment. Shown in their own "Elaborated" section on the Project
    /// page, across every session, not nested under whichever one triggered each one.
    var elaboratedImages: [ElaboratedImage] = []
    /// A user-chosen cover image filename (living directly in this project's own folder, next to
    /// `project.json`) — `nil` means "use the automatic one" (`ProjectStore
    /// .mostRecentThumbnailURL(for:)`'s own most-recent-capture fallback). Removing a custom
    /// thumbnail just clears this back to `nil` rather than needing to somehow "restore" the
    /// automatic one — it was never gone, just shadowed.
    var customThumbnailFileName: String?

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

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, goal, plannedStartDate, plannedEndDate, createdDate, location, tags, notes, sessions,
             isArchived, deletedAt, equipmentSystemID, folderName, rating, isFavorite, elaboratedImages,
             customThumbnailFileName
    }

    /// Same reasoning as `Session`/`CaptureRecord`'s own custom decoders — `rating`/`isFavorite`
    /// are non-`Optional`, so despite their default initial values, Codable's synthesized decoder
    /// would otherwise require both keys, failing to load any `project.json` written before they
    /// existed (every real project on disk before this feature, i.e. all of them). In an
    /// extension so it doesn't suppress the synthesized memberwise initializer `newProject(...)`
    /// and this codebase's many tests rely on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        goal = try container.decode(String.self, forKey: .goal)
        plannedStartDate = try container.decodeIfPresent(Date.self, forKey: .plannedStartDate)
        plannedEndDate = try container.decodeIfPresent(Date.self, forKey: .plannedEndDate)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        location = try container.decodeIfPresent(GeoLocation.self, forKey: .location)
        tags = try container.decode([String].self, forKey: .tags)
        notes = try container.decode([Annotation].self, forKey: .notes)
        sessions = try container.decode([Session].self, forKey: .sessions)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        equipmentSystemID = try container.decodeIfPresent(UUID.self, forKey: .equipmentSystemID)
        folderName = try container.decode(String.self, forKey: .folderName)
        rating = try container.decodeIfPresent(Rating.self, forKey: .rating) ?? .unrated
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        elaboratedImages = try container.decodeIfPresent([ElaboratedImage].self, forKey: .elaboratedImages) ?? []
        customThumbnailFileName = try container.decodeIfPresent(String.self, forKey: .customThumbnailFileName)
    }
}
