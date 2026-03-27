//
//  SettingsView.swift
//  YAWA
//
//  Created by Keith Sharman on 1/4/26.
//

import SwiftUI
import UIKit
import CoreLocation
import UserNotifications







struct SettingsView: View {
    @StateObject private var appearanceSettings = AppearanceSettings()
    @StateObject private var notifications = NotificationCoordinator()
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

    // Forecast length for the home screen (7 or 10)
    @AppStorage("forecastDaysToShow") private var forecastDaysToShow: Int = 7



    // Radar overlay opacity (used by interactive radar)
    @AppStorage("radarOpacity") private var radarOpacity: Double = 0.80


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
                    notificationsSection
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
            .task {
                await notifications.refreshAuthorizationStatus()
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
                Text("70%").tag(0.70)
                Text("80%").tag(0.80)
            }
            .pickerStyle(.segmented)
            .onAppear {
                if abs(radarOpacity - 0.65) < 0.001 {
                    radarOpacity = 0.70
                }
            }

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

    var notificationsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(notificationStatusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryText)

                Text("Forecast alerts are still in development. This temporary section is only for testing notification permission and delivery.")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            Button {
                Task {
                    let granted = await notifications.requestAuthorizationIfNeeded()
                    print("[N1] granted=\(granted)")
                }
            } label: {
                HStack {
                    Text("Request Notification Access")
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }

            Button {
                Task {
                    let granted = await notifications.requestAuthorizationIfNeeded()
                    print("[N1] granted=\(granted)")

                    if granted {
                        let store = NotificationStore()
                        var prefs = store.loadPreferences()
                        prefs.forecastAlertsEnabled = true
                        store.savePreferences(prefs)
                        print("[N1] forecastAlertsEnabled set to true")

                        await notifications.scheduleTestNotification()
                    }
                }
            } label: {
                HStack {
                    Text("Request Access + Send Test")
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }

            Button {
                let store = NotificationStore()
                store.clearAllNotificationState()
                print("[N1] cleared notification debug state")
            } label: {
                HStack {
                    Text("Clear Notification Debug State")
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }

            Button {
                Task {
                    let candidate = NotificationCandidate(
                        id: "precipSoon|debug|\(Int(Date().timeIntervalSince1970))",
                        kind: .precipSoon,
                        title: "Rain starting soon",
                        body: "Rain is likely in debug mode within the next 2 hours.",
                        fireDate: Date().addingTimeInterval(10),
                        relevanceScore: 100
                    )

                    let content = UNMutableNotificationContent()
                    content.title = candidate.title
                    content.body = candidate.body
                    content.sound = .default

                    let interval = max(1, candidate.fireDate.timeIntervalSinceNow)
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: "yc.forecast.\(candidate.id)",
                        content: content,
                        trigger: trigger
                    )

                    do {
                        try await UNUserNotificationCenter.current().add(request)
                        print("[N1] forced precipSoon debug notification scheduled")
                    } catch {
                        print("[N1] forced precipSoon debug notification failed: \(error)")
                    }
                }
            } label: {
                HStack {
                    Text("Force precipSoon Debug Notification")
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }

            Button {
                notifications.openSystemSettings()
            } label: {
                HStack {
                    Text("Open iPhone Notification Settings")
                        .foregroundStyle(primaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AnyShapeStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9)))
                }
                .contentShape(Rectangle())
            }
        } header: {
            Text("Notifications")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryText)
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }

    private var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return "Status: Allowed"
        case .provisional:
            return "Status: Provisional"
        case .ephemeral:
            return "Status: Ephemeral"
        case .denied:
            return "Status: Denied"
        case .notDetermined:
            return "Status: Not Requested"
        @unknown default:
            return "Status: Unknown"
        }
    }

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

}
