import Foundation
import Combine

@MainActor
final class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    private let defaults: UserDefaults

    private let preferencesKey = "YCNotificationPreferences"
    private let snapshotsByTargetKeyKey = "YCNotificationSnapshotsByTargetKey"
    private let deliveredIDsByTargetKeyKey = "YCNotificationDeliveredIDsByTargetKey"
    private let lastDeliveredDayByTargetKeyKey = "YCNotificationLastDeliveredDayByTargetKey"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Preferences (global)

    func loadPreferences() -> NotificationPreferences {
        guard let data = defaults.data(forKey: preferencesKey) else {
            return NotificationPreferences.default
        }

        do {
            return try JSONDecoder().decode(NotificationPreferences.self, from: data)
        } catch {
            return NotificationPreferences.default
        }
    }

    func savePreferences(_ preferences: NotificationPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: preferencesKey)
        } catch {
        }
    }

    // MARK: - Snapshot (per targetKey)

    func loadSnapshot(for targetKey: String) -> ForecastNotificationSnapshot? {
        let all = loadSnapshotsDictionary()
        return all[targetKey]
    }

    func saveSnapshot(_ snapshot: ForecastNotificationSnapshot, for targetKey: String) {
        var all = loadSnapshotsDictionary()
        all[targetKey] = snapshot
        saveSnapshotsDictionary(all)
    }

    func removeSnapshot(for targetKey: String) {
        var all = loadSnapshotsDictionary()
        all.removeValue(forKey: targetKey)
        saveSnapshotsDictionary(all)
    }

    // MARK: - Delivered IDs (per targetKey)

    func deliveredIDs(for targetKey: String) -> Set<String> {
        let all = loadDeliveredIDsDictionary()
        return Set(all[targetKey] ?? [])
    }

    func markDelivered(id: String, for targetKey: String) {
        var all = loadDeliveredIDsDictionary()
        var ids = Set(all[targetKey] ?? [])
        ids.insert(id)

        // Cap at 50 entries per location — IDs are keyed by alert title + issued timestamp
        // so they accumulate over time. Sorted order ensures we drop the oldest (lexically
        // earliest) entries first, which works because the issuedAt timestamp is embedded
        // in the ID string in ISO format.
        let sorted = Array(ids).sorted()
        all[targetKey] = sorted.count > 50 ? Array(sorted.suffix(50)) : sorted

        saveDeliveredIDsDictionary(all)
    }

    func clearDeliveredIDs(for targetKey: String) {
        var all = loadDeliveredIDsDictionary()
        all.removeValue(forKey: targetKey)
        saveDeliveredIDsDictionary(all)
    }

    // MARK: - Last delivered day (per targetKey)

    func lastDeliveredDay(for targetKey: String) -> String? {
        let all = loadLastDeliveredDayDictionary()
        return all[targetKey]
    }

    func setLastDeliveredDay(_ day: String?, for targetKey: String) {
        var all = loadLastDeliveredDayDictionary()
        all[targetKey] = day
        saveLastDeliveredDayDictionary(all)
    }

    func clearLastDeliveredDay(for targetKey: String) {
        var all = loadLastDeliveredDayDictionary()
        all.removeValue(forKey: targetKey)
        saveLastDeliveredDayDictionary(all)
    }

    // MARK: - Cleanup

    func clearState(for targetKey: String) {
        removeSnapshot(for: targetKey)
        clearDeliveredIDs(for: targetKey)
        clearLastDeliveredDay(for: targetKey)
    }

    func clearAllState() {
        defaults.removeObject(forKey: snapshotsByTargetKeyKey)
        defaults.removeObject(forKey: deliveredIDsByTargetKeyKey)
        defaults.removeObject(forKey: lastDeliveredDayByTargetKeyKey)
    }

    // MARK: - Private dictionary helpers

    private func loadSnapshotsDictionary() -> [String: ForecastNotificationSnapshot] {
        guard let data = defaults.data(forKey: snapshotsByTargetKeyKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: ForecastNotificationSnapshot].self, from: data)
        } catch {
            return [:]
        }
    }

    private func saveSnapshotsDictionary(_ value: [String: ForecastNotificationSnapshot]) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: snapshotsByTargetKeyKey)
        } catch {
        }
    }

    private func loadDeliveredIDsDictionary() -> [String: [String]] {
        guard let data = defaults.data(forKey: deliveredIDsByTargetKeyKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            return [:]
        }
    }

    private func saveDeliveredIDsDictionary(_ value: [String: [String]]) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: deliveredIDsByTargetKeyKey)
        } catch {
        }
    }

    private func loadLastDeliveredDayDictionary() -> [String: String] {
        guard let data = defaults.data(forKey: lastDeliveredDayByTargetKeyKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            return [:]
        }
    }

    private func saveLastDeliveredDayDictionary(_ value: [String: String]) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: lastDeliveredDayByTargetKeyKey)
        } catch {
        }
    }
}
