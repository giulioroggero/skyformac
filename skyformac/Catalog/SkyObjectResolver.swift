import Foundation

/// "The object info modal can be opened in other pages of the application where an object is
/// listed, like a captured session or Live Capture" — resolves a bare free-text object name (a
/// `Session.plannedObjects` entry, a live acquisition target) into everything
/// `SkyVisibilityObjectDetailView` needs, the same way "What to See" itself does, but starting
/// from just a name instead of an already-computed `SkyVisibilityCalculator.Result`.
enum SkyObjectResolver {
    struct Info {
        let title: String
        let subtitle: String
        let symbolName: String
        let riseTime: Date?
        let peakTime: Date
        let setTime: Date?
        let skyCoordinates: (raDegrees: Double, decDegrees: Double)?
    }

    /// `nil` when `objectName` matches neither the bundled catalog nor a planet/the Moon — a
    /// free-typed target ("a comet," something not in Messier/Caldwell/NGC/bright stars) has
    /// nothing this can show. `location` being `nil` still resolves the object itself (name, type,
    /// magnitude) but skips rise/peak/set, which need an actual observer position to mean anything.
    static func resolve(objectName: String, location: GeoLocation?, date: Date = Date()) -> Info? {
        let trimmed = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let catalogObject = SkyAtlasLookup.catalogObject(forObjectName: trimmed) {
            let subtitle = "\(catalogObject.friendlyTypeName) · magnitude \(String(format: "%.1f", catalogObject.magnitude))"
            guard let location else {
                return Info(
                    title: catalogObject.displayName, subtitle: subtitle, symbolName: catalogObject.symbolName,
                    riseTime: nil, peakTime: date, setTime: nil,
                    skyCoordinates: (catalogObject.raDegrees, catalogObject.decDegrees)
                )
            }
            let peak = SkyVisibilityCalculator.peakTonight(
                raDegrees: catalogObject.raDegrees, decDegrees: catalogObject.decDegrees,
                latitudeDegrees: location.latitude, longitudeDegrees: location.longitude, on: date
            )
            let peakTime = peak?.time ?? date
            let (rise, set) = SkyVisibilityCalculator.riseAndSetTimes(
                raDegrees: catalogObject.raDegrees, decDegrees: catalogObject.decDegrees,
                latitudeDegrees: location.latitude, longitudeDegrees: location.longitude, around: peakTime
            )
            return Info(
                title: catalogObject.displayName, subtitle: subtitle, symbolName: catalogObject.symbolName,
                riseTime: rise, peakTime: peakTime, setTime: set,
                skyCoordinates: (catalogObject.raDegrees, catalogObject.decDegrees)
            )
        }

        if let planetName = matchingSolarSystemBodyName(trimmed) {
            guard let location else {
                return Info(
                    title: planetName, subtitle: "Solar system body",
                    symbolName: planetName == "Moon" ? "moon.fill" : "circle.fill",
                    riseTime: nil, peakTime: date, setTime: nil, skyCoordinates: nil
                )
            }
            let position: (raDegrees: Double, decDegrees: Double)
            if planetName == "Moon" {
                let moon = PlanetaryPositionCalculator.moonPosition(on: date).equatorial
                position = (moon.rightAscensionDegrees, moon.declinationDegrees)
            } else if let planet = PlanetaryPositionCalculator.Planet(rawValue: planetName) {
                let equatorial = PlanetaryPositionCalculator.position(of: planet, on: date)
                position = (equatorial.rightAscensionDegrees, equatorial.declinationDegrees)
            } else {
                return nil
            }
            let peak = SkyVisibilityCalculator.peakTonight(
                raDegrees: position.raDegrees, decDegrees: position.decDegrees,
                latitudeDegrees: location.latitude, longitudeDegrees: location.longitude, on: date
            )
            let peakTime = peak?.time ?? date
            let (rise, set) = SkyVisibilityCalculator.riseAndSetTimes(
                raDegrees: position.raDegrees, decDegrees: position.decDegrees,
                latitudeDegrees: location.latitude, longitudeDegrees: location.longitude, around: peakTime
            )
            return Info(
                title: planetName, subtitle: "Solar system body",
                symbolName: planetName == "Moon" ? "moon.fill" : "circle.fill",
                riseTime: rise, peakTime: peakTime, setTime: set, skyCoordinates: nil
            )
        }

        return nil
    }

    /// Matches "Saturn", "Moon (Detail)" (`PlanetaryPreset.moon`'s own raw value, what
    /// `CameraManager.quickStart(with:)` actually stores into `plannedObjects`), "the Moon", etc.
    /// — a prefix match against each known name rather than an exact one, since free text around
    /// the app tends to add a parenthetical or article.
    private static func matchingSolarSystemBodyName(_ text: String) -> String? {
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("moon") || lowercased == "the moon" { return "Moon" }
        for planet in PlanetaryPositionCalculator.Planet.allCases where lowercased.hasPrefix(planet.rawValue.lowercased()) {
            return planet.rawValue
        }
        return nil
    }
}
