import CoreLocation
import Testing
@testable import skyformac

@MainActor
private final class FakeLocationManager: LocationRequesting {
    var authorizationStatus: CLAuthorizationStatus
    private(set) var requestedWhenInUseAuthorization = false
    private(set) var requestedLocation = false

    init(authorizationStatus: CLAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {
        requestedWhenInUseAuthorization = true
    }

    func requestLocation() {
        requestedLocation = true
    }
}

@MainActor
struct CoreLocationProviderTests {
    @Test func deniedAuthorizationFailsImmediatelyWithoutTouchingTheManager() {
        let manager = FakeLocationManager(authorizationStatus: .denied)
        let provider = CoreLocationProvider(manager: manager)

        var result: GeoLocation??
        provider.requestCurrentLocation { result = $0 }

        #expect(result != nil)
        #expect(result! == nil)
        #expect(!manager.requestedLocation)
        #expect(provider.lastErrorMessage != nil)
    }

    @Test func notDeterminedRequestsAuthorizationFirst() {
        let manager = FakeLocationManager(authorizationStatus: .notDetermined)
        let provider = CoreLocationProvider(manager: manager)

        provider.requestCurrentLocation { _ in }

        #expect(manager.requestedWhenInUseAuthorization)
        #expect(!manager.requestedLocation)
    }

    @Test func alreadyAuthorizedRequestsALocationDirectly() {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let provider = CoreLocationProvider(manager: manager)

        provider.requestCurrentLocation { _ in }

        #expect(manager.requestedLocation)
    }

    @Test func authorizationGrantedAfterRequestingThenAsksForALocation() async throws {
        let manager = FakeLocationManager(authorizationStatus: .notDetermined)
        let provider = CoreLocationProvider(manager: manager)
        provider.requestCurrentLocation { _ in }

        manager.authorizationStatus = .authorizedAlways
        provider.locationManagerDidChangeAuthorization(CLLocationManager())

        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.requestedLocation)
    }

    @Test func didUpdateLocationsProducesAGPSSourcedGeoLocation() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let provider = CoreLocationProvider(manager: manager)

        var result: GeoLocation??
        provider.requestCurrentLocation { result = $0 }
        let location = CLLocation(latitude: 45.07, longitude: 7.68)
        provider.locationManager(CLLocationManager(), didUpdateLocations: [location])

        try await Task.sleep(for: .milliseconds(50))

        let geo = try #require(result ?? nil)
        #expect(geo.source == .gps)
        #expect(abs(geo.latitude - 45.07) < 0.0001)
        #expect(abs(geo.longitude - 7.68) < 0.0001)
        #expect(provider.lastLocation == geo)
    }

    @Test func didFailWithErrorCallsCompletionWithNil() async throws {
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let provider = CoreLocationProvider(manager: manager)

        var result: GeoLocation??
        provider.requestCurrentLocation { result = $0 }
        provider.locationManager(CLLocationManager(), didFailWithError: CLError(.locationUnknown))

        try await Task.sleep(for: .milliseconds(50))

        #expect(result != nil)
        #expect(result! == nil)
        #expect(provider.lastErrorMessage != nil)
    }
}

struct GeoLocationManualTests {
    @Test func manualRejectsOutOfRangeLatitude() {
        #expect(GeoLocation.manual(latitude: 91, longitude: 0, name: nil) == nil)
        #expect(GeoLocation.manual(latitude: -91, longitude: 0, name: nil) == nil)
    }

    @Test func manualRejectsOutOfRangeLongitude() {
        #expect(GeoLocation.manual(latitude: 0, longitude: 181, name: nil) == nil)
        #expect(GeoLocation.manual(latitude: 0, longitude: -181, name: nil) == nil)
    }

    @Test func manualAcceptsAValidCoordinate() throws {
        let geo = try #require(GeoLocation.manual(latitude: 45.07, longitude: 7.68, name: "Backyard"))
        #expect(geo.source == .manual)
        #expect(geo.displayName == "Backyard")
    }
}
