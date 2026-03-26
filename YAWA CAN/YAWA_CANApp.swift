//
//  YAWA_CANApp.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import SwiftUI
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif


enum YCWidgetShared {
    /// Replace with your real App Group identifier once the widget target exists.
    static let appGroupID = "group.com.widgetal.yawacan"
    static let weatherSnapshotKey = "yc.widget.weatherSnapshot"
    static let lastRefreshDateKey = "yc.widget.lastRefreshDate"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func save(snapshot: WeatherSnapshot) {
        guard let defaults = sharedDefaults else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(snapshot)
            defaults.set(data, forKey: weatherSnapshotKey)
            defaults.set(Date(), forKey: lastRefreshDateKey)
        } catch {
            defaults.set(Date(), forKey: lastRefreshDateKey)
        }

        requestWidgetReload()
    }

    static func requestWidgetReload() {
        #if canImport(WidgetKit)
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

@main
struct YAWA_CANApp: App {
    @AppStorage(AppearanceSettings.appearanceKey)
    private var appearancePreferenceRaw: String = "system"

    private var preferredColorScheme: ColorScheme? {
        switch appearancePreferenceRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // "system"
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(preferredColorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
