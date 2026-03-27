import Foundation

enum NotificationRuleEngine {
    static func evaluate(
        snapshot: ForecastNotificationSnapshot,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        preferences: NotificationPreferences
    ) -> [NotificationCandidate] {
        var candidates: [NotificationCandidate] = []

        if let precip = makePrecipSoonCandidate(
            snapshot: snapshot,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        ) {
            candidates.append(precip)
        }

        if let wind = makeWindyTomorrowCandidate(
            snapshot: snapshot,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        ) {
            candidates.append(wind)
        }

        return candidates.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    private static func makePrecipSoonCandidate(
        snapshot: ForecastNotificationSnapshot,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> NotificationCandidate? {
        let decoder = hourlyDecoder(timeZone: timeZone)

        let hourly = snapshot.hourly.compactMap { point -> (date: Date, point: ForecastNotificationSnapshot.HourlyPoint)? in
            guard let date = decoder.date(from: point.timeISO) else {
                print("[N1] precipSoon failed to parse hourly timeISO=\(point.timeISO)")
                return nil
            }
            return (date, point)
        }
        .sorted { $0.date < $1.date }

        let previewFormatter = ISO8601DateFormatter()
        previewFormatter.formatOptions = [.withInternetDateTime]
        previewFormatter.timeZone = timeZone

        guard !hourly.isEmpty else {
            print("[N1] precipSoon aborted: no hourly rows after parsing")
            return nil
        }
        
        

        let nextTwoHours = hourly.filter {
            $0.date >= now && $0.date <= now.addingTimeInterval(2 * 60 * 60)
        }
        print("[N1] precipSoon nextTwoHours count=\(nextTwoHours.count) location=\(snapshot.locationName)")

        guard let firstIncoming = nextTwoHours.first(where: isMeaningfulPrecipitation) else {
            print("[N1] precipSoon no qualifying entry in nextTwoHours")
            return nil
        }

        let title: String
        if isSnowLike(point: firstIncoming.point) {
            title = "Snow starting soon"
        } else {
            title = "Rain starting soon"
        }

        let body = "\(title.replacingOccurrences(of: " starting soon", with: "")) is likely in \(snapshot.locationName) within the next 2 hours."

        let candidate = NotificationCandidate(
            id: "precipSoon|\(locationKey(for: snapshot))|\(firstIncoming.point.timeISO)",
            kind: .precipSoon,
            title: title,
            body: body,
            fireDate: now.addingTimeInterval(60),
            relevanceScore: 100
        )
        print("[N1] precipSoon candidate built id=\(candidate.id)")
        return candidate
    }

    private static func makeWindyTomorrowCandidate(
        snapshot: ForecastNotificationSnapshot,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> NotificationCandidate? {
        let decoder = dayDecoder(timeZone: timeZone)

        let localHour = calendar.component(.hour, from: now)
        guard (16...21).contains(localHour) else { return nil }

        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        let tomorrowStart = calendar.startOfDay(for: tomorrow)

        guard let tomorrowPoint = snapshot.daily.first(where: { point in
            guard let date = decoder.date(from: point.dateISO) else { return false }
            return calendar.isDate(date, inSameDayAs: tomorrowStart)
        }) else {
            return nil
        }

        let gust = tomorrowPoint.windGustMaxKPH ?? 0
        print("[N1] windyTomorrow gust=\(gust) location=\(snapshot.locationName)")
        guard gust >= 45 else { return nil }

        let fireDate = fireDateForWindTomorrow(now: now, calendar: calendar)

        return NotificationCandidate(
            id: "windyTomorrow|\(locationKey(for: snapshot))|\(tomorrowPoint.dateISO)",
            kind: .windyTomorrow,
            title: "Windy tomorrow",
            body: "Gusty conditions are expected tomorrow in \(snapshot.locationName).",
            fireDate: fireDate,
            relevanceScore: 80
        )
    }

    private static func isMeaningfulPrecipitation(
        _ entry: (date: Date, point: ForecastNotificationSnapshot.HourlyPoint)
    ) -> Bool {
        let probability = entry.point.precipitationProbability ?? 0
        return probability >= 60
    }

    private static func isSnowLike(point: ForecastNotificationSnapshot.HourlyPoint) -> Bool {
        if let weatherCode = point.weatherCode, snowWeatherCodes.contains(weatherCode) {
            return true
        }

        if let tempC = point.temperatureC, tempC <= 0 {
            return true
        }

        return false
    }

    private static var snowWeatherCodes: Set<Int> {
        [71, 73, 75, 77, 85, 86]
    }

    private static func locationKey(for snapshot: ForecastNotificationSnapshot) -> String {
        let raw = snapshot.locationName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = raw.replacingOccurrences(of: " ", with: "_")
        return collapsed.isEmpty ? "unknown_location" : collapsed
    }

    private static func hourlyDecoder(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }

    private static func dayDecoder(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func fireDateForWindTomorrow(now: Date, calendar: Calendar) -> Date {
        if let sevenPM = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now), sevenPM > now {
            return sevenPM
        }
        return now.addingTimeInterval(60)
    }
}
