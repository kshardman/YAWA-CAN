import Foundation

struct MoonData {
    let phase: Double           // 0.0–1.0 (0 = new, 0.5 = full, 1 = new again)
    let illumination: Double    // 0.0–1.0
    let isWaxing: Bool
    let phaseName: String
    let phaseEmoji: String
    let rise: Date?
    let set: Date?
    let nextFullMoon: Date
    let nextNewMoon: Date
    let timeZoneID: String
}

enum MoonCalculator {

    // MARK: - Public entry point

    static func moonData(lat: Double, lon: Double, on date: Date, timeZoneID: String) -> MoonData {
        let jd = julianDay(from: date)
        let phase = moonPhase(jd: jd)
        let illumination = moonIllumination(phase: phase)
        let isWaxing = phase < 0.5
        let phaseName = moonPhaseName(phase: phase)
        let phaseEmoji = moonPhaseEmoji(phase: phase)
        let rise = moonRise(lat: lat, lon: lon, date: date, timeZoneID: timeZoneID)
        let set  = moonSet(lat: lat, lon: lon, date: date, timeZoneID: timeZoneID)
        let nextFull = nextMoonPhase(after: date, targetPhase: 0.5)
        let nextNew  = nextMoonPhase(after: date, targetPhase: 0.0)

        return MoonData(
            phase: phase,
            illumination: illumination,
            isWaxing: isWaxing,
            phaseName: phaseName,
            phaseEmoji: phaseEmoji,
            rise: rise,
            set: set,
            nextFullMoon: nextFull,
            nextNewMoon: nextNew,
            timeZoneID: timeZoneID
        )
    }

    // MARK: - Julian Day

