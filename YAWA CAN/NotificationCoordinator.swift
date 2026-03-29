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
}

@MainActor
final class NotificationCoordinator: ObservableObject {
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
            print("[N1] notification authorization denied")
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                print("[N1] requestAuthorization result=\(granted)")
                await refreshAuthorizationStatus()
                return granted
            } catch {
                print("[N1] requestAuthorization failed: \(error)")
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
        print("[N1] reevaluate start enabled=\(prefs.forecastAlertsEnabled) location=\(selectedLocationKey)")
        guard prefs.forecastAlertsEnabled else { return }

        await refreshAuthorizationStatus()
        print("[N1] authorization status=\(authorizationStatus.rawValue)")
        guard authorizationStatus == .authorized ||
              authorizationStatus == .provisional ||
              authorizationStatus == .ephemeral else {
            print("[N1] reevaluate aborted: notifications not authorized")
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
        print("[N1] candidates count=\(candidates.count)")

        guard let winner = candidates.sorted(by: { $0.relevanceScore > $1.relevanceScore }).first else {
            print("[N1] reevaluate complete: no winning candidate")
            return
        }
        print("[N1] winner id=\(winner.id) fireDate=\(winner.fireDate)")

        let alreadyDelivered = store.loadDeliveredIDs()
        guard !alreadyDelivered.contains(winner.id) else {
            print("[N1] reevaluate aborted: winner already scheduled/notified id=\(winner.id)")
            return
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

        let interval = max(1, winner.fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)

        let requestID = "yc.forecast.\(winner.id)"
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

        do {
            try await center.add(request)
            print("[N1] scheduled requestID=\(requestID) interval=\(interval)")

            let appState = await MainActor.run { UIApplication.shared.applicationState }
            if appState == .active {
                print("[N1] note: YC is active, so the notification banner may not appear while the app is open")
            }

            var delivered = alreadyDelivered
            delivered.insert(winner.id)
            store.saveDeliveredIDs(delivered)

            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            store.saveLastDeliveredDayString(formatter.string(from: Date()))
        } catch {
            print("[N1] failed to schedule notification: \(error)")
        }
    }

    private func routeKindString(for kind: NotificationCandidate.Kind) -> String {
        switch kind {
        case .precipSoon:
            return "precipSoon"
        case .windyTomorrow:
            return "windyTomorrow"
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
            print("[N1] test notification scheduled")
        } catch {
            print("[N1] test notification failed: \(error)")
        }
    }

    func removeAllScheduledForecastAlerts() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("yc.forecast.") }

        print("[N1] removing scheduled forecast alerts count=\(ids.count)")
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
