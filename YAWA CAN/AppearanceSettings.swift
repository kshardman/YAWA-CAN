//
//  AppearanceSettings.swift
//  YAWA
//
//  Created by chatGPT on 2/22/26.
//


import SwiftUI
import Combine

final class AppearanceSettings: ObservableObject {

    static let appearanceKey = "appearancePreference"   // "system" | "light" | "dark"
    static let styleKey = "appStyleMode"
    
    @Published private(set) var appearancePreferenceRaw: String
    @Published private(set) var stylePreferenceRaw: String
    

    @Published private(set) var revision: Int = 0

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.appearancePreferenceRaw = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "system"
        self.stylePreferenceRaw = UserDefaults.standard.string(forKey: Self.styleKey) ?? "themed"

        // Keep in sync when Settings changes AppStorage/UserDefaults
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadFromUserDefaults()
            }
            .store(in: &cancellables)
    }

    func reloadFromUserDefaults() {
        let a = UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "system"
        let s = UserDefaults.standard.string(forKey: Self.styleKey) ?? "themed"

        var changed = false
        if a != appearancePreferenceRaw {
            appearancePreferenceRaw = a
            changed = true
        }
        if s != stylePreferenceRaw {
            stylePreferenceRaw = s
            changed = true
        }

        if changed {
            revision &+= 1
        }
    }
    var isSystemStyle: Bool { stylePreferenceRaw.lowercased() == "system" }
}
