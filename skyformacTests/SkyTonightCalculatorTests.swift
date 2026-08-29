import Foundation
import Testing
@testable import skyformac

struct SkyTonightCalculatorTests {
    @Test func statusHasNoNightWindowOrVisibleObjectsWithoutALocation() {
        let status = SkyTonightCalculator.status(location: nil, plannedObjectNames: ["M31"])
        #expect(status.location == nil)
        #expect(status.nightWindow == nil)
        #expect(status.visiblePlannedObjects.isEmpty)
        #expect(!status.isWorthGoingOut)
    }

    @Test func unresolvableObjectNamesAreSilentlyExcluded() {
        let location = GeoLocation(latitude: 45, longitude: 9, name: nil, source: .manual)
        let status = SkyTonightCalculator.status(location: location, plannedObjectNames: ["Not A Real Object At All"])
        #expect(status.visiblePlannedObjects.isEmpty)
    }

    /// M31 (dec ≈ 41.27°) is circumpolar from latitude 80°N with a comfortable margin — its
    /// minimum possible altitude there is dec − (90 − lat) ≈ 31°, above the 30° default threshold
    /// regardless of exactly when the night window falls, so this doesn't depend on transit timing
    /// lining up (unlike a non-circumpolar object would). Near the winter solstice, 80°N is also
    /// reliably dark nearly all day, so a night window is virtually guaranteed to exist too.
    @Test func recognizesACircumpolarPlannedObjectAsVisibleTonight() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 21))!
        let location = GeoLocation(latitude: 80, longitude: 9, name: nil, source: .manual)
        let status = SkyTonightCalculator.status(location: location, plannedObjectNames: ["M31", "Not Real"], date: date)
        #expect(status.nightWindow != nil)
        #expect(status.visiblePlannedObjects.contains { $0.name == "M31" })
        #expect(status.isWorthGoingOut)
    }

    @Test func duplicatePlannedObjectNamesOnlyAppearOnce() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 21))!
        let location = GeoLocation(latitude: 80, longitude: 9, name: nil, source: .manual)
        let status = SkyTonightCalculator.status(location: location, plannedObjectNames: ["M31", "M31", "M31"], date: date)
        #expect(status.visiblePlannedObjects.filter { $0.name == "M31" }.count == 1)
    }
}
