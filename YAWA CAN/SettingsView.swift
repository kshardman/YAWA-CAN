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
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SettingsView: View {
    @StateObject private var appearanceSettings = AppearanceSettings()
    @StateObject private var notifications = NotificationCoordinator()
    @State private var isPresentingShare = false
    let monitoredFavorites: [MonitoredFavoriteLocation]
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

    // The app-level .preferredColorScheme updates the window, but an already-
    // presented sheet is a separate hosting controller that won't re-evaluate it
    // live. Drive the sheet's own scheme off the observed appearance object so it
    // re-themes immediately when the picker changes.
    private var preferredColorScheme: ColorScheme? {
        switch appearanceSettings.appearancePreferenceRaw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // "system"
        }
    }

    private var backgroundView: some View {
        YAWATheme.background(for: colorScheme)
            .ignoresSafeArea()
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

    // AI forecast outlook (on-device Apple Intelligence). On by default — the app
    // has shipped with it always-on; off shows the plain generated outlook.
    @AppStorage("ai.forecastOutlook.enabled") private var aiOutlookEnabled: Bool = true

    // Daily briefing
    @AppStorage("briefing.isEnabled")      private var briefingEnabled:      Bool   = false
    @AppStorage("briefing.hour")           private var briefingHour:         Int    = 7
    @AppStorage("briefing.minute")         private var briefingMinute:       Int    = 0
    @AppStorage("briefing.pinnedLocationID") private var briefingLocationID: String = ""

    // Radar overlay opacity (used by interactive radar)
    @AppStorage("radarOpacity") private var radarOpacity: Double = 0.80


    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                // ✅ Full-screen theme background
                backgroundView

                List {
                    appearanceSection
                    forecastSection
                    forecastOutlookSection
                    radarSection
                    notificationsSection
                    briefingSection
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
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
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
        // Give the sheet its own scheme so it updates live with the picker; the
        // app-level .preferredColorScheme only re-themes the window behind it.
        .preferredColorScheme(preferredColorScheme)
    }
}

// MARK: - Sections

private extension SettingsView {

    /// True when the on-device Apple Intelligence model can generate the outlook.
    private var appleIntelligenceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Toggle for the AI outlook — only shown on devices that support Apple
    /// Intelligence (elsewhere the plain generated outlook is always used).
    @ViewBuilder
    var forecastOutlookSection: some View {
        if appleIntelligenceAvailable {
            Section {
                Toggle(isOn: $aiOutlookEnabled) {
                    Label("Summarize with Apple Intelligence", systemImage: "apple.intelligence")
                        .foregroundStyle(primaryText)
                }
                .tint(.green)

                Text("Write each day's outlook as a short, friendly summary using Apple Intelligence. Runs entirely on your device. When off, a plain generated outlook is shown instead.")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Forecast Outlook")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryText)
            }
            .textCase(nil)
            .listRowBackground(rowBackgroundView)
            .listRowSeparator(.hidden)
        }
    }

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

