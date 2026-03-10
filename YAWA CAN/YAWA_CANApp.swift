//
//  YAWA_CANApp.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import SwiftUI
import SwiftData

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
