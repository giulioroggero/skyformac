import Foundation

/// How an object's own angular size compares to a field of view — "is this fully in frame, too
/// small to be worth much, or too big to fit," the question a framing decision actually turns on,
/// not the raw arcminute numbers themselves.
enum FieldOfViewFit: Equatable, Sendable {
    /// No `majorAxisArcmin` on the catalog entry (most stars, and any object this catalog just
    /// doesn't have a published size for) — there's nothing to compare, not a judgment either way.
    case unknownSize
    /// Smaller than a tenth of the frame's narrow side — technically fits, but framing it alone
    /// would mean a lot of empty sky around a tiny target.
    case small
    case fits
    /// Longer than the frame's narrow side but not its wide side — some real compositions
    /// (a galaxy along the diagonal, say) still work, but a plain rectangular fit won't have it.
    case partiallyFits
    /// Longer than even the frame's wide side — no orientation fits it fully.
    case tooLarge

    /// Classifies `majorAxisArcmin` (an object's longest angular dimension) against a `width` ×
    /// `height` field of view, both in arcminutes.
    static func classify(majorAxisArcmin: Double?, fieldOfViewWidthArcmin width: Double, heightArcmin height: Double) -> FieldOfViewFit {
        guard let majorAxisArcmin, majorAxisArcmin > 0 else { return .unknownSize }
        let narrowSide = min(width, height)
        let wideSide = max(width, height)
        if majorAxisArcmin > wideSide { return .tooLarge }
        if majorAxisArcmin > narrowSide { return .partiallyFits }
        if majorAxisArcmin < narrowSide * 0.1 { return .small }
        return .fits
    }
}

/// An 8-point compass direction, derived from an azimuth (0° = north, increasing eastward) — the
/// "which way do I actually have to look" framing an observer uses, not a raw bearing number.
enum CardinalDirection: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case n = "N", ne = "NE", e = "E", se = "SE", s = "S", sw = "SW", w = "W", nw = "NW"
    var id: String { rawValue }

    /// The azimuth this compass point is centered on — the anchor `HorizonProfile` interpolates
    /// between.
    var azimuthDegrees: Double {
        Double(CardinalDirection.allCases.firstIndex(of: self) ?? 0) * (360 / Double(CardinalDirection.allCases.count))
    }

    static func nearest(toAzimuthDegrees azimuth: Double) -> CardinalDirection {
        let step = 360.0 / Double(allCases.count)
        let normalized = azimuth.truncatingRemainder(dividingBy: 360)
        let wrapped = normalized < 0 ? normalized + 360 : normalized
        let index = Int((wrapped / step).rounded()) % allCases.count
        return allCases[index]
    }
}

/// A per-direction "how high do I actually need to clear before this is above my own rooftop,
/// trees, or a neighboring building" horizon — the astronomical horizon (0°) is rarely the
/// observer's *real* one. Stored as 8 compass-point anchors (`CardinalDirection.allCases` order);
/// anything in between is linearly interpolated between its two neighbors, so the obstruction
/// outline reads as one smooth shape rather than 8 flat steps.
struct HorizonProfile: Codable, Equatable, Sendable {
    /// One altitude value per `CardinalDirection.allCases`, in that order.
    var altitudesDegrees: [Double]

    static let clear = HorizonProfile.uniform(0)

    /// The same obstruction altitude in every direction — a flat "minimum altitude" number
    /// expressed as a `HorizonProfile`, the shape every visibility scan actually consumes now.
    static func uniform(_ altitudeDegrees: Double) -> HorizonProfile {
        HorizonProfile(altitudesDegrees: Array(repeating: altitudeDegrees, count: CardinalDirection.allCases.count))
    }

    func altitude(for direction: CardinalDirection) -> Double {
        guard let index = CardinalDirection.allCases.firstIndex(of: direction), altitudesDegrees.indices.contains(index) else { return 0 }
        return altitudesDegrees[index]
    }

    mutating func setAltitude(_ altitude: Double, for direction: CardinalDirection) {
        guard let index = CardinalDirection.allCases.firstIndex(of: direction) else { return }
        while altitudesDegrees.count <= index { altitudesDegrees.append(0) }
        altitudesDegrees[index] = altitude
    }

