import SwiftUI
import CoreLocation
import MapKit
import Charts
import Combine
import UIKit

/// YAWA CAN - Main ContentView
/// Uses `WeatherViewModel` + `WeatherServiceProtocol` (Open-Meteo service) and renders
/// the core YAWA UX: current tile, hourly temp chart, and 7‑day forecast.
///
/// - Loads the last-selected location (or Toronto by default) and updates when the user selects a favorite/current location.
/// - All units are Canada defaults: °C, km/h, kPa, mm, km.
struct ContentView: View {
    @StateObject private var viewModel = WeatherViewModel(service: OpenMeteoWeatherService())
    @StateObject private var locationStore = LocationStore()

    @State private var showingLocations = false
    @State private var selected: SavedLocation? = nil
    @State private var showingNotInCanadaAlert = false
    @State private var showingSettings = false
    @State private var radarTarget: RadarTarget? = nil
    
    @State private var selectedDay: DailyForecastDay? = nil
    
    @State private var sunRefreshToken = Date()

    @Environment(\.colorScheme) private var colorScheme

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
            ZStack {
                appBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        headerButton

                        if viewModel.isLoading {
                            loadingRow
                        }

                        if let msg = viewModel.errorMessage {
                            Text(msg)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let snap = viewModel.snapshot {
                            currentTile(snap)
 
//                        hourlyTile(snap)
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
            }
            .navigationTitle("YAWA CAN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor("gearshape", scheme: colorScheme))
                    }
                    .accessibilityLabel("Settings")

                    Button {
                        showingLocations = true
                    } label: {
                        Image(systemName: "location.circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor("location.circle", scheme: colorScheme))
                    }
                    .accessibilityLabel("Locations")
                }
            }
            // Make the nav bar match the background.
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(YAWATheme.background(for: colorScheme), for: .navigationBar)
        }
        .task {
            // Initial selection: last-used favorite if present, otherwise Toronto.
            let initial = locationStore.selected ?? SavedLocation.toronto
            selected = initial
            await viewModel.load(for: initial.coordinate, locationName: initial.displayName)
        }
        .sheet(item: $selectedDay) { day in
            DailyForecastDetailSheet(day: day)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingLocations) {
            LocationPickerView(
                store: locationStore,
                onSelect: { loc in
                    // Enforce Canada-only.
                    guard loc.countryCode == "CA" else {
                        showingNotInCanadaAlert = true
                        return
                    }
                    selected = loc
                    locationStore.setSelected(loc)
                    Task { await viewModel.load(for: loc.coordinate, locationName: loc.displayName) }
                },
                onSelectCurrentLocation: { loc in
                    guard loc.countryCode == "CA" else {
                        showingNotInCanadaAlert = true
                        return
                    }
                    selected = loc
                    locationStore.setSelected(loc)
                    Task { await viewModel.load(for: loc.coordinate, locationName: loc.displayName) }
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
        .alert("Canada only", isPresented: $showingNotInCanadaAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Outside Canada. Try: Vancouver, BC • Calgary, AB • Montréal, QC.")
        }
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            showingLocations = true
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected?.displayName ?? "–")
                        .font(.title2.weight(.semibold))
                    Text("Canada • °C • km/h • kPa")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                            .font(.subheadline)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(YAWATheme.symbolColor("clock", scheme: colorScheme))
                            .opacity(0.9)

                        Text("Now")
                            .font(.headline)
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
                // Temperature
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(round(snap.current.temperatureC)))")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    Text("°C")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                // Supporting metrics (icons right next to values)
                VStack(alignment: .trailing, spacing: 6) {
                    metricIconValue(icon: "wind", value: snap.current.windDisplay)
                    metricIconValue(icon: "humidity.fill", value: "\(Int(round(snap.current.humidityPercent)))%")
                    metricIconValue(icon: "gauge", value: String(format: "%.1f kPa", snap.current.pressureKPa))
                }
                .padding(.top, -8)
                .font(.subheadline)
                .monospacedDigit()
            }
        }
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

                Text("\(Int(round(snap.current.apparentTemperatureC)))°C")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(feelsLikeSubtitleText(for: snap.current))
                    .font(.callout)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))

                Text(dewPointComfortSubtitleText(for: snap.current))
                    .font(.callout)
                    .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
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

