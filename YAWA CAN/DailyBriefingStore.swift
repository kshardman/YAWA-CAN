import Foundation
import CoreLocation
import UserNotifications
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "YAWA-CAN", category: "DailyBriefing")

/// Manages the opt-in daily weather briefing notification.
///
/// The notification fires once per day at the user's chosen time.
/// Content is time-aware: before 17:00 it summarises today's daytime
/// forecast ("Today · Location"); at 17:00 or later it switches to the
/// overnight forecast ("Tonight · Location").
///
/// Each day's notification gets a unique date-stamped identifier so that
/// rescheduling tomorrow's notification never removes today's delivered
/// one from Notification Center.
final class DailyBriefingStore {
    static let shared = DailyBriefingStore()

    private init() {}

    // MARK: - Constants

    static let notificationIDPrefix = "yawacan.briefing."

    /// Hour at which content switches from "Today" to "Tonight" framing.
    private static let eveningCutoffHour = 17

    // MARK: - Persisted settings

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.isEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.isEnabled) }
    }

    var scheduledHour: Int {
        get { (UserDefaults.standard.object(forKey: Keys.hour) as? Int) ?? 7 }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hour) }
    }

    var scheduledMinute: Int {
        get { UserDefaults.standard.integer(forKey: Keys.minute) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.minute) }
    }

    // MARK: - Cached content + coordinate

    private var cachedBody: String? {
        get { UserDefaults.standard.string(forKey: Keys.cachedBody) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cachedBody) }
    }

    var cachedLocationName: String? { UserDefaults.standard.string(forKey: Keys.cachedLocationName) }
    var cachedLat: Double?          { UserDefaults.standard.object(forKey: Keys.cachedLat) as? Double }
    var cachedLon: Double?          { UserDefaults.standard.object(forKey: Keys.cachedLon) as? Double }
    var cachedUsesUSUnits: Bool     { UserDefaults.standard.bool(forKey: Keys.cachedUsesUSUnits) }

    // MARK: - Pinned briefing location

    /// The UUID string of the user-chosen location for the briefing.
    /// Nil means "follow whatever location was last viewed."
    var pinnedLocationID: String? {
        get { UserDefaults.standard.string(forKey: Keys.pinnedLocationID) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pinnedLocationID) }
    }
    var pinnedLat: Double? {
        get { UserDefaults.standard.object(forKey: Keys.pinnedLat) as? Double }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pinnedLat) }
    }
    var pinnedLon: Double? {
        get { UserDefaults.standard.object(forKey: Keys.pinnedLon) as? Double }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pinnedLon) }
    }
    var pinnedLocationName: String? {
        get { UserDefaults.standard.string(forKey: Keys.pinnedLocationName) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pinnedLocationName) }
    }
    var pinnedUsesUSUnits: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.pinnedUsesUSUnits) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pinnedUsesUSUnits) }
    }

    /// Effective values used for scheduling — pinned location takes priority over the last-viewed cache.
    var effectiveLat: Double?          { pinnedLat ?? cachedLat }
    var effectiveLon: Double?          { pinnedLon ?? cachedLon }
    var effectiveLocationName: String? { pinnedLocationName ?? cachedLocationName }
    var effectiveUsesUSUnits: Bool     { pinnedLocationID != nil ? pinnedUsesUSUnits : cachedUsesUSUnits }

    func pin(id: String, lat: Double, lon: Double, name: String, usesUSUnits: Bool) {
        pinnedLocationID   = id
        pinnedLat          = lat
        pinnedLon          = lon
        pinnedLocationName = name
        pinnedUsesUSUnits  = usesUSUnits
    }

    func unpin() {
        pinnedLocationID   = nil
        pinnedLat          = nil
        pinnedLon          = nil
        pinnedLocationName = nil
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let isEnabled          = "briefing.isEnabled"
        static let hour               = "briefing.hour"
        static let minute             = "briefing.minute"
        static let cachedBody         = "briefing.cachedBody"
        static let cachedLocationName = "briefing.cachedLocationName"
        static let cachedLat          = "briefing.cachedLat"
        static let cachedLon          = "briefing.cachedLon"
        static let cachedUsesUSUnits  = "briefing.cachedUsesUSUnits"
        static let pinnedLocationID   = "briefing.pinnedLocationID"
        static let pinnedLat          = "briefing.pinnedLat"
        static let pinnedLon          = "briefing.pinnedLon"
        static let pinnedLocationName = "briefing.pinnedLocationName"
        static let pinnedUsesUSUnits  = "briefing.pinnedUsesUSUnits"
    }

    // MARK: - Reschedule with fresh forecast data

    /// Build and schedule the daily briefing from fresh snapshot data.
    /// Call this after every successful weather fetch.
    func reschedule(
        lat: Double,
        lon: Double,
        locationName: String,
        snapshot: WeatherSnapshot,
        usesUSUnits: Bool
    ) async {
        // Always update the viewed-location cache.
        UserDefaults.standard.set(lat,          forKey: Keys.cachedLat)
        UserDefaults.standard.set(lon,          forKey: Keys.cachedLon)
        UserDefaults.standard.set(locationName, forKey: Keys.cachedLocationName)
        UserDefaults.standard.set(usesUSUnits,  forKey: Keys.cachedUsesUSUnits)

        guard isEnabled else { return }

        // If a location is pinned, only post when the incoming data is for that location.
        if let pLat = pinnedLat, let pLon = pinnedLon, let pName = pinnedLocationName {
            guard abs(pLat - lat) < 0.01 && abs(pLon - lon) < 0.01 else { return }
            let isEvening = scheduledHour >= Self.eveningCutoffHour
            let body = buildBody(snapshot: snapshot, isEvening: isEvening, usesUSUnits: pinnedUsesUSUnits)
            cachedBody = body
            let title = isEvening ? "Tonight · \(pName)" : "Today · \(pName)"
            await post(title: title, body: body)
        } else {
            let isEvening = scheduledHour >= Self.eveningCutoffHour
            let body = buildBody(snapshot: snapshot, isEvening: isEvening, usesUSUnits: usesUSUnits)
            cachedBody = body
            let title = isEvening ? "Tonight · \(locationName)" : "Today · \(locationName)"
            await post(title: title, body: body)
        }
    }

    /// Pin an explicit briefing location, fetch fresh forecast data for it,
    /// and reschedule. Falls back to cached content if the network call fails.
    func chooseLocation(id: String, lat: Double, lon: Double, name: String, usesUSUnits: Bool) async {
        pin(id: id, lat: lat, lon: lon, name: name, usesUSUnits: usesUSUnits)

        // Cache immediately so the BGTask has coordinates even if the fetch below fails.
        UserDefaults.standard.set(lat,  forKey: Keys.pinnedLat)
        UserDefaults.standard.set(lon,  forKey: Keys.pinnedLon)
        UserDefaults.standard.set(name, forKey: Keys.pinnedLocationName)

        guard isEnabled else { return }

        let service = OpenMeteoWeatherService()
        do {
            let snapshot = try await service.fetchWeather(
                coordinate:   CLLocationCoordinate2D(latitude: lat, longitude: lon),
                locationName: name,
                forecastDays: 3
            )
            let isEvening = scheduledHour >= Self.eveningCutoffHour
            let body = buildBody(snapshot: snapshot, isEvening: isEvening, usesUSUnits: usesUSUnits)
            cachedBody = body
            let title = isEvening ? "Tonight · \(name)" : "Today · \(name)"
            await post(title: title, body: body)
        } catch {
            logger.warning("Daily briefing chooseLocation fetch failed, falling back to cache: \(error)")
            await rescheduleFromCache()
        }
    }

    /// Re-schedule using the last cached body (no network call).
    /// The title is always rebuilt from cachedLocationName + current scheduledHour
    /// so stale cached titles never bleed through.
    func rescheduleFromCache() async {
        guard isEnabled else { return }
        guard let locationName = cachedLocationName, let body = cachedBody else {
            logger.info("Daily briefing: no cached content — skipping fallback reschedule")
            return
        }
        let isEvening = scheduledHour >= Self.eveningCutoffHour
        let title = isEvening ? "Tonight · \(locationName)" : "Today · \(locationName)"
        await post(title: title, body: body)
    }

    // MARK: - Cancel

    func cancel() {
        Task {
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.notificationIDPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            logger.info("Daily briefing cancelled (\(ids.count) pending removed)")
        }
    }

    // MARK: - Internal posting

    private func post(title: String, body: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
           || settings.authorizationStatus == .provisional else {
            logger.info("Daily briefing: notification permission not granted — skipping")
            return
        }

        let fireDate  = nextFireDate()
        let dateLabel = Self.dateLabel(for: fireDate)
        let id        = Self.notificationIDPrefix + dateLabel

        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            ),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        // Remove stale pending briefings (different date) before adding the new one.
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let staleIDs = pending.map(\.identifier)
            .filter { $0.hasPrefix(Self.notificationIDPrefix) && $0 != id }
        if !staleIDs.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: staleIDs)
        }

        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Daily briefing scheduled for \(dateLabel) at \(self.scheduledHour):\(String(format: "%02d", self.scheduledMinute))")
        } catch {
            logger.error("Daily briefing scheduling failed: \(error)")
        }
    }

    // MARK: - Content builder

    private func buildBody(snapshot: WeatherSnapshot, isEvening: Bool, usesUSUnits: Bool) -> String {
        guard let today = snapshot.daily.first else {
            return "Tap to see today's forecast."
        }

        func format(_ celsius: Double) -> Int {
            usesUSUnits ? Int((celsius * 9 / 5 + 32).rounded()) : Int(celsius.rounded())
        }
        let unit = usesUSUnits ? "°F" : "°C"

        var parts: [String] = []

        if isEvening {
            parts.append("Low \(format(today.lowC))\(unit)")
        } else {
            parts.append("High \(format(today.highC))\(unit), low \(format(today.lowC))\(unit)")
        }

        if !today.conditionText.isEmpty {
            parts.append(today.conditionText)
        }

        if today.precipChancePercent >= 20 {
            parts.append("\(today.precipChancePercent)% chance of precipitation")
        }

        return parts.isEmpty ? "Tap to see today's forecast." : parts.joined(separator: " · ")
    }

    // MARK: - Date helpers

    private func nextFireDate() -> Date {
        let cal   = Calendar.current
        let now   = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour   = scheduledHour
        comps.minute = scheduledMinute
        comps.second = 0
        guard let today = cal.date(from: comps) else { return now }
        return today > now ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    private static func dateLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
