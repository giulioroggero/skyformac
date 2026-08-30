import Charts
import SwiftUI

/// Everything "What to See" remembers across relaunches — persisted as one blob
/// (`AppSettings.skyVisibilityConfig`) rather than one `UserDefaults` key per field, since it's
/// all read/written together at the same few moments (load on open, save on any change). Sort
/// field and cardinal directions are stored by raw string rather than referencing
/// `SkyVisibilityExplorerView.SortField`/`CardinalDirection` directly, so this stays decodable
/// even if a future case gets renamed — an unrecognized string is just dropped, not a decode
/// failure for the whole blob.
struct SkyVisibilityConfig: Codable, Sendable {
    var latitudeText: String
    var longitudeText: String
    var date: Date
    var sortCriteria: [SortCriterionData]
    var typeFilters: [String]
    var cardinalFilters: [String]
    var isMagnitudeFilterEnabled: Bool
    var maxMagnitudeFilter: Double
    var isHorizonClearanceFilterEnabled: Bool
    var isFieldOfViewFilterEnabled: Bool

    struct SortCriterionData: Codable, Sendable {
        var field: String
        var ascending: Bool
    }
}

/// "A database of sky objects with what can be seen in a certain period of time, at what
/// lat/long. Starting from that the user can create a new project, or a session in an existing
/// project, or launch a capture for an existing session." — scans the bundled Messier/Caldwell/
/// NGC catalog (`SkyCatalog`) against `SkyVisibilityCalculator` for a chosen night/location, and
/// turns any result directly into one of those three actions. Each result also shows its type,
/// magnitude, and peak time, and the whole list can be sorted/filtered by any of those.
///
/// "Add an image example of each object" — deliberately not a real per-object photo: bundling one
/// for every catalog entry (hundreds of objects) would meaningfully bloat the app, and fetching
/// one from the network on demand would be this app's first real network dependency, contrary to
/// the "runs entirely locally, no telemetry, no account" stance the rest of it holds to (see
/// `docs/distribution.md`). Each row instead gets a representative SF Symbol for its object type
/// (`SkyCatalogObject.symbolName`) — genuinely just a type indicator, not presented as a photo of
/// that specific object.
struct SkyVisibilityExplorerView: View {
    var cameraManager: CameraManager
    /// Mirrors `NewProjectSheet`'s own completion closure — the caller decides what "created,
    /// now go look at it" means (`ProjectsBrowserView` resets its path to the new project).
    var onCreateProject: (Project) -> Void
    var onOpenSession: (Project, Session) -> Void