    static func julianDay(from date: Date) -> Double {
        // JD at J2000.0 epoch = 2451545.0
        return date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    // MARK: - Moon phase (0–1)

    // Returns synodic phase: 0 = new moon, 0.25 = first quarter,
    // 0.5 = full moon, 0.75 = last quarter
    static func moonPhase(jd: Double) -> Double {
        let synodicMonth = 29.53058868
        // Known new moon at JD 2451550.1 (Jan 6, 2000 18:14 UTC)
        let knownNewMoon = 2451550.1
        let elapsed = jd - knownNewMoon
        var phase = (elapsed / synodicMonth).truncatingRemainder(dividingBy: 1.0)
        if phase < 0 { phase += 1.0 }
        return phase
    }

    // MARK: - Illumination

    static func moonIllumination(phase: Double) -> Double {
        // Illuminated fraction: (1 - cos(phase * 2π)) / 2
        return (1.0 - cos(phase * 2.0 * .pi)) / 2.0
    }

    // MARK: - Phase name

    static func moonPhaseName(phase: Double) -> String {
        switch phase {
        case 0.0..<0.03, 0.97...1.0: return "New Moon"
        case 0.03..<0.22:            return "Waxing Crescent"
        case 0.22..<0.28:            return "First Quarter"
        case 0.28..<0.47:            return "Waxing Gibbous"
        case 0.47..<0.53:            return "Full Moon"
        case 0.53..<0.72:            return "Waning Gibbous"
        case 0.72..<0.78:            return "Last Quarter"
        default:                      return "Waning Crescent"
        }
    }

    static func moonPhaseEmoji(phase: Double) -> String {
        switch phase {
        case 0.0..<0.03, 0.97...1.0: return "🌑"
        case 0.03..<0.22:            return "🌒"
        case 0.22..<0.28:            return "🌓"
        case 0.28..<0.47:            return "🌔"
        case 0.47..<0.53:            return "🌕"
        case 0.53..<0.72:            return "🌖"
        case 0.72..<0.78:            return "🌗"
        default:                      return "🌘"
        }
    }

    // MARK: - Next phase date

    static func nextMoonPhase(after date: Date, targetPhase: Double) -> Date {
        let synodicMonth = 29.53058868 * 86400.0 // seconds
        let jd = julianDay(from: date)
        let currentPhase = moonPhase(jd: jd)

        var daysAhead = targetPhase - currentPhase
        if daysAhead <= 0.01 { daysAhead += 1.0 }
        let secondsAhead = daysAhead * synodicMonth

        return date.addingTimeInterval(secondsAhead)
    }

    // MARK: - Moonrise / Moonset

    // Uses the same iterative horizon-crossing approach as professional
    // ephemeris libraries: sample moon altitude every hour, then bisect
    // to find the exact crossing minute.
    static func moonRise(lat: Double, lon: Double, date: Date, timeZoneID: String) -> Date? {
        return moonEvent(lat: lat, lon: lon, date: date, timeZoneID: timeZoneID, rising: true)
    }

    static func moonSet(lat: Double, lon: Double, date: Date, timeZoneID: String) -> Date? {
        return moonEvent(lat: lat, lon: lon, date: date, timeZoneID: timeZoneID, rising: false)
    }

    private static func moonEvent(
        lat: Double, lon: Double, date: Date,
        timeZoneID: String, rising: Bool
    ) -> Date? {
        guard let tz = TimeZone(identifier: timeZoneID) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let midnight = cal.date(from: comps) else { return nil }

        // Sample altitude at each hour of the local day
        var prevAlt = moonAltitude(lat: lat, lon: lon, at: midnight)
        for h in 1...48 {
            let t = midnight.addingTimeInterval(Double(h) * 3600)
            let alt = moonAltitude(lat: lat, lon: lon, at: t)
            let prevT = midnight.addingTimeInterval(Double(h - 1) * 3600)

            let crossedUp   = rising  && prevAlt < 0 && alt >= 0
            let crossedDown = !rising && prevAlt >= 0 && alt < 0

            if crossedUp || crossedDown {
                // Bisect within this 1-hour window to ~1-minute precision
                if let exact = bisect(lat: lat, lon: lon,
                                      lo: prevT, hi: t,
                                      rising: rising, iterations: 6) {
                    // Only return events within today (local calendar day)
                    let eventComps = cal.dateComponents([.year, .month, .day], from: exact)
                    if eventComps.year == comps.year &&
                       eventComps.month == comps.month &&
                       eventComps.day == comps.day {
                        return exact
                    }
                }
            }
            prevAlt = alt
        }
        return nil
    }

    private static func bisect(
        lat: Double, lon: Double,
        lo: Date, hi: Date,
        rising: Bool, iterations: Int
    ) -> Date? {
        var lo = lo, hi = hi
        for _ in 0..<iterations {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            let alt = moonAltitude(lat: lat, lon: lon, at: mid)
            if rising {
                if alt < 0 { lo = mid } else { hi = mid }
            } else {
                if alt >= 0 { lo = mid } else { hi = mid }
            }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    // MARK: - Moon altitude at a given UTC instant

    private static func moonAltitude(lat: Double, lon: Double, at date: Date) -> Double {
        let jd = julianDay(from: date)
        let (ra, dec) = moonRADec(jd: jd)

        // Greenwich Mean Sidereal Time → Local Sidereal Time → Hour Angle
        let gmst = greenwichSiderealTime(jd: jd)
        let lst  = gmst + lon / 15.0      // degrees
        let ha   = (lst - ra).truncatingRemainder(dividingBy: 360.0)

        let latR  = lat * .pi / 180
        let decR  = dec * .pi / 180
        let haR   = ha  * .pi / 180

        let sinAlt = sin(latR) * sin(decR) + cos(latR) * cos(decR) * cos(haR)
        return asin(min(1, max(-1, sinAlt))) * 180 / .pi
    }

    // MARK: - Low-precision moon RA/Dec (Jean Meeus Ch. 47 simplified)

    private static func moonRADec(jd: Double) -> (ra: Double, dec: Double) {
        let T = (jd - 2451545.0) / 36525.0

        // Moon's mean longitude
        let L0 = (218.3164477 + 481267.88123421 * T).truncatingRemainder(dividingBy: 360)
        // Moon's mean anomaly
        let M  = (134.9633964 + 477198.8675055  * T).truncatingRemainder(dividingBy: 360)
        // Moon's mean elongation
        let D  = (297.8501921 + 445267.1114034  * T).truncatingRemainder(dividingBy: 360)
        // Sun's mean anomaly
        let Ms = (357.5291092 + 35999.0502909   * T).truncatingRemainder(dividingBy: 360)
        // Moon's argument of latitude
        let F  = (93.2720950  + 483202.0175233  * T).truncatingRemainder(dividingBy: 360)

        let toR = Double.pi / 180

        // Ecliptic longitude corrections (degrees × 10⁻⁶)
        let dL =
              6288774 * sin(M * toR)
            + 1274027 * sin((2*D - M) * toR)
            +  658314 * sin(2*D * toR)
            +  213618 * sin(2*M * toR)
            -  185116 * sin(Ms * toR)
            -  114332 * sin(2*F * toR)
            +   58793 * sin((2*D - 2*M) * toR)
            +   57066 * sin((2*D - Ms - M) * toR)
            +   53322 * sin((2*D + M) * toR)
            +   45758 * sin((2*D - Ms) * toR)

        let lambda = L0 + dL / 1_000_000.0  // ecliptic longitude, degrees

        // Obliquity of ecliptic (simplified)
        let eps = 23.439291 - 0.013004 * T

        let lambdaR = lambda * toR
        let epsR    = eps * toR

        let ra  = atan2(sin(lambdaR) * cos(epsR), cos(lambdaR)) * 180 / .pi
        let dec = asin(sin(lambdaR) * sin(epsR)) * 180 / .pi

        // Convert RA to hours (0–24)
        let raH = ((ra / 15.0).truncatingRemainder(dividingBy: 24.0) + 24).truncatingRemainder(dividingBy: 24.0)

        return (ra: raH * 15.0, dec: dec) // return RA as degrees for GMST subtraction
    }

    // MARK: - Greenwich Sidereal Time (degrees)

    private static func greenwichSiderealTime(jd: Double) -> Double {
        let T = (jd - 2451545.0) / 36525.0
        var theta = 280.46061837
            + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * T * T
            - T * T * T / 38710000.0
        theta = theta.truncatingRemainder(dividingBy: 360.0)
        if theta < 0 { theta += 360 }
        return theta
    }
}
