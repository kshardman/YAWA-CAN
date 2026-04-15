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
            AppLogger.log("[N1] failed decoding notification preferences error=\(error)")
            return NotificationPreferences.default
        }
    }

    func savePreferences(_ preferences: NotificationPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: preferencesKey)
        } catch {
            AppLogger.log("[N1] failed encoding notification preferences error=\(error)")
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
        AppLogger.log("[N1] notification snapshot saved targetKey=\(targetKey)")
    }

    func removeSnapshot(for targetKey: String) {
        var all = loadSnapshotsDictionary()
        all.removeValue(forKey: targetKey)
        saveSnapshotsDictionary(all)
        AppLogger.log("[N1] notification snapshot removed targetKey=\(targetKey)")
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
        AppLogger.log("[N1] notification delivered id=\(id) targetKey=\(targetKey) totalIDs=\(all[targetKey]?.count ?? 0)")
    }

    func clearDeliveredIDs(for targetKey: String) {
        var all = loadDeliveredIDsDictionary()
        all.removeValue(forKey: targetKey)
        saveDeliveredIDsDictionary(all)
        AppLogger.log("[N1] cleared delivered IDs targetKey=\(targetKey)")
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
        AppLogger.log("[N1] set last delivered day targetKey=\(targetKey) day=\(day ?? "nil")")
    }

    func clearLastDeliveredDay(for targetKey: String) {
        var all = loadLastDeliveredDayDictionary()
        all.removeValue(forKey: targetKey)
        saveLastDeliveredDayDictionary(all)
        AppLogger.log("[N1] cleared last delivered day targetKey=\(targetKey)")
    }

    // MARK: - Cleanup

    func clearState(for targetKey: String) {
        removeSnapshot(for: targetKey)
        clearDeliveredIDs(for: targetKey)
        clearLastDeliveredDay(for: targetKey)
        AppLogger.log("[N1] cleared notification state targetKey=\(targetKey)")
    }

    func clearAllState() {
        defaults.removeObject(forKey: snapshotsByTargetKeyKey)
        defaults.removeObject(forKey: deliveredIDsByTargetKeyKey)
        defaults.removeObject(forKey: lastDeliveredDayByTargetKeyKey)
        AppLogger.log("[N1] cleared all notification state")
    }

    // MARK: - Private dictionary helpers

    private func loadSnapshotsDictionary() -> [String: ForecastNotificationSnapshot] {
        guard let data = defaults.data(forKey: snapshotsByTargetKeyKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: ForecastNotificationSnapshot].self, from: data)
        } catch {
            AppLogger.log("[N1] failed decoding snapshot dictionary error=\(error)")
            return [:]
        }
    }

    private func saveSnapshotsDictionary(_ value: [String: ForecastNotificationSnapshot]) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: snapshotsByTargetKeyKey)
        } catch {
            AppLogger.log("[N1] failed encoding snapshot dictionary error=\(error)")
        }
    }

    private func loadDeliveredIDsDictionary() -> [String: [String]] {
        guard let data = defaults.data(forKey: deliveredIDsByTargetKeyKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            AppLogger.log("[N1] failed decoding delivered IDs dictionary error=\(error)")
            return [:]
        }
    }

    private func saveDeliveredIDsDictionary(_ value: [String: [String]]) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: deliveredIDsByTargetKeyKey)
        } catch {
            AppLogger.log("[N1] failed encoding delivered IDs dictionary error=\(error)")
        }
    }

    private func loadLastDeliveredDayDictionary() -> [String: String] {
        guard let data = defaults.data(forKey: lastDeliveredDayByTargetKeyKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            AppLogger.log("[N1] failed decoding last delivered day dictionary error=\(error)")
            return [:]
        }
    }

    private func saveLastDeliveredDayDictionary(_ value: [String: String]) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: lastDeliveredDayByTargetKeyKey)
        } catch {
            AppLogger.log("[N1] failed encoding last delivered day dictionary error=\(error)")
        }
    }
}
