import SwiftUI
import CoreLocation
import MapKit
import Charts
import Combine
import UIKit

// YAWA CAN - Main ContentView
/// Uses `WeatherViewModel` + `WeatherServiceProtocol` (Open-Meteo service) and renders
/// the core YAWA UX: current tile, hourly temp chart, and 7‑day forecast.

private func alertSeverityColor(_ severity: String) -> Color {
    switch severity.lowercased() {
    case "extreme":
        return .red
    case "severe":
        return Color.orange.opacity(0.9)
    case "moderate":
        return .orange
    case "minor":
        return .yellow
    default:
        return .orange
    }
}

private func normalizedAlertTitle(_ title: String) -> String {
    title
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .map { word in
            let lower = word.lowercased()
            let smallWords = ["of", "and", "in", "for", "to", "with"]
            if smallWords.contains(lower) {
                return lower
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        .joined(separator: " ")
}

enum RefreshLog {
    static let enabled = false

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[YCREFRESH] \(message())")
    }
}

struct ContentView: View {
    @StateObject private var viewModel = WeatherViewModel()
    @StateObject private var locationStore = LocationStore()
    @StateObject private var locationResolver = LocationResolver()
    private let weatherService = OpenMeteoWeatherService()

    @State private var showingLocations = false
    @State private var selected: SavedLocation? = nil
    @State private var displayedLocation: SavedLocation? = nil
    @State private var showingSettings = false
    @State private var radarTarget: RadarTarget? = nil
    
    @State private var selectedDaySelection: ForecastDetailSelection? = nil
    @State private var forecastDetailDetent: PresentationDetent = .fraction(0.7)
    
    @State private var selectedAlert: WeatherAlert? = nil
    
    @State private var showingAllAlerts = false
    @State private var showingAQIInfo = false
    
    @State private var pendingNotificationRoute: NotificationRoute? = nil
    
    @AppStorage("yawa.can.isCurrentLocationSelected") private var isCurrentLocationSelected: Bool = false
    @AppStorage("yc.notifications.lastFavoritesMonitorAutoRunAt") private var lastFavoritesMonitorAutoRunAt: Double = 0
    
    @MainActor
    private func refreshWeather(showLoading: Bool = true) async {
        RefreshLog.log("refresh requested showLoading=\(showLoading) currentLocation=\(isCurrentLocationSelected)")

        if refreshInFlight {
            pendingRefresh = true
            pendingRefreshShowsLoading = pendingRefreshShowsLoading || showLoading
            RefreshLog.log("refresh queued while in flight")
            return
        }

        refreshInFlight = true
        defer {
            refreshInFlight = false

            if pendingRefresh {
                let rerunShowsLoading = pendingRefreshShowsLoading
                pendingRefresh = false
                pendingRefreshShowsLoading = false
                RefreshLog.log("running queued refresh showLoading=\(rerunShowsLoading)")
                Task { @MainActor in
                    await refreshWeather(showLoading: rerunShowsLoading)
                }
            }
        }

        var loc = selected ?? locationStore.selected ?? SavedLocation.toronto
        RefreshLog.log("refresh starting target=\(loc.displayName) lat=\(loc.latitude) lon=\(loc.longitude)")

        if isCurrentLocationSelected {
            do {
                let currentLoc = try await locationResolver.requestOneShotLocation()
                locationStore.setSelectedCurrentLocation(currentLoc)
                selected = currentLoc
                displayedLocation = currentLoc
                loc = currentLoc
                RefreshLog.log("one-shot location resolved target=\(currentLoc.displayName) lat=\(currentLoc.latitude) lon=\(currentLoc.longitude)")
            } catch {
                RefreshLog.log("one-shot location failed error=\(error.localizedDescription)")
                // Keep using the most recent selected location if a fresh current-location lookup fails.
            }
        } else {
            selected = loc
        }

        await viewModel.load(
            latitude: loc.latitude,
            longitude: loc.longitude,
            locationName: loc.displayName,
            service: weatherService,
            forecastDays: forecastDaysToShow,
            showLoading: showLoading
        )

        displayedLocation = loc
        temperatureAnimationKey = UUID()
        sunRefreshToken = Date()
        lastUpdatedAt = Date()
        RefreshLog.log("refresh completed target=\(loc.displayName)")
    }
    
    @MainActor
    private func refreshOnForegroundIfNeeded() async {
        let now = Date()
        if let last = lastForegroundRefreshAt,
           now.timeIntervalSince(last) < 20 {
            RefreshLog.log("foreground refresh skipped due to throttle")
            return
        }

        lastForegroundRefreshAt = now
        RefreshLog.log("foreground refresh triggered")
        await refreshWeather(showLoading: false)
    }
    
    @State private var sunRefreshToken = Date()
    @State private var temperatureAnimationKey = UUID()
    @State private var lastUpdatedAt: Date? = nil

    // Settings: how many forecast days to show (7 or 10)
    @AppStorage("forecastDaysToShow") private var forecastDaysToShow: Int = 7

    // MARK: - Easter egg (tap Sun card 5x)
    @State private var showEasterEgg: Bool = false
    @State private var sunTapCount: Int = 0
    @State private var sunTapResetTask: Task<Void, Never>? = nil
    @State private var easterEggHideTask: Task<Void, Never>? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var lastForegroundRefreshAt: Date? = nil
    @State private var refreshInFlight = false
    @State private var pendingRefresh = false
    @State private var pendingRefreshShowsLoading = false

    private var appBackground: LinearGradient {
        YAWATheme.background(for: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                appBackground
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            Color.clear
                                .frame(height: 0)
                                .id("top")

                            headerButton

                            if viewModel.isLoading && viewModel.snapshot == nil {
                                loadingRow
                            }

                            if let message = viewModel.errorMessage, viewModel.snapshot == nil {
                                Text(message)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if let snap = viewModel.snapshot {
                                currentTile(snap)
                                dailyTile(snap)
                                radarCard()
                                comfortTile(snap)
                                airQualityTile(snap)
                                sunTile(snap)
                            } else if !viewModel.isLoading && viewModel.errorMessage == nil {
                                Text("No weather loaded yet.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .padding(.top, 6)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable {
                        await refreshWeather()
                    }
                    .onChange(of: selected?.id) { _, _ in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    }
                }

                if showEasterEgg {
                    easterEggOverlay
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .zIndex(999)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .fontDesign(.rounded)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingLocations = true
                    } label: {
                        Image(systemName: "location.circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor("location.circle", scheme: colorScheme))
                    }
                    .accessibilityLabel("Locations")
                    
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor("gearshape", scheme: colorScheme))
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(YAWATheme.background(for: colorScheme), for: .navigationBar)
        }
        .task {
            let initial = locationStore.selected ?? locationStore.favorites.first ?? SavedLocation.toronto
            selected = initial
            UserDefaults.standard.set(initial.displayName, forKey: "yawa.can.selectedLocationDisplayName")
            await refreshWeather()
        }
        .onChange(of: forecastDaysToShow) { _, _ in
            Task {
                await refreshWeather()
            }
        }
        .onChange(of: viewModel.snapshot) { _, newSnapshot in
            guard let newSnapshot else { return }
            applyPendingNotificationRouteIfPossible(snapshot: newSnapshot)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                #if DEBUG
                AppLogger.log("[N1] YC foregrounded at \(Date())")
                #endif
                Task { @MainActor in
                    await refreshOnForegroundIfNeeded()
                }
            } else if newPhase == .inactive {
                #if DEBUG
                AppLogger.log("[N1] YC inactive at \(Date())")
                #endif
            } else if newPhase == .background {
                #if DEBUG
                AppLogger.log("[N1] YC backgrounded at \(Date())")
                #endif
            }
        }
        .sheet(item: $selectedDaySelection) { selection in
            DailyForecastDetailSheet(
                days: selection.days,
                initialIndex: selection.initialIndex,
                hourlyTempsC: selection.hourlyTempsC,
                hourlyTimeISO: selection.hourlyTimeISO,
                hourlyPrecipChancePercent: selection.hourlyPrecipChancePercent,
                timeZoneID: selection.timeZoneID,
                usesUSUnits: usesUSUnits
            )
            .presentationDetents([.fraction(0.70), .large], selection: $forecastDetailDetent)
            .presentationDragIndicator(.visible)
            .onAppear {
                forecastDetailDetent = .fraction(0.70)
            }
        }
        .sheet(item: $selectedAlert) { alert in
            AlertDetailSheet(alert: alert)
                .presentationDetents([.fraction(0.90), .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: "\(selectedLocationForAlerts.latitude),\(selectedLocationForAlerts.longitude)") {
            await loadAlertsForSelectedLocation()
        }
        .sheet(isPresented: $showingLocations) {
            LocationPickerView(
                store: locationStore,
                onSelect: { loc in
                    locationStore.setSelected(loc)
                    selected = loc
                    isCurrentLocationSelected = false

                    Task { @MainActor in
                        await refreshWeather()
                    }
                },
                onSelectCurrentLocation: { loc in
                    locationStore.setSelectedCurrentLocation(loc)
                    selected = loc
                    displayedLocation = loc
                    isCurrentLocationSelected = true

                    Task { @MainActor in
                        await refreshWeather()
                    }
                }
            )
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                monitoredFavorites: locationStore.favorites.map {
                    MonitoredFavoriteLocation(
                        displayName: $0.displayName,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        countryCode: $0.countryCode
                    )
                }
            )
        }
        .sheet(item: $radarTarget) { target in
            RadarView(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ycNotificationRouteReceived)) { note in
            guard let route = note.object as? NotificationRoute else { return }
            handleNotificationRoute(route)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ycNotificationDebugStateCleared)) { _ in
            clearNotificationRouteUIState()
            clearFavoritesMonitorAutoRunThrottle()
        }
    }

    // MARK: - Easter egg overlay

    private var easterEggOverlay: some View {
        VStack {
            Spacer().frame(height: 10)

            Text("Yawa ✨ Yet Another Weather App")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: showEasterEgg)
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            showingLocations = true
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(displayedLocation?.headerName ?? selected?.headerName ?? locationStore.selected?.headerName ?? "Toronto, ON")
                            .font(.title2.weight(.semibold))

                        if isCurrentLocationSelected {
                            Image(systemName: "location.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9))
                                .offset(y: 0.5)
                                .padding(.trailing, 1)
                                .accessibilityHidden(true)
                        }
                    }

                    Text(locationUnitsSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastUpdatedAt {
                        Text("Updated \(lastUpdatedText(lastUpdatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose location")
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading weather…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: - Tiles

    private func currentTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.subheadline.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor("clock", scheme: colorScheme))
                            .opacity(0.9)

                        Text("Now")
                            .font(.headline)

                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.secondary)
                        }
                    }
                    Text(snap.current.conditionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                let nowSymbol = nowSymbolName(for: snap)
                Image(systemName: nowSymbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.symbolColor(nowSymbol, scheme: colorScheme))
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(currentTemperatureValueText(snap.current.temperatureC))
                        .font(.system(size: 60, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .opacity(viewModel.isLoading ? 0.82 : 1.0)
                        .animation(.easeInOut(duration: 0.22), value: temperatureAnimationKey)
                        .animation(.easeInOut(duration: 0.18), value: viewModel.isLoading)

                    Text(temperatureUnitLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(viewModel.isLoading ? 0.78 : 1.0)
                        .animation(.easeInOut(duration: 0.22), value: temperatureAnimationKey)
                        .animation(.easeInOut(duration: 0.18), value: viewModel.isLoading)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    metricIconValue(icon: "wind", value: windValueText(for: snap.current))
                    metricIconValue(icon: "humidity.fill", value: "\(Int(round(snap.current.humidityPercent)))%")
                    metricIconValue(icon: "gauge", value: pressureValueText(for: snap.current.pressureKPa))
                }
                .padding(.top, -8)
                .font(.subheadline)
                .monospacedDigit()
            }
        }
        .opacity(viewModel.isLoading ? 0.72 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: viewModel.isLoading)
        .tileStyle()
    }

    private func comfortTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "figure.walk")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.symbolColor("figure.walk", scheme: colorScheme))
                    .opacity(0.9)

                Text("Comfort")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "thermometer")
                        .font(.subheadline.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.symbolColor("thermometer", scheme: colorScheme))
                        .opacity(colorScheme == .dark ? 0.90 : 0.82)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }

                    Text("Feels like")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                }

                Spacer()

                Text(apparentTemperatureText(snap.current.apparentTemperatureC))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(feelsLikeSubtitleText(for: snap.current))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))

                Text(comfortSummaryText(for: snap.current))
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textTertiary(for: colorScheme))
            }
            .padding(.top, 2)
        }
        .tileStyle()
    }

    private func airQualityTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            // Header
            HStack(spacing: 6) {
                Image(systemName: "aqi.medium")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YAWATheme.symbolColor("aqi.medium", scheme: colorScheme))
                Text("Air Quality")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    showingAQIInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.6))
                }
                .accessibilityLabel("About Air Quality Index")
            }
            .sheet(isPresented: $showingAQIInfo) {
                AQIInfoSheet()
            }

            if let aq = snap.airQuality {
                HStack(alignment: .center, spacing: 14) {

                    // AQI number + category
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(aq.usAQI)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundStyle(aqiColor(aq.categoryColor, scheme: colorScheme))
                            Text("AQI")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                                .padding(.bottom, 8)
                        }
                        HStack(spacing: 6) {
                            Circle()
                                .fill(aqiColor(aq.categoryColor, scheme: colorScheme))
                                .frame(width: 8, height: 8)
                            Text(aq.category)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(aqiColor(aq.categoryColor, scheme: colorScheme))
                        }
                    }

                    Spacer()

                    // PM2.5 secondary stat
                    if let pm25 = aq.pm25 {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(String(format: "%.1f", pm25))
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                            Text(pm25Label(for: aq.categoryColor))
                                .font(.caption)
                                .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                        }
                    }
                }

                // AQI scale bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(aqiColor(aq.categoryColor, scheme: colorScheme))
                            .frame(width: geo.size.width * min(1.0, Double(aq.usAQI) / 300.0), height: 6)
                    }
                }
                .frame(height: 6)

            } else {
                Text("Air quality data unavailable.")
                    .font(.subheadline)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                    .padding(.vertical, 6)
            }
        }
        .tileStyle()
    }

    private func pm25Label(for category: AirQualityData.AQIColor) -> String {
        switch category {
        case .green:  return "Fine particles"
        case .yellow: return "Some fine particles"
        case .orange: return "Elevated fine particles"
        case .red:    return "High fine particles"
        case .purple: return "Very high fine particles"
        case .maroon: return "Hazardous particles"
        }
    }

    private func aqiColor(_ category: AirQualityData.AQIColor, scheme: ColorScheme) -> Color {
        switch category {
        case .green:  return Color(red: 0.18, green: 0.72, blue: 0.38)
        case .yellow: return Color(red: 0.85, green: 0.70, blue: 0.10)
        case .orange: return Color(red: 0.95, green: 0.50, blue: 0.10)
        case .red:    return Color(red: 0.85, green: 0.18, blue: 0.18)
        case .purple: return Color(red: 0.55, green: 0.18, blue: 0.72)
        case .maroon: return Color(red: 0.50, green: 0.05, blue: 0.10)
        }
    }

    private func nowSymbolName(for snap: WeatherSnapshot) -> String {
        let base = snap.current.symbolName
        guard isNight(for: snap) else { return base }

        switch base {
        case "sun.max.fill", "sun.max":
            return "moon.stars.fill"
        case "cloud.sun.fill", "cloud.sun":
            return "cloud.moon.fill"
        case "cloud.sun.rain.fill", "cloud.sun.rain":
            return "cloud.moon.rain.fill"
        default:
            return base
        }
    }

    private func isNight(for snap: WeatherSnapshot) -> Bool {
        guard let sun = snap.sun else { return false }

        let tz: TimeZone? = {
            let id = snap.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            return TimeZone(identifier: id)
        }()

        let now = Date()
        if let tz {
            let cal = Calendar.current
            let nowComp = cal.dateComponents(in: tz, from: now)
            let srComp = cal.dateComponents(in: tz, from: sun.sunrise)
            let ssComp = cal.dateComponents(in: tz, from: sun.sunset)

            guard
                let nowZ = Calendar(identifier: cal.identifier).date(from: nowComp),
                let srZ  = Calendar(identifier: cal.identifier).date(from: srComp),
                let ssZ  = Calendar(identifier: cal.identifier).date(from: ssComp)
            else {
                return !(now >= sun.sunrise && now <= sun.sunset)
            }
            return !(nowZ >= srZ && nowZ <= ssZ)
        }

        return !(now >= sun.sunrise && now <= sun.sunset)
    }

    @State private var activeAlerts: [WeatherAlert] = []
    @State private var isLoadingAlerts = false
    @StateObject private var notificationCoordinator = NotificationCoordinator()
    private let favoritesNotificationMonitor = FavoritesNotificationMonitor()
    
    private var selectedLocationForAlerts: SavedLocation {
        selected ?? displayedLocation ?? locationStore.selected ?? .toronto
    }

    private func effectiveCountryCode(for location: SavedLocation) -> String {
        let inferred = inferredCountryCode(for: location.displayName)
        if inferred == "US" || inferred == "CA" {
            return inferred
        }
        return location.countryCode
    }

    private var activeAlertsForSelectedLocation: [WeatherAlert] {
        activeAlerts
    }
    
    @MainActor
    private func loadAlertsForSelectedLocation() async {
        let requestedLocation = selectedLocationForAlerts
        let requestedCountryCode = effectiveCountryCode(for: requestedLocation)

        guard shouldFetchAlerts(for: requestedLocation, countryCode: requestedCountryCode) else {
            clearAlertsForNonCanadianLocation(requestedLocation, countryCode: requestedCountryCode)
            return
        }

        isLoadingAlerts = true
        defer { isLoadingAlerts = false }

        do {
            let alerts = try await fetchAlertsForLocation(requestedLocation, countryCode: requestedCountryCode)
            await applyAlertsIfStillCurrent(alerts, requestedLocation: requestedLocation, countryCode: requestedCountryCode)
        } catch {
            await handleAlertFetchError(error, requestedLocation: requestedLocation, countryCode: requestedCountryCode)
        }
    }

    private func shouldFetchAlerts(for location: SavedLocation, countryCode: String) -> Bool {
        countryCode == "CA"
    }

    private func clearAlertsForNonCanadianLocation(_ location: SavedLocation, countryCode: String) {
        activeAlerts = []
        isLoadingAlerts = false
        viewModel.updateNotificationSnapshotForecastAlert(
            nil,
            expectedLocationName: location.displayName,
            expectedLatitude: location.latitude,
            expectedLongitude: location.longitude
        )
        #if DEBUG
        AppLogger.log("[Alerts] skipping fetch for non-CA location: \(location.displayName) countryCode=\(countryCode)")
        #endif
    }

    private func fetchAlertsForLocation(_ location: SavedLocation, countryCode: String) async throws -> [WeatherAlert] {
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        let service = CanadaAlertService()
        let tightDelta = 0.15
        let wideDelta  = 0.75

        #if DEBUG
        AppLogger.log("[Alerts] starting fetch for: \(location.displayName) (\(location.latitude), \(location.longitude))")
        #endif

        let tightAlerts = try await service.fetchAlerts(withDelta: tightDelta, for: coordinate, countryCode: countryCode)

        if !tightAlerts.isEmpty {
            #if DEBUG
            AppLogger.log("[Alerts] found \(tightAlerts.count) alerts in tight range (Δ\(tightDelta))")
            #endif
            return tightAlerts
        }

        #if DEBUG
        AppLogger.log("[Alerts] no alerts in tight range (Δ\(tightDelta)) — widening to Δ\(wideDelta)")
        #endif
        return try await service.fetchAlerts(withDelta: wideDelta, for: coordinate, countryCode: countryCode)
    }

    @MainActor
    private func applyAlertsIfStillCurrent(
        _ alerts: [WeatherAlert],
        requestedLocation: SavedLocation,
        countryCode: String
    ) async {
        guard isStillCurrentLocation(requestedLocation, countryCode: countryCode) else {
            #if DEBUG
            AppLogger.log("[Alerts] result discarded — location changed from \(requestedLocation.displayName)")
            #endif
            return
        }

        // Sort descending by expiry so the longest-running (most significant) alert is first.
        activeAlerts = alerts.sorted { ($0.expiresAt ?? .distantFuture) > ($1.expiresAt ?? .distantFuture) }
        viewModel.updateNotificationSnapshotForecastAlert(
            activeAlerts.first,
            expectedLocationName: requestedLocation.displayName,
            expectedLatitude: requestedLocation.latitude,
            expectedLongitude: requestedLocation.longitude
        )
        #if DEBUG
        AppLogger.log("[Alerts] final active alerts count: \(activeAlerts.count)")
        #endif
    }

    @MainActor
    private func handleAlertFetchError(
        _ error: Error,
        requestedLocation: SavedLocation,
        countryCode: String
    ) async {
        guard isStillCurrentLocation(requestedLocation, countryCode: countryCode) else {
            #if DEBUG
            AppLogger.log("[Alerts] fetch failure discarded — location changed from \(requestedLocation.displayName)")
            #endif
            return
        }

        #if DEBUG
        AppLogger.log("[Alerts] fetch failed for \(requestedLocation.displayName): \(error.localizedDescription)")
        #endif
        activeAlerts = []
        viewModel.updateNotificationSnapshotForecastAlert(
            nil,
            expectedLocationName: requestedLocation.displayName,
            expectedLatitude: requestedLocation.latitude,
            expectedLongitude: requestedLocation.longitude
        )
    }

    private func isStillCurrentLocation(_ location: SavedLocation, countryCode: String) -> Bool {
        let current = selectedLocationForAlerts
        return abs(current.latitude  - location.latitude)  < 0.0001 &&
               abs(current.longitude - location.longitude) < 0.0001 &&
               effectiveCountryCode(for: current) == countryCode
    }

    private func dailyTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            
            // Alerts section – always show first alert + tappable "more" if needed
            if let firstAlert = activeAlertsForSelectedLocation.first {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        selectedAlert = firstAlert
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(alertSeverityColor(firstAlert.severity))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(normalizedAlertTitle(firstAlert.title))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                                    .lineLimit(1)
                                
 //                               Text("Area: \(firstAlert.areaName)")
                                Text("\(firstAlert.areaName)")
                                    .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
//                                    .font(.caption2)
//                                    .foregroundStyle(YAWATheme.textTertiary(for: colorScheme))
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(firstAlert.severity)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(alertSeverityColor(firstAlert.severity))
                                
                                Text(firstAlert.expiresSoonText ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                
                    // "+ more" tappable row (only if more alerts exist)
                    if activeAlertsForSelectedLocation.count > 1 {
                        Button {
                            showingAllAlerts = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("+\(activeAlertsForSelectedLocation.count - 1) more alerts")
                                    .font(.subheadline)                    // exact match to forecast header size
                                    .fontWeight(.semibold)                 // exact match to forecast header weight
                                    .foregroundStyle(.tint)                // accent color to indicate tappable
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)                        // keep small and secondary
                                    .foregroundStyle(.tint.opacity(0.8))
                            }
                            .padding(.vertical, 4)                         // tight spacing to align with forecast rows
                            .padding(.horizontal, 0)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.yellow.opacity(colorScheme == .dark ? 0.15 : 0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(alertSeverityColor(firstAlert.severity).opacity(0.5), lineWidth: 1)
                )
                
                Divider().opacity(0.3).padding(.vertical, 2)
            }
            
            // Forecast header – always visible
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.symbolColor("calendar", scheme: colorScheme))
                    .opacity(0.85)
                
                Text("\(max(1, min(forecastDaysToShow, 10)))-Day Forecast")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                
                Spacer()
            }
            
            // Forecast rows – now always visible below alerts
            let daysToShow = max(1, min(forecastDaysToShow, 10))
            let days: [DailyForecastDay] = Array(snap.daily.prefix(daysToShow))
            
            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let dayDateW: CGFloat = 78
                let iconW: CGFloat = 36
                
                let sym = day.symbolName
                let isTonight: Bool = {
                    guard let sunset = snap.sun?.sunset else { return false }
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = TimeZone(identifier: snap.timeZoneID) ?? .current
                    return cal.isDateInToday(day.date) && Date() > sunset
                }()
                Button {
                    selectedDaySelection = ForecastDetailSelection(
                        days: days,
                        initialIndex: idx,
                        hourlyTempsC: snap.hourlyTempsC,
                        hourlyTimeISO: snap.hourlyTimeISO,
                        hourlyPrecipChancePercent: snap.hourlyPrecipChancePercent,
                        timeZoneID: snap.timeZoneID
                    )
                } label: {
                    HStack(spacing: 4) {
                        // Left block: weekday/date/icon/PoP (modified)
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(weekdayLabel(day.date, timeZoneID: snap.timeZoneID, sunset: snap.sun?.sunset))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                                
                                Text(dateLabel(day.date, timeZoneID: snap.timeZoneID))
                                    .font(.caption)
                                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.75))
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                            .frame(width: dayDateW, alignment: .leading)
                            
                            let rawPop = day.precipChancePercent
                            let roundedPop = max(0, min(100, Int((Double(rawPop) / 10.0).rounded() * 10.0)))
                            let popText: String? = (roundedPop > 0) ? "\(roundedPop)%" : nil
                            
                            Group {
                                if let popText {
                                    VStack(spacing: 2) {
                                        Image(systemName: sym)
                                            .symbolRenderingMode(.hierarchical)
                                            .foregroundStyle(YAWATheme.symbolColor(sym, scheme: colorScheme))
                                            .font(.title3)
                                            .frame(height: 18, alignment: .center)
                                        
                                        Text(popText)
                                            .font(popText == "100%" ? .caption2.weight(.semibold) : .caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                                            .frame(height: 10, alignment: .top)
                                    }
                                } else {
                                    Image(systemName: sym)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(YAWATheme.symbolColor(sym, scheme: colorScheme))
                                        .font(.title3)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                            }
                            .frame(width: iconW, height: 34, alignment: .center)
                        }
                        .frame(width: dayDateW + 4 + iconW, alignment: .leading)
                        
                        // Forecast text
                        Text(refinedDailyRowConditionText(for: day))
                            .font(.subheadline)
                            .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                            .layoutPriority(2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        
                        Spacer(minLength: 8)
                        
                        // High/Low
                        HStack(spacing: 3) {
                            Text(isTonight ? "—" : tempDisplay(day.highC))
                            Text("/")
                                .foregroundStyle(.secondary)
                            Text(tempDisplay(day.lowC))
                                .foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if idx != days.count - 1 {
                    Divider().opacity(0.5)
                }
            }
            
            Text("Source: Open-Meteo")
                .font(.caption)
                .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9))
                .padding(.top, 8)
        }
        .tileStyle()
        .sheet(isPresented: $showingAllAlerts) {
            AllAlertsSheet(alerts: activeAlertsForSelectedLocation)
                .presentationDetents([.fraction(0.9), .large])
                .presentationDragIndicator(.visible)
        }
    }
    

    
    private func refinedDailyRowConditionText(for day: DailyForecastDay) -> String {
        let raw = day.conditionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        // Correct rain → snow/frozen when the daily high is at or below 0°C.
        let corrected = temperatureCorrectedConditionText(raw, highC: day.highC)
        if corrected != raw { return corrected }

        if lower.contains("rain") || lower.contains("drizzle") || lower.contains("snow") ||
            lower.contains("shower") || lower.contains("thunder") || lower.contains("fog") ||
            lower.contains("ice") || lower.contains("sleet") || lower.contains("mix") {
            return raw
        }

        switch day.symbolName {
        case "sun.max.fill", "sun.max":
            if lower == "mostly cloudy" || lower == "cloudy" {
                return "Mostly clear"
            }
            return raw

        case "cloud.sun.fill", "cloud.sun":
            if lower == "mostly cloudy" || lower == "cloudy" || lower == "mostly clear" {
                return "Partly cloudy"
            }
            return raw

        case "cloud.fill":
            if lower == "mostly clear" || lower == "partly cloudy" {
                return "Mostly cloudy"
            }
            return raw

        default:
            return raw
        }
    }

    private func radarCard() -> some View {
        Button {
            openRadar()
            lightHaptic()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.symbolColor("dot.radiowaves.left.and.right", scheme: colorScheme))
                        .opacity(0.85)

                    Text("Radar")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                        .opacity(0.9)
                }

                Text("View live radar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))

                Text("Source: rainviewer.com")
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textTertiary(for: colorScheme))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tileStyle()
        .accessibilityLabel("Radar")
    }
    
    private func sunTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.symbolColor("sun.max", scheme: colorScheme))
                    .opacity(0.9)

                Text("Sun")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()
            }

            if let sun = snap.sun {
                let tz = TimeZone(identifier: snap.timeZoneID) ?? .current
                let now = sunRefreshToken
                let sunState: (sunrise: Date, sunset: Date, isNight: Bool, progressForArc: Double) = {
                    let cal: Calendar = {
                        var c = Calendar(identifier: .gregorian)
                        c.timeZone = tz
                        return c
                    }()

                    var sunrise = sun.sunrise
                    var sunset = sun.sunset

                    let inProvidedWindow = (now >= sunrise && now <= sunset)

                    if !inProvidedWindow, now < sunrise {
                        if let srPrev = cal.date(byAdding: .day, value: -1, to: sunrise),
                           let ssPrev = cal.date(byAdding: .day, value: -1, to: sunset),
                           now >= srPrev && now <= ssPrev {
                            sunrise = srPrev
                            sunset = ssPrev
                        }
                    }

                    if !(now >= sunrise && now <= sunset), now > sunset {
                        if let srNext = cal.date(byAdding: .day, value: 1, to: sunrise),
                           let ssNext = cal.date(byAdding: .day, value: 1, to: sunset),
                           now >= srNext && now <= ssNext {
                            sunrise = srNext
                            sunset = ssNext
                        }
                    }

                    let isNight = !(now >= sunrise && now <= sunset)
                    let dayProgress = sunProgress(sunrise: sunrise, sunset: sunset, now: now)

                    let progressForArc: Double
                    if isNight {
                        let nightStart: Date
                        let nightEnd: Date

                        if now < sunrise {
                            nightStart = cal.date(byAdding: .day, value: -1, to: sunset)
                                ?? sunset.addingTimeInterval(-24 * 60 * 60)
                            nightEnd = sunrise
                        } else {
                            nightStart = sunset
                            nightEnd = cal.date(byAdding: .day, value: 1, to: sunrise)
                                ?? sunrise.addingTimeInterval(24 * 60 * 60)
                        }

                        progressForArc = sunProgress(sunrise: nightStart, sunset: nightEnd, now: now)
                    } else {
                        progressForArc = dayProgress
                    }

                    return (sunrise, sunset, isNight, progressForArc)
                }()

                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        sunValueColumn(
                            title: "Sunrise",
                            value: timeString(sunState.sunrise, timeZoneID: snap.timeZoneID)
                        )
                        .frame(maxWidth: .infinity)

                        Divider().opacity(0.25)

                        sunValueColumn(
                            title: "Sunset",
                            value: timeString(sunState.sunset, timeZoneID: snap.timeZoneID)
                        )
                        .frame(maxWidth: .infinity)
                    }

                    SunArcView(
                        progress: sunState.progressForArc,
                        arcRiseFraction: 0.32,
                        height: 72,
                        arcLineWidth: 0,
                        markerSize: 14,
                        isThemed: (colorScheme == .dark),
                        isNight: sunState.isNight,
                        showsArc: false,
                        showsHorizon: true,
                        horizonLineWidth: 1.5,
                        horizonYOffset: 35,
                        horizonEndpointInset: 55,
                        horizonBaseFraction: 0.75,
                        showsHorizonTrees: true,
                        arcEndpointYOffset: 10,
                        onTapRefresh: { handleSunArcTap() },
                        enablesTapRefresh: true
                    )
                    .id(sunRefreshToken)
                    .offset(y: -70)
                    .padding(.top, 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { handleSunArcTap() }
                .padding(.vertical, 4)
                .padding(.horizontal, 10)

                Text("Local time: \(localTimeText(timeZone: tz, now: now))")
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
            } else {
                Text("Sun times unavailable.")
                    .font(.callout)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
            }
        }
        .tileStyle()
    }

    private func sunValueColumn(title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Color.clear
                .frame(height: 24)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(title)
                .font(.caption)
                .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    private func timeString(_ date: Date, timeZoneID: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "h:mm a"
        if let tzid = timeZoneID, let tz = TimeZone(identifier: tzid) {
            f.timeZone = tz
        }
        return f.string(from: date)
    }

    private func metricIconValue(icon: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(YAWATheme.symbolColor(icon, scheme: colorScheme))
                .opacity(colorScheme == .dark ? 0.90 : 0.82)
                .frame(width: 18, alignment: .center)
                .offset(y: 0.5)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(width: 104, alignment: .trailing)
    }

    private var displayedCountryCode: String {
        displayedLocation?.countryCode ?? selected?.countryCode ?? locationStore.selected?.countryCode ?? "CA"
    }

    private var usesUSUnits: Bool {
        displayedCountryCode == "US"
    }

    private var temperatureUnitLabel: String {
        usesUSUnits ? "°F" : "°C"
    }

    private var locationUnitsSubtitle: String {
        switch displayedCountryCode {
        case "US":
            return "United States • °F • mph • inHg"
        case "MX":
            return "Mexico • °C • km/h • kPa"
        default:
            return "Canada • °C • km/h • kPa"
        }
    }

    private var navigationTitleText: String {
        usesUSUnits ? "YAWA US" : "YAWA CAN"
    }
    
    private func currentTemperatureValueText(_ celsius: Double) -> String {
        let value = usesUSUnits ? cToF(celsius) : celsius
        return "\(Int(round(value)))"
    }

    private func apparentTemperatureText(_ celsius: Double) -> String {
        let value = usesUSUnits ? cToF(celsius) : celsius
        return "\(Int(round(value)))\(temperatureUnitLabel)"
    }

    private func windValueText(for current: CurrentConditions) -> String {
        let direction = windDirectionPrefix(from: current.windDisplay)
        let speedValue = usesUSUnits ? current.windSpeedKph * 0.621371 : current.windSpeedKph
        let unit = usesUSUnits ? "mph" : "km/h"
        return "\(direction) \(Int(round(speedValue))) \(unit)"
    }

    private func pressureValueText(for pressureKPa: Double) -> String {
        if usesUSUnits {
            let inHg = pressureKPa * 0.2953
            return String(format: "%.2f inHg", inHg)
        } else {
            return String(format: "%.1f kPa", pressureKPa)
        }
    }

    private func windDirectionPrefix(from display: String) -> String {
        let parts = display.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first else { return display }
        return String(first)
    }

    private func cToF(_ celsius: Double) -> Double {
        (celsius * 9.0 / 5.0) + 32.0
    }
    
    private func weekdayLabel(_ date: Date, timeZoneID: String, sunset: Date? = nil) -> String {
        let tz = TimeZone(identifier: timeZoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        if cal.isDateInToday(date) {
            // Show "Tonight" if we're past sunset
            if let sunset, Date() > sunset {
                return "Tonight"
            }
            return "Today"
        }
        if cal.isDateInTomorrow(date) {
            return "Tomorrow"
        }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = tz
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func dateLabel(_ date: Date, timeZoneID: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    private func tempDisplay(_ celsius: Double) -> String {
        let value = usesUSUnits ? cToF(celsius) : celsius
        return "\(Int(round(value)))°"
    }
    
    private static let sunLocalTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a z"
        return f
    }()

    private func localTimeText(timeZone: TimeZone, now: Date = Date()) -> String {
        let f = Self.sunLocalTimeFormatter
        f.timeZone = timeZone
        return f.string(from: now)
    }
    
    private func lastUpdatedText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    @MainActor
    private func handleSunArcTap() {
        sunTapCount += 1
        sunRefreshToken = Date()

        sunTapResetTask?.cancel()
        sunTapResetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 3_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            sunTapCount = 0
        }

        if sunTapCount >= 5 {
            sunTapCount = 0
            sunTapResetTask?.cancel()
            withAnimation {
                showEasterEgg = true
            }

            easterEggHideTask?.cancel()
            easterEggHideTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation {
                    showEasterEgg = false
                }
            }
        }
    }

    private func lightHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
    }
    
    private func clearNotificationRouteUIState() {
        pendingNotificationRoute = nil
        selectedDaySelection = nil
        #if DEBUG
        AppLogger.log("[N1] cleared in-app notification route UI state")
        #endif
    }

    private func handleNotificationRoute(_ route: NotificationRoute) {
        let routedLocation = SavedLocation(
            id: UUID(),
            displayName: route.locationName,
            latitude: route.latitude,
            longitude: route.longitude,
            countryCode: inferredCountryCode(for: route.locationName)
        )

        viewModel.beginNotificationRoute(
            latitude: route.latitude,
            longitude: route.longitude,
            locationName: route.locationName
        )

        pendingNotificationRoute = route
        selected = routedLocation
        displayedLocation = routedLocation
        isCurrentLocationSelected = false
        locationStore.setSelected(routedLocation)

        Task { @MainActor in
            await refreshWeather(showLoading: true)
            if let snapshot = viewModel.snapshot {
                applyPendingNotificationRouteIfPossible(snapshot: snapshot)
            }
        }

        #if DEBUG
        print("[N1] tapped notification kind=\(route.kind) location=\(route.locationName) targetDateISO=\(route.targetDateISO ?? "nil")")
        #endif
    }

    private func applyPendingNotificationRouteIfPossible(snapshot: WeatherSnapshot) {
        guard let route = pendingNotificationRoute else { return }
        guard let targetDateISO = route.targetDateISO else { return }
        guard route.kind == "windyTomorrow" || route.kind == "precipSoon" || route.kind == "notableForecast" else {
            pendingNotificationRoute = nil
            return
        }

        let selectedName = (selected?.displayName ?? displayedLocation?.displayName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let routeName = route.locationName.trimmingCharacters(in: .whitespacesAndNewlines)

        let sameCoordinates = abs(route.latitude - snapshotLocationLatitude) < 0.001 &&
            abs(route.longitude - snapshotLocationLongitude) < 0.001
        let sameName = !selectedName.isEmpty && selectedName.caseInsensitiveCompare(routeName) == .orderedSame

        guard sameCoordinates || sameName else {
            #if DEBUG
            AppLogger.log("[N1] pending route waiting for matching location kind=\(route.kind) route=\(route.locationName) selected=\(selectedName)")
            #endif
            return
        }

        if route.kind == "notableForecast" {
            pendingNotificationRoute = nil
            #if DEBUG
            AppLogger.log("[N1] notableForecast route applied to main screen only")
            #endif
            return
        }

        let daysToShow = max(1, min(forecastDaysToShow, 10))
        let days = Array(snapshot.daily.prefix(daysToShow))
        guard !days.isEmpty else { return }

        let tz = TimeZone(identifier: snapshot.timeZoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = cal
        dayFormatter.timeZone = tz
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let hourlyFormatter = DateFormatter()
        hourlyFormatter.calendar = cal
        hourlyFormatter.timeZone = tz
        hourlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        hourlyFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let targetDate: Date?
        if route.kind == "precipSoon" {
            targetDate = hourlyFormatter.date(from: targetDateISO) ?? dayFormatter.date(from: targetDateISO)
        } else {
            targetDate = dayFormatter.date(from: targetDateISO)
        }

        guard let targetDate else {
            pendingNotificationRoute = nil
            #if DEBUG
            AppLogger.log("[N1] route date parse failed kind=\(route.kind) targetDateISO=\(targetDateISO)")
            #endif
            return
        }

        guard let matchIndex = days.firstIndex(where: { cal.isDate($0.date, inSameDayAs: targetDate) }) else {
            pendingNotificationRoute = nil
            #if DEBUG
            AppLogger.log("[N1] no forecast day matched route kind=\(route.kind) targetDateISO=\(targetDateISO)")
            #endif
            return
        }

        selectedDaySelection = ForecastDetailSelection(
            days: days,
            initialIndex: matchIndex,
            hourlyTempsC: snapshot.hourlyTempsC,
            hourlyTimeISO: snapshot.hourlyTimeISO,
            hourlyPrecipChancePercent: snapshot.hourlyPrecipChancePercent,
            timeZoneID: snapshot.timeZoneID
        )
        forecastDetailDetent = .fraction(0.70)
        pendingNotificationRoute = nil

        #if DEBUG
        AppLogger.log("[N1] opened forecast detail from notification route kind=\(route.kind) index=\(matchIndex) dateISO=\(targetDateISO)")
        #endif
    }

    private var snapshotLocationLatitude: Double {
        displayedLocation?.latitude ?? selected?.latitude ?? locationStore.selected?.latitude ?? 0
    }

    private var snapshotLocationLongitude: Double {
        displayedLocation?.longitude ?? selected?.longitude ?? locationStore.selected?.longitude ?? 0
    }

    private func inferredCountryCode(for displayName: String) -> String {
        let upper = displayName.uppercased()

        let canadianSuffixes = [
            ", AB", ", BC", ", MB", ", NB", ", NL", ", NS", ", NT", ", NU", ", ON", ", PE", ", QC", ", SK", ", YT"
        ]
        if canadianSuffixes.contains(where: { upper.hasSuffix($0) }) {
            return "CA"
        }

        let usSuffixes = [
            ", AL", ", AK", ", AZ", ", AR", ", CA", ", CO", ", CT", ", DE", ", FL", ", GA", ", HI", ", ID", ", IL", ", IN", ", IA", ", KS", ", KY", ", LA", ", ME", ", MD", ", MA", ", MI", ", MN", ", MS", ", MO", ", MT", ", NE", ", NV", ", NH", ", NJ", ", NM", ", NY", ", NC", ", ND", ", OH", ", OK", ", OR", ", PA", ", RI", ", SC", ", SD", ", TN", ", TX", ", UT", ", VT", ", VA", ", WA", ", WV", ", WI", ", WY"
        ]
        if usSuffixes.contains(where: { upper.hasSuffix($0) }) {
            return "US"
        }

        return "CA"
    }

    @MainActor
    private func maybeRunFavoritesMonitorOnForeground() {
        let now = Date().timeIntervalSince1970
        let throttle: TimeInterval = 45 * 60
        let elapsed = now - lastFavoritesMonitorAutoRunAt

        guard elapsed >= throttle else {
            #if DEBUG
            AppLogger.log("[N1] auto favorites monitor skipped: throttle active remaining=\(throttle - elapsed)")
            #endif
            return
        }

        lastFavoritesMonitorAutoRunAt = now
        #if DEBUG
        AppLogger.log("[N1] auto favorites monitor starting on foreground")
        #endif

        Task {
            let monitoredKeys = Set(UserDefaults.standard.stringArray(forKey: "YCBackgroundMonitoredFavorites") ?? [])
            let monitoredFavorites = locationStore.favorites
                .filter {
                    monitoredKeys.contains("\($0.displayName)|\($0.latitude)|\($0.longitude)")
                }
                .prefix(5)
                .map {
                    MonitoredFavoriteLocation(
                        displayName: $0.displayName,
                        latitude: $0.latitude,
                        longitude: $0.longitude,
                        countryCode: effectiveCountryCode(for: $0)
                    )
                }
            guard !monitoredFavorites.isEmpty else {
                #if DEBUG
                AppLogger.log("[N1] auto favorites monitor skipped: no bell-selected favorites")
                #endif
                return
            }
            await favoritesNotificationMonitor.evaluateFavorites(monitoredFavorites)
        }
    }
// MARK: - Location Picker View

// (existing code above)

    @MainActor
    private func clearFavoritesMonitorAutoRunThrottle() {
        lastFavoritesMonitorAutoRunAt = 0
        #if DEBUG
        AppLogger.log("[N1] cleared favorites-monitor auto-run throttle")
        #endif
    }

    private func openRadar() {
        let loc = selected ?? locationStore.selected ?? SavedLocation.toronto

        let newTarget = RadarTarget(
            latitude: loc.latitude,
            longitude: loc.longitude,
            title: loc.displayName
        )

        Task { @MainActor in
            if radarTarget != nil {
                radarTarget = nil
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            radarTarget = newTarget
        }
    }
}

// MARK: - Chart

private struct HourlyTempChart: View {
    let temps: [Double]
    let precipChancePercent: [Double]
    let hourPositions: [Double]
    let usesUSUnits: Bool
    let showCurrentHourMarker: Bool
    let currentHourIndex: Double?

    @Environment(\.colorScheme) private var colorScheme

    private var temperatureLineColor: Color {
        colorScheme == .dark ? Color(red: 0.20, green: 0.78, blue: 0.98) : Color(red: 0.29, green: 0.69, blue: 0.91)
    }

    private var precipBarColor: Color {
        Color.cyan.opacity(colorScheme == .dark ? 0.34 : 0.44)
    }

    private var chartTempMin: Double {
        temps.min() ?? 0
    }

    private var chartTempMax: Double {
        temps.max() ?? 0
    }

    private var tempChartPadding: Double {
        let range = max(chartTempMax - chartTempMin, 1.0)
        return max(2.0, range * 0.22)
    }

    private var tempChartLowerBound: Double {
        chartTempMin - tempChartPadding
    }

    private var tempChartUpperBound: Double {
        chartTempMax + tempChartPadding
    }

    private var tempAxisValues: [Double] {
        let step = usesUSUnits ? 10.0 : 5.0
        let start = floor(tempChartLowerBound / step) * step
        let end = ceil(tempChartUpperBound / step) * step

        var values: [Double] = []
        var tick = start
        while tick <= end {
            values.append(tick)
            tick += step
        }

        if values.isEmpty {
            values = [chartTempMin, chartTempMax]
        }

        return values
    }

    private var precipAxisValues: [Double] {
        [0, 50, 100]
    }

    private func hourLabel(for index: Int) -> String {
        let hour = index % 24
        let suffix = hour < 12 ? "a" : "p"
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display)\(suffix)"
    }

    private func shortNowLabel(for fractionalHour: Double) -> String {
        let totalMinutes = Int((fractionalHour * 60.0).rounded())
        let hour24 = max(0, min(23, totalMinutes / 60))
        let minute = max(0, min(59, totalMinutes % 60))
        let suffix = hour24 < 12 ? "am" : "pm"
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, suffix)
    }

    private func precipValue(at index: Int) -> Double {
        guard precipChancePercent.indices.contains(index) else { return 0 }
        return max(0, min(100, precipChancePercent[index]))
    }

    private func hourPosition(at index: Int) -> Double {
        guard hourPositions.indices.contains(index) else { return Double(index) }
        return hourPositions[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            Chart {
                if showCurrentHourMarker, let currentHourIndex {
                    RuleMark(x: .value("Current Hour", currentHourIndex))
                        .foregroundStyle(Color.cyan.opacity(colorScheme == .dark ? 0.55 : 0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .annotation(position: .top, alignment: .center, spacing: 0) {
                            Text(shortNowLabel(for: currentHourIndex))
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.cyan.opacity(colorScheme == .dark ? 0.12 : 0.10))
                                )
                                .foregroundStyle(Color.cyan.opacity(colorScheme == .dark ? 0.95 : 0.85))
                        }
                }
                if showCurrentHourMarker, let currentHourIndex {
                    RuleMark(x: .value("Current Hour Gap", currentHourIndex), yStart: .value("Gap Bottom", tempChartUpperBound - tempChartPadding * 0.55), yEnd: .value("Gap Top", tempChartUpperBound))
                        .foregroundStyle(colorScheme == .dark ? Color(red: 0.05, green: 0.07, blue: 0.12) : Color(.systemBackground))
                        .lineStyle(StrokeStyle(lineWidth: 4))
                }

                ForEach(Array(temps.enumerated()), id: \.offset) { idx, temp in
                    AreaMark(
                        x: .value("Hour", hourPosition(at: idx)),
                        yStart: .value("Baseline", tempChartLowerBound),
                        yEnd: .value("Temp", temp)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                Color.cyan.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Hour", hourPosition(at: idx)),
                        y: .value("Temp", temp)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(temperatureLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXScale(domain: 0...23)
            .chartYScale(domain: tempChartLowerBound...tempChartUpperBound)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: precipAxisValues) { value in
                    AxisTick()
                        .foregroundStyle(.clear)

                    if let v = value.as(Double.self) {
                        AxisValueLabel("\(Int(round(v)))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.clear)
                    }
                }

                AxisMarks(position: .trailing, values: tempAxisValues) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.05))

                    AxisTick()
                        .foregroundStyle(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.10))

                    if let v = value.as(Double.self) {
                        AxisValueLabel("\(Int(round(v)))°")
                    }
                }
            }
            .frame(height: 126)

            Chart {
                if showCurrentHourMarker, let currentHourIndex {
                    RuleMark(x: .value("Current Hour", currentHourIndex))
                        .foregroundStyle(Color.cyan.opacity(colorScheme == .dark ? 0.50 : 0.40))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }

                RuleMark(y: .value("Precip Mid", 50))
                    .foregroundStyle(Color.cyan.opacity(colorScheme == .dark ? 0.14 : 0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))

                ForEach(Array(precipChancePercent.enumerated()), id: \.offset) { idx, _ in
                    let precip = precipValue(at: idx)
                    if precip > 0 {
                        BarMark(
                            x: .value("Hour", hourPosition(at: idx)),
                            yStart: .value("Precip Base", 0),
                            yEnd: .value("Precip", precip),
                            width: 6
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    precipBarColor.opacity(0.55),
                                    precipBarColor.opacity(0.95)
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .opacity(0.92)
                    }
                }
            }
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                    if let idx = value.as(Int.self) {
                        AxisValueLabel(hourLabel(for: idx))
                    }
                    AxisGridLine()
                        .foregroundStyle(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.06))
                    AxisTick()
                        .foregroundStyle(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: precipAxisValues) { value in
                    AxisTick()
                        .foregroundStyle(Color.cyan.opacity(colorScheme == .dark ? 0.65 : 0.55))

                    if let v = value.as(Double.self) {
                        AxisValueLabel("\(Int(round(v)))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.cyan.opacity(colorScheme == .dark ? 0.95 : 0.90))
                    }
                }

                AxisMarks(position: .trailing, values: tempAxisValues) { value in
                    AxisTick()
                        .foregroundStyle(.clear)

                    if let v = value.as(Double.self) {
                        AxisValueLabel("\(Int(round(v)))°")
                            .font(.caption2)
                            .foregroundStyle(.clear)
                    }
                }
            }
            .frame(height: 48)
            .offset(y: -2)

            Text("Time")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
        }
        .animation(.easeInOut(duration: 0.25), value: temps)
        .animation(.easeInOut(duration: 0.25), value: precipChancePercent)
    }
}