                Text("Enable notifications to receive important alert updates for monitored favorites.")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

#if DEBUG
            Button {
                Task {
                    let granted = await notifications.requestAuthorizationIfNeeded()

                    if granted {
                        let store = NotificationStore()
                        var prefs = store.loadPreferences()
                        prefs.forecastAlertsEnabled = true
                        store.savePreferences(prefs)

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
                lightHaptic()
                let store = NotificationStore()
                store.clearAllState()
                let defaults = UserDefaults.standard
                for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("yc.notifications.lastScheduledAt.") {
                    defaults.removeObject(forKey: key)
                }
                defaults.removeObject(forKey: "yc.notifications.lastFavoritesMonitorScheduleAt")
                NotificationCenter.default.post(name: .ycNotificationDebugStateCleared, object: nil)
            } label: {
                HStack {
                    Text("Clear Notification Debug State")
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }

            Button {
                lightHaptic()
                Task {
                    let store = NotificationStore()
                    store.clearAllState()
                    var prefs = store.loadPreferences()
                    prefs.forecastAlertsEnabled = true
                    store.savePreferences(prefs)

                    let defaults = UserDefaults.standard
                    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("yc.notifications.lastScheduledAt.") {
                        defaults.removeObject(forKey: key)
                    }
                    defaults.removeObject(forKey: "yc.notifications.lastFavoritesMonitorScheduleAt")


                    NotificationCenter.default.post(name: .ycNotificationDebugStateCleared, object: nil)

                    await notifications.clearAllSystemNotifications()
                }
            } label: {
                HStack {
                    Text("Full Reset Notifications")
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
                        relevanceScore: 100,
                        locationName: "Debug Location",
                        locationLatitude: 0,
                        locationLongitude: 0,
                        targetDateISO: nil,
                        notableCategory: nil,
                        severityClass: nil,
                        sourceHeadline: nil
                    )

                    let content = UNMutableNotificationContent()
                    content.title = candidate.title
                    content.body = candidate.body
                    content.sound = .default

//                    let interval = max(1, candidate.fireDate.timeIntervalSinceNow)
#if DEBUG
let interval: TimeInterval = 15
#else
let interval = max(1, candidate.fireDate.timeIntervalSinceNow)
#endif
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                    let request = UNNotificationRequest(
                        identifier: "yc.forecast.\(candidate.id)",
                        content: content,
                        trigger: trigger
                    )

                    do {
                        try await UNUserNotificationCenter.current().add(request)
                    } catch {
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
                lightHaptic()

                guard !isPresentingShare else {
                    return
                }

                guard let url = AppLogger.exportURL() else {
                    return
                }

                isPresentingShare = true
                AppLogger.log("[N1] share log tapped url=\(url.path)")

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    SharePresenter.present(items: [url])

                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    isPresentingShare = false
                }
            } label: {
                HStack {
                    Text("Share Notification Log")
                        .foregroundStyle(primaryText)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(AnyShapeStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9)))
                }
                .contentShape(Rectangle())
            }

            Button(role: .destructive) {
                lightHaptic()
                AppLogger.clear()
            } label: {
                HStack {
                    Text("Clear Notification Log")
                    Spacer()
                }
                .contentShape(Rectangle())
            }

            Button {
                lightHaptic()
                Task {
                    let monitor = FavoritesNotificationMonitor()
                    await monitor.evaluateFavorites(monitoredFavorites)
                }
            } label: {
                HStack {
                    Text("Run Favorites Notification Monitor")
                        .foregroundStyle(primaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
#endif

            Button {
                lightHaptic()
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

    // MARK: - Daily Briefing

    private var briefingTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour:   briefingHour,
                    minute:          briefingMinute,
                    second:          0,
                    of:              Date()
                ) ?? Date()
            },
            set: { date in
                let comps      = Calendar.current.dateComponents([.hour, .minute], from: date)
                briefingHour   = comps.hour   ?? 7
                briefingMinute = comps.minute ?? 0
                DailyBriefingStore.shared.scheduledHour   = briefingHour
                DailyBriefingStore.shared.scheduledMinute = briefingMinute
                guard briefingEnabled else { return }
                Task { await DailyBriefingStore.shared.rescheduleFromCache() }
            }
        )
    }

    var briefingSection: some View {
        Section {
            Toggle(isOn: $briefingEnabled) {
                Label("Daily briefing", systemImage: "sun.horizon.fill")
                    .foregroundStyle(primaryText)
            }
            .tint(.green)
            .onChange(of: briefingEnabled) { _, newValue in
                Task {
                    if newValue {
                        let granted = await notifications.requestAuthorizationIfNeeded()
                        if granted {
                            await DailyBriefingStore.shared.rescheduleFromCache()
                        } else {
                            briefingEnabled = false
                        }
                    } else {
                        DailyBriefingStore.shared.cancel()
                    }
                }
            }

            if briefingEnabled {
                HStack {
                    Text("Delivery time")
                        .foregroundStyle(primaryText)
                    Spacer()
                    DatePicker(
                        "",
                        selection:           briefingTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .colorScheme(colorScheme)
                }

                if !monitoredFavorites.isEmpty {
                    HStack {
                        Text("Location")
                            .foregroundStyle(primaryText)
                        Spacer()
                        Menu {
                            Button {
                                briefingLocationID = ""
                                DailyBriefingStore.shared.unpin()
                                Task { await DailyBriefingStore.shared.rescheduleFromCache() }
                            } label: {
                                Label("Current location", systemImage: briefingLocationID.isEmpty ? "checkmark" : "location")
                            }
                            Divider()
                            ForEach(monitoredFavorites, id: \.id) { loc in
                                Button {
                                    briefingLocationID = loc.id
                                    let usesUSUnits = loc.countryCode.uppercased() != "CA"
                                    Task {
                                        await DailyBriefingStore.shared.chooseLocation(
                                            id:          loc.id,
                                            lat:         loc.latitude,
                                            lon:         loc.longitude,
                                            name:        loc.displayName,
                                            usesUSUnits: usesUSUnits
                                        )
                                    }
                                } label: {
                                    Label(
                                        loc.displayName,
                                        systemImage: briefingLocationID == loc.id ? "checkmark" : "mappin"
                                    )
                                }
                            }
                        } label: {
                            let name: String = {
                                if briefingLocationID.isEmpty { return "Current location" }
                                return monitoredFavorites.first(where: { $0.id == briefingLocationID })?.displayName ?? "Current location"
                            }()
                            HStack(spacing: 4) {
                                Text(name)
                                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                            }
                        }
                    }
                }
            }

            Text("Get a daily weather summary at your chosen time. Notifications before 5 PM show today's high and conditions; at 5 PM or later they switch to tonight's low and overnight outlook.")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Daily Briefing")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryText)
        } footer: {
            if briefingEnabled,
               notifications.authorizationStatus != .authorized,
               notifications.authorizationStatus != .provisional {
                Text("Enable notifications in iOS Settings to receive briefings.")
                    .foregroundStyle(.orange)
            }
        }
        .textCase(nil)
        .listRowBackground(rowBackgroundView)
        .listRowSeparator(.hidden)
    }

    var privacySection: some View {
        Section(header: Text("Privacy").font(.subheadline.weight(.semibold)).foregroundStyle(primaryText)) {
            Text("YAWA CAN uses your location to show nearby conditions, forecasts, and radar. Forecast data is provided by Open-Meteo.")
                .font(.caption)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .listRowBackground(rowBackgroundView)
                .listRowSeparator(.hidden)

            Link(destination: URL(string: "https://widgetaldigital.com/yawacan/getting-started-ios.html")!) {
                HStack {
                    Text("Getting Started")
                        .foregroundStyle(primaryText)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AnyShapeStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9)))
                }
                .contentShape(Rectangle())
            }
            .listRowBackground(rowBackgroundView)
            .listRowSeparator(.hidden)

            Link(destination: URL(string: "https://widgetaldigital.com/yawacan/privacy.html")!) {
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
            .listRowBackground(rowBackgroundView)
            .listRowSeparator(.hidden)
        }
        .textCase(nil)
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

    private func lightHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }

}
