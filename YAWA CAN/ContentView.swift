import SwiftUI
import CoreLocation
import MapKit
import Charts
import Combine
import UIKit

// YAWA CAN - Main ContentView
/// Uses `WeatherViewModel` + `WeatherServiceProtocol` (Open-Meteo service) and renders
/// the core YAWA UX: current tile, hourly temp chart, and 7‑day forecast.
//
/// - Loads the last-selected location, otherwise the first saved favorite.
/// - Toronto is used only as a final fallback if no locations exist.
/// - Units adapt by selected country: Canada uses °C / km/h / kPa, U.S. uses °F / mph / inHg.

struct ContentView: View {
    @StateObject private var viewModel = WeatherViewModel(service: OpenMeteoWeatherService())
    @StateObject private var locationStore = LocationStore()
    @StateObject private var locationResolver = LocationResolver()
    

    @State private var showingLocations = false
    @State private var selected: SavedLocation? = nil
    @State private var displayedLocation: SavedLocation? = nil
    @State private var showingSettings = false
    @State private var radarTarget: RadarTarget? = nil
    
    @State private var selectedDaySelection: ForecastDetailSelection? = nil
    @State private var forecastDetailDetent: PresentationDetent = .fraction(0.7)
    
    @AppStorage("yawa.can.isCurrentLocationSelected") private var isCurrentLocationSelected: Bool = false
    
    @MainActor
    private func refreshWeather() async {
        let fallback = locationStore.favorites.first ?? SavedLocation.toronto
        var loc = displayedLocation ?? selected ?? locationStore.selected ?? fallback

        if isCurrentLocationSelected {
            do {
                let currentLoc = try await locationResolver.requestOneShotLocation()
                locationStore.setSelectedCurrentLocation(currentLoc)
                selected = currentLoc
                displayedLocation = currentLoc
                loc = currentLoc
            } catch {
                // If GPS refresh fails, keep using the last known location.
            }
        } else {
            selected = loc
        }

        let days = max(1, min(forecastDaysToShow, 10))
        await viewModel.load(for: loc.coordinate, locationName: loc.displayName, forecastDays: days)
        if viewModel.snapshot != nil {
            displayedLocation = loc
            temperatureAnimationKey = UUID()
            sunRefreshToken = Date()
            lastUpdatedAt = Date()
        }
    }
    