private struct ForecastDetailSelection: Identifiable {
    let days: [DailyForecastDay]
    let initialIndex: Int
    let hourlyTempsC: [Double]
    let hourlyTimeISO: [String]
    let hourlyPrecipChancePercent: [Double]
    let timeZoneID: String

    var id: String {
        guard days.indices.contains(initialIndex) else { return UUID().uuidString }
        return "\(days[initialIndex].date.timeIntervalSince1970)-\(initialIndex)"
    }
}

private struct AlertDetailSheet: View {
    let alert: WeatherAlert

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(alertSeverityColor(alert.severity))
                            .offset(y: 1)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(alert.title.replacingOccurrences(of: "^-\\s*", with: "", options: .regularExpression).localizedCapitalized)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Area: \(alert.areaName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let issuedAt = alert.issuedAt {
                                Text("Issued: \(issuedAtAlertText(issuedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)

                        Text(alert.severity)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(alertSeverityColor(alert.severity))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(alertSeverityColor(alert.severity).opacity(colorScheme == .dark ? 0.14 : 0.10))
                            )
                            .offset(y: 2)
                    }

                    Divider().opacity(0.18)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(summarySections(from: alert.summary)) { section in
                            if let title = section.title {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)

                                    formattedSectionBody(section.body, isMetadata: section.title == nil)
                                }
                                .padding(.top, 2)
                            } else {
                                formattedSectionBody(section.body, isMetadata: section.title == nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 22)
                .background(innerCard)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
            .navigationTitle("Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.82))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.05)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss alert")
                }
            }
        }
        .fontDesign(.rounded)
    }

    private func issuedAtAlertText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd, h:mm a"
        return formatter.string(from: date)
    }

    private var innerCard: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                colorScheme == .dark
                ? Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.95)
                : Color(.systemBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.04),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05),
                radius: 10,
                y: 4
            )
    }

    private struct AlertSummarySection: Identifiable {
        let id = UUID()
        let title: String?
        let body: String
    }

    private func summarySections(from text: String) -> [AlertSummarySection] {
        var lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let first = lines.first {
            let upper = first.uppercased()
            if (upper.contains("WARNING") || upper.contains("STATEMENT")) && (upper.contains("AM") || upper.contains("PM")) {
                lines.removeFirst()
            }
        }

        let junkMarkers = [
            "PLEASE CONTINUE TO MONITOR",
            "TO REPORT SEVERE WEATHER",
            "IN EFFECT FOR:",
            "FOLLOW:",
            "REGIONAL ATOM"
        ]

        let selectedAreaUpper = alert.areaName.uppercased()
        
        let selectedCityUpper = alert.areaName
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        
        lines = lines.filter { line in
            let upper = line.uppercased()

            if junkMarkers.contains(where: { upper.contains($0) }) {
                return false
            }

            if !selectedAreaUpper.isEmpty && upper == selectedAreaUpper {
                return false
            }
            
            if !selectedCityUpper.isEmpty && upper == selectedCityUpper {
                return false
            }
            if !selectedCityUpper.isEmpty && upper.hasPrefix(selectedCityUpper + " - ") {
                return false
            }

            if upper.hasSuffix(" AND VICINITY") {
                return false
            }

            return true
        }

        let sectionHeaderTitles: [String: String] = [
            "WHAT:": "What",
            "WHAT AND WHERE:": "What and where",
            "WHAT AND WHEN:": "What and when",
            "WHEN:": "When",
            "WHERE:": "Where",
            "IMPACTS:": "Impacts",
            "REMARKS:": "Remarks",
            "ADDITIONAL INFORMATION:": "Additional information",
            "LOCATIONS:": "Locations",
            "TOTAL SNOWFALL:": "Total snowfall",
            "TIME SPAN:": "Time span"
        ]

        let inlineHeaderTitles: [String: String] = [
            "WHAT:": "What",
            "WHAT AND WHERE:": "What and where",
            "WHAT AND WHEN:": "What and when",
            "WHEN:": "When",
            "WHERE:": "Where",
            "IMPACTS:": "Impacts",
            "REMARKS:": "Remarks",
            "ADDITIONAL INFORMATION:": "Additional information",
            "LOCATIONS:": "Locations",
            "TOTAL SNOWFALL:": "Total snowfall",
            "TIME SPAN:": "Time span"
        ]

        var sections: [AlertSummarySection] = []
        var currentTitle: String? = nil
        var currentLines: [String] = []

        func flushCurrentSection() {
            let body = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            sections.append(AlertSummarySection(title: currentTitle, body: body))
        }

        for line in lines {
            let upper = line.uppercased()

            if let mappedTitle = sectionHeaderTitles[upper] {
                flushCurrentSection()
                currentTitle = mappedTitle
                currentLines = []
                continue
            }

            var handledInlineHeader = false
            for (key, mappedTitle) in inlineHeaderTitles {
                if upper.hasPrefix(key), upper != key {
                    flushCurrentSection()
                    currentTitle = mappedTitle
                    let remainder = line.dropFirst(key.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    currentLines = remainder.isEmpty ? [] : [remainder]
                    handledInlineHeader = true
                    break
                }
            }

            if handledInlineHeader {
                continue
            }

            if line.hasPrefix("-") {
                let trimmed = String(line.drop(while: { $0 == "-" || $0 == " " }))
                currentLines.append(trimmed.isEmpty ? "•" : "• " + trimmed)
            } else {
                currentLines.append(line)
            }
        }

        flushCurrentSection()

        if sections.isEmpty {
            let metadataPrefixes = [
                "IMPACT LEVEL:",
                "FORECAST CONFIDENCE:"
            ]

            let whenIndicators = [
                "BEGINNING",
                "CONTINUE",
                "UNTIL",
                "THROUGH",
                "TONIGHT",
                "THIS AFTERNOON",
                "THIS EVENING",
                "FRIDAY",
                "SATURDAY",
                "SUNDAY",
                "MONDAY",
                "TUESDAY",
                "WEDNESDAY",
                "THURSDAY"
            ]

            let impactIndicators = [
                "HAZARDOUS",
                "VISIBILITY",
                "TRAVEL",
                "SLIPPERY",
                "DIFFICULT TO NAVIGATE",
                "FLOODING",
                "LANDSLIDE",
                "WASHOUT",
                "POOLING"
            ]

            var metadataLines: [String] = []
            var remainingLines: [String] = []

            for line in lines {
                let upper = line.uppercased()
                if metadataPrefixes.contains(where: { upper.hasPrefix($0) }) {
                    metadataLines.append(line)
                } else {
                    remainingLines.append(line)
                }
            }

            var leadLines: [String] = []
            var whenLines: [String] = []
            var impactLines: [String] = []
            var bodyLines: [String] = []

            if let firstRemaining = remainingLines.first {
                leadLines.append(firstRemaining)
                remainingLines.removeFirst()
            }

            for line in remainingLines {
                let upper = line.uppercased()
                if whenIndicators.contains(where: { upper.contains($0) }) {
                    whenLines.append(line)
                } else if impactIndicators.contains(where: { upper.contains($0) }) {
                    impactLines.append(line)
                } else {
                    bodyLines.append(line)
                }
            }

            var fallbackSections: [AlertSummarySection] = []

            let metadataBody = metadataLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !metadataBody.isEmpty {
                fallbackSections.append(AlertSummarySection(title: nil, body: metadataBody))
            }

            let leadBody = leadLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !leadBody.isEmpty {
                fallbackSections.append(AlertSummarySection(title: nil, body: leadBody))
            }

            let whenBody = whenLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !whenBody.isEmpty {
                fallbackSections.append(AlertSummarySection(title: "When", body: whenBody))
            }

            let impactsBody = impactLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !impactsBody.isEmpty {
                fallbackSections.append(AlertSummarySection(title: "Impacts", body: impactsBody))
            }

            let body = bodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                fallbackSections.append(AlertSummarySection(title: nil, body: body))
            }

            return fallbackSections
        }

        return sections
    }

    @ViewBuilder
    private func formattedSectionBody(_ text: String, isMetadata: Bool) -> some View {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        VStack(alignment: .leading, spacing: isMetadata ? 4 : 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if isMetadata {
                    Text(line)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.82 : 0.68))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                } else if line.hasPrefix("• ") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("•")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(String(line.dropFirst(2)))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