    func altitudeDegrees(atAzimuthDegrees azimuth: Double) -> Double {
        let directions = CardinalDirection.allCases
        let step = 360.0 / Double(directions.count)
        let normalized = azimuth.truncatingRemainder(dividingBy: 360)
        let wrapped = normalized < 0 ? normalized + 360 : normalized
        let lowerIndex = Int(wrapped / step) % directions.count
        let upperIndex = (lowerIndex + 1) % directions.count
        let fraction = (wrapped - Double(lowerIndex) * step) / step
        let lowerAltitude = altitude(for: directions[lowerIndex])
        let upperAltitude = altitude(for: directions[upperIndex])
        return lowerAltitude + (upperAltitude - lowerAltitude) * fraction
    }
}

/// "A database of sky objects with what can be seen in a certain period of time, at what
/// lat/long" — combines `SkyCatalog`'s bundled Messier/Caldwell/NGC/bright-star objects with
/// `HorizontalCoordinates`' RA/Dec → Alt/Az conversion to answer "what's actually worth pointing
/// at, from here, on this night," the starting point `SkyVisibilityExplorerView` builds a new
/// project/session/capture from.
enum SkyVisibilityCalculator {
    struct Result: Identifiable, Sendable {
        var id: String { object.id }
        let object: SkyCatalogObject
        /// The highest altitude (degrees above the horizon) this object reaches during the
        /// night's dark window.
        let maxAltitudeDegrees: Double
        /// When it reaches that peak — the best time to actually be imaging it.
        let timeOfMaxAltitude: Date
        /// When it climbs back above the horizon before the peak, and drops back below it after —
        /// "when rise and when is no longer visible," independent of whether that happens to fall
        /// inside the dark window itself (an object can rise in daylight and still be well placed
        /// once it's actually dark). `nil` for either one means circumpolar in that direction —
        /// already up before this whole 24h scan started, or still up at the end of it.
        let riseTime: Date?
        let setTime: Date?
    }

