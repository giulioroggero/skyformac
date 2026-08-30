import Foundation
import Testing
@testable import skyformac

struct SkyObjectResolverTests {
    @Test func resolvesACatalogObjectByCommonName() {
        let info = SkyObjectResolver.resolve(objectName: "Andromeda Galaxy", location: nil)
        #expect(info?.title == "Andromeda Galaxy")
        #expect(info?.skyCoordinates != nil)
    }

    @Test func resolvesACatalogObjectByBareDesignation() {
        let info = SkyObjectResolver.resolve(objectName: "M31", location: nil)
        #expect(info?.title == "Andromeda Galaxy")
    }

    @Test func resolvesAPlanetByName() {
        let info = SkyObjectResolver.resolve(objectName: "Saturn", location: nil)
        #expect(info?.title == "Saturn")
        #expect(info?.subtitle == "Solar system body")
        #expect(info?.skyCoordinates == nil)
    }

    @Test func resolvesTheMoonIncludingItsQuickStartLabel() {
        #expect(SkyObjectResolver.resolve(objectName: "Moon", location: nil)?.title == "Moon")
        // `PlanetaryPreset.moon`'s own raw value, what `CameraManager.quickStart(with:)` actually
        // stores into `Session.plannedObjects` — must resolve the same as the bare name.
        #expect(SkyObjectResolver.resolve(objectName: "Moon (Detail)", location: nil)?.title == "Moon")
    }

    @Test func returnsNilForUnrecognizedText() {
        #expect(SkyObjectResolver.resolve(objectName: "Definitely Not A Real Object", location: nil) == nil)
    }

    @Test func returnsNilForEmptyOrWhitespaceOnlyText() {
        #expect(SkyObjectResolver.resolve(objectName: "   ", location: nil) == nil)
        #expect(SkyObjectResolver.resolve(objectName: "", location: nil) == nil)
    }

    @Test func withALocationComputesRiseAndSetAroundTonightsPeak() {
        let location = GeoLocation(latitude: 45, longitude: 9, name: nil, source: .manual)
        let date = Date(timeIntervalSince1970: 946_728_000)
        let info = SkyObjectResolver.resolve(objectName: "M31", location: location, date: date)
        #expect(info != nil)
        if let rise = info?.riseTime { #expect(rise <= info!.peakTime) }
        if let set = info?.setTime { #expect(set >= info!.peakTime) }
    }
}
