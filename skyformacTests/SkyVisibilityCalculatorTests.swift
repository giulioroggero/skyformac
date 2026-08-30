import Foundation
import Testing
@testable import skyformac

struct SkyVisibilityCalculatorTests {
    private static let midLatitudeDate = Date(timeIntervalSince1970: 946_728_000) // 2000-01-01, winter in the north

    @Test func nightWindowStartsBeforeItEnds() {
        let window = SkyVisibilityCalculator.nightWindow(
            for: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9
        )
        let unwrapped = try? #require(window)
        #expect((unwrapped?.start ?? .distantFuture) < (unwrapped?.end ?? .distantPast))
    }

    @Test func nightWindowIsGenuinelyDarkAtItsMidpoint() {
        guard let window = SkyVisibilityCalculator.nightWindow(
            for: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9
        ) else {
            Issue.record("expected a night window at mid-latitude in winter")
            return
        }
        let midpoint = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
        let sunRA = SolarPosition.rightAscensionDegrees(on: midpoint)
        let sunDec = SolarPosition.declinationDegrees(on: midpoint)
        let (sunAltitude, _) = HorizontalCoordinates.altitudeAzimuth(
            raDegrees: sunRA, decDegrees: sunDec, latitudeDegrees: 45, longitudeDegrees: 9, on: midpoint
        )
        #expect(sunAltitude < -12)
    }

    /// The north celestial pole (dec 90°) sits at a fixed altitude equal to latitude all night —
    /// a deterministic object to check the whole "scan the catalog, keep what clears the
    /// threshold" pipeline against, independent of `HorizontalCoordinatesTests`' own unit-level
    /// checks on the transform itself.
    @Test func visibleObjectsIncludesTheNorthCelestialPoleWhenLatitudeClearsTheThreshold() {
        let ncp = SkyCatalogObject(
            id: "ncp-test", commonName: "NCP Test", objectType: "test",
            raDegrees: 0, decDegrees: 90, magnitude: 0
        )
        let results = SkyVisibilityCalculator.visibleObjects(
            in: [ncp], on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 30
        )
        #expect(results.count == 1)
        #expect(abs((results.first?.maxAltitudeDegrees ?? 0) - 45) < 1)
    }

    @Test func visibleObjectsExcludesObjectsThatNeverClearTheThreshold() {
        let ncp = SkyCatalogObject(
            id: "ncp-test", commonName: "NCP Test", objectType: "test",
            raDegrees: 0, decDegrees: 90, magnitude: 0
        )
        let results = SkyVisibilityCalculator.visibleObjects(
            in: [ncp], on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 60
        )
        #expect(results.isEmpty)
    }

    @Test func visibleObjectsSortsBestPlacedFirst() {
        let a = SkyCatalogObject(id: "a", commonName: nil, objectType: "test", raDegrees: 0, decDegrees: 60, magnitude: 0)
        let b = SkyCatalogObject(id: "b", commonName: nil, objectType: "test", raDegrees: 200, decDegrees: 80, magnitude: 0)
        let results = SkyVisibilityCalculator.visibleObjects(
            in: [a, b], on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 0
        )
        #expect(results.count == 2)
        // A general invariant on the actual sort output, rather than a hand-derived expected
        // order — the transit-time math to predict exact peak altitudes by hand is easy to get
        // subtly wrong, while "descending by the field it claims to sort by" is always true.
        #expect(results[0].maxAltitudeDegrees >= results[1].maxAltitudeDegrees)
    }

    @Test func circumpolarObjectsHaveNoRiseOrSetTime() {
        let ncp = SkyCatalogObject(id: "ncp-test", commonName: nil, objectType: "test", raDegrees: 0, decDegrees: 90, magnitude: 0)
        let results = SkyVisibilityCalculator.visibleObjects(
            in: [ncp], on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 30
        )
        #expect(results.first?.riseTime == nil)
        #expect(results.first?.setTime == nil)
    }

