import Foundation

/// Converts an object's fixed equatorial position (right ascension/declination — the same
/// coordinates every `SkyCatalogObject` is stored in) into the observer-specific, time-varying
/// altitude/azimuth actually needed to answer "is this above the horizon, and how high, right
/// now/tonight, from here." Standard low-precision spherical astronomy (Meeus-style formulas,
/// no atmospheric refraction correction) — the same "good enough for planning, not sub-arcminute
/// pointing" precision class as `SolarPosition`.
enum HorizontalCoordinates {
    /// Greenwich Mean Sidereal Time, in degrees, via the standard IAU polynomial (Meeus ch. 12).
    static func greenwichMeanSiderealTimeDegrees(on date: Date) -> Double {
        let jd = julianDay(date)
        let t = (jd - 2_451_545.0) / 36525
        let gmst = 280.46061837 + 360.98564736629 * (jd - 2_451_545.0)
            + 0.000387933 * t * t - t * t * t / 38_710_000
        return normalizedDegrees(gmst)
    }

    /// Local sidereal time — Greenwich sidereal time shifted by the observer's own longitude
    /// (east positive, matching every other longitude value in this app).
    static func localSiderealTimeDegrees(on date: Date, longitudeDegrees: Double) -> Double {
        normalizedDegrees(greenwichMeanSiderealTimeDegrees(on: date) + longitudeDegrees)
    }

    /// The observer-relative altitude (degrees above the horizon, negative below it) and azimuth
    /// (degrees, 0 = north, increasing eastward) of a fixed RA/Dec position at a given moment and
    /// location.
    static func altitudeAzimuth(
        raDegrees: Double, decDegrees: Double, latitudeDegrees: Double, longitudeDegrees: Double, on date: Date
    ) -> (altitude: Double, azimuth: Double) {
        let lst = localSiderealTimeDegrees(on: date, longitudeDegrees: longitudeDegrees)
        let hourAngleDegrees = normalizedDegrees(lst - raDegrees)

        let ha = hourAngleDegrees * .pi / 180
        let dec = decDegrees * .pi / 180
        let lat = latitudeDegrees * .pi / 180

        let sinAltitude = sin(dec) * sin(lat) + cos(dec) * cos(lat) * cos(ha)
        let altitude = asin(min(1, max(-1, sinAltitude)))

        let sinAzimuth = -sin(ha) * cos(dec)
        let cosAzimuth = sin(dec) - sin(lat) * sinAltitude
        let azimuth = normalizedDegrees(atan2(sinAzimuth, cosAzimuth) * 180 / .pi)

        return (altitude * 180 / .pi, azimuth)
    }

    private static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2_440_587.5
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        // `wrapped + 360` above can round back up to exactly 360.0 for a `wrapped` that was only
        // an infinitesimal amount below zero (360's own floating-point spacing is ~5.68e-14, well
        // above what a tiny negative remainder needs to round away) — guard the result back into
        // `0..<360` rather than assuming one subtraction is always enough.
        if wrapped >= 360 { wrapped -= 360 }
        return wrapped
    }
}
