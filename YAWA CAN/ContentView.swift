import SwiftUI
import CoreLocation
import MapKit
import Charts
import Combine

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
    
    @State private var selectedDay: DailyForecastDay? = nil

    var body: some View {
        NavigationStack {
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
                        sunTile(snap)
                    } else if !viewModel.isLoading && viewModel.errorMessage == nil {
                        Text("No weather loaded yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 8)
                }
                .padding(16)
            }
            .navigationTitle("YAWA CAN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")

                    Button {
                        showingLocations = true
                    } label: {
                        Image(systemName: "location.circle")
                    }
                    .accessibilityLabel("Locations")
                }
            }
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
                    Text("Now")
                        .font(.headline)
                    Text(snap.current.conditionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: snap.current.symbolName)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(round(snap.current.temperatureC)))")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("°C")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Divider().opacity(0.25)

            metricRow(label: "Wind", value: "\(Int(round(snap.current.windSpeedKph))) km/h")
            metricRow(label: "Humidity", value: "\(Int(round(snap.current.humidityPercent)))%")
            metricRow(label: "Pressure", value: String(format: "%.1f kPa", snap.current.pressureKPa))
        }
        .tileStyle()
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
        VStack(alignment: .leading, spacing: 10) {
            Text("7-Day Forecast")
                .font(.headline)

            let days = Array(snap.daily.prefix(7))
            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                Button {
                    selectedDay = day
                } label: {
                    HStack(spacing: 10) {
                        Text(shortDay(day.date))
                            .font(.callout)
                            .frame(width: 42, alignment: .leading)

                        Image(systemName: day.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 22)

                        Text(day.conditionText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()

                        Text("\(day.precipChancePercent)%")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)

                        Text("\(Int(round(day.highC)))° / \(Int(round(day.lowC)))°")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 92, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if idx != days.count - 1 {
                    Divider().opacity(0.18)
                }
            }
        }
        .tileStyle()
    }
    
    private func sunTile(_ snap: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sun")
                    .font(.headline)
                Spacer()
                Image(systemName: "sun.max.fill")
                    .symbolRenderingMode(.hierarchical)
            }

            if let sun = snap.sun {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sunrise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(timeString(sun.sunrise, timeZoneID: snap.timeZoneID))
                            .font(.title3.weight(.semibold))
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sunset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(timeString(sun.sunset, timeZoneID: snap.timeZoneID))
                            .font(.title3.weight(.semibold))
                    }
                }
            } else {
                Text("Sun times unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .tileStyle()
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

    private func shortDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "EEE"
        return f.string(from: date)
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

private extension View {
    func tileStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
            .shadow(color: Color.white.opacity(0.08), radius: 1, x: 0, y: 1)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: day.symbolName)
                        .font(.system(size: 34, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
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
                        Text("High")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(round(day.highC)))°C")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Low")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(round(day.lowC)))°C")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Precip")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(day.precipChancePercent)%")
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