    @MainActor
    private func refreshOnForegroundIfNeeded() async {
        let now = Date()

        if let last = lastForegroundRefreshAt,
           now.timeIntervalSince(last) < 20 {
            return
        }

        lastForegroundRefreshAt = now
        await refreshWeather()
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

    // Use the shared YAWA theme background so CAN matches NOAA styling.
    private var appBackground: Color {
        YAWATheme.background(for: colorScheme)
    }

    private var cardBackground: Color {
        YAWATheme.cardBackground(for: colorScheme)
    }

    private var cardStroke: Color {
        YAWATheme.cardStroke(for: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                appBackground
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            // Scroll-to-top anchor
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
                                sunTile(snap)
                                comfortTile(snap)
                            } else if !viewModel.isLoading && viewModel.errorMessage == nil {
                                Text("No weather loaded yet.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Spacer(minLength: 8)
                        }
                        .padding(16)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable {
                        await refreshWeather()
                    }
                    .onChange(of: selected?.id) { _, _ in
                        // When a new location is selected, jump back to the top so the current card is visible.
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    }
                }
                // Easter egg overlay (drops from the nav bar)
                if showEasterEgg {
                    easterEggOverlay
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .zIndex(999)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .fontDesign(.rounded)
            .navigationTitle(navigationTitleText)
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
            // Make the nav bar match the background.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(YAWATheme.background(for: colorScheme), for: .navigationBar)
        }
        .task {
            // Initial selection: whatever the user last chose in Locations, otherwise the first saved favorite.
            let initial = locationStore.selected ?? locationStore.favorites.first ?? SavedLocation.toronto
            selected = initial
            await refreshWeather()
        }
        .onChange(of: forecastDaysToShow) { _, _ in
            Task {
                await refreshWeather()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { @MainActor in
                await refreshOnForegroundIfNeeded()
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
        .sheet(isPresented: $showingLocations) {
            LocationPickerView(
                store: locationStore,
                onSelect: { loc in
                    selected = loc
                    isCurrentLocationSelected = false
                    locationStore.setSelected(loc)
                    let days = max(1, min(forecastDaysToShow, 10))
                    Task {
                        await viewModel.load(for: loc.coordinate, locationName: loc.displayName, forecastDays: days)
                        if viewModel.snapshot != nil {
                            displayedLocation = loc
                            temperatureAnimationKey = UUID()
                        }
                    }
                },
                onSelectCurrentLocation: { loc in
                    selected = loc
                    isCurrentLocationSelected = true
                    locationStore.setSelectedCurrentLocation(loc)
                    let days = max(1, min(forecastDaysToShow, 10))
                    Task {
                        await viewModel.load(for: loc.coordinate, locationName: loc.displayName, forecastDays: days)
                        if viewModel.snapshot != nil {
                            displayedLocation = loc
                            temperatureAnimationKey = UUID()
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $radarTarget) { target in
            RadarView(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
                        Text(selected?.displayName ?? "–")
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.subheadline.weight(.semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(
                                viewModel.isLoading
                                ? Color.cyan.opacity(colorScheme == .dark ? 0.92 : 0.78)
                                : YAWATheme.symbolColor("clock", scheme: colorScheme)
                            )
                            .opacity(0.9)
                            .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                            .animation(
                                viewModel.isLoading
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .easeOut(duration: 0.18),
                                value: viewModel.isLoading
                            )

                        Text("Now")
                            .font(.headline)
                    }
                    Text(snap.current.conditionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let lastUpdatedAt {
                        Text("Updated \(lastUpdatedText(lastUpdatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                let nowSymbol = nowSymbolName(for: snap)
                Image(systemName: nowSymbol)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.symbolColor(nowSymbol, scheme: colorScheme))
            }

            HStack(alignment: .center, spacing: 12) {
                // Temperature
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(currentTemperatureValueText(snap.current.temperatureC))
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
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

                // Supporting metrics (icons right next to values)
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
                    .font(.headline)

                Spacer()
            }

            // Align the big value baseline with the “Feels like” label.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "thermometer")
                        .font(.subheadline.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.symbolColor("thermometer", scheme: colorScheme))
                        .opacity(colorScheme == .dark ? 0.90 : 0.82)
                        // Images don’t have a text baseline; pin to bottom so it participates nicely.
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

    // Swap day/night icons like YAWA NOAA (sun by day, moon by night) using sunrise/sunset.
    private func nowSymbolName(for snap: WeatherSnapshot) -> String {
        let base = snap.current.symbolName
        guard isNight(for: snap) else { return base }

        // Map common “day” symbols to their night equivalents.
        switch base {
        case "sun.max.fill", "sun.max":
            return "moon.stars.fill"
        case "cloud.sun.fill", "cloud.sun":
            return "cloud.moon.fill"
        case "cloud.sun.rain.fill", "cloud.sun.rain":
            return "cloud.moon.rain.fill"
        default:
            // If the service already provides a moon icon (or it's not a day-specific icon), keep it.
            return base
        }
    }

    private func isNight(for snap: WeatherSnapshot) -> Bool {
        guard let sun = snap.sun else { return false }

        // Use the snapshot time zone when available so day/night matches the selected location.
        let tz: TimeZone? = {
            let id = snap.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            return TimeZone(identifier: id)
        }()

        let now = Date()
        if let tz {
            // Compare by converting all dates to the same time zone.
            let cal = Calendar.current
            let nowComp = cal.dateComponents(in: tz, from: now)
            let srComp = cal.dateComponents(in: tz, from: sun.sunrise)
            let ssComp = cal.dateComponents(in: tz, from: sun.sunset)

            // Rebuild comparable Date values anchored in that time zone.
            guard
                let nowZ = Calendar(identifier: cal.identifier).date(from: nowComp),
                let srZ  = Calendar(identifier: cal.identifier).date(from: srComp),
                let ssZ  = Calendar(identifier: cal.identifier).date(from: ssComp)
            else {
                return !(now >= sun.sunrise && now <= sun.sunset)
            }
            return !(nowZ >= srZ && nowZ <= ssZ)
        }

        // Fallback: compare directly.
        return !(now >= sun.sunrise && now <= sun.sunset)
    }


    private var selectedLocationForAlerts: SavedLocation {
        selected ?? displayedLocation ?? locationStore.selected ?? .toronto
    }

    private var activeAlertsForSelectedLocation: [WeatherAlert] {
        StubAlertService().sampleAlerts(for: selectedLocationForAlerts)
    }

    private func dailyTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {

            if let alert = activeAlertsForSelectedLocation.first {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.orange)
                            .opacity(0.95)

                        Text(alert.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                            .lineLimit(1)

                        Spacer()

                        Text(alert.severity)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    Text(alert.summary)
                        .font(.caption)
                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Area: \(alert.areaName)")
                        .font(.caption2)
                        .foregroundStyle(YAWATheme.textTertiary(for: colorScheme))
                }

                Divider().opacity(0.5)
            }

            // Header row
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

            // Forecast rows
            let daysToShow = max(1, min(forecastDaysToShow, 10))
            let days: [DailyForecastDay] = Array(snap.daily.prefix(daysToShow))

            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let weekdayW: CGFloat = 40
                let dateW: CGFloat = 32
                let iconW: CGFloat = 36

                let sym = day.symbolName
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
                        // Left block: weekday + date + icon/PoP (fixed width so everything aligns)
                        HStack(spacing: 4) {
                            HStack(spacing: 2) {
                                Text(weekdayLabel(day.date, timeZoneID: snap.timeZoneID))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                                    .lineLimit(1)
                                    .frame(width: weekdayW, alignment: .leading)

                                Text(dateLabel(day.date, timeZoneID: snap.timeZoneID))
                                    .font(.caption)
                                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .frame(width: dateW, alignment: .leading)
                            }

                            let rawPop = day.precipChancePercent
                            let roundedPop = max(0, min(100, Int((Double(rawPop) / 10.0).rounded() * 10.0)))
                            let popText: String? = (roundedPop > 0) ? "\(roundedPop)%" : nil

                            // Icon + PoP (NOAA-style): keep a stable footprint, and avoid icon/text overlap.
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
                                    // No PoP: vertically center the icon within the same footprint.
                                    Image(systemName: sym)
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(YAWATheme.symbolColor(sym, scheme: colorScheme))
                                        .font(.title3)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                            }
                            .frame(width: iconW, height: 34, alignment: .center)
                        }
                        .frame(width: weekdayW + dateW + 4 + iconW + 2, alignment: .leading)

                        // Brief forecast text
                        Text(refinedDailyRowConditionText(for: day))
                            .font(.subheadline)
                            .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                            .layoutPriority(2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Spacer(minLength: 8)

                        // Right column (fixed)
                        Text("H \(tempDisplay(day.highC))  L \(tempDisplay(day.lowC))")
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

            // Attribution
            Text("Source: Open-Meteo")
                .font(.caption)
                .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9))
                .padding(.top, 8)
        }
        .tileStyle()
    }

    private func refinedDailyRowConditionText(for day: DailyForecastDay) -> String {
        let raw = day.conditionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        // Keep explicit precip/fog/thunder wording untouched.
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
            openRadar()           // ✅ sets radarTarget based on selected favorite / current location
            lightHaptic()         // optional
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.subheadline)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.symbolColor("dot.radiowaves.left.and.right", scheme: colorScheme))
                        .opacity(0.85)

                    Text("Radar")
                        .font(.headline)
                        .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                        .opacity(0.9)
                }

                Text("Tap to view interactive radar")
                    .font(.callout)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))

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
                    .font(.headline)

                Spacer()
            }

            if let sun = snap.sun {
                let tz = TimeZone(identifier: snap.timeZoneID) ?? .current
                let now = sunRefreshToken
                let isNight = !(now >= sun.sunrise && now <= sun.sunset)
                let t = sunProgress(sunrise: sun.sunrise, sunset: sun.sunset, now: now)
                let progressForArc = isNight ? 0.5 : t

                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        sunValueColumn(
                            title: "Sunrise",
                            value: timeString(sun.sunrise, timeZoneID: snap.timeZoneID)
                        )
                        .frame(maxWidth: .infinity)

                        Divider().opacity(0.25)

                        sunValueColumn(
                            title: "Sunset",
                            value: timeString(sun.sunset, timeZoneID: snap.timeZoneID)
                        )
                        .frame(maxWidth: .infinity)
                    }

                    SunArcView(
                        progress: progressForArc,
                        arcRiseFraction: 0.32,
                        height: 72,
                        arcLineWidth: 0,
                        markerSize: 14,
                        isThemed: (colorScheme == .dark),
                        isNight: isNight,
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

    private struct SunCardData {
        let progressForArc: Double
        let isNight: Bool
    }

    private func sunCardData(sun: SunTimes, timeZone: TimeZone, now: Date) -> SunCardData {
        // Interpret all timestamps in the selected location's time zone.
        let cal = Calendar.current
        let nowComp = cal.dateComponents(in: timeZone, from: now)
        let srComp = cal.dateComponents(in: timeZone, from: sun.sunrise)
        let ssComp = cal.dateComponents(in: timeZone, from: sun.sunset)

        let cal2 = Calendar(identifier: cal.identifier)
        let nowZ = cal2.date(from: nowComp) ?? now
        let srZ  = cal2.date(from: srComp) ?? sun.sunrise
        let ssZ  = cal2.date(from: ssComp) ?? sun.sunset

        // Night: keep the marker centered (matches the NOAA card vibe).
        if nowZ < srZ || nowZ > ssZ {
            return SunCardData(progressForArc: 0.5, isNight: true)
        }

        let denom = max(ssZ.timeIntervalSince(srZ), 1)
        let raw = nowZ.timeIntervalSince(srZ) / denom
        let clamped = min(1.0, max(0.0, raw))
        return SunCardData(progressForArc: clamped, isNight: false)
    }

    private func sunValueColumn(icon: String, title: String, value: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.9))

                Text(title)
                    .font(.caption)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme).opacity(0.85))
            }
            .frame(maxWidth: .infinity)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeString(_ date: Date, timeZoneID: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "h:mm a"   // 12h like you requested
        if let tzid = timeZoneID, let tz = TimeZone(identifier: tzid) {
            f.timeZone = tz
        }
        return f.string(from: date)
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
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


    private var usesUSUnits: Bool {
        (displayedLocation?.countryCode ?? selected?.countryCode ?? locationStore.selected?.countryCode ?? "CA") == "US"
    }

    private var temperatureUnitLabel: String {
        usesUSUnits ? "°F" : "°C"
    }

    private var locationUnitsSubtitle: String {
        usesUSUnits ? "United States • °F • mph • inHg" : "Canada • °C • km/h • kPa"
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
        return "\(direction) \(Int(round(speedValue)))"
    }

    private func pressureValueText(for pressureKPa: Double) -> String {
        if usesUSUnits {
            let inHg = pressureKPa * 0.2953
            return String(format: "%.2f", inHg)
        } else {
            return String(format: "%.1f", pressureKPa)
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
    

    private func shortDay(_ date: Date, timeZoneID: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
    
    private func weekdayLabel(_ date: Date, timeZoneID: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func dateLabel(_ date: Date, timeZoneID: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        f.dateFormat = "M/d"   // matches the small date style you use in NOAA
        return f.string(from: date)
    }

    private func tempDisplay(_ celsius: Double) -> String {
        let value = usesUSUnits ? cToF(celsius) : celsius
        return "\(Int(round(value)))°"
    }

    /// NOAA-ish: round precip to nearest 10 and clamp 0...100
    private func popTextRoundedTo10(_ percent: Int) -> String {
        let clamped = max(0, min(100, percent))
        let rounded = Int((Double(clamped) / 10.0).rounded() * 10.0)
        return "\(rounded)%"
    }
    
    private static let sunLocalTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a z"  // 12h with zone
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
        f.dateFormat = "h:mm:ss a"
        return f.string(from: date)
    }

    // MARK: - Sun card tap (tree refresh) + Easter egg

    @MainActor
    private func handleSunArcTap() {
        // This is the same tap that regenerates the trees (SunArcView tap refresh).
        // Count these taps; after 5, show the Easter egg.

        sunTapCount += 1

        // Keep the visual behavior: tapping refreshes/re-randomizes the SunArcView.
        sunRefreshToken = Date()

        // Reset the counter if the user pauses too long between taps.
        sunTapResetTask?.cancel()
        sunTapResetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 3_500_000_000) // 3.5s
            } catch {
                // Cancelled: do not reset the count.
                return
            }
            guard !Task.isCancelled else {
                return
            }
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
                    try await Task.sleep(nanoseconds: 4_000_000_000) // 4.0s
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
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
    
    private func openRadar() {
        // Present RadarView centered on the currently selected YC location.
        let loc = selected ?? locationStore.selected ?? SavedLocation.toronto

        let newTarget = RadarTarget(
            latitude: loc.latitude,
            longitude: loc.longitude,
            title: loc.displayName
        )

        // Deterministic presentation: if already shown, dismiss and re-present.
        Task { @MainActor in
            if radarTarget != nil {
                radarTarget = nil
                try? await Task.sleep(nanoseconds: 80_000_000) // 0.08s
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
        let suffix = hour24 < 12 ? "AM" : "PM"
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
                                .padding(.horizontal, 4)
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

// MARK: - Styling

private struct WeatherAlert: Identifiable, Equatable {
    let id: String
    let title: String
    let severity: String
    let summary: String
    let areaName: String
    let issuedAt: Date?
    let expiresAt: Date?
}

private protocol AlertServiceProtocol {
    func activeAlerts(for coordinate: CLLocationCoordinate2D, countryCode: String) async throws -> [WeatherAlert]
}

private struct StubAlertService: AlertServiceProtocol {
    func activeAlerts(for coordinate: CLLocationCoordinate2D, countryCode: String) async throws -> [WeatherAlert] {
        sampleAlerts(forCountryCode: countryCode, coordinate: coordinate)
    }

    func sampleAlerts(for location: SavedLocation) -> [WeatherAlert] {
        guard location.countryCode == "CA" else { return [] }

        return [
            WeatherAlert(
                id: "stub-special-weather-statement",
                title: "Special Weather Statement",
                severity: "Moderate",
                summary: "Stub alert for YC UI development. Replace this with official Environment Canada alert data once the real alert service is wired up.",
                areaName: location.displayName,
                issuedAt: nil,
                expiresAt: nil
            )
        ]
    }

    private func sampleAlerts(forCountryCode countryCode: String, coordinate: CLLocationCoordinate2D) -> [WeatherAlert] {
        guard countryCode == "CA" else { return [] }

        return [
            WeatherAlert(
                id: "stub-special-weather-statement",
                title: "Special Weather Statement",
                severity: "Moderate",
                summary: "Stub alert for YC UI development. Replace this with official Environment Canada alert data once the real alert service is wired up.",
                areaName: "Selected location",
                issuedAt: nil,
                expiresAt: nil
            )
        ]
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

// MARK: - Locations

private struct SavedLocation: Identifiable, Codable, Equatable {
    let id: UUID
    let displayName: String
    let latitude: Double
    let longitude: Double
    let countryCode: String

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

        // Auto-add to favorites only for searched/saved places.
        // Do not auto-add a current-location selection, because its coordinates can
        // vary slightly from one request to the next and create duplicate rows.
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

    func addFavorite(_ loc: SavedLocation) {
        guard !favorites.contains(where: {
            $0.displayName.caseInsensitiveCompare(loc.displayName) == .orderedSame &&
            $0.countryCode == loc.countryCode
        }) else { return }

        favorites.append(loc)
        favorites.sort { a, b in
            a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        Self.saveArray(favorites, key: favoritesKey)
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        Self.saveArray(favorites, key: favoritesKey)
    }

    // MARK: persistence
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
        // Don’t allow concurrent requests (keeps continuations safe).
        guard pendingLocation == nil else { throw LocationError.alreadyInFlight }

        // Ensure authorization first.
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
            // Still waiting; don’t resume yet.
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
        guard let loc = locations.first else {
            pendingLocation?.resume(throwing: LocationError.noLocation)
            pendingLocation = nil
            return
        }

        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, error in
            guard let self else { return }
            guard let cont = self.pendingLocation else { return }
            self.pendingLocation = nil

            if error != nil {
                cont.resume(throwing: LocationError.reverseGeocodeFailed)
                return
            }

            let pm = placemarks?.first
            let country = pm?.isoCountryCode ?? ""
            let city = pm?.locality ?? pm?.subAdministrativeArea ?? "Unknown"
            let prov = pm?.administrativeArea ?? ""
            let name = prov.isEmpty ? city : "\(city), \(prov)"

            let out = SavedLocation(
                id: UUID(),
                displayName: name,
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                countryCode: country
            )
            cont.resume(returning: out)
        }
    }
}

private struct LocationPickerView: View {
    @ObservedObject var store: LocationStore
    let onSelect: (SavedLocation) -> Void
    let onSelectCurrentLocation: (SavedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var resolver = LocationResolver()
    @AppStorage("yawa.can.isCurrentLocationSelected") private var isCurrentLocationSelected: Bool = false

    @State private var query: String = ""
    @State private var results: [SavedLocation] = []
    @State private var isSearching = false
    @State private var searchError: String? = nil

    // Prevent out-of-order async searches from updating UI (e.g. showing "No matches" while results exist).
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
                            Spacer()
                            if isCurrentLocationSelected {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
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
                                    Text(loc.displayName)
                                    Spacer()
                                    if store.selected == loc {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Favorites") {
                    let favoritesSorted = store.favorites.sorted { a, b in
                        a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                    }

                    ForEach(favoritesSorted) { loc in
                        Button {
                            store.setSelected(loc)
                            onSelect(loc)
                            dismiss()
                        } label: {
                            HStack {
                                Text(loc.displayName)
                                Spacer()
                                if store.selected == loc {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete(perform: store.removeFavorites)
                }
            }
            .navigationTitle("Locations")
            .navigationBarTitleDisplayMode(.inline)
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
            // Cancel any in-flight search; we only want the latest query to win.
            searchTask?.cancel()

            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else {
                results = []
                searchError = nil
                isSearching = false
                return
            }

            // Debounce + generation token to avoid out-of-order UI updates.
            searchGeneration &+= 1
            let gen = searchGeneration

            searchTask = Task {
                // small debounce so we don't hammer MKLocalSearch while typing
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await runSearch(expectedQuery: trimmed, generation: gen)
            }
        }
    }

    private func runSearch(expectedQuery: String, generation: Int) async {
        // Ensure this request still corresponds to the current text.
        let currentQ = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentQ == expectedQuery else { return }
        guard expectedQuery.count >= 3 else { return }

        isSearching = true
        searchError = nil

        do {
            let found = try await LocationSearch.searchCities(query: expectedQuery)

            // Ignore results from stale searches.
            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == expectedQuery else { return }

            results = found
            searchError = found.isEmpty ? "No matches found." : nil
        } catch {
            // Ignore errors from cancelled/stale searches.
            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == expectedQuery else { return }

            searchError = "Search failed. Please try again."
            results = []
        }

        // Only clear searching state if we're still the active generation.
        if generation == searchGeneration {
            isSearching = false
        }
    }
}

private enum LocationSearch {
    static func searchCities(query: String) async throws -> [SavedLocation] {
        // Use MKLocalSearch and return both Canadian and U.S. matches.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        // Center roughly on North America to bias Canada/U.S. results.
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

            let city = pm.locality ?? pm.subAdministrativeArea
            guard let city else { return nil }

            let prov = pm.administrativeArea ?? ""
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

        // De-dupe by name + country.
        var seen = Set<String>()
        let deduped = results.filter { seen.insert("\($0.displayName)|\($0.countryCode)").inserted }

        // Prefer Canadian matches first.
        return deduped.sorted { a, b in
            if a.countryCode == b.countryCode { return a.displayName < b.displayName }
            if a.countryCode == "CA" { return true }
            if b.countryCode == "CA" { return false }
            return a.countryCode < b.countryCode
        }
    }
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
                            Text(day.conditionText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    Divider().opacity(0.18)

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

                    Divider().opacity(0.18)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Discussion")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(forecastSummary)
                            .font(.body)
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

                    // Spacer(minLength: 0) -- removed for inner card to hug content
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
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
            .background(sheetBackground)
            .scrollIndicators(.hidden)
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
        }
        .fontDesign(.rounded)
    }

    private var roundedPrecipChance: Int {
        let clamped = max(0, min(100, day.precipChancePercent))
        return Int((Double(clamped) / 10.0).rounded() * 10.0)
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
        var sentences: [String] = [
            "\(normalizedConditionText(day.conditionText)), with a high of \(formattedTemp(day.highC)) and a low of \(formattedTemp(day.lowC))."
        ]

        let condition = day.conditionText.lowercased()

        if roundedPrecipChance > 0 {
            let hasThunder = condition.contains("thunder") || condition.contains("storm")
            let hasIce = condition.contains("freezing rain") || condition.contains("ice") || condition.contains("icy")
            let hasMix = condition.contains("sleet") || condition.contains("mix") || condition.contains("mixed")
            let hasSnow = condition.contains("snow")
            let hasRain = condition.contains("rain") || condition.contains("drizzle") || condition.contains("showers")

            if hasThunder {
                if roundedPrecipChance <= 20 {
                    sentences.append("Thunderstorms are possible.")
                } else if roundedPrecipChance <= 50 {
                    sentences.append("There is a moderate chance of thunderstorms.")
                } else {
                    sentences.append("Thunderstorms are likely at times.")
                }
            } else if hasIce {
                if roundedPrecipChance <= 20 {
                    sentences.append("A slight chance of freezing rain or icy conditions.")
                } else if roundedPrecipChance <= 50 {
                    sentences.append("There is a moderate chance of freezing rain or icy conditions.")
                } else {
                    sentences.append("Freezing rain or icy conditions are likely at times.")
                }
            } else if hasMix {
                if roundedPrecipChance <= 20 {
                    sentences.append("A slight chance of mixed precipitation.")
                } else if roundedPrecipChance <= 50 {
                    sentences.append("There is a moderate chance of mixed precipitation.")
                } else {
                    sentences.append("Mixed precipitation is likely at times.")
                }
            } else if hasSnow {
                if roundedPrecipChance <= 20 {
                    sentences.append("Light snow possible.")
                } else if roundedPrecipChance <= 50 {
                    sentences.append("There is a moderate chance of snow.")
                } else {
                    sentences.append("Accumulating snow likely.")
                }
            } else if hasRain {
                if roundedPrecipChance <= 20 {
                    sentences.append("A slight chance of rain.")
                } else if roundedPrecipChance <= 50 {
                    sentences.append("There is a moderate chance of rain.")
                } else {
                    sentences.append("Periods of rain are likely.")
                }
            } else {
                if roundedPrecipChance <= 20 {
                    sentences.append("A slight chance of precipitation.")
                } else if roundedPrecipChance <= 50 {
                    sentences.append("There is a moderate chance of precipitation.")
                } else {
                    sentences.append("Periods of precipitation are likely.")
                }
            }
        } else {
            sentences.append("Dry conditions expected.")
        }

        return sentences.joined(separator: " ")
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

        return Array(zip(hourlyTimeISO.indices, hourlyTimeISO)).compactMap { idx, iso in
            guard idx < hourlyTempsC.count, idx < hourlyPrecipChancePercent.count else { return nil }
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

    private enum FeelsLikeMode {
        case windChill
        case heatIndex
        case actual
    }


    private func computeFeelsLikeMode(tempC: Double, windKph: Double, relativeHumidity: Double?) -> FeelsLikeMode {
        // Wind chill only applies at/under 10°C (50°F) and with meaningful wind.
        if tempC <= 10.0, windKph >= 5.0 {
            return .windChill
        }

        // Heat index applies at/above ~26.7°C (80°F) with sufficient humidity.
        if tempC >= 26.7, let rh = relativeHumidity, rh >= 40.0 {
            return .heatIndex
        }

        return .actual
    }

    // MARK: - Dew Point / Comfort helpers (YN-style, but metric)

    private func dewPointComfortSubtitleText(for current: CurrentConditions) -> String {
        let dpC = current.dewPointC

        // Convert the YN bands (°F) into approximate °C thresholds.
        // 50°F≈10.0°C, 55°F≈12.8°C, 60°F≈15.6°C, 65°F≈18.3°C,
        // 70°F≈21.1°C, 75°F≈23.9°C
        switch dpC {
        case ..<10.0:
            return "Dry air"
        case 10.0..<12.8:
            return "Comfortable"
        case 12.8..<15.6:
            return "Pleasant"
        case 15.6..<18.3:
            return "Slightly humid"
        case 18.3..<21.1:
            return "Humid"
        case 21.1..<23.9:
            return "Very humid"
        default:
            return "Oppressive humidity"
        }
    }
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

