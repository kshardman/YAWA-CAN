//
//  AppDelegate.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 4/4/26.
//


import UIKit
import BackgroundTasks
import Foundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let appRefreshIdentifier = "com.widgetal.yawacan.apprefresh"
    private let favoritesStorageKey = "yawa.can.favorites"
    private let monitoredFavoritesKey = "YCBackgroundMonitoredFavorites"
    private let maxBackgroundFavorites = 5

    private struct BackgroundSavedFavorite: Decodable {
        let displayName: String
        let latitude: Double
        let longitude: Double
        let countryCode: String
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLogger.log("[N1][BG] register setup id=\(Self.appRefreshIdentifier)")
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.appRefreshIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            AppLogger.log("[N1][BG] launch received id=\(Self.appRefreshIdentifier)")
            self.handleAppRefresh(task: task)
        }

        AppLogger.log("[N1][BG] register completed id=\(Self.appRefreshIdentifier) success=\(didRegister)")
        return true
    }

    func scheduleAppRefreshNow() {
        let request = BGAppRefreshTaskRequest(identifier: Self.appRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.log("[N1][BG] submitted BGAppRefreshTaskRequest id=\(Self.appRefreshIdentifier) earliest=\(String(describing: request.earliestBeginDate))")
        } catch {
            AppLogger.log("[N1][BG] failed to submit BGAppRefreshTaskRequest id=\(Self.appRefreshIdentifier) error=\(error)")
        }
    }

    private func monitoredFavoriteKey(
        displayName: String,
        latitude: Double,
        longitude: Double
    ) -> String {
        "\(displayName)|\(latitude)|\(longitude)"
    }

    private func loadSavedFavorites() -> [BackgroundSavedFavorite] {
        guard let data = UserDefaults.standard.data(forKey: favoritesStorageKey) else {
            AppLogger.log("[N1][BG] no saved favorites found")
            return []
        }

        do {
            let favorites = try JSONDecoder().decode([BackgroundSavedFavorite].self, from: data)
            AppLogger.log("[N1][BG] loaded saved favorites count=\(favorites.count)")
            return favorites
        } catch {
            AppLogger.log("[N1][BG] failed decoding saved favorites error=\(error)")
            return []
        }
    }

    private func loadBackgroundMonitoredFavorites() -> [MonitoredFavoriteLocation] {
        let monitoredKeys = UserDefaults.standard.stringArray(forKey: monitoredFavoritesKey) ?? []
        let savedFavorites = loadSavedFavorites()

        if monitoredKeys.isEmpty {
            AppLogger.log("[N1][BG] no monitored favorite keys found")
            return []
        }

        let resolved = monitoredKeys.prefix(maxBackgroundFavorites).compactMap { key in
            savedFavorites.first {
                monitoredFavoriteKey(
                    displayName: $0.displayName,
                    latitude: $0.latitude,
                    longitude: $0.longitude
                ) == key
            }.map {
                MonitoredFavoriteLocation(
                    displayName: $0.displayName,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    countryCode: $0.countryCode
                )
            }
        }

        AppLogger.log("[N1][BG] resolved monitored favorites requested=\(min(monitoredKeys.count, maxBackgroundFavorites)) resolved=\(resolved.count)")
        return resolved
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        AppLogger.log("[N1][BG] app refresh started id=\(Self.appRefreshIdentifier)")

        scheduleAppRefreshNow()

        let work = Task(priority: .background) {
            defer {
                task.setTaskCompleted(success: true)
                AppLogger.log("[N1][BG] app refresh completed")
            }

            if Task.isCancelled {
                AppLogger.log("[N1][BG] work arrived already cancelled")
                return
            }

            let monitoredFavorites = loadBackgroundMonitoredFavorites()
            guard !monitoredFavorites.isEmpty else {
                AppLogger.log("[N1][BG] no monitored favorites resolved; exiting cleanly")
                return
            }

            AppLogger.log("[N1][BG] running favorites monitor count=\(monitoredFavorites.count)")
            await FavoritesNotificationMonitor().evaluateFavorites(monitoredFavorites)
            AppLogger.log("[N1][BG] favorites monitor finished count=\(monitoredFavorites.count)")
        }

        task.expirationHandler = {
            AppLogger.log("[N1][BG] app refresh expired; cancelling work")
            work.cancel()
        }
    }
}
