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

        guard let firstDusk = samples.first(where: { $0.altitude < sunAltitudeThresholdDegrees }),
              let dawnIndex = samples.firstIndex(where: { $0.date > firstDusk.date && $0.altitude >= sunAltitudeThresholdDegrees })
        else { return nil }
        return (firstDusk.date, samples[dawnIndex].date)
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
                results.append(Result(object: object, maxAltitudeDegrees: bestAltitude, timeOfMaxAltitude: bestTime))
            }
        }
        return results.sorted { $0.maxAltitudeDegrees > $1.maxAltitudeDegrees }
    }
}