private struct AllAlertsSheet: View {
    let alerts: [WeatherAlert]
    
    @State private var selectedAlertInSheet: WeatherAlert? = nil  // Temp state for detail sheet
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(alerts) { alert in
                    Button {
                        selectedAlertInSheet = alert  // Open detail sheet
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(alertSeverityColor(alert.severity))
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(normalizedAlertTitle(alert.title))
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text("Area: \(alert.areaName)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    if let issuedAt = alert.issuedAt {
                                        Text("Issued: \(issuedAtListText(issuedAt))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(alert.expiresSoonText ?? alert.severity)
                                        .font(.caption)
                                        .foregroundStyle(alertSeverityColor(alert.severity))
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("All Active Alerts (\(alerts.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.82))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.05)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss alerts")
                }
            }
            .sheet(item: $selectedAlertInSheet) { alert in
                AlertDetailSheet(alert: alert)
                    .presentationDetents([.fraction(0.90), .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .fontDesign(.rounded)
    }
    private func issuedAtListText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd, h:mm a"
        return formatter.string(from: date)
    }
}



// MARK: - Styling

struct WeatherAlert: Identifiable, Equatable {
    let id = UUID().uuidString  // ← Always unique UUID
    let title: String
    let severity: String
    let summary: String
    let areaName: String
    let issuedAt: Date?
    let expiresAt: Date?
    
    var expiresSoonText: String? {
        guard let expires = expiresAt else { return nil }
        let interval = expires.timeIntervalSinceNow
        if interval < 0 { return "Expired" }
        if interval < 3600 { return "Expires soon" }
        let hours = Int(interval / 3600)
        return "Expires in \(hours)h"
    }
}

struct CanadaAlertService {
    
    // Reusable helper – accessible from outside the struct (internal access)
    func fetchAlerts(
        withDelta delta: Double,
        for coordinate: CLLocationCoordinate2D,
        countryCode: String
    ) async throws -> [WeatherAlert] {
        guard countryCode == "CA" else { return [] }
        
        let bbox = "\(coordinate.longitude - delta),\(coordinate.latitude - delta),\(coordinate.longitude + delta),\(coordinate.latitude + delta)"
        
        let urlString = "https://api.weather.gc.ca/collections/weather-alerts/items?f=json&lang=en&bbox=\(bbox)&limit=20"
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString) else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        struct Response: Decodable {
            let features: [Feature]
        }
        
        struct Feature: Decodable {
            let properties: Properties
        }
        
        struct Properties: Decodable {
            let alert_name_en: String?
            let alert_text_en: String?
            let severity_en: String?
            let publication_datetime: String?
            let expiration_datetime: String?
            let feature_name_en: String?
            let status_en: String?
            
            private static let isoFormatter: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [
                    .withInternetDateTime,
                    .withDashSeparatorInDate,
                    .withFullDate,
                    .withFullTime,
                    .withTimeZone,
                    .withColonSeparatorInTime,
                    .withFractionalSeconds
                ]
                return f
            }()
            
            var issuedAt: Date? {
                publication_datetime.flatMap { Self.isoFormatter.date(from: $0) }
            }
            
            var expiresAt: Date? {
                expiration_datetime.flatMap { Self.isoFormatter.date(from: $0) }
            }
            
            var isActive: Bool {
                guard let issued = issuedAt, let exp = expiresAt else {
                    return status_en?.lowercased() == "issued"
                }
                let now = Date()
                return now >= issued && now <= exp
            }
        }
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(Response.self, from: data)
        
        let alerts = response.features
            .map { $0.properties }
            .filter { $0.isActive }
            .map { prop in
                WeatherAlert(
                    title: prop.alert_name_en ?? "Weather Alert",
                    severity: prop.severity_en?.capitalized ?? "Moderate",
                    summary: prop.alert_text_en ?? "No details available",
                    areaName: prop.feature_name_en ?? "Affected area",
                    issuedAt: prop.issuedAt,
                    expiresAt: prop.expiresAt
                )
            }
        
        return alerts
    }
}

// MARK: - AQI Info Sheet

private struct AQIInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let bands: [(color: Color, range: String, label: String, description: String)] = [
        (Color(red: 0.18, green: 0.72, blue: 0.38), "0–50",   "Good",                            "Air quality is satisfactory and poses little or no risk."),
        (Color(red: 0.85, green: 0.70, blue: 0.10), "51–100", "Moderate",                        "Acceptable, but some pollutants may be a concern for a small number of sensitive people."),
        (Color(red: 0.95, green: 0.50, blue: 0.10), "101–150","Unhealthy for Sensitive Groups",  "Members of sensitive groups may experience health effects. The general public is less likely to be affected."),
        (Color(red: 0.85, green: 0.18, blue: 0.18), "151–200","Unhealthy",                       "Everyone may begin to experience health effects. Sensitive groups may experience more serious effects."),
        (Color(red: 0.55, green: 0.18, blue: 0.72), "201–300","Very Unhealthy",                  "Health alert: everyone may experience more serious health effects."),
        (Color(red: 0.50, green: 0.05, blue: 0.10), "301+",   "Hazardous",                       "Health warning of emergency conditions. The entire population is likely to be affected.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    Text("The US Air Quality Index (AQI) is a scale from 0 to 500 that tells you how clean or polluted the air is, and what health effects may be a concern. The higher the AQI, the greater the level of air pollution and health concern.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("AQI Scale")
                            .font(.headline)

                        ForEach(bands, id: \.range) { band in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(band.color)
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(band.range)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(band.color)
                                        Text("·")
                                            .foregroundStyle(.secondary)
                                        Text(band.label)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text(band.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("About Fine Particles (PM2.5)")
                            .font(.headline)
                        Text("Fine particles are tiny airborne particles 2.5 micrometers or smaller — about 30 times smaller than a human hair. They come from vehicle exhaust, wildfire smoke, and industrial emissions. Because they're so small, they can penetrate deep into your lungs and affect your health. The PM2.5 value shown is measured in micrograms per cubic meter of air (μg/m³).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text("Source: US EPA AQI standard")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
            }
            .navigationTitle("Air Quality Index")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct TileStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(YAWATheme.cardBackground(for: scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        scheme == .dark
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    YAWATheme.cardStroke(for: scheme).opacity(0.95),
                                    YAWATheme.cardStroke(for: scheme).opacity(0.65),
                                    YAWATheme.cardStroke(for: scheme).opacity(0.35)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        ),
                        lineWidth: scheme == .dark ? 0.9 : 0.9
                    )
            )
    }
}

private extension View {
    func tileStyle() -> some View {
        modifier(TileStyleModifier())
    }
}

private struct SavedLocation: Identifiable, Codable, Equatable {
    let id: UUID
    let displayName: String
    let latitude: Double
    let longitude: Double
    let countryCode: String

    var cityName: String {
        displayName
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? displayName
    }
    
    var headerName: String {
        switch countryCode {
        case "MX":
            return cityName
        case "CA", "US":
            return displayName
        default:
            return displayName
        }
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static let toronto = SavedLocation(
        id: UUID(),
        displayName: "Toronto, ON",
        latitude: 43.6532,
        longitude: -79.3832,
        countryCode: "CA"
    )

    static let vancouver = SavedLocation(
        id: UUID(),
        displayName: "Vancouver, BC",
        latitude: 49.2827,
        longitude: -123.1207,
        countryCode: "CA"
    )
}

@MainActor
private final class LocationStore: ObservableObject {
    @Published private(set) var favorites: [SavedLocation] = []
    @Published private(set) var selected: SavedLocation? = nil

    private let favoritesKey = "yawa.can.favorites"
    private let selectedKey = "yawa.can.selected"

    init() {
        favorites = Self.loadArray(key: favoritesKey) ?? [SavedLocation.toronto, SavedLocation.vancouver]
        favorites.sort { a, b in
            a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        Self.saveArray(favorites, key: favoritesKey)
        selected = Self.loadOne(key: selectedKey)
    }

    func setSelected(_ loc: SavedLocation) {
        selected = loc
        Self.saveOne(loc, key: selectedKey)

        let normalizedName = loc.displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isCurrentLocationSelection = normalizedName == "current location"

        guard !isCurrentLocationSelection else { return }

        if !favorites.contains(where: {
            $0.displayName.caseInsensitiveCompare(loc.displayName) == .orderedSame &&
            $0.countryCode == loc.countryCode
        }) {
            favorites.append(loc)
            favorites.sort { a, b in
                a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            Self.saveArray(favorites, key: favoritesKey)
        }
    }

    func setSelectedCurrentLocation(_ loc: SavedLocation) {
        selected = loc
        Self.saveOne(loc, key: selectedKey)
    }


    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        Self.saveArray(favorites, key: favoritesKey)
    }

    private static func loadArray(key: String) -> [SavedLocation]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([SavedLocation].self, from: data)
    }

    private static func saveArray(_ value: [SavedLocation], key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadOne(key: String) -> SavedLocation? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedLocation.self, from: data)
    }

    private static func saveOne(_ value: SavedLocation, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

@MainActor
private final class LocationResolver: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var authorization: CLAuthorizationStatus = .notDetermined

    private var pendingLocation: CheckedContinuation<SavedLocation, Error>?
    private var pendingAuth: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
    }

    enum LocationError: LocalizedError {
        case alreadyInFlight
        case permissionDenied
        case permissionRestricted
        case noLocation
        case reverseGeocodeFailed

        var errorDescription: String? {
            switch self {
            case .alreadyInFlight: return "Location request already in progress."
            case .permissionDenied: return "Location permission denied."
            case .permissionRestricted: return "Location permission restricted."
            case .noLocation: return "No location available."
            case .reverseGeocodeFailed: return "Could not resolve location name."
            }
        }
    }

    func requestOneShotLocation() async throws -> SavedLocation {
        guard pendingLocation == nil else { throw LocationError.alreadyInFlight }

        try await ensureAuthorized()

        return try await withCheckedThrowingContinuation { cont in
            self.pendingLocation = cont
            self.manager.requestLocation()
        }
    }

    private func ensureAuthorized() async throws {
        let status = manager.authorizationStatus
        authorization = status

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return
        case .denied:
            throw LocationError.permissionDenied
        case .restricted:
            throw LocationError.permissionRestricted
        case .notDetermined:
            try await withCheckedThrowingContinuation { cont in
                self.pendingAuth = cont
                self.manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            throw LocationError.permissionDenied
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        authorization = status

        guard let cont = pendingAuth else { return }
        pendingAuth = nil

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            cont.resume()
        case .denied:
            cont.resume(throwing: LocationError.permissionDenied)
        case .restricted:
            cont.resume(throwing: LocationError.permissionRestricted)
        case .notDetermined:
            pendingAuth = cont
        @unknown default:
            cont.resume(throwing: LocationError.permissionDenied)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pendingLocation?.resume(throwing: error)
        pendingLocation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            pendingLocation?.resume(throwing: LocationError.noLocation)
            pendingLocation = nil
            return
        }

        let continuation = pendingLocation
        pendingLocation = nil

        Task { @MainActor in
            guard let cont = continuation else { return }
            do {
                guard let request = MKReverseGeocodingRequest(location: loc) else {
                    cont.resume(throwing: LocationError.reverseGeocodeFailed)
                    return
                }
                let mapItems = try await request.mapItems
                let mapItem = mapItems.first

                // TODO: MKMapItem.placemark is deprecated in iOS 26. Migrate to mapItem.address
                // once Apple exposes structured fields (locality, administrativeArea, isoCountryCode).
                let pm = mapItem?.placemark
                let country = pm?.isoCountryCode ?? ""
                let city = pm?.locality ?? pm?.subAdministrativeArea ?? "Unknown"
                let prov = Self.normalizedAdministrativeArea(pm?.administrativeArea ?? "", countryCode: country)
                let name = prov.isEmpty ? city : "\(city), \(prov)"

                let out = SavedLocation(
                    id: UUID(),
                    displayName: name,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    countryCode: country
                )
                cont.resume(returning: out)
            } catch {
                cont.resume(throwing: LocationError.reverseGeocodeFailed)
            }
        }
    }
    
    nonisolated private static func normalizedAdministrativeArea(_ administrativeArea: String, countryCode: String) -> String {
        guard countryCode == "MX" else { return administrativeArea }

        let normalized = administrativeArea.trimmingCharacters(in: .whitespacesAndNewlines)
        let mexicoMap: [String: String] = [
            "Q. Roo.": "Quintana Roo",
            "Q.Roo.": "Quintana Roo",
            "QR": "Quintana Roo",
            "CDMX": "Ciudad de México",
            "D.F.": "Ciudad de México",
            "DF": "Ciudad de México",
            "Edo. Méx.": "Estado de México",
            "Edo. Mex.": "Estado de México",
            "Méx.": "Estado de México",
            "Mex.": "Estado de México",
            "N.L.": "Nuevo León",
            "NL": "Nuevo León",
            "B.C.": "Baja California",
            "BC": "Baja California",
            "B.C.S.": "Baja California Sur",
            "BCS": "Baja California Sur",
            "Coah.": "Coahuila",
            "Chis.": "Chiapas",
            "Chih.": "Chihuahua",
            "Gro.": "Guerrero",
            "Hgo.": "Hidalgo",
            "Jal.": "Jalisco",
            "Mich.": "Michoacán",
            "Mor.": "Morelos",
            "Nay.": "Nayarit",
            "Oax.": "Oaxaca",
            "Pue.": "Puebla",
            "Qro.": "Querétaro",
            "Sin.": "Sinaloa",
            "Son.": "Sonora",
            "Tab.": "Tabasco",
            "Tamps.": "Tamaulipas",
            "Tlax.": "Tlaxcala",
            "Ver.": "Veracruz",
            "Yuc.": "Yucatán",
            "Zac.": "Zacatecas"
        ]

        return mexicoMap[normalized] ?? normalized
    }
}

private struct LocationPickerView: View {
    @ObservedObject var store: LocationStore
    let onSelect: (SavedLocation) -> Void
    let onSelectCurrentLocation: (SavedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var resolver = LocationResolver()
    @AppStorage("yawa.can.isCurrentLocationSelected") private var isCurrentLocationSelected: Bool = false

    @State private var query: String = ""
    @State private var results: [SavedLocation] = []
    @State private var isSearching = false
    @State private var searchError: String? = nil

    @State private var searchGeneration: Int = 0
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search city, state, province", text: $query)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await runSearch(expectedQuery: query.trimmingCharacters(in: .whitespacesAndNewlines), generation: searchGeneration) } }
                    }
                    .listRowBackground(YAWATheme.cardFill(for: colorScheme))

                    Button {
                        Task {
                            do {
                                let loc = try await resolver.requestOneShotLocation()
                                onSelectCurrentLocation(loc)
                                dismiss()
                            } catch {
                                // Keep silent for now; user can retry.
                            }
                        }
                    } label: {
                        HStack {
                            Label("Current Location", systemImage: "location")
                                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.92))
                            Spacer()
                            if isCurrentLocationSelected {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .listRowBackground(YAWATheme.cardFill(for: colorScheme))
                }

                if let searchError {
                    Section {
                        Text(searchError)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                if isSearching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Searching…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { loc in
                            Button {
                                store.setSelected(loc)
                                onSelect(loc)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(displayNameForList(loc))
                                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.92))
                                    Spacer()
                                    if store.selected == loc {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .listRowBackground(YAWATheme.cardFill(for: colorScheme))
                        }
                    }
                }

                favoritesSection
            }
            .scrollContentBackground(.hidden)
            .background(YAWATheme.background(for: colorScheme).ignoresSafeArea())
            .listStyle(.insetGrouped)
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fontDesign(.rounded)
        .task {
            results = []
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()

            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else {
                results = []
                searchError = nil
                isSearching = false
                return
            }

            searchGeneration &+= 1
            let gen = searchGeneration

            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await runSearch(expectedQuery: trimmed, generation: gen)
            }
        }
    }

    
    private func runSearch(expectedQuery: String, generation: Int) async {
        let currentQ = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentQ == expectedQuery else { return }
        guard expectedQuery.count >= 3 else { return }

        isSearching = true
        searchError = nil

        do {
            let found = try await LocationSearch.searchCities(query: expectedQuery)

            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == expectedQuery else { return }

            results = found
            searchError = found.isEmpty ? "No matches found." : nil
        } catch {
            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == expectedQuery else { return }

            searchError = "Search failed. Please try again."
            results = []
        }

        if generation == searchGeneration {
            isSearching = false
        }
    }
    
    @ViewBuilder
    private func favoriteRow(for loc: SavedLocation) -> some View {
        HStack(spacing: 12) {
            Button {
                store.setSelected(loc)
                onSelect(loc)
                dismiss()
            } label: {
                HStack {
                    Text(displayNameForList(loc))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.black.opacity(0.92))
                    Spacer()
                    if store.selected == loc {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleBackgroundMonitoredFavorite(loc)
            } label: {
                Image(systemName: isBackgroundMonitoredFavorite(loc) ? "bell.fill" : "bell")
                    .foregroundStyle(isBackgroundMonitoredFavorite(loc) ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isBackgroundMonitoredFavorite(loc)
                ? "Remove background notification favorite"
                : "Add background notification favorite"
            )
        }
    }

    
    private func displayNameForList(_ loc: SavedLocation) -> String {
        // Mexico → "City, Mexico"
        if loc.countryCode == "MX" {
            let city = loc.displayName
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? loc.displayName
            
            return "\(city), Mexico"
        }

        // US / Canada → keep full "City, State/Province"
        return loc.displayName
    }

    private func backgroundMonitoredFavoriteKey(_ favorite: SavedLocation) -> String {
        "\(favorite.displayName)|\(favorite.latitude)|\(favorite.longitude)"
    }

    private func isBackgroundMonitoredFavorite(_ favorite: SavedLocation) -> Bool {
        let keys = UserDefaults.standard.stringArray(forKey: "YCBackgroundMonitoredFavorites") ?? []
        return keys.contains(backgroundMonitoredFavoriteKey(favorite))
    }

    private func toggleBackgroundMonitoredFavorite(_ favorite: SavedLocation) {
        let defaults = UserDefaults.standard
        var keys = defaults.stringArray(forKey: "YCBackgroundMonitoredFavorites") ?? []
        let key = backgroundMonitoredFavoriteKey(favorite)

        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
            defaults.set(keys, forKey: "YCBackgroundMonitoredFavorites")
            return
        }

        guard keys.count < 5 else { return }
        keys.append(key)
        defaults.set(keys, forKey: "YCBackgroundMonitoredFavorites")
    }

    private func removeFavorites(at offsets: IndexSet) {
        let favoritesSorted = store.favorites.sorted { a, b in
            a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

        let favoritesToRemove = offsets.compactMap { index in
            favoritesSorted.indices.contains(index) ? favoritesSorted[index] : nil
        }

        store.removeFavorites(at: offsets)

        guard !favoritesToRemove.isEmpty else { return }

        let defaults = UserDefaults.standard
        var keys = defaults.stringArray(forKey: "YCBackgroundMonitoredFavorites") ?? []
        let removeKeys = Set(favoritesToRemove.map(backgroundMonitoredFavoriteKey))
        keys.removeAll { removeKeys.contains($0) }
        defaults.set(keys, forKey: "YCBackgroundMonitoredFavorites")
    }
    
    private var favoritesSection: some View {
        Section {
            let favoritesSorted = store.favorites.sorted { a, b in
                a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }

            ForEach(favoritesSorted) { loc in
                favoriteRow(for: loc)
                    .listRowBackground(YAWATheme.cardFill(for: colorScheme))
            }
            .onDelete(perform: removeFavorites)
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Favorites")
                Text("Tap the bell to monitor up to 3 favorites for background alerts from Environment Canada.  Canadian cities only.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.74) : Color.black.opacity(0.58))
                    .textCase(nil)
            }
            .padding(.bottom, 4)
        }
    }
}

private enum LocationSearch {
    static func searchCities(query: String) async throws -> [SavedLocation] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.0, longitude: -98.0),
            span: MKCoordinateSpan(latitudeDelta: 38, longitudeDelta: 58)
        )

        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        let items = response.mapItems
        let results: [SavedLocation] = items.compactMap { item in
            let pm = item.placemark

            let country = pm.isoCountryCode ?? ""
            guard ["CA", "US", "MX"].contains(country) else { return nil }

            let city = pm.locality ?? pm.subAdministrativeArea
            guard let city else { return nil }

            let prov = normalizedAdministrativeArea(pm.administrativeArea ?? "", countryCode: country)
            let name = prov.isEmpty ? city : "\(city), \(prov)"

            let coord = pm.coordinate
            return SavedLocation(
                id: UUID(),
                displayName: name,
                latitude: coord.latitude,
                longitude: coord.longitude,
                countryCode: country
            )
        }

        var seen = Set<String>()
        let deduped = results.filter { seen.insert("\($0.displayName)|\($0.countryCode)").inserted }

        let rank: [String: Int] = ["CA": 0, "US": 1, "MX": 2]

        return deduped.sorted { a, b in
            if a.countryCode == b.countryCode {
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            return (rank[a.countryCode] ?? 99) < (rank[b.countryCode] ?? 99)
        }
    }

    private static func normalizedAdministrativeArea(_ administrativeArea: String, countryCode: String) -> String {
        guard countryCode == "MX" else { return administrativeArea }

        let normalized = administrativeArea.trimmingCharacters(in: .whitespacesAndNewlines)
        let mexicoMap: [String: String] = [
            "Q. Roo.": "Quintana Roo",
            "Q.Roo.": "Quintana Roo",
            "QR": "Quintana Roo",
            "CDMX": "Ciudad de México",
            "D.F.": "Ciudad de México",
            "DF": "Ciudad de México",
            "Edo. Méx.": "Estado de México",
            "Edo. Mex.": "Estado de México",
            "Méx.": "Estado de México",
            "Mex.": "Estado de México",
            "N.L.": "Nuevo León",
            "NL": "Nuevo León",
            "B.C.": "Baja California",
            "BC": "Baja California",
            "B.C.S.": "Baja California Sur",
            "BCS": "Baja California Sur",
            "Coah.": "Coahuila",
            "Chis.": "Chiapas",
            "Chih.": "Chihuahua",
            "Gro.": "Guerrero",
            "Hgo.": "Hidalgo",
            "Jal.": "Jalisco",
            "Mich.": "Michoacán",
            "Mor.": "Morelos",
            "Nay.": "Nayarit",
            "Oax.": "Oaxaca",
            "Pue.": "Puebla",
            "Qro.": "Querétaro",
            "Sin.": "Sinaloa",
            "Son.": "Sonora",
            "Tab.": "Tabasco",
            "Tamps.": "Tamaulipas",
            "Tlax.": "Tlaxcala",
            "Ver.": "Veracruz",
            "Yuc.": "Yucatán",
            "Zac.": "Zacatecas"
        ]

        return mexicoMap[normalized] ?? normalized
    }
}

