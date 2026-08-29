import Foundation

/// "Should I even go out tonight" — the one-glance status the menu-bar item shows, built entirely
/// from data already in this app (location, planned objects) plus the low-precision astronomy
/// already added for "What to See"/Sky Events. No weather/seeing API — this app runs entirely
/// locally with no network dependency by design (see `docs/distribution.md`'s own "no telemetry,
/// no account" stance), so "worth it" here means "is it actually dark, and does anything you've
/// already planned clear a useful altitude," not real-time cloud cover.
enum SkyTonightCalculator {
    struct Status {
        var location: GeoLocation?
        var nightWindow: (start: Date, end: Date)?
        var moonPhase: SkyEventsCalculator.MoonPhase
        /// Every distinct `Session.plannedObjects` entry (across every active project) that both
        /// resolves to a fixed sky position (`SkyAtlasLookup` — so not a planet/the Moon, which
        /// have no fixed position a static lookup can place) and clears `minAltitudeDegrees`
        /// sometime during tonight's dark window, sorted best-placed first.
        var visiblePlannedObjects: [(name: String, maxAltitudeDegrees: Double)]

        var isWorthGoingOut: Bool {
            nightWindow != nil && !visiblePlannedObjects.isEmpty
        }
    }

    static func status(
        location: GeoLocation?, plannedObjectNames: [String], date: Date = Date(), minAltitudeDegrees: Double = 30
    ) -> Status {
        let moonPhase = SkyEventsCalculator.moonPhase(on: date)
        guard let location else {
            return Status(location: nil, nightWindow: nil, moonPhase: moonPhase, visiblePlannedObjects: [])
        }
        let window = SkyVisibilityCalculator.nightWindow(for: date, latitudeDegrees: location.latitude, longitudeDegrees: location.longitude)
        var visible: [(name: String, maxAltitudeDegrees: Double)] = []
        if let window {
            let sampleInterval: TimeInterval = 20 * 60
            let sampleCount = max(1, Int(window.end.timeIntervalSince(window.start) / sampleInterval))
            for name in Set(plannedObjectNames) {
                guard let position = SkyAtlasLookup.position(forObjectName: name) else { continue }
                var bestAltitude = -90.0
                for i in 0...sampleCount {
                    let sampleDate = window.start.addingTimeInterval(Double(i) * sampleInterval)
                    let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                        raDegrees: position.raDegrees, decDegrees: position.decDegrees,
                        latitudeDegrees: location.latitude, longitudeDegrees: location.longitude, on: sampleDate
                    )
                    if altitude > bestAltitude { bestAltitude = altitude }
                }
                if bestAltitude >= minAltitudeDegrees { visible.append((name, bestAltitude)) }
            }
        }
        return Status(
            location: location, nightWindow: window, moonPhase: moonPhase,
            visiblePlannedObjects: visible.sorted { $0.maxAltitudeDegrees > $1.maxAltitudeDegrees }
        )
    }
}