    @State private var date: Date
    /// The calendar day the "Time of Day" slider is currently centered on — deliberately separate
    /// state from `date` itself, not derived from it on every access: `date`'s own calendar day
    /// flips at midnight, exactly the instant a user is most likely to scrub across, so if the
    /// slider recomputed its center from `date` live, dragging through midnight would yank the
    /// center (and the whole 48h window) out from under the thumb mid-drag. Only explicitly
    /// re-pointed when the user picks a genuinely different date (the `DatePicker`) or hits
    /// "Tonight" — never by the slider's own dragging, which only ever moves `date`'s time.
    @State private var sliderAnchorDay: Date
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var results: [SkyVisibilityCalculator.Result] = []
    @State private var isCalculating = false
    @State private var hasCalculated = false
    @State private var recalculationTask: Task<Void, Never>?
    @State private var addingToProjectObject: SkyCatalogObject?
    @State private var launchingCaptureObject: SkyCatalogObject?
    @State private var conjunctions: [SkyEventsCalculator.Conjunction] = []
    @State private var sortCriteria: [SortCriterion] = [SortCriterion(field: .peakAltitude, ascending: false)]
    @State private var typeFilters: Set<String> = []
    @State private var cardinalFilters: Set<CardinalDirection> = []
    @State private var isMagnitudeFilterEnabled = false
    @State private var maxMagnitudeFilter: Double = 12
    @State private var isHorizonClearanceFilterEnabled = false
    @State private var horizonProfile: HorizonProfile = AppSettings.horizonProfile
    @State private var isEditingHorizon = false
    @State private var skyMapWindowController: DetachedContentWindowController?
    @State private var fovWidthArcmin: Double = AppSettings.fieldOfViewWidthArcmin
    @State private var fovHeightArcmin: Double = AppSettings.fieldOfViewHeightArcmin
    @State private var isFieldOfViewFilterEnabled = false
    @State private var planetResults: [SkyVisibilityCalculator.PlanetResult] = []
    @State private var detailSubject: DetailSubject?
    @State private var searchText = ""
    @State private var resultCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]
    @State private var planetCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]

    /// One entry in the "sort by A, then by B…" list — order in the array is priority order
    /// (earlier entries break ties in later ones), so "current altitude, then magnitude" and
    /// "magnitude, then current altitude" are genuinely different orderings, not the same set.
    private struct SortCriterion: Identifiable, Equatable {
        let id = UUID()
        var field: SortField
        var ascending: Bool
    }

    private struct DetailSubject: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbolName: String
        let riseTime: Date?
        let peakTime: Date
        let setTime: Date?
        /// `nil` for planets/the Moon — a real-sky-survey cutout is meaningless for a body that
        /// moves, and SDSS's own imagery doesn't cover the solar system anyway.
        let skyCoordinates: (raDegrees: Double, decDegrees: Double)?
        /// `nil` for planets/the Moon — there's no fixed `SkyCatalogObject` to hang "New Project"/
        /// "Add to Session"/"Launch Capture" off of for something that isn't a catalog entry.
        let catalogObject: SkyCatalogObject?
    }

    private enum SortField: String, CaseIterable, Identifiable {
        case name = "Name", type = "Type", magnitude = "Magnitude", peakAltitude = "Peak Altitude", peakTime = "Peak Time"
        case currentAltitude = "Current Altitude"
        var id: String { rawValue }
    }

    init(cameraManager: CameraManager, onCreateProject: @escaping (Project) -> Void, onOpenSession: @escaping (Project, Session) -> Void) {
        self.cameraManager = cameraManager
        self.onCreateProject = onCreateProject
        self.onOpenSession = onOpenSession
        let saved = AppSettings.skyVisibilityConfig
        let location = cameraManager.locationProvider.lastLocation
        _latitudeText = State(initialValue: saved?.latitudeText ?? location.map { String(format: "%.4f", $0.latitude) } ?? "")
        _longitudeText = State(initialValue: saved?.longitudeText ?? location.map { String(format: "%.4f", $0.longitude) } ?? "")

        let today = Date()
        // 23:00 rather than literal "now" — opening the page at, say, 4pm shouldn't default every
        // reading to broad daylight when the whole point of the page is planning tonight's imaging.
        let defaultDate = Calendar(identifier: .gregorian).date(bySettingHour: 23, minute: 0, second: 0, of: today) ?? today
        // A saved date only wins if it's still "tonight" by the time the page is reopened — the
        // same night's evening through the following dawn (up to 6am), not some older night a
        // saved value happened to be sitting on. Anything stale falls back to the 23:00 default
        // above rather than reopening onto a date that's no longer relevant.
        let calendar = Calendar(identifier: .gregorian)
        let todayStart = calendar.startOfDay(for: today)
        let tomorrow6am = calendar.date(byAdding: .hour, value: 30, to: todayStart) ?? today
        if let savedDate = saved?.date, savedDate >= todayStart, savedDate < tomorrow6am {
            _date = State(initialValue: savedDate)
            _sliderAnchorDay = State(initialValue: savedDate)
        } else {
            _date = State(initialValue: defaultDate)
            _sliderAnchorDay = State(initialValue: today)
        }

        if let saved {
            let restoredCriteria = saved.sortCriteria.compactMap { entry in
                SortField(rawValue: entry.field).map { SortCriterion(field: $0, ascending: entry.ascending) }
            }
            _sortCriteria = State(initialValue: restoredCriteria.isEmpty ? [SortCriterion(field: .peakAltitude, ascending: false)] : restoredCriteria)
            _typeFilters = State(initialValue: Set(saved.typeFilters))
            _cardinalFilters = State(initialValue: Set(saved.cardinalFilters.compactMap(CardinalDirection.init(rawValue:))))
            _isMagnitudeFilterEnabled = State(initialValue: saved.isMagnitudeFilterEnabled)
            _maxMagnitudeFilter = State(initialValue: saved.maxMagnitudeFilter)
            _isHorizonClearanceFilterEnabled = State(initialValue: saved.isHorizonClearanceFilterEnabled)
            _isFieldOfViewFilterEnabled = State(initialValue: saved.isFieldOfViewFilterEnabled)
        }
    }

    /// Persists everything `SkyVisibilityConfig` tracks — called after any change to one of those
    /// fields (see the `.onChange` chain in `body`) so the next time this page opens, it picks up
    /// where this session left off rather than resetting to built-in defaults.
    private func saveConfig() {
        AppSettings.skyVisibilityConfig = SkyVisibilityConfig(
            latitudeText: latitudeText, longitudeText: longitudeText, date: date,
            sortCriteria: sortCriteria.map { SkyVisibilityConfig.SortCriterionData(field: $0.field.rawValue, ascending: $0.ascending) },
            typeFilters: Array(typeFilters), cardinalFilters: cardinalFilters.map(\.rawValue),
            isMagnitudeFilterEnabled: isMagnitudeFilterEnabled, maxMagnitudeFilter: maxMagnitudeFilter,
            isHorizonClearanceFilterEnabled: isHorizonClearanceFilterEnabled,
            isFieldOfViewFilterEnabled: isFieldOfViewFilterEnabled
        )
    }

    /// Messier + Caldwell + NGC — real deep-sky imaging targets. Bright stars are left out on
    /// purpose: they're catalog entries for plate-solving/star-pattern recognition, not the kind
    /// of thing this planning tool is for.
    private var catalog: [SkyCatalogObject] {
        SkyCatalog.messierObjects + SkyCatalog.caldwellObjects + SkyCatalog.ngcObjects
    }

    /// 23:59 of `sliderAnchorDay` — the fixed pivot the "Time of Day" slider is centered on. Using
    /// a stable, separately-tracked anchor day (rather than deriving "which day" from `date`
    /// itself on every access) is what keeps this constant for an entire drag — see
    /// `sliderAnchorDay`'s own doc comment for why that matters.
    private var sliderCenter: Date {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: sliderAnchorDay) ?? sliderAnchorDay
    }

    /// The `DatePicker`'s own binding — writing through this (rather than `$date` directly) is
    /// what re-centers `sliderAnchorDay` on an explicit date pick, without the "Time of Day"
    /// slider's own dragging (`TimeOfDaySliderView`, which only ever writes `date` directly)
    /// doing the same on every keystroke of scrubbing through midnight.
    private var dateBinding: Binding<Date> {
        Binding(
            get: { date },
            set: { newValue in
                date = newValue
                sliderAnchorDay = newValue
            }
        )
    }

    private var parsedLatitude: Double? { Double(latitudeText) }
    private var parsedLongitude: Double? { Double(longitudeText) }

    /// "Tonight" means *night*, not "whatever the wall clock says right now" — jump to the
    /// midpoint of astronomical darkness (sunset + twilight through sunrise), computed from
    /// today's date at this location, so the slider and results land on actual sky-dark sky
    /// rather than, say, 10am. Falls back to right now if there's no location yet to compute a
    /// night window from, or the sun never gets dark enough tonight (polar day).
    private func jumpToTonight() {
        sliderAnchorDay = Date()
        guard let latitude = parsedLatitude, let longitude = parsedLongitude,
              let window = SkyVisibilityCalculator.nightWindow(
                  for: Date(), latitudeDegrees: latitude, longitudeDegrees: longitude, sunAltitudeThresholdDegrees: -12
              ) else {
            date = Date()
            return
        }
        date = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
    }

    /// Every distinct object type actually present in the current results — a dropdown listing
    /// types that would filter everything out isn't useful, so this only ever shows what's here.
    private var availableTypes: [String] {
        Array(Set(results.map(\.object.friendlyTypeName))).sorted()
    }

    private var displayedResults: [SkyVisibilityCalculator.Result] {
        var filtered = results
        if !typeFilters.isEmpty {
            filtered = filtered.filter { typeFilters.contains($0.object.friendlyTypeName) }
        }
        if isMagnitudeFilterEnabled {
            filtered = filtered.filter { $0.object.magnitude <= maxMagnitudeFilter }
        }
        if !cardinalFilters.isEmpty {
            filtered = filtered.filter {
                cardinalFilters.contains(currentDirection(raDegrees: $0.object.raDegrees, decDegrees: $0.object.decDegrees))
            }
        }
        if isHorizonClearanceFilterEnabled {
            filtered = filtered.filter { isClearOfHorizon(raDegrees: $0.object.raDegrees, decDegrees: $0.object.decDegrees) }
        }
        if isFieldOfViewFilterEnabled {
            filtered = filtered.filter { fieldOfViewFit(for: $0.object) != .tooLarge }
        }
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            filtered = filtered.filter {
                $0.object.displayName.localizedCaseInsensitiveContains(trimmedSearch) || $0.object.id.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }
        // Applied least-significant-first: `Array.sorted(by:)` is stable (guaranteed since Swift
        // 5), so each later (more significant) pass only reorders across ties from the passes
        // before it, rather than undoing them — exactly what "sort by A, then by B" needs.
        var sorted = filtered
        for criterion in sortCriteria.reversed() {
            sorted = sortSingle(sorted, field: criterion.field, ascending: criterion.ascending)
        }
        return sorted
    }

    private func sortSingle(_ items: [SkyVisibilityCalculator.Result], field: SortField, ascending: Bool) -> [SkyVisibilityCalculator.Result] {
        switch field {
        case .name:
            return items.sorted { ascending ? $0.object.displayName < $1.object.displayName : $0.object.displayName > $1.object.displayName }
        case .type:
            return items.sorted { ascending ? $0.object.friendlyTypeName < $1.object.friendlyTypeName : $0.object.friendlyTypeName > $1.object.friendlyTypeName }
        case .magnitude:
            return items.sorted { ascending ? $0.object.magnitude < $1.object.magnitude : $0.object.magnitude > $1.object.magnitude }
        case .peakAltitude:
            return items.sorted { ascending ? $0.maxAltitudeDegrees < $1.maxAltitudeDegrees : $0.maxAltitudeDegrees > $1.maxAltitudeDegrees }
        case .peakTime:
            return items.sorted { ascending ? $0.timeOfMaxAltitude < $1.timeOfMaxAltitude : $0.timeOfMaxAltitude > $1.timeOfMaxAltitude }
        case .currentAltitude:
            return items.sorted {
                let lhs = currentAltitude(raDegrees: $0.object.raDegrees, decDegrees: $0.object.decDegrees)
                let rhs = currentAltitude(raDegrees: $1.object.raDegrees, decDegrees: $1.object.decDegrees)
                return ascending ? lhs < rhs : lhs > rhs
            }
        }
    }

    /// The numeric value behind both `altitudeNowText(raDegrees:decDegrees:)` and the "Current
    /// Altitude" sort — `-90` (always sorts last) when there's no location to compute it from yet,
    /// so picking that sort before entering coordinates doesn't silently do nothing.
    private func currentAltitude(raDegrees: Double, decDegrees: Double) -> Double {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return -90 }
        return HorizontalCoordinates.altitudeAzimuth(
            raDegrees: raDegrees, decDegrees: decDegrees, latitudeDegrees: latitude, longitudeDegrees: longitude, on: date
        ).altitude
    }

    private func currentAzimuth(raDegrees: Double, decDegrees: Double) -> Double {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return 0 }
        return HorizontalCoordinates.altitudeAzimuth(
            raDegrees: raDegrees, decDegrees: decDegrees, latitudeDegrees: latitude, longitudeDegrees: longitude, on: date
        ).azimuth
    }

    private func currentDirection(raDegrees: Double, decDegrees: Double) -> CardinalDirection {
        CardinalDirection.nearest(toAzimuthDegrees: currentAzimuth(raDegrees: raDegrees, decDegrees: decDegrees))
    }

    /// Whether this object is currently higher than the obstruction height the user has set for
    /// *its own* current direction — "visible from here" in the sense that actually matters when
    /// there's a real rooftop or tree in the way, not just "above the mathematical 0° horizon."
    private func isClearOfHorizon(raDegrees: Double, decDegrees: Double) -> Bool {
        let altitude = currentAltitude(raDegrees: raDegrees, decDegrees: decDegrees)
        let azimuth = currentAzimuth(raDegrees: raDegrees, decDegrees: decDegrees)
        return altitude > horizonProfile.altitudeDegrees(atAzimuthDegrees: azimuth)
    }

    private func fieldOfViewFit(for object: SkyCatalogObject) -> FieldOfViewFit {
        FieldOfViewFit.classify(majorAxisArcmin: object.majorAxisArcmin, fieldOfViewWidthArcmin: fovWidthArcmin, heightArcmin: fovHeightArcmin)
    }

    private func fieldOfViewFitLabel(_ fit: FieldOfViewFit) -> String? {
        switch fit {
        case .unknownSize: return nil
        case .small: return "Small in frame"
        case .fits: return "Fits in frame"
        case .partiallyFits: return "Partially fits frame"
        case .tooLarge: return "Too large for frame"
        }
    }

    private func fieldOfViewFitColor(_ fit: FieldOfViewFit) -> Color {
        switch fit {
        case .unknownSize, .small: return .secondary
        case .fits: return .green
        case .partiallyFits: return .orange
        case .tooLarge: return .red
        }
    }

    private struct SensorSizePreset: Identifiable {
        let id: String
        let displayName: String
        let widthMM: Double
        let heightMM: Double
    }

    /// Physical sensor dimensions for the cameras already in `EquipmentCatalog` — reusing those
    /// same names (rather than inventing an unrelated list) since they're what a user setting this
    /// up is likely to actually recognize, even though `EquipmentItem` itself doesn't store sensor
    /// size and this preset list isn't read back from a saved `EquipmentSystem`. Widely-published
    /// nominal sensor sizes, not exact-to-the-micron datasheet values — plenty for "roughly what
    /// field of view would this give me."
    private static let sensorSizePresets: [SensorSizePreset] = [
        SensorSizePreset(id: "camera.zwo.asi678mc", displayName: "ZWO ASI678MC (1/1.8″)", widthMM: 7.4, heightMM: 5.3),
        SensorSizePreset(id: "camera.zwo.asi294mc", displayName: "ZWO ASI294MC Pro (4/3″)", widthMM: 19.1, heightMM: 13.0),
        SensorSizePreset(id: "camera.zwo.asi224mc", displayName: "ZWO ASI224MC (1/3″)", widthMM: 4.8, heightMM: 3.6),
        SensorSizePreset(id: "camera.qhy.qhy268m", displayName: "QHYCCD QHY268M (APS-C)", widthMM: 23.5, heightMM: 15.7),
        SensorSizePreset(id: "camera.canon.eosra", displayName: "Canon EOS Ra (Full Frame)", widthMM: 36.0, heightMM: 24.0),
    ]

    private struct EyepiecePreset: Identifiable {
        let id: String
        let displayName: String
        let focalLengthMM: Double
        let apparentFieldDegrees: Double
    }

    /// Same reasoning as `sensorSizePresets`, for the eyepieces already in `EquipmentCatalog` —
    /// published nominal apparent field of view per model (Plössls are conventionally ~50°, a
    /// named "82°" eyepiece is exactly that by design, X-Cel LX is a ~60°-class design).
    private static let eyepiecePresets: [EyepiecePreset] = [
        EyepiecePreset(id: "eyepiece.televue.plossl25", displayName: "Tele Vue Plössl 25mm", focalLengthMM: 25, apparentFieldDegrees: 50),
        EyepiecePreset(id: "eyepiece.explorescientific.82-14", displayName: "Explore Scientific 82° 14mm", focalLengthMM: 14, apparentFieldDegrees: 82),
        EyepiecePreset(id: "eyepiece.celestron.xcel7", displayName: "Celestron X-Cel LX 7mm", focalLengthMM: 7, apparentFieldDegrees: 60),
    ]

    /// Sensor width/height projected through a telescope's focal length — the standard small-angle
    /// approximation (3438 arcmin per radian) astrophotography FOV calculators use.
    private func applyCameraFieldOfView(sensor: SensorSizePreset, telescope: TelescopeProfile) {
        let arcminPerMM = 3438.0 / telescope.focalLengthMillimeters
        fovWidthArcmin = (sensor.widthMM * arcminPerMM).rounded()
        fovHeightArcmin = (sensor.heightMM * arcminPerMM).rounded()
    }

    /// An eyepiece's true field is its own apparent field divided by the magnification it gives on
    /// this telescope (telescope focal length ÷ eyepiece focal length) — a circular field, so width
    /// and height both get the same value rather than a true rectangular frame.
    private func applyEyepieceFieldOfView(eyepiece: EyepiecePreset, telescope: TelescopeProfile) {
        let magnification = telescope.focalLengthMillimeters / eyepiece.focalLengthMM
        let trueFieldArcmin = (eyepiece.apparentFieldDegrees / magnification) * 60
        fovWidthArcmin = trueFieldArcmin.rounded()
        fovHeightArcmin = trueFieldArcmin.rounded()
    }

    /// The Moon/planet's RA/Dec right now — pulled out since `altitudeNowText(planet:)` and the
    /// sky-map dots both need a planet's live position, not just the peak-tonight snapshot
    /// `PlanetResult` itself stores.
    private func planetEquatorial(_ planet: SkyVisibilityCalculator.PlanetResult) -> (raDegrees: Double, decDegrees: Double)? {
        if planet.name == "Moon" {
            let moon = PlanetaryPositionCalculator.moonPosition(on: date).equatorial
            return (moon.rightAscensionDegrees, moon.declinationDegrees)
        } else if let matched = PlanetaryPositionCalculator.Planet(rawValue: planet.name) {
            let equatorial = PlanetaryPositionCalculator.position(of: matched, on: date)
            return (equatorial.rightAscensionDegrees, equatorial.declinationDegrees)
        }
        return nil
    }

    /// Every filtered deep-sky result plus every planet/Moon result, projected onto the sky-map
    /// dial — planets aren't affected by the deep-sky list's own type/search filters (there's
    /// nothing there to filter on), but they do still respect the shared horizon-clearance coloring
    /// so the dial reads as "everything currently up," not just the catalog half of it.
    private var skyMapDots: [SkyCompassView.Dot] {
        guard parsedLatitude != nil, parsedLongitude != nil else { return [] }
        let objectDots = displayedResults.map { result in
            SkyCompassView.Dot(
                id: result.id,
                displayName: result.object.displayName,
                azimuthDegrees: currentAzimuth(raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees),
                altitudeDegrees: currentAltitude(raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees),
                magnitude: result.object.magnitude,
                isClearOfHorizon: isClearOfHorizon(raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees),
                onSelect: { openDetail(for: result) }
            )
        }
        let planetDots = planetResults.compactMap { planet -> SkyCompassView.Dot? in
            guard let position = planetEquatorial(planet) else { return nil }
            return SkyCompassView.Dot(
                id: planet.id,
                displayName: planet.name,
                azimuthDegrees: currentAzimuth(raDegrees: position.raDegrees, decDegrees: position.decDegrees),
                altitudeDegrees: currentAltitude(raDegrees: position.raDegrees, decDegrees: position.decDegrees),
                magnitude: planet.magnitude,
                isClearOfHorizon: isClearOfHorizon(raDegrees: position.raDegrees, decDegrees: position.decDegrees),
                onSelect: { openDetail(for: planet) }
            )
        }
        return objectDots + planetDots
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "Where and When") {
                    LabeledContent("Date & Time") {
                        DatePicker("", selection: dateBinding, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    }
                    Text("Picks which night to scan. Once results are in, scrub the exact time and jump to tonight from \"Filter by,\" below — the time of day is itself a filter on what's visible right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Latitude") {
                        TextField("e.g. 45.4642", text: $latitudeText).frame(width: 140)
                    }
                    LabeledContent("Longitude") {
                        TextField("e.g. 9.1900", text: $longitudeText).frame(width: 140)
                    }
                    Button("Use Current Location") {
                        cameraManager.locationProvider.requestCurrentLocation { location in
                            guard let location else { return }
                            latitudeText = String(format: "%.4f", location.latitude)
                            longitudeText = String(format: "%.4f", location.longitude)
                        }
                    }
                    HStack {
                        Button("Find What's Visible") { Task { await calculate() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(parsedLatitude == nil || parsedLongitude == nil || isCalculating)
                        if isCalculating { ProgressView().controlSize(.small) }
                    }
                }

                PageSection(title: "Sky Events") {
                    LabeledContent("Moon Phase") {
                        Text("\(moonPhase.phaseName) (\(Int(moonPhase.illuminatedFraction * 100))% illuminated)")
                    }
                    if let sunTimes {
                        LabeledContent("Sunset / Sunrise") {
                            Text("\(Self.timeFormatter.string(from: sunTimes.sunset)) / \(Self.timeFormatter.string(from: sunTimes.sunrise))")
                        }
                    } else if parsedLatitude != nil && parsedLongitude != nil {
                        LabeledContent("Sunset / Sunrise") {
                            Text("Sun doesn't set below the horizon on this date/location (polar day).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if hasCalculated {
                        if conjunctions.isEmpty {
                            Text("No planet/Moon conjunctions within a week of this date.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(conjunctions) { conjunction in
                                Text("\(conjunction.bodyA) – \(conjunction.bodyB): \(String(format: "%.1f", conjunction.separationDegrees))° apart on \(Self.dateFormatter.string(from: conjunction.date))")
                                    .font(.caption)
                            }
                        }
                    } else {
                        Text("Planet/Moon conjunctions within a week of this date show up after you find what's visible.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if hasCalculated {
                    PageSection(title: "Planets & Moon Tonight") {
                        if planetResults.isEmpty {
                            Text("No planets or the Moon clear your horizon tonight from this location.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(planetResults) { planet in
                                planetRow(planet)
                                Divider()
                            }
                        }
                    }
                }

                if hasCalculated {
                    PageSection(title: "\(results.count) Object\(results.count == 1 ? "" : "s")") {
                        if results.isEmpty {
                            Text("Nothing in the catalog clears your horizon on this night from this location — adjust your horizon profile in the Sky Map, or try a different date.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("Search by name…", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .padding(.bottom, 4)

                            // The Sky Map sits beside the filters rather than in its own section
                            // further down the page — it's itself a filter (and an editor for the
                            // horizon profile the filters/scan both use), not just an illustration.
                            HStack(alignment: .top, spacing: 24) {
                                sortAndFilterControls
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Sky Map").font(.subheadline.bold())
                                        Spacer()
                                        Button("Detach…") { openSkyMapWindow() }
                                    }
                                    skyMapSection(fillsAvailableSpace: false)
                                }
                            }
                            .padding(.bottom, 4)

                            ForEach(displayedResults) { result in
                                resultRow(result)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("What to See")
        .onChange(of: date) { _, _ in scheduleRecalculation(); saveConfig() }
        .onChange(of: latitudeText) { _, _ in scheduleRecalculation(); saveConfig() }
        .onChange(of: longitudeText) { _, _ in scheduleRecalculation(); saveConfig() }
        .onChange(of: horizonProfile) { _, newValue in
            AppSettings.horizonProfile = newValue
            scheduleRecalculation()
        }
        .onChange(of: sortCriteria) { _, _ in saveConfig() }
        .onChange(of: typeFilters) { _, _ in saveConfig() }
        .onChange(of: cardinalFilters) { _, _ in saveConfig() }
        .onChange(of: isMagnitudeFilterEnabled) { _, _ in saveConfig() }
        .onChange(of: maxMagnitudeFilter) { _, _ in saveConfig() }
        .onChange(of: isHorizonClearanceFilterEnabled) { _, _ in saveConfig() }
        .onChange(of: isFieldOfViewFilterEnabled) { _, _ in saveConfig() }
        .sheet(item: $addingToProjectObject) { object in
            AddSkyObjectToProjectSheet(candidates: cameraManager.projectsLibrary.activeProjects) { project in
                let session = Session.newSession(name: object.displayName, goal: "Observe \(object.displayName)", plannedObjects: [object.displayName])
                if let updated = try? cameraManager.projectsLibrary.addSession(session, to: project) {
                    onOpenSession(updated, session)
                }
            }
        }
        .sheet(item: $launchingCaptureObject) { object in
            LaunchCaptureForSkyObjectSheet(candidates: sessionCandidates) { candidate in
                cameraManager.setActive(project: candidate.project, session: candidate.session)
            }
        }
        .sheet(item: $detailSubject) { subject in
            SkyVisibilityObjectDetailView(
                title: subject.title, subtitle: subject.subtitle, symbolName: subject.symbolName,
                riseTime: subject.riseTime, peakTime: subject.peakTime, setTime: subject.setTime,
                skyCoordinates: subject.skyCoordinates,
                actions: subject.catalogObject.map { object in detailActions(for: object) },
                onDismiss: { detailSubject = nil }
            )
        }
    }

    private var sessionCandidates: [SkyObjectSessionCandidate] {
        cameraManager.projectsLibrary.activeProjects.flatMap { project in
            project.sessions.map { SkyObjectSessionCandidate(project: project, session: $0) }
        }
    }

    private func openDetail(for result: SkyVisibilityCalculator.Result) {
        detailSubject = DetailSubject(
            title: result.object.displayName,
            subtitle: "\(result.object.friendlyTypeName) · magnitude \(String(format: "%.1f", result.magnitudeOrPlaceholder))",
            symbolName: result.object.symbolName,
            riseTime: result.riseTime, peakTime: result.timeOfMaxAltitude, setTime: result.setTime,
            skyCoordinates: (result.object.raDegrees, result.object.decDegrees), catalogObject: result.object
        )
    }

    /// The same three actions `resultRow`'s own `Menu` offers, wired for the detail sheet instead
    /// — each dismisses the detail sheet first, since "Add to Session"/"Launch Capture" present
    /// their own sheet off `addingToProjectObject`/`launchingCaptureObject`, and only one sheet can
    /// be presented from this view at a time.
    private func detailActions(for object: SkyCatalogObject) -> SkyVisibilityObjectDetailView.DetailActions {
        SkyVisibilityObjectDetailView.DetailActions(
            canAddToSession: !cameraManager.projectsLibrary.activeProjects.isEmpty,
            canLaunchCapture: !sessionCandidates.isEmpty,
            onNewProject: {
                detailSubject = nil
                var project = Project.newProject(name: object.displayName, goal: "Observe \(object.displayName)")
                let session = Session.newSession(name: object.displayName, goal: "Observe \(object.displayName)", plannedObjects: [object.displayName])
                project.sessions = [session]
                if (try? cameraManager.projectsLibrary.save(project)) != nil {
                    onCreateProject(project)
                }
            },
            onAddToSession: {
                detailSubject = nil
                addingToProjectObject = object
            },
            onLaunchCapture: {
                detailSubject = nil
                launchingCaptureObject = object
            }
        )
    }

    @ViewBuilder
    private func planetRow(_ planet: SkyVisibilityCalculator.PlanetResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: planet.name == "Moon" ? "moon.fill" : "circle.fill").font(.title2).foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(planet.name).font(.headline)
                Text(riseSetSummary(rise: planet.riseTime, peak: planet.timeOfMaxAltitude, set: planet.setTime, peakAltitude: planet.maxAltitudeDegrees))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let altitudeNow = altitudeNowText(planet: planet) {
                    Text(altitudeNow).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let curve = planetCurves[planet.name] {
                altitudeChart(curve)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(for: planet) }
    }

    private func openDetail(for planet: SkyVisibilityCalculator.PlanetResult) {
        detailSubject = DetailSubject(
            title: planet.name, subtitle: "Solar system body",
            symbolName: planet.name == "Moon" ? "moon.fill" : "circle.fill",
            riseTime: planet.riseTime, peakTime: planet.timeOfMaxAltitude, setTime: planet.setTime,
            skyCoordinates: nil, catalogObject: nil
        )
    }

    /// A compact altitude-vs-time sparkline for one result row — time on the x-axis, altitude on
    /// y, plus a vertical rule marking the currently-picked "Date & Time" so it's obvious at a
    /// glance where "now" falls on the object's own rise/set curve.
    @ViewBuilder
    private func altitudeChart(_ samples: [SkyVisibilityCalculator.AltitudeSample]) -> some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.time), y: .value("Altitude", sample.altitudeDegrees))
            }
            RuleMark(y: .value("Horizon", 0)).foregroundStyle(.secondary.opacity(0.4))
            RuleMark(x: .value("Now", date)).foregroundStyle(.orange.opacity(0.7))
        }
        .chartYScale(domain: -90...90)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [-90, -45, 0, 45, 90]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let altitude = value.as(Double.self) { Text("\(Int(altitude))°") }
                }
            }
        }
        .frame(width: 260, height: 90)
    }

    private func riseSetSummary(rise: Date?, peak: Date, set: Date?, peakAltitude: Double) -> String {
        let riseText = rise.map(Self.timeFormatter.string) ?? "already up"
        let setText = set.map(Self.timeFormatter.string) ?? "still up at dawn"
        return "Rises \(riseText), peaks at \(Int(peakAltitude))° around \(Self.timeFormatter.string(from: peak)), \(set == nil ? setText : "sets \(setText)")"
    }

    /// The reason changing the "Date & Time" field's *time* component (not just its date) does
    /// something visible — the peak/rise/set fields above are all about tonight's dark window as a
    /// whole, unaffected by the exact hour picked, but this reads the object's real altitude at
    /// that exact moment.
    private func altitudeNowText(raDegrees: Double, decDegrees: Double) -> String? {
        guard parsedLatitude != nil, parsedLongitude != nil else { return nil }
        let altitude = currentAltitude(raDegrees: raDegrees, decDegrees: decDegrees)
        let direction = currentDirection(raDegrees: raDegrees, decDegrees: decDegrees)
        return "Altitude at \(Self.timeFormatter.string(from: date)): \(Int(altitude))° (\(direction.rawValue))"
    }

    private func altitudeNowText(planet: SkyVisibilityCalculator.PlanetResult) -> String? {
        guard parsedLatitude != nil, parsedLongitude != nil, let position = planetEquatorial(planet) else { return nil }
        return altitudeNowText(raDegrees: position.raDegrees, decDegrees: position.decDegrees)
    }

    @ViewBuilder
    private func resultRow(_ result: SkyVisibilityCalculator.Result) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // A representative type icon, not a real photo of this specific object — see this
            // file's own top-of-file doc comment for why an actual per-object thumbnail isn't
            // something this app can offer without either bundling a large image set or adding a
            // network dependency it deliberately doesn't have.
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: result.object.symbolName).font(.title2).foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.object.displayName).font(.headline)
                Text("\(result.object.friendlyTypeName) · mag \(String(format: "%.1f", result.magnitudeOrPlaceholder))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(riseSetSummary(rise: result.riseTime, peak: result.timeOfMaxAltitude, set: result.setTime, peakAltitude: result.maxAltitudeDegrees))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let altitudeNow = altitudeNowText(raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees) {
                    Text(altitudeNow).font(.caption2).foregroundStyle(.tertiary)
                }
                if let fitLabel = fieldOfViewFitLabel(fieldOfViewFit(for: result.object)) {
                    Text(fitLabel).font(.caption2).foregroundStyle(fieldOfViewFitColor(fieldOfViewFit(for: result.object)))
                }
            }
            Spacer()
            if let curve = resultCurves[result.id] {
                altitudeChart(curve)
            }
            Menu {
                Button("New Project…") {
                    var project = Project.newProject(name: result.object.displayName, goal: "Observe \(result.object.displayName)")
                    let session = Session.newSession(name: result.object.displayName, goal: "Observe \(result.object.displayName)", plannedObjects: [result.object.displayName])
                    project.sessions = [session]
                    if (try? cameraManager.projectsLibrary.save(project)) != nil {
                        onCreateProject(project)
                    }
                }
                Button("Add Session to Existing Project…") { addingToProjectObject = result.object }
                    .disabled(cameraManager.projectsLibrary.activeProjects.isEmpty)
                Button("Launch Capture for Existing Session…") { launchingCaptureObject = result.object }
                    .disabled(sessionCandidates.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(for: result) }
    }

    /// The "sort by A, then by B" + "filter by type/magnitude/direction/my horizon" controls for
    /// the results list — a `Menu` per multi-select filter rather than a custom picker, since
    /// SwiftUI has no built-in multi-select control and this reuses something already native.
    @ViewBuilder
    private var sortAndFilterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Time of Day").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Tonight") { jumpToTonight() }
                        .help("Jump to tonight's dark sky — after sunset, once astronomical twilight ends")
                }
                TimeOfDaySliderView(date: $date, sliderCenter: sliderCenter)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Field of View").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Width", value: $fovWidthArcmin, format: .number).frame(width: 60)
                    Text("×")
                    TextField("Height", value: $fovHeightArcmin, format: .number).frame(width: 60)
                    Text("arcmin")
                    Menu("Examples…") {
                        Menu("From Camera + Telescope") {
                            ForEach(Self.sensorSizePresets) { sensor in
                                Menu(sensor.displayName) {
                                    ForEach(TelescopeProfile.allCases) { telescope in
                                        Button(telescope.rawValue) { applyCameraFieldOfView(sensor: sensor, telescope: telescope) }
                                    }
                                }
                            }
                        }
                        Menu("From Eyepiece + Telescope") {
                            ForEach(Self.eyepiecePresets) { eyepiece in
                                Menu(eyepiece.displayName) {
                                    ForEach(TelescopeProfile.allCases) { telescope in
                                        Button(telescope.rawValue) { applyEyepieceFieldOfView(eyepiece: eyepiece, telescope: telescope) }
                                    }
                                }
                            }
                        }
                    }
                    .help("Fill in width/height from a common camera+telescope pairing or an eyepiece's own true field, instead of working out the arcminutes by hand.")
                    Toggle("Hide objects too large to fit", isOn: $isFieldOfViewFilterEnabled)
                }
                Text("Shown per object below as \"Fits/Small/Partially fits/Too large\" — objects with no published angular size aren't judged either way.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: fovWidthArcmin) { _, newValue in AppSettings.fieldOfViewWidthArcmin = newValue }
            .onChange(of: fovHeightArcmin) { _, newValue in AppSettings.fieldOfViewHeightArcmin = newValue }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sort by").font(.caption).foregroundStyle(.secondary)
                ForEach($sortCriteria) { $criterion in
                    HStack {
                        Picker("", selection: $criterion.field) {
                            ForEach(SortField.allCases) { field in Text(field.rawValue).tag(field) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Button {
                            criterion.ascending.toggle()
                        } label: {
                            Image(systemName: criterion.ascending ? "arrow.up" : "arrow.down")
                        }
                        .help(criterion.ascending ? "Ascending" : "Descending")
                        if sortCriteria.count > 1 {
                            Button {
                                sortCriteria.removeAll { $0.id == criterion.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                let unusedFields = SortField.allCases.filter { field in !sortCriteria.contains { $0.field == field } }
                if !unusedFields.isEmpty {
                    Menu("Add Sort…") {
                        ForEach(unusedFields) { field in
                            Button(field.rawValue) { sortCriteria.append(SortCriterion(field: field, ascending: false)) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Filter by").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Menu {
                        ForEach(availableTypes, id: \.self) { type in
                            Button {
                                if typeFilters.contains(type) { typeFilters.remove(type) } else { typeFilters.insert(type) }
                            } label: {
                                if typeFilters.contains(type) { Label(type, systemImage: "checkmark") } else { Text(type) }
                            }
                        }
                        if !typeFilters.isEmpty {
                            Divider()
                            Button("Clear") { typeFilters.removeAll() }
                        }
                    } label: {
                        Text(typeFilters.isEmpty ? "All Types" : "\(typeFilters.count) Type\(typeFilters.count == 1 ? "" : "s")")
                    }
                    .frame(width: 130)

                    Menu {
                        ForEach(CardinalDirection.allCases) { direction in
                            Button {
                                if cardinalFilters.contains(direction) { cardinalFilters.remove(direction) } else { cardinalFilters.insert(direction) }
                            } label: {
                                if cardinalFilters.contains(direction) { Label(direction.rawValue, systemImage: "checkmark") } else { Text(direction.rawValue) }
                            }
                        }
                        if !cardinalFilters.isEmpty {
                            Divider()
                            Button("Clear") { cardinalFilters.removeAll() }
                        }
                    } label: {
                        Text(cardinalFilters.isEmpty ? "Any Direction" : cardinalFilters.map(\.rawValue).sorted().joined(separator: ", "))
                    }
                    .frame(width: 150)

                    Toggle(isOn: $isMagnitudeFilterEnabled) {
                        Text("Magnitude ≤ \(String(format: "%.1f", maxMagnitudeFilter))")
                    }
                    if isMagnitudeFilterEnabled {
                        Slider(value: $maxMagnitudeFilter, in: -2...18, step: 0.5).frame(width: 120)
                    }

                    Toggle("Clear of my horizon", isOn: $isHorizonClearanceFilterEnabled)
                        .help("Only show objects currently above the obstruction height set for their direction — see the Sky Map below.")
                }
            }
        }
    }

    /// The 360°-sky-as-a-2D-dial view: azimuth around the edge, altitude toward the center (the
    /// zenith), every currently-filtered object plotted as a dot sized by brightness. Doubles as
    /// the editor for `horizonProfile` — "Edit My Horizon" swaps in draggable handles on the same
    /// dial instead of a separate control, since the whole point is seeing the obstruction shape
    /// against the actual sky it's blocking.
    /// Opens the Sky Map in a real, independently movable/resizable window — the same
    /// `DetachedContentWindowController` Post-Processing/Edit Image use, not a bigger sheet, since
    /// a sheet can't be dragged to a second monitor or resized past what this page declares. The
    /// window's content is `skyMapSection` itself (not a copy), so editing the horizon there
    /// updates the exact same `horizonProfile` this page's own filters and scan already read.
    /// Not a `ScrollView` here (unlike a typical detached-window body) — `fillsAvailableSpace`
    /// means the dial itself is meant to grow and re-center as the window resizes, which a
    /// scrolling container would just clip instead of allowing.
    private func openSkyMapWindow() {
        skyMapWindowController = DetachedContentWindowController(
            title: "Sky Map", contentSize: NSSize(width: 640, height: 720), minSize: NSSize(width: 380, height: 480),
            onClose: { skyMapWindowController = nil }
        ) {
            skyMapSection(fillsAvailableSpace: true)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        skyMapWindowController?.showWindow(nil)
    }

    /// `fillsAvailableSpace`: the embedded (next-to-filters) presentation keeps a fixed, compact
    /// dial so it doesn't fight the results list for room; the detached window (see
    /// `openSkyMapWindow`) instead lets the dial expand and stay centered as the window itself
    /// resizes, since there it's the only thing on screen.
    @ViewBuilder
    private func skyMapSection(fillsAvailableSpace: Bool) -> some View {
        if parsedLatitude == nil || parsedLongitude == nil {
            Text("Enter a location above to see the sky map.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("This *is* what decides what's visible — an object only counts as \"visible\" if it clears this shape somewhere in its own direction, not a separate flat altitude number. Dot size is relative brightness (magnitude); the shaded edge is your own horizon obstruction, not the mathematical one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SkyCompassView(
                    dots: skyMapDots, horizonProfile: $horizonProfile, isEditable: isEditingHorizon,
                    fillsAvailableSpace: fillsAvailableSpace
                )
                Button(isEditingHorizon ? "Done Editing My Horizon" : "Edit My Horizon…") {
                    isEditingHorizon.toggle()
                }
                if isEditingHorizon {
                    Text("Drag a handle out to where trees, a roof, or a building actually block your view in that direction — objects below that line are filtered out by \"Clear of my horizon,\" above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: fillsAvailableSpace ? .infinity : nil, maxHeight: fillsAvailableSpace ? .infinity : nil)
        }
    }

    /// Auto-recalculates "Find What's Visible" (and the Sky Map, which reads the same `results`/
    /// `planetResults`) a beat after the user stops touching date/time/location/minimum-altitude —
    /// debounced rather than firing on every keystroke or slider tick, since a full catalog scan
    /// on every single change (especially while dragging the "Time of Day" slider) would be both
    /// wasteful and visibly janky. Only kicks in once the user has already run the first
    /// calculation manually — a fresh, untouched page shouldn't start scanning in the background
    /// just because a location autofilled from `CoreLocationProvider`.
    private func scheduleRecalculation() {
        guard hasCalculated else { return }
        recalculationTask?.cancel()
        recalculationTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await calculate()
        }
    }

    private func calculate() async {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return }
        isCalculating = true
        let target = catalog
        let selectedDate = date
        let profile = horizonProfile
        let (computedResults, computedConjunctions, computedPlanets, computedResultCurves, computedPlanetCurves) = await Task.detached(priority: .userInitiated) { () -> ([SkyVisibilityCalculator.Result], [SkyEventsCalculator.Conjunction], [SkyVisibilityCalculator.PlanetResult], [String: [SkyVisibilityCalculator.AltitudeSample]], [String: [SkyVisibilityCalculator.AltitudeSample]]) in
            let visible = SkyVisibilityCalculator.visibleObjects(
                in: target, on: selectedDate, latitudeDegrees: latitude, longitudeDegrees: longitude, horizonProfile: profile
            )
            let calendar = Calendar(identifier: .gregorian)
            let windowStart = calendar.date(byAdding: .day, value: -7, to: selectedDate) ?? selectedDate
            let windowEnd = calendar.date(byAdding: .day, value: 7, to: selectedDate) ?? selectedDate
            let events = SkyEventsCalculator.conjunctions(in: windowStart...windowEnd)
            let planets = SkyVisibilityCalculator.visiblePlanets(
                on: selectedDate, latitudeDegrees: latitude, longitudeDegrees: longitude, horizonProfile: profile
            )

            var resultCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]
            for result in visible {
                resultCurves[result.id] = SkyVisibilityCalculator.altitudeCurve(
                    raDegrees: result.object.raDegrees, decDegrees: result.object.decDegrees,
                    latitudeDegrees: latitude, longitudeDegrees: longitude, on: selectedDate
                )
            }
            var planetCurves: [String: [SkyVisibilityCalculator.AltitudeSample]] = [:]
            for planet in planets {
                let position: (raDegrees: Double, decDegrees: Double)
                if planet.name == "Moon" {
                    let moon = PlanetaryPositionCalculator.moonPosition(on: selectedDate).equatorial
                    position = (moon.rightAscensionDegrees, moon.declinationDegrees)
                } else if let matched = PlanetaryPositionCalculator.Planet(rawValue: planet.name) {
                    let equatorial = PlanetaryPositionCalculator.position(of: matched, on: selectedDate)
                    position = (equatorial.rightAscensionDegrees, equatorial.declinationDegrees)
                } else {
                    continue
                }
                planetCurves[planet.name] = SkyVisibilityCalculator.altitudeCurve(
                    raDegrees: position.raDegrees, decDegrees: position.decDegrees,
                    latitudeDegrees: latitude, longitudeDegrees: longitude, on: selectedDate
                )
            }

            return (visible, events, planets, resultCurves, planetCurves)
        }.value
        results = computedResults
        conjunctions = computedConjunctions
        planetResults = computedPlanets
        resultCurves = computedResultCurves
        planetCurves = computedPlanetCurves
        isCalculating = false
        hasCalculated = true
    }

    private var moonPhase: SkyEventsCalculator.MoonPhase { SkyEventsCalculator.moonPhase(on: date) }

    /// `nightWindow`'s own dusk/dawn scan, at a 0° threshold instead of its default -12° — the Sun
    /// crossing the true horizon is exactly sunset/sunrise, not just "dark enough to image." `nil`
    /// without a location, or during a polar-day stretch where the Sun never actually sets.
    private var sunTimes: (sunset: Date, sunrise: Date)? {
        guard let latitude = parsedLatitude, let longitude = parsedLongitude else { return nil }
        guard let window = SkyVisibilityCalculator.nightWindow(
            for: date, latitudeDegrees: latitude, longitudeDegrees: longitude, sunAltitudeThresholdDegrees: 0
        ) else { return nil }
        return (window.start, window.end)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()


    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private extension SkyVisibilityCalculator.Result {
    /// `SkyCatalogObject.magnitude` is always present, but naming it through this small shim
    /// keeps the view's own display logic reading as "whatever we have to show," not tied to the
    /// catalog model's exact field name if that ever changes shape.
    var magnitudeOrPlaceholder: Double { object.magnitude }
}

struct SkyObjectSessionCandidate: Identifiable {
    let project: Project
    let session: Session
    var id: Session.ID { session.id }
}

private struct AddSkyObjectToProjectSheet: View {
    let candidates: [Project]
    var onAdd: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Session to Project").font(.headline).padding()
            Divider()
            if candidates.isEmpty {
                Text("No projects yet — create one first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(candidates) { project in
                    Button {
                        onAdd(project)
                        dismiss()
                    } label: {
                        Text(project.name.isEmpty ? "Untitled Project" : project.name)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}

private struct LaunchCaptureForSkyObjectSheet: View {
    let candidates: [SkyObjectSessionCandidate]
    var onLaunch: (SkyObjectSessionCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Launch Capture for Session").font(.headline).padding()
            Divider()
            if candidates.isEmpty {
                Text("No sessions yet — create a project and session first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(candidates) { candidate in
                    Button {
                        onLaunch(candidate)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.session.name)
                            Text(candidate.project.name.isEmpty ? "Untitled Project" : candidate.project.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}

/// The 360°-sky-flattened-to-a-disc control: azimuth around the edge (north up, east to the
/// right — the same orientation as facing north and looking up), altitude toward the center (the
/// zenith), so "which direction, how high" reads as one glance instead of two separate numbers
/// per object. Also the horizon-obstruction editor — `isEditable` swaps in drag handles on the
/// same 8 compass anchors `horizonProfile` stores, so the shape being edited is always shown
/// against the actual sky it's meant to be excluding.
/// The "move time like Stellarium" slider, split out into its own view so a drag only re-renders
/// this small subview instead of the entire "What to See" page (every result row's chart, the
/// whole Sky Map) on every single tick — when this lived as plain `@State` on the parent view,
/// each tick's state change forced a full re-evaluation of that whole page's body, which is what
/// actually made the slider feel unresponsive despite the drag/commit split already in place.
///
/// Spans a full 48 hours (`0...48`, `24` at `sliderCenter`) rather than one 24-hour day, so both
/// the night before *and* the night after the picked date are reachable without re-picking a date
/// — `sliderCenter` (23:59 of the picked evening) sits at the middle, not the edge, so either
/// night reads as one contiguous stretch on its own half of the track. Dragging moves this view's
/// own `dragValue` immediately (so the thumb and its label feel responsive) but only writes the
/// real `date` binding — and everything expensive that depends on it — on release or a second's
/// pause. A compact `DatePicker` alongside it offers direct keyboard/stepper entry for anyone who'd
/// rather type an exact time than scrub for it; typing there commits immediately, no throttle.
private struct TimeOfDaySliderView: View {
    @Binding var date: Date
    var sliderCenter: Date

    @State private var isDragging = false
    @State private var dragValue: Double = 24
    @State private var commitTask: Task<Void, Never>?

    private var committedValue: Double {
        date.timeIntervalSince(sliderCenter) / 3600 + 24
    }

    private var displayedDate: Date {
        isDragging ? sliderCenter.addingTimeInterval((dragValue - 24) * 3600) : date
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isDragging ? dragValue : committedValue },
            set: { newValue in
                isDragging = true
                dragValue = newValue
                scheduleCommit()
            }
        )
    }

    /// The manual-entry `DatePicker`'s own binding — shows the live scrub position while
    /// dragging (so it never looks stale next to a moving thumb), but a direct edit here commits
    /// straight to `date` and cancels any pending drag-commit rather than fighting with it.
    private var manualEntryBinding: Binding<Date> {
        Binding(
            get: { displayedDate },
            set: { newValue in
                commitTask?.cancel()
                isDragging = false
                date = newValue
            }
        )
    }

    var body: some View {
        HStack {
            Slider(
                value: sliderBinding, in: 0...48, step: 5.0 / 60,
                onEditingChanged: { editing in if !editing { commit() } }
            )
            Text(Self.dayTimeFormatter.string(from: displayedDate))
                .monospacedDigit()
                .frame(width: 110, alignment: .trailing)
            DatePicker("", selection: manualEntryBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
                .frame(width: 80)
        }
        .help("Scrub through 48 hours centered on midnight tonight, Stellarium-style — a filter on \"what's visible right now\" just as much as type or magnitude are. Updates once you release or pause for a second, not on every tick. Or type/step an exact time in the field on the right.")
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        commitTask?.cancel()
        date = sliderCenter.addingTimeInterval((dragValue - 24) * 3600)
        isDragging = false
    }

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return formatter
    }()
}

private struct SkyCompassView: View {
    struct Dot: Identifiable {
        let id: String
        let displayName: String
        let azimuthDegrees: Double
        let altitudeDegrees: Double
        let magnitude: Double
        let isClearOfHorizon: Bool
        var onSelect: () -> Void
    }

    let dots: [Dot]
    @Binding var horizonProfile: HorizonProfile
    var isEditable: Bool
    /// `false` (the default): a fixed, compact dial for sitting next to the filters list. `true`
    /// (the detached window): the dial expands to fill whatever space it's given and stays
    /// centered as that space changes — see `openSkyMapWindow`'s own doc comment.
    var fillsAvailableSpace: Bool = false

    private let margin: CGFloat = 26
    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 3

    @State private var baseZoom: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1
    @State private var hoveredDotID: String?

    private var zoom: CGFloat { min(max(baseZoom * gestureZoom, minZoom), maxZoom) }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if fillsAvailableSpace {
                    GeometryReader { outer in
                        let side = max(120, min(outer.size.width, outer.size.height))
                        dial(side: side)
                            .position(x: outer.size.width / 2, y: outer.size.height / 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    dial(side: 320)
                }
            }

            HStack(spacing: 8) {
                Button {
                    baseZoom = max(baseZoom - 0.5, minZoom)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(baseZoom <= minZoom)
                Button("Reset Zoom") { baseZoom = 1 }
                    .disabled(baseZoom == 1)
                Button {
                    baseZoom = min(baseZoom + 0.5, maxZoom)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(baseZoom >= maxZoom)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// An invisible, generously-sized tap/hover target centered on the dot's own drawn position —
    /// the actual painted dot can be just a few points across (a dim, high-magnitude object), too
    /// small to reliably hit or hover on its own.
    @ViewBuilder
    private func dotHitTarget(_ dot: Dot, in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - margin
        let point = pointOnDial(center: center, radius: radius, azimuthDegrees: dot.azimuthDegrees, altitudeDegrees: dot.altitudeDegrees)
        let targetSize = max(dotDiameter(forMagnitude: dot.magnitude) + 12, 18)
        Circle()
            .fill(Color.clear)
            .frame(width: targetSize, height: targetSize)
            .contentShape(Circle())
            .position(point)
            .onTapGesture { dot.onSelect() }
            .onHover { hovering in
                if hovering {
                    hoveredDotID = dot.id
                } else if hoveredDotID == dot.id {
                    hoveredDotID = nil
                }
            }
    }

    /// The actual dial — a fixed `side` × `side` square, everything computed relative to that so
    /// it works identically whether `side` is the compact embedded 320 or whatever the detached
    /// window's available space resolves to.
    @ViewBuilder
    private func dial(side: CGFloat) -> some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - margin

                for altitude in stride(from: 0.0, through: 90.0, by: 30.0) {
                    let r = radius * CGFloat(1 - altitude / 90)
                    context.stroke(
                        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .color(.secondary.opacity(0.25))
                    )
                    let labelPoint = CGPoint(x: center.x + 4, y: center.y - r)
                    context.draw(
                        Text("\(Int(altitude))°").font(.caption2).foregroundStyle(.secondary),
                        at: labelPoint, anchor: .leading
                    )
                }

                context.fill(horizonPath(center: center, radius: radius), with: .color(.red.opacity(0.18)))
                context.stroke(horizonPath(center: center, radius: radius), with: .color(.red.opacity(0.65)), lineWidth: 1.5)

                for direction in CardinalDirection.allCases {
                    let point = pointOnDial(center: center, radius: radius + margin * 0.55, azimuthDegrees: direction.azimuthDegrees, altitudeDegrees: 0)
                    context.draw(
                        Text(direction.rawValue).font(.caption.bold()).foregroundStyle(.secondary),
                        at: point
                    )
                }

                for dot in dots {
                    let point = pointOnDial(center: center, radius: radius, azimuthDegrees: dot.azimuthDegrees, altitudeDegrees: dot.altitudeDegrees)
                    let diameter = dotDiameter(forMagnitude: dot.magnitude)
                    let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
                    let isHovered = dot.id == hoveredDotID
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(dot.isClearOfHorizon ? .yellow : .secondary.opacity(0.5))
                    )
                    if isHovered {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.white), lineWidth: 1.5)
                    }
                }
            }
            .frame(width: side, height: side)
            .background(Circle().fill(Color.black.opacity(0.85)))

            GeometryReader { proxy in
                ForEach(dots) { dot in
                    dotHitTarget(dot, in: proxy.size)
                }
                if isEditable {
                    ForEach(CardinalDirection.allCases) { direction in
                        horizonHandle(direction: direction, in: proxy.size)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(zoom, anchor: .center)
        .clipped()
        .gesture(
            MagnificationGesture()
                .updating($gestureZoom) { value, state, _ in state = value }
                .onEnded { value in baseZoom = min(max(baseZoom * value, minZoom), maxZoom) }
        )
        .overlay(alignment: .top) {
            if let hoveredDotID, let hovered = dots.first(where: { $0.id == hoveredDotID }) {
                Text(hovered.displayName)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 4)
            }
        }
    }

    private func horizonPath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for (index, direction) in CardinalDirection.allCases.enumerated() {
            let point = pointOnDial(center: center, radius: radius, azimuthDegrees: direction.azimuthDegrees, altitudeDegrees: horizonProfile.altitude(for: direction))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// North up, east to the right, altitude 90° (zenith) at the center and 0° (horizon) at the
    /// edge — `azimuth - 90` rotates the standard "0°=up" screen angle so north lands at the top.
    private func pointOnDial(center: CGPoint, radius: CGFloat, azimuthDegrees: Double, altitudeDegrees: Double) -> CGPoint {
        let clampedAltitude = min(max(altitudeDegrees, 0), 90)
        let r = radius * CGFloat(1 - clampedAltitude / 90)
        let angle = (azimuthDegrees - 90) * .pi / 180
        return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }

    /// Brighter (lower/negative magnitude) objects get a bigger dot — not to scale with real
    /// perceived brightness, just enough spread to be visually obvious at a glance.
    private func dotDiameter(forMagnitude magnitude: Double) -> CGFloat {
        let clamped = min(max(magnitude, -6), 16)
        return CGFloat(16 - clamped) * 0.7 + 4
    }

    @ViewBuilder
    private func horizonHandle(direction: CardinalDirection, in size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - margin
        let point = pointOnDial(center: center, radius: radius, azimuthDegrees: direction.azimuthDegrees, altitudeDegrees: horizonProfile.altitude(for: direction))
        Circle()
            .fill(Color.orange)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - center.x
                        let dy = value.location.y - center.y
                        let distance = sqrt(dx * dx + dy * dy)
                        let newAltitude = 90 * (1 - min(max(distance / radius, 0), 1))
                        horizonProfile.setAltitude(newAltitude, for: direction)
                    }
            )
    }
}