/// Remaps rain-family condition text to snow/frozen equivalents when the daily high is ≤ 0°C.
/// Used by both ContentView forecast rows and DailyForecastDetailSheet.
private func temperatureCorrectedConditionText(_ raw: String, highC: Double) -> String {
    let lower = raw.lowercased()

    // "Freezing rain/drizzle" is already meteorologically correct — leave it alone.
    guard !lower.contains("freezing") else { return raw }

    // Only correct when the high doesn't reach 0°C — rain is physically implausible.
    guard highC <= 0 else { return raw }

    // Exact WMO description matches first — these are Title Cased from Open-Meteo
    if lower == "light drizzle"   { return "Light freezing drizzle" }
    if lower == "drizzle"         { return "Freezing drizzle" }
    if lower == "heavy drizzle"   { return "Freezing drizzle" }
    if lower == "light rain"      { return "Light snow" }
    if lower == "rain"            { return "Snow" }
    if lower == "heavy rain"      { return "Heavy snow" }
    if lower == "light showers"   { return "Light snow showers" }
    if lower == "showers"         { return "Snow showers" }
    if lower == "heavy showers"   { return "Heavy snow showers" }

    // Fallback for custom/generated strings (e.g. "rain likely", "rain possible")
    if lower.contains("rain shower") {
        let result = raw.replacingOccurrences(of: "rain shower", with: "snow shower", options: [.caseInsensitive])
        return result.prefix(1).uppercased() + result.dropFirst()
    }
    if lower.contains("rain") {
        let result = raw.replacingOccurrences(of: "rain", with: "snow", options: [.caseInsensitive])
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    return raw
}

private struct DailyForecastDetailSheet: View {
    let days: [DailyForecastDay]
    let hourlyTempsC: [Double]
    let hourlyTimeISO: [String]
    let hourlyPrecipChancePercent: [Double]
    let timeZoneID: String
    let usesUSUnits: Bool

    @State private var currentIndex: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    init(days: [DailyForecastDay], initialIndex: Int, hourlyTempsC: [Double], hourlyTimeISO: [String], hourlyPrecipChancePercent: [Double], timeZoneID: String, usesUSUnits: Bool) {
        self.days = days
        self.hourlyTempsC = hourlyTempsC
        self.hourlyTimeISO = hourlyTimeISO
        self.hourlyPrecipChancePercent = hourlyPrecipChancePercent
        self.timeZoneID = timeZoneID
        self.usesUSUnits = usesUSUnits
        _currentIndex = State(initialValue: min(max(initialIndex, 0), max(days.count - 1, 0)))
    }
    private var day: DailyForecastDay {
        days[currentIndex]
    }

    private var canGoPrevious: Bool {
        currentIndex > 0
    }

    private var canGoNext: Bool {
        currentIndex < days.count - 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if days.count > 1 {
                        HStack(spacing: 6) {
                            Spacer()
                            ForEach(Array(days.enumerated()), id: \.offset) { idx, _ in
                                Circle()
                                    .fill(idx == currentIndex ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.28))
                                    .frame(width: idx == currentIndex ? 8 : 6, height: idx == currentIndex ? 8 : 6)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 2)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: day.symbolName)
                            .font(.system(size: 30, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor(day.symbolName, scheme: colorScheme))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(longDay(day.date))
                                .font(.headline.weight(.semibold))
                            Text(temperatureCorrectedConditionText(day.conditionText, highC: day.highC))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    Divider().opacity(0.18)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("High")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(temperatureText(day.highC))
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Low")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(temperatureText(day.lowC))
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if roundedPrecipChance > 0 {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Precip")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(roundedPrecipChance)%")
                                        .font(.title3.weight(.semibold))
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if shouldShowWindRow {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("Wind")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)

                                        if isWindyFlagVisible {
                                            Text("Windy")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(windyFlagColor)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule()
                                                        .fill(windyFlagColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                                                )
                                                .fixedSize()
                                        }
                                    }

                                    Text(windPrimaryText)
                                        .font(.title3.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Gusts")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary.opacity(0.72))
                                    Text(windGustDisplayText)
                                        .font(.headline.weight(.medium))
                                        .foregroundStyle(.secondary.opacity(colorScheme == .dark ? 0.82 : 0.72))
                                        .monospacedDigit()
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.bottom, -2)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Discussion")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(forecastSummary)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)


                    if !hourlyTempsForDay.isEmpty {
                        Divider().opacity(0.18)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hourly")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar")
                                    .font(.caption2.weight(.semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)

                                Text("Temperature trend and precipitation chance")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            HourlyTempChart(
                                temps: hourlyTempsForDay,
                                precipChancePercent: hourlyPrecipForDay,
                                hourPositions: hourlyHoursForDay.map(Double.init),
                                usesUSUnits: usesUSUnits,
                                showCurrentHourMarker: isToday,
                                currentHourIndex: currentHourIndex
                            )
                            .frame(height: 210, alignment: .top)
                            .padding(.top, 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            let horizontal = value.translation.width
                            let vertical = value.translation.height
                            guard abs(horizontal) > abs(vertical) else { return }

                            if horizontal < -40, canGoNext {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentIndex += 1
                                }
                            } else if horizontal > 40, canGoPrevious {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentIndex -= 1
                                }
                            }
                        }
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(innerCard)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .background(sheetBackground)
            .scrollIndicators(.never)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.03),
                        .init(color: .black, location: 0.97),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        guard abs(vertical) > abs(horizontal), vertical > 80 else { return }
                        dismiss()
                    }
            )
        }
        .fontDesign(.rounded)
    }

    private var roundedPrecipChance: Int {
        let clamped = max(0, min(100, day.precipChancePercent))
        return Int((Double(clamped) / 10.0).rounded() * 10.0)
    }

    private var windSpeedValueText: String? {
        guard let windKPH = day.windSpeedKPH else { return nil }
        let value = usesUSUnits ? windKPH * 0.621371 : windKPH
        let rounded = Int(round(value))
        return "\(rounded)"
    }

    private var windDirectionText: String? {
        guard let degrees = day.windDirectionDegrees else { return nil }
        return cardinalDirection(for: degrees)
    }

    private var windPrimaryText: String {
        let speed = windSpeedValueText ?? "—"
        let unit = usesUSUnits ? " mph" : " km/h"
        if let direction = windDirectionText {
            return "\(direction) \(speed)\(unit)"
        }
        return "\(speed)\(unit)"
    }


    private var windGustText: String? {
        guard let gustKPH = day.windGustKPH else { return nil }
        let value = usesUSUnits ? gustKPH * 0.621371 : gustKPH
        let rounded = Int(round(value))
        return "\(rounded)"
    }

    private var windGustDisplayText: String {
        guard let gust = windGustText else { return "—" }
        return "up to \(gust)"
    }

    private var shouldShowWindRow: Bool {
        windSpeedValueText != nil || windGustText != nil || windDirectionText != nil
    }

    private var isWindyFlagVisible: Bool {
        guard let gustKPH = day.windGustKPH else { return false }
        return gustKPH >= 45
    }

    private var windSummarySentence: String? {
        guard let gustKPH = day.windGustKPH else { return nil }

        let gustValue = usesUSUnits ? gustKPH * 0.621371 : gustKPH
        let breezyThreshold = usesUSUnits ? 22.0 : 35.0
        let windyThreshold = usesUSUnits ? 30.0 : 45.0
        let veryWindyThreshold = usesUSUnits ? 40.0 : 60.0

        if gustValue >= veryWindyThreshold {
            return "Very windy, with strong gusts at times."
        } else if gustValue >= windyThreshold {
            return "Windy conditions expected."
        } else if gustValue >= breezyThreshold {
            return "Breezy at times."
        } else {
            return nil
        }
    }

    private var windyFlagColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.95) : Color.blue.opacity(0.82)
    }

    private var sheetBackground: some View {
        Color.clear
            .ignoresSafeArea()
    }
    
    private var innerCard: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                colorScheme == .dark
                ? Color(red: 0.05, green: 0.07, blue: 0.12).opacity(0.95)
                : Color(.systemBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.04),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05),
                radius: 10,
                y: 4
            )
    }
    
    private var isToday: Bool {
        Calendar.current.isDateInToday(day.date)
    }

    private var currentHourIndex: Double? {
        guard isToday else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneID) ?? .current

        let now = Date()
        let startOfDay = cal.startOfDay(for: day.date)

        let hours = now.timeIntervalSince(startOfDay) / 3600.0
        return max(0.0, min(23.999, hours))
    }

    private var forecastSummary: String {
        let correctedText = temperatureCorrectedConditionText(day.conditionText, highC: day.highC)
        let isFreezing = day.highC <= 0

        // Strip qualifier words that refineDailySky may have appended (e.g. "Snow possible",
        // "Rain likely") so phrase builders don't produce "Snow possible expected."
        let strippedText = correctedText
            .replacingOccurrences(of: " likely", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " possible", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        let condition = normalizedConditionText(strippedText)
        let rawLower = strippedText.lowercased()

        // Determine if the condition already carries a precip word
        let hasPrecipWord = rawLower.contains("rain") || rawLower.contains("snow") ||
            rawLower.contains("storm") || rawLower.contains("shower") ||
            rawLower.contains("drizzle") || rawLower.contains("hail") ||
            rawLower.contains("freezing") || rawLower.contains("grains")

        // Classify precip-bearing conditions by contains rather than exact match,
        // so granular descriptions like "Light snow" and "Heavy showers" are caught.
        let isSimplePrecip = hasPrecipWord

        var summary: String

        if isSimplePrecip {
            if roundedPrecipChance <= 30 {
                summary = simplePrecipPossiblePhrase(condition: condition, rawLower: rawLower)
            } else if roundedPrecipChance <= 60 {
                summary = simplePrecipChancePhrase(condition: condition, rawLower: rawLower)
            } else {
                summary = simplePrecipLikelyPhrase(condition: condition, rawLower: rawLower)
            }
        } else {
            summary = conditionBasePhrase(condition)
        }

        // Append a precip tail only when the condition doesn't already carry precip language
        if roundedPrecipChance > 0 && !isSimplePrecip {
            if roundedPrecipChance <= 20 {
                summary += slightPrecipTailPhrase(isFreezing: isFreezing)
            } else if roundedPrecipChance <= 50 {
                summary += chancePrecipTailPhrase(isFreezing: isFreezing)
            } else {
                summary += likelyPrecipTailPhrase(isFreezing: isFreezing)
            }
        } else if roundedPrecipChance == 0 {
            // Suppress dry tail when wind will provide a more meaningful secondary note
            let windIsNotable = windSummarySentence != nil
            let impliesDry = rawLower.contains("clear") || rawLower.contains("sun") ||
                rawLower.contains("mainly") || rawLower.contains("mostly clear")
            if !impliesDry && !windIsNotable {
                summary += dryTailPhrase()
            }
        }

        // Wind tail
        let hasWithClause = summary.contains(", with ")
        if let windSentence = windSummarySentence {
            if windSentence.contains("Very windy") {
                summary += hasWithClause ? strongWindTailPhraseAfterWith() : strongWindTailPhrase()
            } else if windSentence.contains("Windy") {
                summary += hasWithClause ? windyTailPhraseAfterWith() : windyTailPhrase()
            } else if windSentence.contains("Breezy") {
                summary += hasWithClause ? breezyTailPhraseAfterWith() : breezyTailPhrase()
            }
        }

        return summary + "."
    }

    private var summaryVariationSeed: Int {
        let dayKey = Calendar.current.startOfDay(for: day.date).timeIntervalSince1970
        let roundedHigh = Int(round(day.highC))
        let roundedLow = Int(round(day.lowC))
        return Int(dayKey) ^ (roundedPrecipChance << 2) ^ (roundedHigh << 1) ^ roundedLow
    }

    private func variant(_ options: [String]) -> String {
        guard !options.isEmpty else { return "" }
        let index = abs(summaryVariationSeed) % options.count
        return options[index]
    }

    // MARK: - Base phrase builders

    private func conditionBasePhrase(_ condition: String) -> String {
        variant([
            condition,
            "Expect a \(condition.lowercased()) day",
            "\(condition) throughout the day"
        ])
    }

    // MARK: - Precip phrase builders

    private func simplePrecipPossiblePhrase(condition: String, rawLower: String) -> String {
        variant([
            "\(condition) possible",
            "\(condition) may develop",
            "A chance of \(rawLower)"
        ])
    }

    private func simplePrecipChancePhrase(condition: String, rawLower: String) -> String {
        variant([
            "A chance of \(rawLower)",
            "\(condition) at times",
            "\(condition) possible"
        ])
    }

    private func simplePrecipLikelyPhrase(condition: String, rawLower: String) -> String {
        variant([
            "\(condition) expected",
            "Periods of \(rawLower)",
            "\(condition) likely"
        ])
    }

    // MARK: - Precip tail phrases (appended to non-precip base)

    private func slightPrecipTailPhrase(isFreezing: Bool) -> String {
        let precip = isFreezing ? "snow" : "rain"
        return variant([
            ", with a slight chance of \(precip)",
            ", with a low chance of \(precip)"
        ])
    }

    private func chancePrecipTailPhrase(isFreezing: Bool) -> String {
        let precip = isFreezing ? "snow" : "rain"
        return variant([
            ", with a chance of \(precip)",
            ", with some \(precip) possible"
        ])
    }

    private func likelyPrecipTailPhrase(isFreezing: Bool) -> String {
        let precip = isFreezing ? "snow" : "rain"
        return variant([
            ", with periods of \(precip)",
            ", with \(precip) at times"
        ])
    }

    private func dryTailPhrase() -> String {
        variant([
            ", dry",
            ", staying dry",
            ", with no precipitation expected"
        ])
    }

    // MARK: - Wind tail phrases

    private func strongWindTailPhrase() -> String {
        variant([
            ", with strong winds at times",
            ", with gusty winds at times"
        ])
    }

    private func strongWindTailPhraseAfterWith() -> String {
        variant([
            ", and strong winds at times",
            ", and gusty winds at times"
        ])
    }

    private func windyTailPhrase() -> String {
        variant([
            ", and windy at times",
            ", with periods of wind"
        ])
    }

    private func windyTailPhraseAfterWith() -> String {
        variant([
            ", and windy at times",
            ", and periods of wind"
        ])
    }

    private func breezyTailPhrase() -> String {
        variant([
            ", breezy at times",
            ", with a breeze at times"
        ])
    }

    private func breezyTailPhraseAfterWith() -> String {
        variant([
            ", and breezy at times",
            ", and a breeze at times"
        ])
    }

    private func normalizedConditionText(_ text: String) -> String {
        guard let first = text.first else { return "Forecast conditions" }
        return first.isLowercase ? first.uppercased() + text.dropFirst() : text
    }

    private func formattedTemp(_ celsius: Double) -> String {
        let value = usesUSUnits ? ((celsius * 9.0 / 5.0) + 32.0) : celsius
        let rounded = Int(round(value))
        let unit = usesUSUnits ? "°F" : "°C"
        return rounded > 0 ? "\(rounded)\(unit)" : "\(rounded)\(unit)"
    }

    private func temperatureText(_ celsius: Double) -> String {
        let value = usesUSUnits ? ((celsius * 9.0 / 5.0) + 32.0) : celsius
        let rounded = Int(round(value))
        let unit = usesUSUnits ? "°F" : "°C"
        return "\(rounded)\(unit)"
    }

    private func longDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    private func cardinalDirection(for degrees: Double) -> String {
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let positive = normalized >= 0 ? normalized : normalized + 360
        let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((positive / 22.5).rounded()) % directions.count
        return directions[index]
    }

    
    private struct HourlyPoint: Identifiable {
        let id: String
        let date: Date
        let tempC: Double
        let precip: Double
    }

    private var hourlyDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }

    private var hourlyPointsForDay: [HourlyPoint] {
        let tz = TimeZone(identifier: timeZoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        return Array(zip(hourlyTimeISO.indices, hourlyTimeISO)).compactMap { idx, iso -> HourlyPoint? in
            guard idx < hourlyTempsC.count,
                  idx < hourlyPrecipChancePercent.count else { return nil }
            
            guard let date = hourlyDateFormatter.date(from: iso) else { return nil }
            guard cal.isDate(date, inSameDayAs: day.date) else { return nil }

            return HourlyPoint(
                id: iso,
                date: date,
                tempC: hourlyTempsC[idx],
                precip: hourlyPrecipChancePercent[idx]
            )
        }
        .sorted { $0.date < $1.date }
    }

    private var hourlyTempsForDay: [Double] {
        let slice = hourlyPointsForDay.map(\.tempC)
        if usesUSUnits {
            return slice.map { ($0 * 9.0 / 5.0) + 32.0 }
        } else {
            return slice
        }
    }

    private var hourlyPrecipForDay: [Double] {
        hourlyPointsForDay.map(\.precip)
    }

    private var hourlyHoursForDay: [Int] {
        let tz = TimeZone(identifier: timeZoneID) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return hourlyPointsForDay.map { cal.component(.hour, from: $0.date) }
    }
}

