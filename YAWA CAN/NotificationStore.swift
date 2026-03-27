//
//  NotificationStore.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/26/26.
//
import Foundation

final class NotificationStore {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let preferences = "yc.notifications.preferences"
        static let deliveredIDs = "yc.notifications.deliveredIDs"
        static let lastDeliveredDayString = "yc.notifications.lastDeliveredDayString"
        static let snapshot = "yc.notifications.snapshot"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPreferences() -> NotificationPreferences {
        guard
            let data = defaults.data(forKey: Keys.preferences),
            let prefs = try? decoder.decode(NotificationPreferences.self, from: data)
        else {
            return .default
        }
        return prefs
    }

    func savePreferences(_ prefs: NotificationPreferences) {
        guard let data = try? encoder.encode(prefs) else { return }
        defaults.set(data, forKey: Keys.preferences)
    }

    func loadDeliveredIDs() -> Set<String> {
        let values = defaults.stringArray(forKey: Keys.deliveredIDs) ?? []
        return Set(values)
    }

    func saveDeliveredIDs(_ ids: Set<String>) {
        defaults.set(Array(ids).sorted(), forKey: Keys.deliveredIDs)
    }

    func loadLastDeliveredDayString() -> String? {
        defaults.string(forKey: Keys.lastDeliveredDayString)
    }

    func saveLastDeliveredDayString(_ value: String?) {
        defaults.set(value, forKey: Keys.lastDeliveredDayString)
    }

    func loadSnapshot() -> ForecastNotificationSnapshot? {
        guard
            let data = defaults.data(forKey: Keys.snapshot),
            let snapshot = try? decoder.decode(ForecastNotificationSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    func saveSnapshot(_ snapshot: ForecastNotificationSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.snapshot)
    }

    func clearAllNotificationState() {
        defaults.removeObject(forKey: Keys.deliveredIDs)
        defaults.removeObject(forKey: Keys.lastDeliveredDayString)
        defaults.removeObject(forKey: Keys.snapshot)
    }
}
