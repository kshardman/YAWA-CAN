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
    var preferredColorScheme: ColorScheme? {
        switch appearancePreferenceRaw.lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var isSystemStyle: Bool { stylePreferenceRaw.lowercased() == "system" }

    var skyView: AnyView {
        isSystemStyle
        ? AnyView(Color(.systemBackground).ignoresSafeArea())
        : AnyView(YAWATheme.sky.ignoresSafeArea())
    }

    // Background behind everything
    var appBackground: Color {
        isSystemStyle ? Color(.systemGroupedBackground) : YAWATheme.sky
    }

    // Cards
    var card: Color {
        isSystemStyle ? Color(.secondarySystemGroupedBackground) : YAWATheme.card
    }
    // Secondary surface used for larger containers / list row backgrounds.
    // In themed mode we keep this consistent with the glass card fill (less saturated than the old `card2` blue).
    var card2: Color {
        isSystemStyle ? Color(.secondarySystemGroupedBackground) : YAWATheme.card
    }

    // Text
    var textPrimary: Color   { isSystemStyle ? Color(.label) : YAWATheme.textPrimary }
    var textSecondary: Color { isSystemStyle ? Color(.secondaryLabel) : YAWATheme.textSecondary }
    var textTertiary: Color  { isSystemStyle ? Color(.tertiaryLabel) : YAWATheme.textTertiary }
}
