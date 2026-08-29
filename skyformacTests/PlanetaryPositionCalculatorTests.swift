import Foundation
import Testing
@testable import skyformac

struct PlanetaryPositionCalculatorTests {
    @Test func everyPlanetPositionStaysWithinValidRARange() {
        let calendar = Calendar(identifier: .gregorian)
        for month in stride(from: 1, through: 12, by: 3) {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 10))!
            for planet in PlanetaryPositionCalculator.Planet.allCases {
                let position = PlanetaryPositionCalculator.position(of: planet, on: date)
                #expect(position.rightAscensionDegrees >= 0 && position.rightAscensionDegrees < 360)
                #expect(position.declinationDegrees >= -90 && position.declinationDegrees <= 90)
            }
        }
    }

    /// Mercury never strays far from the Sun in the sky (its real, well-known maximum elongation
    /// is ~28°) — a genuine astronomical fact this low-precision model should still reproduce
    /// reasonably well, not just "RA/Dec are in range."
    @Test func mercuryStaysCloseToTheSun() {
        let calendar = Calendar(identifier: .gregorian)
        for month in stride(from: 1, through: 12, by: 2) {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 15))!
            let mercury = PlanetaryPositionCalculator.position(of: .mercury, on: date)
            let sunLongitude = PlanetaryPositionCalculator.sunEclipticLongitudeDegrees(on: date)
            // Compare via RA as a rough proxy for ecliptic longitude — close enough near the
            // ecliptic (where Mercury always is) for this sanity bound.
            var difference = abs(mercury.rightAscensionDegrees - sunLongitude).truncatingRemainder(dividingBy: 360)
            if difference > 180 { difference = 360 - difference }
            #expect(difference < 40)
        }
    }

    @Test func moonPositionStaysWithinValidRanges() {
        let calendar = Calendar(identifier: .gregorian)
        for day in stride(from: 1, through: 28, by: 7) {
            let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: day))!
            let moon = PlanetaryPositionCalculator.moonPosition(on: date)
            #expect(moon.equatorial.rightAscensionDegrees >= 0 && moon.equatorial.rightAscensionDegrees < 360)
            #expect(moon.equatorial.declinationDegrees >= -90 && moon.equatorial.declinationDegrees <= 90)
            #expect(moon.eclipticLongitudeDegrees >= 0 && moon.eclipticLongitudeDegrees < 360)
        }
    }
}

struct SkyEventsCalculatorTests {
    @Test func moonPhaseIlluminatedFractionStaysWithinValidRange() {
        let calendar = Calendar(identifier: .gregorian)
        for day in stride(from: 1, through: 28, by: 4) {
            let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: day))!
            let phase = SkyEventsCalculator.moonPhase(on: date)
            #expect(phase.illuminatedFraction >= 0 && phase.illuminatedFraction <= 1)
            #expect(!phase.phaseName.isEmpty)
        }
    }

    @Test func conjunctionsFindsEveryPairAtAGenerousThreshold() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30))!
        // 180° is the maximum possible angular separation — every one of the 6-choose-2 = 15 body
        // pairs trivially clears that "threshold" at every sampled date, so this is really testing
        // that every pair actually gets checked, not that some genuine close approach was found.
        let results = SkyEventsCalculator.conjunctions(in: start...end, thresholdDegrees: 180)
        #expect(results.count == 15)
    }

    @Test func conjunctionsReturnsNothingAtAnImpossiblyTightThreshold() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let results = SkyEventsCalculator.conjunctions(in: start...end, thresholdDegrees: 0)
        #expect(results.isEmpty)
    }
}
