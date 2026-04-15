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

        if let notable = makeNotableForecastCandidate(
            snapshot: snapshot,
            now: now,
            calendar: calendar,
            timeZone: timeZone
        ) {
            candidates.append(notable)
        }

        return candidates.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    private static func makeNotableForecastCandidate(
        snapshot: ForecastNotificationSnapshot,
        now: Date,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> NotificationCandidate? {
        guard let alert = snapshot.forecastAlertSummary else { return nil }

        let combinedText = "\(alert.title) \(alert.severity)"
        let category = parseNotableCategory(from: combinedText)
        let severity = parseSeverityClass(from: combinedText)

        guard qualifiesAsNotableForecast(category: category, severity: severity) else {
            print("[N1] notableForecast filtered out title=\(alert.title) severity=\(alert.severity)")
            return nil
        }

        let normalizedTitle = normalizedNotableForecastTitle(category: category, severity: severity, fallback: alert.title)
        let title = sentenceCaseAlertTitle(alert.title)
        let body = notableForecastBody(
            locationName: snapshot.locationName,
            issuedAt: alert.issuedAt,
            timeZone: timeZone
        )
        let dateISO = dayISOFromAlertExpiry(alert.expiresAt, calendar: calendar, timeZone: timeZone)

        let issuedKey: String = {
            guard let issuedAt = alert.issuedAt else { return "noIssuedAt" }

            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            return formatter.string(from: issuedAt)
        }()

        let titleKey = alert.title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "|", with: "-")

        let candidate = NotificationCandidate(
            id: "notableForecast|\(locationKey(for: snapshot))|\(category.rawValue)|\(severity?.rawValue ?? "none")|\(issuedKey)|\(titleKey)",
            kind: .notableForecast,
            title: title,
            body: body,
            fireDate: Date().addingTimeInterval(10),
            relevanceScore: relevanceScore(category: category, severity: severity),
            locationName: snapshot.locationName,
            locationLatitude: snapshot.locationLatitude,
            locationLongitude: snapshot.locationLongitude,
            targetDateISO: dateISO,
            notableCategory: category,
            severityClass: severity,
            sourceHeadline: alert.title
        )
        print("[N1] notableForecast candidate built id=\(candidate.id) title=\(candidate.title)")
        print("[N1] notableForecast normalizedTitle=\(normalizedTitle) sourceHeadline=\(alert.title)")
        print("[N1] notableForecast issuedAt=\(alert.issuedAt?.description ?? "nil") id=\(candidate.id)")
        return candidate
    }

    private static func normalizedNotableForecastTitle(
        category: NotableForecastCategory,
        severity: AlertSeverityClass?,
        fallback: String
    ) -> String {
        switch (category, severity) {
        case (.flooding, .warning):
            return "Flood warning"
        case (.flooding, .watch):
            return "Flood watch"
        case (.winterWeather, .warning):
            return "Winter weather warning"
        case (.winterWeather, .watch):
            return "Winter weather watch"
        case (.winterWeather, .advisory):
            return "Winter weather advisory"
        case (.thunder, .warning):
            return "Thunderstorm warning"
        case (.thunder, .watch):
            return "Thunderstorm watch"
        case (.specialStatement, .statement):
            return "Special weather statement"
        case (.wind, .warning):
            return "Wind warning"
        case (.wind, .watch):
            return "Wind watch"
        default:
            return fallback
        }
    }


    private static func sentenceCaseAlertTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return title }

        return trimmed
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                guard let first = lower.first else { return String(word) }
                return String(first).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func normalizedNotableForecastBody(
        category: NotableForecastCategory,
        severity: AlertSeverityClass?,
        locationName: String
    ) -> String {
        switch (category, severity) {
        case (.flooding, .warning):
            return "Tap to view the flood alert in YC."
        case (.flooding, .watch):
            return "Tap to view the flood watch in YC."
        case (.winterWeather, .warning):
            return "Tap to view the winter weather warning in YC."
        case (.winterWeather, .watch):
            return "Tap to view the winter weather watch in YC."
        case (.winterWeather, .advisory):
            return "Tap to view the winter weather advisory in YC."
        case (.thunder, .warning):
            return "Tap to view the thunderstorm warning in YC."
        case (.thunder, .watch):
            return "Tap to view the thunderstorm watch in YC."
        case (.specialStatement, .statement):
            return "Tap to view the alert in YC."
        case (.wind, .warning):
            return "Tap to view the wind warning in YC."
        case (.wind, .watch):
            return "Tap to view the wind watch in YC."
        default:
            return "Tap to view the alert in YC."
        }
    }

    private static func notableForecastBody(
        locationName: String,
        issuedAt: Date?,
        timeZone: TimeZone
    ) -> String {
        guard let issuedAt else { return locationName }

        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d, h:mm a"

        return "\(locationName) • Issued \(formatter.string(from: issuedAt))"
    }

    private static func dayISOFromAlertExpiry(
        _ expiresAt: Date?,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> String? {
        guard let expiresAt else { return nil }
        let formatter = DateFormatter()
        var cal = calendar
        cal.timeZone = timeZone
        formatter.calendar = cal
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: expiresAt)
    }

    private static func parseSeverityClass(from text: String) -> AlertSeverityClass? {
        let lower = text.lowercased()

        if lower.contains("warning") { return .warning }
        if lower.contains("watch") { return .watch }
        if lower.contains("advisory") { return .advisory }
        if lower.contains("statement") { return .statement }

        return nil
    }

    private static func parseNotableCategory(from text: String) -> NotableForecastCategory {
        let lower = text.lowercased()

        if lower.contains("fog advisory") {
            return .specialStatement
        }

        if lower.contains("special weather statement") {
            return .specialStatement
        }
        if lower.contains("flood") {
            return .flooding
        }
        if lower.contains("freezing rain") || lower.contains("ice") || lower.contains("icy") ||
            lower.contains("winter") || lower.contains("snow") || lower.contains("blizzard") {
            return .winterWeather
        }
        if lower.contains("wind") {
            return .wind
        }
        if lower.contains("thunder") || lower.contains("storm") {
            return .thunder
        }
        if lower.contains("heat") {
            return .heat
        }
        if lower.contains("cold") || lower.contains("freeze") || lower.contains("frost") {
            return .cold
        }
        if lower.contains("air quality") || lower.contains("smoke") {
            return .airQuality
        }
        if lower.contains("fog") {
            return .fog
        }

        return .unknown
    }

    private static func qualifiesAsNotableForecast(
        category: NotableForecastCategory,
        severity: AlertSeverityClass?
    ) -> Bool {
        return true
    }

    private static func relevanceScore(
        category: NotableForecastCategory,
        severity: AlertSeverityClass?
    ) -> Int {
        let base: Int = {
            switch severity {
            case .warning: return 95
            case .watch: return 85
            case .advisory: return 75
            case .statement: return 60
            case nil: return 50
            }
        }()

        let categoryBonus: Int = {
            switch category {
            case .flooding: return 5
            case .winterWeather: return 4
            case .thunder: return 3
            case .wind: return 2
            case .specialStatement: return 0
            case .heat, .cold, .airQuality, .fog: return 0
            case .unknown: return -5
            }
        }()

        return base + categoryBonus
    }

    private static func locationKey(for snapshot: ForecastNotificationSnapshot) -> String {
        let raw = snapshot.locationName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = raw.replacingOccurrences(of: " ", with: "_")
        return collapsed.isEmpty ? "unknown_location" : collapsed
    }

}