    @Test func nonCircumpolarObjectRisesBeforeAndSetsAfterItsPeak() {
        // dec 0° at latitude 45° is well clear of the ~45° circumpolar threshold, so it genuinely
        // rises and sets within a 24h period rather than staying up (or down) the whole time.
        let equatorial = SkyCatalogObject(id: "eq-test", commonName: nil, objectType: "test", raDegrees: 180, decDegrees: 0, magnitude: 0)
        let results = SkyVisibilityCalculator.visibleObjects(
            in: [equatorial], on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 20
        )
        guard let result = results.first else {
            Issue.record("expected this object to clear 20° at some point")
            return
        }
        if let rise = result.riseTime { #expect(rise <= result.timeOfMaxAltitude) }
        if let set = result.setTime { #expect(set >= result.timeOfMaxAltitude) }
    }

    @Test func visiblePlanetsReturnsStructurallyConsistentResults() {
        let results = SkyVisibilityCalculator.visiblePlanets(
            on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 0
        )
        for result in results {
            #expect(result.maxAltitudeDegrees >= 0)
            if let rise = result.riseTime { #expect(rise <= result.timeOfMaxAltitude) }
            if let set = result.setTime { #expect(set >= result.timeOfMaxAltitude) }
        }
        for i in 1..<results.count {
            #expect(results[i - 1].maxAltitudeDegrees >= results[i].maxAltitudeDegrees)
        }
    }

    @Test func visiblePlanetsExcludesEverythingAtAnImpossibleThreshold() {
        let results = SkyVisibilityCalculator.visiblePlanets(
            on: Self.midLatitudeDate, latitudeDegrees: 45, longitudeDegrees: 9, minAltitudeDegrees: 95
        )
        #expect(results.isEmpty)
    }

    @Test func altitudeCurveSpansMidnightToMidnightOfTheGivenDay() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 14))!
        let samples = SkyVisibilityCalculator.altitudeCurve(
            raDegrees: 0, decDegrees: 90, latitudeDegrees: 45, longitudeDegrees: 9, on: date
        )
        #expect(samples.first?.time == calendar.startOfDay(for: date))
        #expect(samples.last!.time.timeIntervalSince(samples.first!.time) <= 24 * 3600)
        #expect(samples.count > 1)
    }

    @Test func altitudeCurveMatchesTheNorthCelestialPoleInvariant() {
        // The same "altitude == latitude, constant all night" fact used elsewhere in this file —
        // every sample on the curve should show it too, not just a single spot-checked moment.
        let samples = SkyVisibilityCalculator.altitudeCurve(
            raDegrees: 0, decDegrees: 90, latitudeDegrees: 45, longitudeDegrees: 9, on: Self.midLatitudeDate
        )
        for sample in samples {
            #expect(abs(sample.altitudeDegrees - 45) < 0.5)
        }
    }

    /// Regression test for a real bug: `nightWindow` used to anchor its scan on literal noon of
    /// `date`'s own calendar day, so an early-morning `date` (already in the middle of a night
    /// that started the *previous* evening) would report *tonight's* dusk/tomorrow's dawn instead
    /// of the dusk that already passed and the dawn coming up — a full day off, and the direct
    /// cause of a "sunset/sunrise are wrong for my coordinates" report that was actually a wrong
    /// night, not wrong astronomy.
    @Test func nightWindowForAnEarlyMorningMomentCoversTheNightAlreadyInProgress() {
        let calendar = Calendar(identifier: .gregorian)
        let earlyMorning = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 2))!
        guard let window = SkyVisibilityCalculator.nightWindow(
            for: earlyMorning, latitudeDegrees: 45, longitudeDegrees: 9
        ) else {
            Issue.record("expected a night window at mid-latitude in winter")
            return
        }
        // The window covering a 2am moment must have already started (dusk was yesterday evening)
        // and must not have ended yet (dawn is still ahead) — not a window that's entirely in the
        // future, which is what the old noon-of-`date` bug produced.
        #expect(window.start < earlyMorning)
        #expect(window.end > earlyMorning)
    }
}

struct CardinalDirectionTests {
    @Test func nearestMatchesTheExactCompassAnchors() {
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 0) == .n)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 45) == .ne)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 90) == .e)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 135) == .se)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 180) == .s)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 225) == .sw)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 270) == .w)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 315) == .nw)
    }

    @Test func nearestWrapsAroundTheZeroSeam() {
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 359) == .n)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: -1) == .n)
        #expect(CardinalDirection.nearest(toAzimuthDegrees: 361) == .n)
    }
}

struct HorizonProfileTests {
    @Test func altitudeAtAnAnchorMatchesThatDirectionExactly() {
        var profile = HorizonProfile.clear
        profile.setAltitude(20, for: .n)
        #expect(profile.altitudeDegrees(atAzimuthDegrees: 0) == 20)
    }

    @Test func altitudeBetweenTwoAnchorsInterpolatesLinearly() {
        var profile = HorizonProfile.clear
        profile.setAltitude(0, for: .n)
        profile.setAltitude(40, for: .ne)
        #expect(abs(profile.altitudeDegrees(atAzimuthDegrees: 22.5) - 20) < 0.01)
    }

    @Test func altitudeInterpolationWrapsFromTheLastAnchorBackToTheFirst() {
        var profile = HorizonProfile.clear
        profile.setAltitude(0, for: .nw)
        profile.setAltitude(40, for: .n)
        #expect(abs(profile.altitudeDegrees(atAzimuthDegrees: 337.5) - 20) < 0.01)
    }

    @Test func clearProfileHasNoObstructionAnywhere() {
        let profile = HorizonProfile.clear
        for azimuth in stride(from: 0.0, to: 360.0, by: 30.0) {
            #expect(profile.altitudeDegrees(atAzimuthDegrees: azimuth) == 0)
        }
    }
}
