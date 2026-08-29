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
}
