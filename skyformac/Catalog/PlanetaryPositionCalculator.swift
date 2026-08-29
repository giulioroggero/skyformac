import Foundation

/// Low-precision (Paul Schlyter's well-known, public-domain "How to compute planetary positions"
/// method — http://www.stjarnhimlen.se/comp/ppcomp.html) geocentric RA/Dec for the Moon and the
/// naked-eye planets. Same precision class as `SolarPosition` (good to roughly a degree, no
/// perturbation terms beyond the primary Keplerian orbit) — plenty for spotting "these two are in
/// conjunction this week" or a rough Moon phase, nowhere near what real ephemeris software or a
/// planetarium app would use for actual pointing.
enum PlanetaryPositionCalculator {
    struct EquatorialPosition {
        var rightAscensionDegrees: Double
        var declinationDegrees: Double
    }

    enum Planet: String, CaseIterable, Sendable {
        case mercury = "Mercury", venus = "Venus", mars = "Mars", jupiter = "Jupiter", saturn = "Saturn"

        /// Osculating orbital elements at epoch 2000-01-01 00:00 UT (Schlyter's own published
        /// table) plus their per-day rate of change — `(N, i, w, a, e, M)` at epoch, then each
        /// element's own `/day` rate, in the same order.
        fileprivate var elements: (epoch: OrbitalElements, ratePerDay: OrbitalElements) {
            switch self {
            case .mercury:
                return (.init(n: 48.3313, i: 7.0047, w: 29.1241, a: 0.387098, e: 0.205635, m: 168.6562),
                        .init(n: 3.24587e-5, i: 5.00e-8, w: 1.01444e-5, a: 0, e: 5.59e-10, m: 4.0923344368))
            case .venus:
                return (.init(n: 76.6799, i: 3.3946, w: 54.8910, a: 0.723330, e: 0.006773, m: 48.0052),
                        .init(n: 2.46590e-5, i: 2.75e-8, w: 1.38374e-5, a: 0, e: -1.302e-9, m: 1.6021302244))
            case .mars:
                return (.init(n: 49.5574, i: 1.8497, w: 286.5016, a: 1.523688, e: 0.093405, m: 18.6021),
                        .init(n: 2.11081e-5, i: -1.78e-8, w: 2.92961e-5, a: 0, e: 2.516e-9, m: 0.5240207766))
            case .jupiter:
                return (.init(n: 100.4542, i: 1.3030, w: 273.8777, a: 5.20256, e: 0.048498, m: 19.8950),
                        .init(n: 2.76854e-5, i: -1.557e-7, w: 1.64505e-5, a: 0, e: 4.469e-9, m: 0.0830853001))
            case .saturn:
                return (.init(n: 113.6634, i: 2.4886, w: 339.3939, a: 9.55475, e: 0.055546, m: 316.9670),
                        .init(n: 2.38980e-5, i: -1.081e-7, w: 2.97661e-5, a: 0, e: -9.499e-9, m: 0.0334442282))
            }
        }
    }

    fileprivate struct OrbitalElements {
        var n: Double
        var i: Double
        var w: Double
        var a: Double
        var e: Double
        var m: Double
    }

    /// Days since 2000-01-01 00:00 UT — Schlyter's own epoch, matching every constant above.
    private static func daysSinceEpoch(_ date: Date) -> Double {
        date.timeIntervalSince(Date(timeIntervalSince1970: 946_684_800)) / 86400
    }

    /// Solves Kepler's equation `M = E - e·sin(E)` for the eccentric anomaly, by simple fixed-point
    /// iteration — converges in a handful of iterations for every eccentricity this app deals with
    /// (nothing here approaches a near-parabolic comet orbit).
    private static func eccentricAnomaly(meanAnomalyDegrees: Double, eccentricity: Double) -> Double {
        let m = meanAnomalyDegrees * .pi / 180
        var e = m + eccentricity * sin(m) * (1 + eccentricity * cos(m))
        for _ in 0..<6 {
            let delta = e - eccentricity * sin(e) - m
            let derivative = 1 - eccentricity * cos(e)
            e -= delta / derivative
        }
        return e
    }

    /// The Sun's own geocentric ecliptic rectangular coordinates and true anomaly-derived
    /// longitude — needed as the reference frame every planet's heliocentric position gets added
    /// to (a planet's geocentric position is its heliocentric position plus the Sun's own
    /// geocentric position, since Earth's own heliocentric position is just the negative of that).
    private static func sunGeocentricEcliptic(daysSinceEpoch d: Double) -> (x: Double, y: Double, longitudeDegrees: Double, distanceAU: Double) {
        let w = normalizedDegrees(282.9404 + 4.70935e-5 * d)
        let e = 0.016709 - 1.151e-9 * d
        let m = normalizedDegrees(356.0470 + 0.9856002585 * d)
        let eccentric = eccentricAnomaly(meanAnomalyDegrees: m, eccentricity: e)
        let xv = cos(eccentric) - e
        let yv = (1 - e * e).squareRoot() * sin(eccentric)
        let r = (xv * xv + yv * yv).squareRoot()
        let trueAnomaly = normalizedDegrees(atan2(yv, xv) * 180 / .pi)
        let longitude = normalizedDegrees(trueAnomaly + w)
        let lonRad = longitude * .pi / 180
        return (r * cos(lonRad), r * sin(lonRad), longitude, r)
    }

