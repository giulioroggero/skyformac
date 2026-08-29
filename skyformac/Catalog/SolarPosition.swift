import Foundation

/// The Sun's own position in the sky, for the one thing `AtlasView` needs it for: roughly which
/// half of the celestial sphere is up *at night* right now, without needing the observer's actual
/// location — the Sun's right ascension is the same everywhere on Earth at a given moment, only
/// its altitude (whether it's actually day or night for *you*) depends on where you are. Good
/// enough for a rough "which part of the sky to point a telescope at tonight" indicator, not
/// precise rise/set/twilight timing (which does need real location + horizon geometry).
enum SolarPosition {
    /// Low-precision solar position (the standard "Astronomical Almanac" approximation, accurate
    /// to about a degree — plenty for a rough half-sky indicator): mean ecliptic longitude plus
    /// the equation of center, converted from ecliptic to equatorial coordinates via the mean
    /// obliquity of the ecliptic. Declination isn't needed here (`AtlasView` only shades by right
    /// ascension), so only that's returned.
    static func rightAscensionDegrees(on date: Date = Date()) -> Double {
        let j2000 = Date(timeIntervalSince1970: 946_728_000) // 2000-01-01 12:00 UTC
        let daysSinceJ2000 = date.timeIntervalSince(j2000) / 86400

        let meanLongitude = normalizedDegrees(280.460 + 0.9856474 * daysSinceJ2000)
        let meanAnomalyRadians = normalizedDegrees(357.528 + 0.9856003 * daysSinceJ2000) * .pi / 180
        let eclipticLongitude = meanLongitude + 1.915 * sin(meanAnomalyRadians) + 0.020 * sin(2 * meanAnomalyRadians)

        let obliquityRadians = 23.439 * .pi / 180
        let lambdaRadians = eclipticLongitude * .pi / 180
        let rightAscensionRadians = atan2(cos(obliquityRadians) * sin(lambdaRadians), cos(lambdaRadians))
        return normalizedDegrees(rightAscensionRadians * 180 / .pi)
    }

    /// The Sun's declination — needed (alongside `rightAscensionDegrees`) to compute the Sun's own
    /// altitude at a given location/time, which is how `SkyVisibilityCalculator` finds the actual
    /// start/end of a night's dark window rather than assuming a fixed clock time.
    static func declinationDegrees(on date: Date = Date()) -> Double {
        let j2000 = Date(timeIntervalSince1970: 946_728_000)
        let daysSinceJ2000 = date.timeIntervalSince(j2000) / 86400

        let meanLongitude = normalizedDegrees(280.460 + 0.9856474 * daysSinceJ2000)
        let meanAnomalyRadians = normalizedDegrees(357.528 + 0.9856003 * daysSinceJ2000) * .pi / 180
        let eclipticLongitude = meanLongitude + 1.915 * sin(meanAnomalyRadians) + 0.020 * sin(2 * meanAnomalyRadians)

        let obliquityRadians = 23.439 * .pi / 180
        let lambdaRadians = eclipticLongitude * .pi / 180
        let declinationRadians = asin(sin(obliquityRadians) * sin(lambdaRadians))
        return declinationRadians * 180 / .pi
    }

    /// Roughly which RA band is up overnight — centered on the antisolar point (the Sun's own RA
    /// plus 180°, since that's what's opposite the Sun and therefore highest around local
    /// midnight), ± a generous 90° either side to cover "worth pointing at sometime this
    /// evening through pre-dawn," not just the exact midnight instant. May wrap across the 0°/360°
    /// seam, so this returns one or two `(start, end)` ranges (both already within `0...360`)
    /// rather than a single range that couldn't represent a wrapped band.
    static func tonightVisibleRARanges(on date: Date = Date()) -> [(start: Double, end: Double)] {
        let antisolarRA = normalizedDegrees(rightAscensionDegrees(on: date) + 180)
        return splitWrappedRange(center: antisolarRA, halfWidth: 90)
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// `center ± halfWidth`, clipped/split to stay within `0...360` — a band that crosses the
    /// 0°/360° seam becomes two ranges instead of one with `start > end`.
    static func splitWrappedRange(center: Double, halfWidth: Double) -> [(start: Double, end: Double)] {
        let start = center - halfWidth
        let end = center + halfWidth
        if start < 0 {
            return [(0, end), (start + 360, 360)]
        }
        if end > 360 {
            return [(start, 360), (0, end - 360)]
        }
        return [(start, end)]
    }
}