//    private func hourlyTile(_ snap: WeatherSnapshot) -> some View {
//        VStack(alignment: .leading, spacing: 10) {
//            HStack {
//                Text("Hourly")
//                    .font(.headline)
//                Spacer()
//                Text("Temp (°C)")
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//            }
//
//            if snap.hourlyTempsC.isEmpty {
//                Text("No hourly data.")
//                    .font(.callout)
//                    .foregroundStyle(.secondary)
//            } else {
//                HourlyTempChart(tempsC: Array(snap.hourlyTempsC.prefix(24)))
//                    .frame(height: 150)
//            }
//        }
//        .tileStyle()
//    }

    private func dailyTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {

            // Header row
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.subheadline)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(YAWATheme.symbolColor("calendar", scheme: colorScheme))
                    .opacity(0.85)

                Text("7-Day Forecast")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))

                Spacer()

                // (Optional) If you want CAN to show a spinner while weather is loading:
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(YAWATheme.textSecondary(for: colorScheme))
                }
            }

            // Forecast rows
            let daysToShow = 7
            let days: [DailyForecastDay] = Array(snap.daily.prefix(daysToShow))

            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                let weekdayW: CGFloat = 40
                let dateW: CGFloat = 32
                let iconW: CGFloat = 36

                let sym = day.symbolName
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
                                        .frame(height: 22, alignment: .center)

                                    Text(popText)
                                        .font(popText == "100%" ? .caption2.weight(.semibold) : .caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                                        .frame(height: 14, alignment: .top)
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
                        .frame(width: iconW, height: 40, alignment: .center)
                    }
                    .frame(width: weekdayW + dateW + 4 + iconW + 2, alignment: .leading)

                    // Brief forecast text
                    Text(day.conditionText)
                        .font(.subheadline)
                        .foregroundStyle(YAWATheme.textSecondary(for: colorScheme))
                        .layoutPriority(2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    // Right column (fixed)
                    Text("H \(tempDisplayC(day.highC))  L \(tempDisplayC(day.lowC))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { selectedDay = day }

                if idx != days.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(YAWATheme.cardBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(YAWATheme.cardStroke(for: colorScheme), lineWidth: 1)
        )
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
                        onTapRefresh: { sunRefreshToken = Date() },
                        enablesTapRefresh: true
                    )
                    .id(sunRefreshToken)
                    .offset(y: -70)
                    .padding(.top, 2)
                }
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
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(YAWATheme.symbolColor(icon, scheme: colorScheme))
                .opacity(colorScheme == .dark ? 0.90 : 0.82)
                .frame(width: 14, alignment: .center)
                .offset(y: 0.5)

            Text(value)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
        }
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

    private func tempDisplayC(_ c: Double) -> String {
        "\(Int(round(c)))°"
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
    let tempsC: [Double]

    var body: some View {
        Chart {
            ForEach(Array(tempsC.enumerated()), id: \.offset) { idx, t in
                LineMark(
                    x: .value("Hour", idx),
                    y: .value("Temp", t)
                )
                PointMark(
                    x: .value("Hour", idx),
                    y: .value("Temp", t)
                )
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 6)) { value in
                if let idx = value.as(Int.self) {
                    AxisValueLabel("\(idx)h")
                }
                AxisGridLine()
                AxisTick()
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing)
        }
    }
}

// MARK: - Styling

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
                        YAWATheme.cardStroke(for: scheme),
                        lineWidth: scheme == .dark ? 1 : 0.8
                    )
            )
            .shadow(
                color: Color.black.opacity(scheme == .dark ? 0.18 : 0.04),
                radius: scheme == .dark ? 12 : 8,
                x: 0,
                y: scheme == .dark ? 8 : 4
            )
    }
}

