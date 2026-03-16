//
//  SettingsView.swift
//  YAWA
//
//  Created by Keith Sharman on 1/4/26.
//

import SwiftUI
import UIKit
import CoreLocation


private extension View {
    @ViewBuilder func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}


enum DashboardStyle: String, CaseIterable, Identifiable {
    case dashboard
    case classic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .classic: return "Classic"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: return "Tiles with quick-read values"
        case .classic: return "Gauges with a more visual feel"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .classic: return "gauge"
        }
    }
}


struct SettingsView: View {
    @StateObject private var appearanceSettings = AppearanceSettings()
    @Environment(\.colorScheme) private var colorScheme

    private var appearanceModeBinding: Binding<String> {
        Binding(
            get: { appearanceSettings.appearancePreferenceRaw },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: AppearanceSettings.appearanceKey)
                appearanceSettings.reloadFromUserDefaults()
            }
        )
    }

    private var backgroundView: some View {
        Group {
            // In Light (or System style), match Favorites/Locations: flat system background.
            if appearanceSettings.isSystemStyle || colorScheme == .light {
                Color(.systemBackground)
            } else {
                YAWATheme.background(for: colorScheme)
            }
        }
    }

    private var rowBackgroundView: some View {
        YAWATheme.cardFill(for: colorScheme)
    }

    private var primaryText: some ShapeStyle {
        AnyShapeStyle(YAWATheme.textPrimary(for: colorScheme))
    }

    private var secondaryText: some ShapeStyle {
        AnyShapeStyle(YAWATheme.textSecondary(for: colorScheme))
    }



    // Dashboard style for the home screen (tiles vs gauges)
    @AppStorage("dashboardStyle") private var dashboardStyleRaw: String = DashboardStyle.dashboard.rawValue

    // Forecast length for the home screen (7 or 10)
    @AppStorage("forecastDaysToShow") private var forecastDaysToShow: Int = 7

    private var dashboardStyle: DashboardStyle {
        DashboardStyle(rawValue: dashboardStyleRaw) ?? .dashboard
    }

    // Radar overlay opacity (used by interactive radar)
    @AppStorage("radarOpacity") private var radarOpacity: Double = 0.80

    @AppStorage("homeEnabled") private var homeEnabled: Bool = false
    @AppStorage("homeLat") private var homeLat: Double = 0
    @AppStorage("homeLon") private var homeLon: Double = 0


    // One-time defaults from bundled config.plist (optional)
    @State private var loadedDefaults = false
    @State private var showKey = false
    @State private var copied = false
    @State private var showWeatherApiKey = false
    @State private var copiedWeatherApiKey = false

    @State private var showingApiKeys = false

    // Draft editing (so the API Keys sheet can Cancel/Back without saving)
    @State private var draftStationID: String = ""
    @State private var draftApiKey: String = ""



    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                // ✅ Full-screen theme background
                backgroundView.ignoresSafeArea()

                List {
                    appearanceSection
                    forecastSection
                    radarSection
//                    homeSection
                    privacySection
                    attributionSection
                    aboutSection
                }
                // ✅ Let the sky show through
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .listStyle(.insetGrouped)

                // ✅ Keep list looking “cardy” on dark backgrounds
                .environment(\.defaultMinListRowHeight, 48)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Match Locations sheet nav styling: no heavy material band.
            // Match Favorites/Locations sheet: consistent “glassy” nav bar
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(
                (appearanceSettings.isSystemStyle || colorScheme == .light) ? .light : .dark,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.headline.weight(.semibold))   // ⬆️ match Favorites/Radar size
                    .foregroundStyle(AnyShapeStyle(YAWATheme.textPrimary(for: colorScheme)))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        (appearanceSettings.isSystemStyle || colorScheme == .light)
                            ? AnyShapeStyle(Color(.systemBackground))
                            : AnyShapeStyle(Color.white.opacity(0.08))
                    )
                    .clipShape(Capsule())
                }
            }
            // .task {
            //     await notifications.refreshAuthorizationStatus()
            // }
        }
        // Preferred color scheme is now handled at the app level
    }
}

// MARK: - Sections

private extension SettingsView {