    /// Scans ±12h around `peakTime` at `sampleInterval` steps to find the nearest 0°-altitude
    /// crossings on either side — "rises" (below → above) before the peak, "sets" (above → below)
    /// after it. Not the same sampling pass `visibleObjects` already did to find the peak itself,
    /// since a rise/set can fall well outside the dark window that pass was scoped to.
    /// Not `private` — `SkyObjectResolver` reuses this directly for the "look this object up from
    /// anywhere in the app" flow, where there's no already-computed peak to hang it off of the way
    /// `visibleObjects`'s own internal call does.
    static func riseAndSetTimes(
        raDegrees: Double, decDegrees: Double, latitudeDegrees: Double, longitudeDegrees: Double,
        around peakTime: Date, sampleInterval: TimeInterval = 10 * 60
    ) -> (rise: Date?, set: Date?) {
        let span = 12 * 3600.0
        let start = peakTime.addingTimeInterval(-span)
        let sampleCount = Int(2 * span / sampleInterval)
        var previous: (date: Date, altitude: Double)?
        var rise: Date?
        var set: Date?
        for i in 0...sampleCount {
            let sampleDate = start.addingTimeInterval(Double(i) * sampleInterval)
            let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                raDegrees: raDegrees, decDegrees: decDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
            )
            if let previous {
                if previous.altitude < 0, altitude >= 0, sampleDate <= peakTime {
                    rise = sampleDate
                }
                if previous.altitude >= 0, altitude < 0, sampleDate > peakTime, set == nil {
                    set = sampleDate
                }
            }
            previous = (sampleDate, altitude)
        }
        return (rise, set)
    }

    /// The night's dark window for `date`'s evening — from when the Sun drops below
    /// `sunAltitudeThresholdDegrees` to when it climbs back above it the next morning. Default
    /// -12° (nautical twilight) rather than -18° (full astronomical darkness): plenty dark enough
    /// for realistic amateur imaging, without excluding evenings where a target sets before true
    /// astronomical night ever falls (common at high latitude in summer). `nil` if the Sun never
    /// actually drops that low within 24h of `date` (far-northern/southern summer).
    static func nightWindow(
        for date: Date, latitudeDegrees: Double, longitudeDegrees: Double, sunAltitudeThresholdDegrees: Double = -12
    ) -> (start: Date, end: Date)? {
        let calendar = Calendar(identifier: .gregorian)
        // Which evening's night `date` belongs to: a pre-noon time (the small hours, still dark
        // before dawn) is part of the night that started the *previous* day's evening, not a night
        // that's still hours away. Scanning from that evening's own noon — rather than literal noon
        // of `date`'s own calendar day — is what keeps a 2am `date` finding last night's already-
        // passed dusk and this morning's upcoming dawn, instead of jumping a full day ahead to
        // tonight's dusk and tomorrow's dawn.
        let hour = calendar.component(.hour, from: date)
        let eveningDay = hour < 12 ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: eveningDay) ?? date
        let sampleCount = 24 * 4 // every 15 minutes across the following 24h
        var samples: [(date: Date, altitude: Double)] = []
        samples.reserveCapacity(sampleCount + 1)
        for i in 0...sampleCount {
            let sampleDate = noon.addingTimeInterval(Double(i) * 900)
            let sunRA = SolarPosition.rightAscensionDegrees(on: sampleDate)
            let sunDec = SolarPosition.declinationDegrees(on: sampleDate)
            let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                raDegrees: sunRA, decDegrees: sunDec,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
            )
            samples.append((sampleDate, altitude))
        }

        // `nil` only means "the Sun never drops below the threshold at all" (polar day/high
        // summer at high latitude) — genuinely no dark window to report. If it *does* drop below
        // but never climbs back within the scanned 24h (deep polar winter, permanent darkness),
        // that's the opposite extreme, not "no window": the rest of the scan is dark throughout,
        // so the window runs to the end of what was actually sampled.
        guard let firstDusk = samples.first(where: { $0.altitude < sunAltitudeThresholdDegrees }) else { return nil }
        let dawnDate = samples.first(where: { $0.date > firstDusk.date && $0.altitude >= sunAltitudeThresholdDegrees })?.date
            ?? samples.last!.date
        return (firstDusk.date, dawnDate)
    }

    /// The highest altitude a single fixed RA/Dec position reaches during tonight's dark window,
    /// and when — the single-object version of what `visibleObjects`'s own inner loop computes
    /// per catalog entry, pulled out so `SkyObjectResolver` (looking an object up from some other
    /// page, with no whole-catalog scan to piggyback on) can get the same answer for just one.
    /// `nil` only when there's no dark window tonight at all (see `nightWindow`'s own doc comment).
    static func peakTonight(
        raDegrees: Double, decDegrees: Double, latitudeDegrees: Double, longitudeDegrees: Double, on date: Date
    ) -> (altitude: Double, time: Date)? {
        guard let window = nightWindow(for: date, latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees) else {
            return nil
        }
        let sampleInterval: TimeInterval = 20 * 60
        let sampleCount = max(1, Int(window.end.timeIntervalSince(window.start) / sampleInterval))
        var bestAltitude = -90.0
        var bestTime = window.start
        for i in 0...sampleCount {
            let sampleDate = window.start.addingTimeInterval(Double(i) * sampleInterval)
            let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                raDegrees: raDegrees, decDegrees: decDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
            )
            if altitude > bestAltitude { bestAltitude = altitude; bestTime = sampleDate }
        }
        return (bestAltitude, bestTime)
    }

    /// Every catalog object whose peak altitude during the night reaches at least
    /// `minAltitudeDegrees`, sorted best-placed (highest peak) first. Runs a full catalog scan
    /// synchronously — cheap enough (a few hundred objects × ~30 samples each, plain trig) to not
    /// need its own background-thread contract, but callers still wrap it in a `Task` since it's
    /// still real work on the UI's behalf.
    /// Scans `sampleCount + 1` evenly-spaced samples from `windowStart`, returning the highest
    /// altitude that clears `horizonProfile` in whatever direction it's in *at that moment*
    /// (`clearsHorizon: true`), or — if it never does — the highest altitude reached regardless
    /// (`clearsHorizon: false`, so a caller can still exclude it while reporting a meaningful
    /// "best it ever got" rather than a meaningless first-sample default). Direction-aware because
    /// an object's azimuth moves through the night just as much as its altitude does — its peak
    /// altitude moment and its best-facing moment aren't necessarily the same one.
    private static func bestHorizonClearingPlacement(
        sampleCount: Int, windowStart: Date, sampleInterval: TimeInterval,
        latitudeDegrees: Double, longitudeDegrees: Double, horizonProfile: HorizonProfile,
        raAt: (Date) -> Double, decAt: (Date) -> Double
    ) -> (altitude: Double, time: Date, clearsHorizon: Bool) {
        var bestAltitude = -90.0
        var bestTime = windowStart
        var clearsHorizonAtBest = false
        for i in 0...sampleCount {
            let sampleDate = windowStart.addingTimeInterval(Double(i) * sampleInterval)
            let (altitude, azimuth) = HorizontalCoordinates.altitudeAzimuth(
                raDegrees: raAt(sampleDate), decDegrees: decAt(sampleDate),
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
            )
            let clearsHorizon = altitude > horizonProfile.altitudeDegrees(atAzimuthDegrees: azimuth)
            if clearsHorizon && (!clearsHorizonAtBest || altitude > bestAltitude) {
                bestAltitude = altitude
                bestTime = sampleDate
                clearsHorizonAtBest = true
            } else if !clearsHorizonAtBest && altitude > bestAltitude {
                bestAltitude = altitude
                bestTime = sampleDate
            }
        }
        return (bestAltitude, bestTime, clearsHorizonAtBest)
    }

    /// "Visible" now means "clears the observer's own horizon" (`horizonProfile` — flat 0° by
    /// default, i.e. the plain mathematical horizon, unless the caller passes a real per-direction
    /// profile), not an arbitrary flat altitude floor — there's no astronomically meaningful
    /// "20°," only whatever this particular sky actually has in the way.
    static func visibleObjects(
        in catalog: [SkyCatalogObject], on date: Date, latitudeDegrees: Double, longitudeDegrees: Double,
        horizonProfile: HorizonProfile = .clear
    ) -> [Result] {
        guard let window = nightWindow(for: date, latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees) else {
            return []
        }
        let sampleInterval: TimeInterval = 20 * 60
        let sampleCount = max(1, Int(window.end.timeIntervalSince(window.start) / sampleInterval))

        var results: [Result] = []
        results.reserveCapacity(catalog.count)
        for object in catalog {
            let placement = bestHorizonClearingPlacement(
                sampleCount: sampleCount, windowStart: window.start, sampleInterval: sampleInterval,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, horizonProfile: horizonProfile,
                raAt: { _ in object.raDegrees }, decAt: { _ in object.decDegrees }
            )
            guard placement.clearsHorizon else { continue }
            let (rise, set) = riseAndSetTimes(
                raDegrees: object.raDegrees, decDegrees: object.decDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, around: placement.time
            )
            results.append(Result(object: object, maxAltitudeDegrees: placement.altitude, timeOfMaxAltitude: placement.time, riseTime: rise, setTime: set))
        }
        return results.sorted { $0.maxAltitudeDegrees > $1.maxAltitudeDegrees }
    }

    struct PlanetResult: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let maxAltitudeDegrees: Double
        let timeOfMaxAltitude: Date
        let riseTime: Date?
        let setTime: Date?
        /// A representative typical apparent magnitude (see
        /// `PlanetaryPositionCalculator.Planet.typicalApparentMagnitude`) — not this specific
        /// night's real value, but enough to size a sky-map dot or apply a magnitude filter.
        let magnitude: Double
    }

    /// Same idea as `visibleObjects`, for the Moon and every naked-eye planet — these don't have
    /// a fixed `SkyCatalogObject` position (they move night to night), so `PlanetaryPositionCalculator`
    /// computes each one fresh for `date` instead of reading from the bundled catalog.
    static func visiblePlanets(
        on date: Date, latitudeDegrees: Double, longitudeDegrees: Double, horizonProfile: HorizonProfile = .clear
    ) -> [PlanetResult] {
        guard let window = nightWindow(for: date, latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees) else {
            return []
        }
        let sampleInterval: TimeInterval = 20 * 60
        let sampleCount = max(1, Int(window.end.timeIntervalSince(window.start) / sampleInterval))

        func bestPlacement(raAt: @escaping (Date) -> Double, decAt: @escaping (Date) -> Double) -> (altitude: Double, time: Date, clearsHorizon: Bool) {
            bestHorizonClearingPlacement(
                sampleCount: sampleCount, windowStart: window.start, sampleInterval: sampleInterval,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, horizonProfile: horizonProfile,
                raAt: raAt, decAt: decAt
            )
        }

        var results: [PlanetResult] = []
        for planet in PlanetaryPositionCalculator.Planet.allCases {
            let placement = bestPlacement(
                raAt: { PlanetaryPositionCalculator.position(of: planet, on: $0).rightAscensionDegrees },
                decAt: { PlanetaryPositionCalculator.position(of: planet, on: $0).declinationDegrees }
            )
            guard placement.clearsHorizon else { continue }
            let position = PlanetaryPositionCalculator.position(of: planet, on: placement.time)
            let (rise, set) = riseAndSetTimes(
                raDegrees: position.rightAscensionDegrees, decDegrees: position.declinationDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, around: placement.time
            )
            results.append(PlanetResult(
                name: planet.rawValue, maxAltitudeDegrees: placement.altitude, timeOfMaxAltitude: placement.time,
                riseTime: rise, setTime: set, magnitude: planet.typicalApparentMagnitude
            ))
        }

        let moonPlacement = bestPlacement(
            raAt: { PlanetaryPositionCalculator.moonPosition(on: $0).equatorial.rightAscensionDegrees },
            decAt: { PlanetaryPositionCalculator.moonPosition(on: $0).equatorial.declinationDegrees }
        )
        if moonPlacement.clearsHorizon {
            let position = PlanetaryPositionCalculator.moonPosition(on: moonPlacement.time).equatorial
            let (rise, set) = riseAndSetTimes(
                raDegrees: position.rightAscensionDegrees, decDegrees: position.declinationDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, around: moonPlacement.time
            )
            results.append(PlanetResult(
                name: "Moon", maxAltitudeDegrees: moonPlacement.altitude, timeOfMaxAltitude: moonPlacement.time,
                riseTime: rise, setTime: set, magnitude: PlanetaryPositionCalculator.moonTypicalApparentMagnitude
            ))
        }

        return results.sorted { $0.maxAltitudeDegrees > $1.maxAltitudeDegrees }
    }

    struct AltitudeSample: Identifiable, Sendable {
        var id: Date { time }
        let time: Date
        let altitudeDegrees: Double
    }

    /// A full-day altitude-vs-time curve for one fixed RA/Dec position — the data behind each "What
    /// to See" result's own small altitude chart. Spans midnight to midnight of `date`'s own
    /// calendar day (not just the dark window `visibleObjects` scopes its peak-finding to), so the
    /// chart shows the whole rise-to-set shape, daylight portions included.
    static func altitudeCurve(
        raDegrees: Double, decDegrees: Double, latitudeDegrees: Double, longitudeDegrees: Double,
        on date: Date, sampleIntervalMinutes: Int = 15
    ) -> [AltitudeSample] {
        let calendar = Calendar(identifier: .gregorian)
        let startOfDay = calendar.startOfDay(for: date)
        let sampleCount = (24 * 60) / sampleIntervalMinutes
        var samples: [AltitudeSample] = []
        samples.reserveCapacity(sampleCount + 1)
        for i in 0...sampleCount {
            let sampleDate = startOfDay.addingTimeInterval(Double(i * sampleIntervalMinutes * 60))
            let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                raDegrees: raDegrees, decDegrees: decDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
            )
            samples.append(AltitudeSample(time: sampleDate, altitudeDegrees: altitude))
        }
        return samples
    }
}
