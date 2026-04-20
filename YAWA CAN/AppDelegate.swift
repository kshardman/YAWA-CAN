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
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.appRefreshIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self.handleAppRefresh(task: task)
        }

        return true
    }

    func scheduleAppRefreshNow() {
        let request = BGAppRefreshTaskRequest(identifier: Self.appRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
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
            return []
        }

        do {
            let favorites = try JSONDecoder().decode([BackgroundSavedFavorite].self, from: data)
            return favorites
        } catch {
            return []
        }
    }

    private func loadBackgroundMonitoredFavorites() -> [MonitoredFavoriteLocation] {
        let monitoredKeys = UserDefaults.standard.stringArray(forKey: monitoredFavoritesKey) ?? []
        let savedFavorites = loadSavedFavorites()

        if monitoredKeys.isEmpty {
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

        return resolved
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {

        scheduleAppRefreshNow()

        let work = Task(priority: .background) {
            defer {
                task.setTaskCompleted(success: true)
            }

            if Task.isCancelled {
                return
            }

            let monitoredFavorites = loadBackgroundMonitoredFavorites()
            guard !monitoredFavorites.isEmpty else {
                return
            }

            await FavoritesNotificationMonitor().evaluateFavorites(monitoredFavorites)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