    var forecastSection: some View {
        Section {
            Picker("Days", selection: $forecastDaysToShow) {
                Text("7").tag(7)
                Text("10").tag(10)
            }
            .pickerStyle(.segmented)
            .onAppear {
                // Guard against old/invalid stored values.
                if forecastDaysToShow != 7 && forecastDaysToShow != 10 {
                    forecastDaysToShow = 7
                }
            }

            Text("Choose how many days to show on the home screen forecast card.")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Forecast Length")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryText)
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }

    var radarSection: some View {
        Section {
            Picker("Opacity", selection: $radarOpacity) {
                Text("50%").tag(0.50)
                Text("65%").tag(0.65)
                Text("80%").tag(0.80)
            }
            .pickerStyle(.segmented)

            Text("Adjust how strongly the radar overlay is drawn on the map.")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Radar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryText)
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }

//    var homeSection: some View {
//        let radiusMeters: Double = 100
//        let hasFix = locationManager.coordinate != nil
//        let isSet = homeEnabled && !(homeLat == 0 && homeLon == 0)
//
//        return Section {
//            Button {
//                guard let c = locationManager.coordinate else { return }
//                homeLat = c.latitude
//                homeLon = c.longitude
//                homeEnabled = true
//                UserDefaults.standard.synchronize()
//                DispatchQueue.main.async {
//                    NotificationCenter.default.post(name: .yawaHomeSettingsDidChange, object: nil)
//                }
//            } label: {
//                HStack {
//                    Label("Set Home to Current Location", systemImage: "house.fill")
//                        .foregroundStyle(primaryText)
//                    Spacer()
//                    Image(systemName: "chevron.right")
//                        .font(.subheadline.weight(.semibold))
//                        .foregroundStyle(AnyShapeStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9)))
//                }
//                .contentShape(Rectangle())
//            }
//            .buttonStyle(.plain)
//            .disabled(!hasFix)
//            .opacity(hasFix ? 1.0 : 0.55)
//
//            if isSet {
//                HStack {
//                    Text("Home is set")
//                        .foregroundStyle(primaryText)
//                    Spacer()
//                    Text("\(Int(radiusMeters)) m")
//                        .foregroundStyle(secondaryText)
//                        .monospacedDigit()
//                }
//                .font(.subheadline)
//
//                Button(role: .destructive) {
//                    homeEnabled = false
//                    homeLat = 0
//                    homeLon = 0
//                    UserDefaults.standard.synchronize()
//                    DispatchQueue.main.async {
//                        NotificationCenter.default.post(name: .yawaHomeSettingsDidChange, object: nil)
//                    }
//                } label: {
//                    Label("Clear Home", systemImage: "trash")
//                }
//            } else {
//                HStack {
//                    Text("Home is not set")
//                        .foregroundStyle(secondaryText)
//                    Spacer()
//                    Text(hasFix ? "Ready" : "Waiting for GPS")
//                        .foregroundStyle(secondaryText)
//                }
//                .font(.subheadline)
//            }
//        } header: {
//            Text("Home")
//                .font(.subheadline.weight(.semibold))
//                .foregroundStyle(primaryText)
//        } footer: {
//            Text("When you’re within 100 meters of Home, YAWA can treat your current GPS location as \"Home\".")
//                .foregroundStyle(secondaryText)
//        }
//        .textCase(nil)
//        .listRowBackground(rowBackgroundView)
//        .listRowSeparator(.hidden)
//    }

    var privacySection: some View {
        Section(header: Text("Privacy").font(.subheadline.weight(.semibold)).foregroundStyle(primaryText)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("YAWA CAN uses your location to show nearby conditions, forecasts, and radar. Forecast data is provided by Open-Meteo.")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: URL(string: "https://widgital-digital.com/yawa-can/index.html")!) {
                    HStack {
                        Text("Privacy Policy")
                            .foregroundStyle(primaryText)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AnyShapeStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9)))
                    }
                    .contentShape(Rectangle())
                }
            }
            .padding(.vertical, 2)
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }

    var attributionSection: some View {
        Section(header: Text("Attribution").font(.subheadline.weight(.semibold)).foregroundStyle(primaryText)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Radar images and tiles are from rainviewer.com. Forecast data is provided by Open-Meteo.")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }


    var appearanceSection: some View {
        Section {
            Picker("Mode", selection: appearanceModeBinding) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Text("Choose System to follow iOS, or force Light/Dark.")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Appearance")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryText)
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }
    
    var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version (Build)")
                    .foregroundStyle(primaryText)

                Spacer()

                Text("\(appVersion) (\(buildNumber))")
                    .foregroundStyle(secondaryText)
                    .monospacedDigit()
            }
        }
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }


    func configValue(_ key: String) throws -> String {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "plist") else {
            throw ConfigError.missingConfigFile
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)

        guard let dict = plist as? [String: Any] else {
            throw ConfigError.missingConfigFile
        }
        guard let value = dict[key] as? String, !value.isEmpty else {
            throw ConfigError.missingKey(key)
        }
        return value
    }

    enum ConfigError: Error {
        case missingConfigFile
        case missingKey(String)
    }
}
