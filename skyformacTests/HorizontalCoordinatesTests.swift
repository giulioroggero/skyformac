import Foundation
import Testing
@testable import skyformac

struct HorizontalCoordinatesTests {
    @Test func greenwichMeanSiderealTimeMatchesTheKnownJ2000Epoch() {
        // At JD 2451545.0 (2000-01-01 12:00 UTC) the GMST polynomial's own constant term is the
        // whole answer (t = 0) — a directly checkable reference value, not a derived one.
        let j2000 = Date(timeIntervalSince1970: 946_728_000)
        let gmst = HorizontalCoordinates.greenwichMeanSiderealTimeDegrees(on: j2000)
        #expect(abs(gmst - 280.46061837) < 0.001)
    }

    @Test func objectAtZenithWhenDeclinationMatchesLatitudeAndHourAngleIsZero() {
        // Hour angle zero means RA == local sidereal time; with dec == latitude, that object is
        // directly overhead by definition of the coordinate transform.
        let date = Date(timeIntervalSince1970: 946_728_000)
        let longitude = 12.0
        let latitude = 40.0
        let lst = HorizontalCoordinates.localSiderealTimeDegrees(on: date, longitudeDegrees: longitude)
        let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
            raDegrees: lst, decDegrees: latitude, latitudeDegrees: latitude, longitudeDegrees: longitude, on: date
        )
        #expect(abs(altitude - 90) < 0.01)
    }

    @Test func northCelestialPoleAltitudeEqualsLatitudeRegardlessOfTimeOrRA() {
        // The NCP (dec 90°) sits at a fixed altitude equal to the observer's latitude, at every
        // hour angle — a good, deterministic circumpolar-object sanity check.
        let latitude = 45.0
        let longitude = -71.0
        for hoursOffset in [0.0, 3.0, 9.0, 17.0] {
            let date = Date(timeIntervalSince1970: 946_728_000 + hoursOffset * 3600)
            let (altitude, _) = HorizontalCoordinates.altitudeAzimuth(
                raDegrees: 123.4, decDegrees: 90, latitudeDegrees: latitude, longitudeDegrees: longitude, on: date
            )
            #expect(abs(altitude - latitude) < 0.01)
        }
    }

    @Test func altitudeStaysWithinValidRange() {
        let date = Date()
        for dec in stride(from: -90.0, through: 90.0, by: 30) {
            for lat in stride(from: -80.0, through: 80.0, by: 40) {
                let (altitude, azimuth) = HorizontalCoordinates.altitudeAzimuth(
                    raDegrees: 200, decDegrees: dec, latitudeDegrees: lat, longitudeDegrees: 0, on: date
                )
                #expect(altitude >= -90 && altitude <= 90)
                #expect(azimuth >= 0 && azimuth < 360)
            }
        }
    }
}