    private static func obliquityRadians(daysSinceEpoch d: Double) -> Double {
        (23.4393 - 3.563e-7 * d) * .pi / 180
    }

    private static func eclipticToEquatorial(x: Double, y: Double, z: Double, obliquity: Double) -> EquatorialPosition {
        let xe = x
        let ye = y * cos(obliquity) - z * sin(obliquity)
        let ze = y * sin(obliquity) + z * cos(obliquity)
        let ra = normalizedDegrees(atan2(ye, xe) * 180 / .pi)
        let dec = atan2(ze, (xe * xe + ye * ye).squareRoot()) * 180 / .pi
        return EquatorialPosition(rightAscensionDegrees: ra, declinationDegrees: dec)
    }

    static func position(of planet: Planet, on date: Date = Date()) -> EquatorialPosition {
        let d = daysSinceEpoch(date)
        let (epoch, rate) = planet.elements
        let n = normalizedDegrees(epoch.n + rate.n * d)
        let i = (epoch.i + rate.i * d) * .pi / 180
        let w = normalizedDegrees(epoch.w + rate.w * d)
        let a = epoch.a + rate.a * d
        let e = epoch.e + rate.e * d
        let m = normalizedDegrees(epoch.m + rate.m * d)

        let eccentric = eccentricAnomaly(meanAnomalyDegrees: m, eccentricity: e)
        let xv = a * (cos(eccentric) - e)
        let yv = a * (1 - e * e).squareRoot() * sin(eccentric)
        let v = atan2(yv, xv)
        let r = (xv * xv + yv * yv).squareRoot()

        let nRad = n * .pi / 180
        let wRad = w * .pi / 180
        let xh = r * (cos(nRad) * cos(v + wRad) - sin(nRad) * sin(v + wRad) * cos(i))
        let yh = r * (sin(nRad) * cos(v + wRad) + cos(nRad) * sin(v + wRad) * cos(i))
        let zh = r * sin(v + wRad) * sin(i)

        let sun = sunGeocentricEcliptic(daysSinceEpoch: d)
        let obliquity = obliquityRadians(daysSinceEpoch: d)
        return eclipticToEquatorial(x: xh + sun.x, y: yh + sun.y, z: zh, obliquity: obliquity)
    }

    /// The Moon's geocentric ecliptic longitude and its geocentric equatorial position — the
    /// longitude, alongside the Sun's own (`sunGeocentricEcliptic`), is what `SkyEventsCalculator`
    /// uses for phase (elongation = Moon longitude − Sun longitude).
    static func moonPosition(on date: Date = Date()) -> (equatorial: EquatorialPosition, eclipticLongitudeDegrees: Double) {
        let d = daysSinceEpoch(date)
        let n = normalizedDegrees(125.1228 - 0.0529538083 * d) * .pi / 180
        let i = 5.1454 * .pi / 180
        let w = normalizedDegrees(318.0634 + 0.1643573223 * d)
        let a = 60.2666
        let e = 0.054900
        let m = normalizedDegrees(115.3654 + 13.0649929509 * d)

        let eccentric = eccentricAnomaly(meanAnomalyDegrees: m, eccentricity: e)
        let xv = a * (cos(eccentric) - e)
        let yv = a * (1 - e * e).squareRoot() * sin(eccentric)
        let v = atan2(yv, xv)
        let r = (xv * xv + yv * yv).squareRoot()

        let wRad = w * .pi / 180
        let xh = r * (cos(n) * cos(v + wRad) - sin(n) * sin(v + wRad) * cos(i))
        let yh = r * (sin(n) * cos(v + wRad) + cos(n) * sin(v + wRad) * cos(i))
        let zh = r * sin(v + wRad) * sin(i)
        let longitude = normalizedDegrees(atan2(yh, xh) * 180 / .pi)

        let obliquity = obliquityRadians(daysSinceEpoch: d)
        let equatorial = eclipticToEquatorial(x: xh, y: yh, z: zh, obliquity: obliquity)
        return (equatorial, longitude)
    }

    /// The Sun's own geocentric ecliptic longitude — the other half of the Moon-phase elongation
    /// calculation, and useful on its own for anything wanting "where's the Sun along the
    /// ecliptic" without needing RA/Dec.
    static func sunEclipticLongitudeDegrees(on date: Date = Date()) -> Double {
        sunGeocentricEcliptic(daysSinceEpoch: daysSinceEpoch(date)).longitudeDegrees
    }

    fileprivate static func normalizedDegrees(_ degrees: Double) -> Double {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        if wrapped >= 360 { wrapped -= 360 }
        return wrapped
    }
}
