import Foundation

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
    private static func riseAndSetTimes(
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
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
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

    /// Every catalog object whose peak altitude during the night reaches at least
    /// `minAltitudeDegrees`, sorted best-placed (highest peak) first. Runs a full catalog scan
    /// synchronously — cheap enough (a few hundred objects × ~30 samples each, plain trig) to not
    /// need its own background-thread contract, but callers still wrap it in a `Task` since it's
    /// still real work on the UI's behalf.
    static func visibleObjects(
        in catalog: [SkyCatalogObject], on date: Date, latitudeDegrees: Double, longitudeDegrees: Double,
        minAltitudeDegrees: Double = 20
    ) -> [Result] {
        guard let window = nightWindow(for: date, latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees) else {
            return []
        }
        let sampleInterval: TimeInterval = 20 * 60
        let sampleCount = max(1, Int(window.end.timeIntervalSince(window.start) / sampleInterval))

        var results: [Result] = []
        results.reserveCapacity(catalog.count)
        for object in catalog {
            var bestAltitude = -90.0
            var bestTime = window.start
            for i in 0...sampleCount {
                let sampleDate = window.start.addingTimeInterval(Double(i) * sampleInterval)
                let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                    raDegrees: object.raDegrees, decDegrees: object.decDegrees,
                    latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
                )
                if altitude > bestAltitude {
                    bestAltitude = altitude
                    bestTime = sampleDate
                }
            }
            if bestAltitude >= minAltitudeDegrees {
                let (rise, set) = riseAndSetTimes(
                    raDegrees: object.raDegrees, decDegrees: object.decDegrees,
                    latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, around: bestTime
                )
                results.append(Result(object: object, maxAltitudeDegrees: bestAltitude, timeOfMaxAltitude: bestTime, riseTime: rise, setTime: set))
            }
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
    }

    /// Same idea as `visibleObjects`, for the Moon and every naked-eye planet — these don't have
    /// a fixed `SkyCatalogObject` position (they move night to night), so `PlanetaryPositionCalculator`
    /// computes each one fresh for `date` instead of reading from the bundled catalog.
    static func visiblePlanets(
        on date: Date, latitudeDegrees: Double, longitudeDegrees: Double, minAltitudeDegrees: Double = 20
    ) -> [PlanetResult] {
        guard let window = nightWindow(for: date, latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees) else {
            return []
        }
        let sampleInterval: TimeInterval = 20 * 60
        let sampleCount = max(1, Int(window.end.timeIntervalSince(window.start) / sampleInterval))

        func bestPlacement(raAt: (Date) -> Double, decAt: (Date) -> Double) -> (altitude: Double, time: Date) {
            var bestAltitude = -90.0
            var bestTime = window.start
            for i in 0...sampleCount {
                let sampleDate = window.start.addingTimeInterval(Double(i) * sampleInterval)
                let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                    raDegrees: raAt(sampleDate), decDegrees: decAt(sampleDate),
                    latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, on: sampleDate
                )
                if altitude > bestAltitude { bestAltitude = altitude; bestTime = sampleDate }
            }
            return (bestAltitude, bestTime)
        }

        var results: [PlanetResult] = []
        for planet in PlanetaryPositionCalculator.Planet.allCases {
            let placement = bestPlacement(
                raAt: { PlanetaryPositionCalculator.position(of: planet, on: $0).rightAscensionDegrees },
                decAt: { PlanetaryPositionCalculator.position(of: planet, on: $0).declinationDegrees }
            )
            guard placement.altitude >= minAltitudeDegrees else { continue }
            let position = PlanetaryPositionCalculator.position(of: planet, on: placement.time)
            let (rise, set) = riseAndSetTimes(
                raDegrees: position.rightAscensionDegrees, decDegrees: position.declinationDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, around: placement.time
            )
            results.append(PlanetResult(name: planet.rawValue, maxAltitudeDegrees: placement.altitude, timeOfMaxAltitude: placement.time, riseTime: rise, setTime: set))
        }

        let moonPlacement = bestPlacement(
            raAt: { PlanetaryPositionCalculator.moonPosition(on: $0).equatorial.rightAscensionDegrees },
            decAt: { PlanetaryPositionCalculator.moonPosition(on: $0).equatorial.declinationDegrees }
        )
        if moonPlacement.altitude >= minAltitudeDegrees {
            let position = PlanetaryPositionCalculator.moonPosition(on: moonPlacement.time).equatorial
            let (rise, set) = riseAndSetTimes(
                raDegrees: position.rightAscensionDegrees, decDegrees: position.declinationDegrees,
                latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees, around: moonPlacement.time
            )
            results.append(PlanetResult(name: "Moon", maxAltitudeDegrees: moonPlacement.altitude, timeOfMaxAltitude: moonPlacement.time, riseTime: rise, setTime: set))
        }

        return results.sorted { $0.maxAltitudeDegrees > $1.maxAltitudeDegrees }
    }
}
