import CoreLocation

/// The subset of `CLLocationManager` `CoreLocationProvider` actually drives — narrowed to a
/// protocol so tests can supply a fake that never touches real Core Location (which needs an
/// `NSLocationWhenInUseUsageDescription` Info.plist entry and a real permission prompt neither
/// of which exist in a headless test process).
@MainActor
protocol LocationRequesting: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
    func requestLocation()
}

extension CLLocationManager: LocationRequesting {}

/// GPS location for a `Project`/`Session` — the counterpart to `GeoLocation.manual(...)` for when
/// the observer would rather not type coordinates by hand. One fix per `requestCurrentLocation`
/// call (not continuous tracking — an observing site doesn't move mid-session), returned via the
/// completion handler so a caller (a "Use Current Location" button) doesn't need to poll.
@Observable
@MainActor
final class CoreLocationProvider: NSObject {
    private let manager: LocationRequesting
    private var pendingCompletion: ((GeoLocation?) -> Void)?

    private(set) var lastLocation: GeoLocation?
    private(set) var lastErrorMessage: String?

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    init(manager: LocationRequesting = CLLocationManager()) {
        self.manager = manager
        super.init()
        (manager as? CLLocationManager)?.delegate = self
    }

    /// Calls `completion` with a fresh `GeoLocation` (`source: .gps`), or `nil` if permission is
    /// denied/restricted or the fix itself fails. Requests permission first when it hasn't been
    /// decided yet — the eventual authorization change continues on to the location request
    /// itself, so callers only need to call this once regardless of prior permission state.
    func requestCurrentLocation(completion: @escaping (GeoLocation?) -> Void) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            lastErrorMessage = "Location access denied — enter coordinates manually instead."
            completion(nil)
        case .notDetermined:
            pendingCompletion = completion
            manager.requestWhenInUseAuthorization()
        default:
            pendingCompletion = completion
            manager.requestLocation()
        }
    }
}

extension CoreLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.pendingCompletion != nil else { return }
            switch self.manager.authorizationStatus {
            case .authorizedAlways:
                self.manager.requestLocation()
            case .denied, .restricted:
                self.lastErrorMessage = "Location access denied — enter coordinates manually instead."
                let completion = self.pendingCompletion
                self.pendingCompletion = nil
                completion?(nil)
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let geo = GeoLocation(
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, name: nil, source: .gps
            )
            self.lastLocation = geo
            let completion = self.pendingCompletion
            self.pendingCompletion = nil
            completion?(geo)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastErrorMessage = String(describing: error)
            let completion = self.pendingCompletion
            self.pendingCompletion = nil
            completion?(nil)
        }
    }
}
