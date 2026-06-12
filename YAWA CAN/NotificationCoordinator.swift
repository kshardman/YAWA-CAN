import Foundation
import Combine
import UserNotifications
import UIKit

extension Notification.Name {
    static let ycNotificationRouteReceived = Notification.Name("ycNotificationRouteReceived")
    static let ycNotificationDebugStateCleared = Notification.Name("ycNotificationDebugStateCleared")
}

struct NotificationRoute: Equatable {
    let kind: String
    let locationName: String
    let latitude: Double
    let longitude: Double
    let targetDateISO: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard
            let kind = userInfo["kind"] as? String,
            let locationName = userInfo["locationName"] as? String,
            let latitude = userInfo["latitude"] as? Double,
            let longitude = userInfo["longitude"] as? Double
        else {
            return nil
        }

        self.kind = kind
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude

        let rawDateISO = userInfo["targetDateISO"] as? String
        self.targetDateISO = (rawDateISO?.isEmpty == false) ? rawDateISO : nil
    }
}

final class NotificationResponseBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponseBridge()

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }

        await MainActor.run {
            NotificationCenter.default.post(name: .ycNotificationRouteReceived, object: route)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Suppress foreground presentation for now, but keep delegate routing enabled.
        return []
    }
}

@MainActor
final class NotificationCoordinator: ObservableObject {
    private let schedulingCooldownInterval: TimeInterval = 15 * 60
    private let favoritesMonitorSuppressionInterval: TimeInterval = 2 * 60
    private let lastScheduledAtKeyPrefix = "yc.notifications.lastScheduledAt."
    private let lastFavoritesMonitorScheduleAtKey = "yc.notifications.lastFavoritesMonitorScheduleAt"
    private func lastScheduledAtKey(for targetKey: String) -> String {
        let sanitized = targetKey
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return lastScheduledAtKeyPrefix + sanitized
    }


    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center: UNUserNotificationCenter
    private let store: NotificationStore

    init(
        center: UNUserNotificationCenter = .current(),
        store: NotificationStore? = nil
    ) {
        self.center = center
        self.store = store ?? NotificationStore()
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorizationStatus()

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            #if DEBUG
            #endif
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                #if DEBUG
                #endif
                await refreshAuthorizationStatus()
                return granted
            } catch {
                #if DEBUG
                #endif
                return false
            }
        @unknown default:
            return false
        }
    }

    func reevaluateAndScheduleIfNeeded(
        snapshot: ForecastNotificationSnapshot,
        selectedLocationKey: String
    ) async {
        let prefs = store.loadPreferences()
        #if DEBUG
        #endif
        guard prefs.forecastAlertsEnabled else { return }

        await refreshAuthorizationStatus()
        #if DEBUG
        #endif
        guard authorizationStatus == .authorized ||
              authorizationStatus == .provisional ||
              authorizationStatus == .ephemeral else {
            #if DEBUG
            #endif
            return
        }

        let timeZone = TimeZone(identifier: snapshot.timezoneIdentifier) ?? .current
        var calendar = Calendar.current
        calendar.timeZone = timeZone

        let candidates = NotificationRuleEngine.evaluate(
            snapshot: snapshot,
            now: Date(),
            calendar: calendar,
            timeZone: timeZone,
            preferences: prefs
        )
        #if DEBUG
        #endif

        guard let winner = candidates.sorted(by: { lhs, rhs in
            if lhs.kind == .notableForecast && rhs.kind != .notableForecast {
                return true
            }
            if lhs.kind != .notableForecast && rhs.kind == .notableForecast {
                return false
            }
            if lhs.relevanceScore != rhs.relevanceScore {
                return lhs.relevanceScore > rhs.relevanceScore
            }
            if lhs.fireDate != rhs.fireDate {
                return lhs.fireDate < rhs.fireDate
            }
            return lhs.id < rhs.id
        }).first else {
            #if DEBUG
            #endif
            return
        }
        #if DEBUG
        #endif

        await scheduleCandidateIfNeeded(
            winner,
            targetKey: selectedLocationKey,
            calendar: calendar,
            timeZone: timeZone,
            logPrefix: "reevaluate"
        )
    }

    func scheduleCandidateIfNeeded(
        _ winner: NotificationCandidate,
        targetKey: String,
        calendar: Calendar,
        timeZone: TimeZone,
        logPrefix: String = "monitor"
    ) async {
        let alreadyDelivered = store.deliveredIDs(for: targetKey)
        guard !alreadyDelivered.contains(winner.id) else {
            #if DEBUG
            #endif
            return
        }
        let cooldownKey = lastScheduledAtKey(for: targetKey)

        if logPrefix != "favorites-monitor",
           let lastFavoritesMonitorScheduleAt = UserDefaults.standard.object(forKey: lastFavoritesMonitorScheduleAtKey) as? Date {
            let elapsedSinceFavoritesMonitor = Date().timeIntervalSince(lastFavoritesMonitorScheduleAt)
            if elapsedSinceFavoritesMonitor < favoritesMonitorSuppressionInterval {
                #if DEBUG
                #endif
                return
            }
        }

        if let lastScheduledAt = UserDefaults.standard.object(forKey: cooldownKey) as? Date {
            let elapsed = Date().timeIntervalSince(lastScheduledAt)
            guard elapsed >= schedulingCooldownInterval else {
                #if DEBUG
                #endif
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = winner.title
        content.body = winner.body
        content.sound = .default
        content.userInfo = [
            "kind": routeKindString(for: winner.kind),
            "locationName": winner.locationName,
            "latitude": winner.locationLatitude,
            "longitude": winner.locationLongitude,
            "targetDateISO": winner.targetDateISO ?? ""
        ]

        #if DEBUG
        let interval: TimeInterval = 45
        #else
        let interval = max(1, winner.fireDate.timeIntervalSinceNow)
        #endif
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)

        let requestID = "yc.forecast.\(winner.id)"
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

        #if DEBUG
        #endif

        do {
            try await center.add(request)
            #if DEBUG
            #endif
            #if DEBUG
            #endif

            let appState = await MainActor.run { UIApplication.shared.applicationState }
            if appState == .active {
                #if DEBUG
                #endif
            }

            store.markDelivered(id: winner.id, for: targetKey)
            UserDefaults.standard.set(Date(), forKey: cooldownKey)
            if logPrefix == "favorites-monitor" {
                UserDefaults.standard.set(Date(), forKey: lastFavoritesMonitorScheduleAtKey)
            }

            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            store.setLastDeliveredDay(formatter.string(from: Date()), for: targetKey)

            await MainActor.run {
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.success)
            }
        } catch {
            #if DEBUG
            #endif
        }
    }

    private func routeKindString(for kind: NotificationCandidate.Kind) -> String {
        switch kind {
        case .precipSoon:
            return "precipSoon"
        case .windyTomorrow:
            return "windyTomorrow"
        case .notableForecast:
            return "notableForecast"
        }
    }

    func scheduleTestNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "YC Test Notification"
        content.body = "If you see this, the pipeline works."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)

        let request = UNNotificationRequest(
            identifier: "yc.test",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            #if DEBUG
            #endif
        } catch {
            #if DEBUG
            #endif
        }
    }

    func removeAllScheduledForecastAlerts() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("yc.forecast.") }

        #if DEBUG
        #endif
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func clearAllSystemNotifications() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        #if DEBUG
        #endif
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