// MARK: - Comfort / Feels Like (YN-style, but metric)


private func feelsLikeSubtitleText(for current: CurrentConditions) -> String {
    let actualC = current.temperatureC
    let apparentC = current.apparentTemperatureC

    if apparentC <= actualC - 1.0 {
        return "Colder due to wind"
    }
    if apparentC >= actualC + 1.0 {
        return "Hotter due to humidity"
    }
    return "Feels close to actual temperature"
}

private func isCurrentlyWet(for current: CurrentConditions) -> Bool {
    let conditions = current.conditionText.lowercased()

    let wetTerms = [
        "drizzle", "rain", "shower", "showers",
        "snow", "snow shower", "snow showers",
        "sleet", "freezing rain", "freezing drizzle",
        "ice", "icy", "wintry mix",
        "mist", "fog", "patchy fog", "dense fog",
        "storm", "thunder", "thunderstorm", "thunderstorms"
    ]

    return wetTerms.contains { conditions.contains($0) }
}

private func comfortSummaryText(for current: CurrentConditions) -> String {
    let dewPointC = current.dewPointC
    let actualC = current.temperatureC
    let apparentC = current.apparentTemperatureC

    let feelsLikeMode: String = {
        if apparentC <= actualC - 1.0 { return "windChill" }
        if apparentC >= actualC + 1.0 { return "heatIndex" }
        return "actual"
    }()

    let baseComfort: String = {
        switch dewPointC {
        case ..<10.0:
            return "Dry and comfortable"
        case 10.0..<15.6:
            return "Comfortable"
        case 15.6..<18.3:
            return "Slightly humid"
        case 18.3..<21.1:
            return "Humid"
        case 21.1..<23.9:
            return "Very humid"
        default:
            return "Oppressive humidity"
        }
    }()

    switch feelsLikeMode {
    case "windChill":
        if isCurrentlyWet(for: current) { return "Cool and damp" }
        if current.humidityPercent >= 80 {
            return "Cool and damp"
        }
        return dewPointC < 15.6 ? "Cool and dry" : "Cool and humid"
        
    case "heatIndex":
        if isCurrentlyWet(for: current) {
            if dewPointC >= 23.9 { return "Hot and oppressive" }
            if dewPointC >= 21.1 { return "Hot and muggy" }
            return "Warm and damp"
        }
        if dewPointC >= 23.9 { return "Hot and oppressive" }
        if dewPointC >= 21.1 { return "Hot and muggy" }
        return "Warm and humid"

    default:
        if isCurrentlyWet(for: current) {
            if dewPointC < 15.6 { return "Cool and damp" }
            if dewPointC < 21.1 { return "Mild and damp" }
            return "Humid and damp"
        }
        return baseComfort
    }
}


#Preview {
    ContentView()
}