private extension View {
    func tileStyle() -> some View {
        modifier(TileStyleModifier())
    }
}

// MARK: - Canada-only Locations

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
        selected = Self.loadOne(key: selectedKey)
    }

    func setSelected(_ loc: SavedLocation) {
        selected = loc
        Self.saveOne(loc, key: selectedKey)
        // Auto-add to favorites if not present.
        if !favorites.contains(where: { $0.displayName == loc.displayName && $0.latitude == loc.latitude && $0.longitude == loc.longitude }) {
            favorites.insert(loc, at: 0)
            Self.saveArray(favorites, key: favoritesKey)
        }
    }

    func addFavorite(_ loc: SavedLocation) {
        guard !favorites.contains(where: { $0.displayName == loc.displayName && $0.latitude == loc.latitude && $0.longitude == loc.longitude }) else { return }
        favorites.insert(loc, at: 0)
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
private final class CanadaLocationResolver: NSObject, ObservableObject, CLLocationManagerDelegate {
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
    @StateObject private var resolver = CanadaLocationResolver()

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
                        TextField("Search city, province", text: $query)
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
                        Label("Current Location", systemImage: "location")
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
                                onSelect(loc)
                                dismiss()
                            } label: {
                                Text(loc.displayName)
                            }
                        }
                    }
                }

                Section("Favorites") {
                    ForEach(store.favorites) { loc in
                        Button {
                            onSelect(loc)
                            dismiss()
                        } label: {
                            Text(loc.displayName)
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
            let found = try await CanadaSearch.searchCities(query: expectedQuery)

            // Ignore results from stale searches.
            guard generation == searchGeneration else { return }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == expectedQuery else { return }

            results = found
            searchError = found.isEmpty ? "No Canadian matches found." : nil
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

private enum CanadaSearch {
    static func searchCities(query: String) async throws -> [SavedLocation] {
        // Use MKLocalSearch and post-filter to CA.
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        // Center roughly on Canada to bias results.
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 56.1304, longitude: -106.3468),
            span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 70)
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
    let day: DailyForecastDay
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: day.symbolName)
                        .font(.system(size: 34, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(YAWATheme.symbolColor(day.symbolName, scheme: colorScheme))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(longDay(day.date))
                            .font(.title3.weight(.semibold))
                        Text(day.conditionText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider().opacity(0.18)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("High", systemImage: "arrow.up")
                            .labelStyle(.titleOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(round(day.highC)))°C")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Low", systemImage: "arrow.down")
                            .labelStyle(.titleOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(round(day.lowC)))°C")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Precip", systemImage: "drop")
                            .labelStyle(.titleOnly)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let clamped = max(0, min(100, day.precipChancePercent))
                        let rounded = Int((Double(clamped) / 10.0).rounded() * 10.0)
                        Text("\(rounded)%")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Forecast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func longDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}


#Preview {
    ContentView()
}


    // MARK: - Comfort / Feels Like (YN-style, but metric)

    private enum FeelsLikeMode {
        case windChill
        case heatIndex
        case actual
    }

    private func feelsLikeSubtitleText(for current: CurrentConditions) -> String {
        let actualC = current.temperatureC
        let feelsC = current.apparentTemperatureC
        let rh = current.humidityPercent
        let windKph = current.windSpeedKph

        let mode = computeFeelsLikeMode(tempC: actualC, windKph: windKph, relativeHumidity: rh)

        switch mode {
        case .windChill:
            return "Colder due to wind"
        case .heatIndex:
            return "Hotter due to humidity"
        case .actual:
            // Deadband so tiny diffs don’t flip message.
            // YN uses ~2°F; use ~1°C here.
            if feelsC <= actualC - 1.0 { return "Colder due to wind" }
            if feelsC >= actualC + 1.0 { return "Hotter due to humidity" }
            return "Feels like actual temperature"
        }
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
