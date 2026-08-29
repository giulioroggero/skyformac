import Foundation

/// "Satellite/transit event alerts (planetary conjunctions, lunar events)" — scoped to what a
/// low-precision geocentric position model (`PlanetaryPositionCalculator`) can actually support
/// well: Moon phase, and planet-pairs (including the Moon) passing close together in the sky.
/// Real satellite passes (the ISS, say) need precise, frequently-updated orbital elements (TLEs)
/// this app has no source for and no business hardcoding — left out rather than faked.
enum SkyEventsCalculator {
    struct MoonPhase {
        var illuminatedFraction: Double
        var phaseName: String
    }

    struct Conjunction: Identifiable {
        var id: String { "\(bodyA)-\(bodyB)-\(Int(date.timeIntervalSince1970))" }
        var date: Date
        var bodyA: String
        var bodyB: String
        var separationDegrees: Double
    }

    /// The Moon's illuminated fraction (0 = new, 1 = full) and a human phase name, from its
    /// elongation from the Sun along the ecliptic — `(1 - cos(elongation)) / 2`, the standard
    /// phase-angle-to-illumination relation for a body lit by a much more distant source.
    static func moonPhase(on date: Date = Date()) -> MoonPhase {
        let moon = PlanetaryPositionCalculator.moonPosition(on: date)
        let sunLongitude = PlanetaryPositionCalculator.sunEclipticLongitudeDegrees(on: date)
        let elongation = angularDifferenceDegrees(moon.eclipticLongitudeDegrees, sunLongitude)
        let illuminated = (1 - cos(elongation * .pi / 180)) / 2
        return MoonPhase(illuminatedFraction: illuminated, phaseName: phaseName(elongationDegrees: elongation, isWaxing: isWaxing(on: date)))
    }

    /// Every naked-eye-planet pair (plus the Moon) that comes within `thresholdDegrees` of each
    /// other at some point in `dateRange`, one entry per pair at its closest approach — sampled
    /// daily, which is plenty of resolution for a conjunction that's visually notable for days
    /// around its actual minimum separation anyway.
    static func conjunctions(in dateRange: ClosedRange<Date>, thresholdDegrees: Double = 5) -> [Conjunction] {
        let calendar = Calendar(identifier: .gregorian)
        var sampleDates: [Date] = []
        var current = dateRange.lowerBound
        while current <= dateRange.upperBound {
            sampleDates.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        guard !sampleDates.isEmpty else { return [] }

        var bodyNames = PlanetaryPositionCalculator.Planet.allCases.map(\.rawValue)
        bodyNames.append("Moon")

        func position(of name: String, on date: Date) -> PlanetaryPositionCalculator.EquatorialPosition {
            if name == "Moon" { return PlanetaryPositionCalculator.moonPosition(on: date).equatorial }
            return PlanetaryPositionCalculator.position(of: PlanetaryPositionCalculator.Planet(rawValue: name)!, on: date)
        }

        var results: [Conjunction] = []
        for i in 0..<bodyNames.count {
            for j in (i + 1)..<bodyNames.count {
                var closest: (date: Date, separation: Double)?
                for date in sampleDates {
                    let a = position(of: bodyNames[i], on: date)
                    let b = position(of: bodyNames[j], on: date)
                    let separation = angularSeparationDegrees(
                        raA: a.rightAscensionDegrees, decA: a.declinationDegrees,
                        raB: b.rightAscensionDegrees, decB: b.declinationDegrees
                    )
                    if closest == nil || separation < closest!.separation {
                        closest = (date, separation)
                    }
                }
                if let closest, closest.separation <= thresholdDegrees {
                    results.append(Conjunction(date: closest.date, bodyA: bodyNames[i], bodyB: bodyNames[j], separationDegrees: closest.separation))
                }
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    /// Great-circle angular separation between two RA/Dec positions (the spherical law of
    /// cosines) — degrees, always `0...180`.
    private static func angularSeparationDegrees(raA: Double, decA: Double, raB: Double, decB: Double) -> Double {
        let ra1 = raA * .pi / 180, dec1 = decA * .pi / 180
        let ra2 = raB * .pi / 180, dec2 = decB * .pi / 180
        let cosSeparation = sin(dec1) * sin(dec2) + cos(dec1) * cos(dec2) * cos(ra1 - ra2)
        return acos(min(1, max(-1, cosSeparation))) * 180 / .pi
    }

    private static func angularDifferenceDegrees(_ a: Double, _ b: Double) -> Double {
        var difference = (a - b).truncatingRemainder(dividingBy: 360)
        if difference < 0 { difference += 360 }
        return difference > 180 ? 360 - difference : difference
    }

    private static func isWaxing(on date: Date) -> Bool {
        let laterMoon = PlanetaryPositionCalculator.moonPosition(on: date.addingTimeInterval(3600))
        let laterSun = PlanetaryPositionCalculator.sunEclipticLongitudeDegrees(on: date.addingTimeInterval(3600))
        let currentMoon = PlanetaryPositionCalculator.moonPosition(on: date)
        let currentSun = PlanetaryPositionCalculator.sunEclipticLongitudeDegrees(on: date)
        let laterElongation = angularDifferenceDegrees(laterMoon.eclipticLongitudeDegrees, laterSun)
        let currentElongation = angularDifferenceDegrees(currentMoon.eclipticLongitudeDegrees, currentSun)
        return laterElongation > currentElongation
    }

    private static func phaseName(elongationDegrees: Double, isWaxing: Bool) -> String {
        switch elongationDegrees {
        case ..<10: return "New Moon"
        case 10..<80: return isWaxing ? "Waxing Crescent" : "Waning Crescent"
        case 80..<100: return isWaxing ? "First Quarter" : "Last Quarter"
        case 100..<170: return isWaxing ? "Waxing Gibbous" : "Waning Gibbous"
        default: return "Full Moon"
        }
    }
}
