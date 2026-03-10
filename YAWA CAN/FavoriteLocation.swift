//
//  FavoriteLocation.swift
//  iOSWeather
//
//  Created by xcode and chatGPT on 1/1/26.
//


import Foundation
import CoreLocation
import Combine

struct FavoriteLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String          // City
    var subtitle: String       // State / Province (only used for US/CA)
    var country: String?       // e.g. "Ireland"
    var isoCountryCode: String? // e.g. "IE"
    var latitude: Double
    var longitude: Double

    init(
        title: String,
        subtitle: String,
        country: String? = nil,
        isoCountryCode: String? = nil,
        latitude: Double,
        longitude: Double
    ) {
        self.id = UUID()
        self.title = title
        self.subtitle = subtitle
        self.country = country
        self.isoCountryCode = isoCountryCode
        self.latitude = latitude
        self.longitude = longitude
    }

    var displayName: String {
        let city = title
        let cc = isoCountryCode ?? ""

        if cc == "US" || cc == "CA" {
            // City, State/Province
            return subtitle.isEmpty ? city : "\(city), \(subtitle)"
        }

        // Everywhere else: City, Country (ignore admin regions like Irish counties)
        if let country, !country.isEmpty {
            return "\(city), \(country)"
        }

        // Fallback
        return subtitle.isEmpty ? city : "\(city), \(subtitle)"
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

/// What the app should show on launch / when returning to the main forecast.
/// - currentLocation: Use LocationManager to resolve the user's current coordinate.
/// - favorite(id): Use a saved favorite's coordinate.
enum LaunchSelection: Codable, Equatable {
    case currentLocation
    case favorite(UUID)

    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case currentLocation, favorite }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .currentLocation:
            self = .currentLocation
        case .favorite:
            let id = try c.decode(UUID.self, forKey: .id)
            self = .favorite(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .currentLocation:
            try c.encode(Kind.currentLocation, forKey: .kind)
        case .favorite(let id):
            try c.encode(Kind.favorite, forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

final class FavoritesStore: ObservableObject {
    @Published private(set) var favorites: [FavoriteLocation] = []

    private let favoritesKey = "favorites.locations.v1"
    private let selectionKey = "favorites.selection.v1"

    /// The user's chosen launch target. Defaults to `.currentLocation`.
    @Published var selection: LaunchSelection = .currentLocation {
        didSet { saveSelection() }
    }

    init() {
        loadFavorites()
        loadSelection()
        // If the saved selection points to a favorite that no longer exists, fall back.
        if case .favorite(let id) = selection,
           favorites.contains(where: { $0.id == id }) == false {
            selection = .currentLocation
        }
    }

    func selectCurrentLocation() {
        selection = .currentLocation
    }

    func select(_ loc: FavoriteLocation) {
        selection = .favorite(loc.id)
    }

    var selectedFavorite: FavoriteLocation? {
        guard case .favorite(let id) = selection else { return nil }
        return favorites.first(where: { $0.id == id })
    }

    var isCurrentLocationSelected: Bool {
        if case .currentLocation = selection { return true }
        return false
    }

    func add(_ loc: FavoriteLocation) {
        if favorites.contains(where: {
            $0.title == loc.title
            && $0.subtitle == loc.subtitle
            && ($0.isoCountryCode ?? "") == (loc.isoCountryCode ?? "")
        }) {
            return
        }

        favorites.append(loc)
        sortFavorites()
        saveFavorites()
    }
    
    func remove(_ loc: FavoriteLocation) {
        favorites.removeAll { $0.id == loc.id }

        // If we just removed the selected favorite, fall back to current location.
        if case .favorite(let id) = selection, id == loc.id {
            selection = .currentLocation
        }

        saveFavorites()
    }

    private func saveFavorites() {
        do {
            let data = try JSONEncoder().encode(favorites)
            UserDefaults.standard.set(data, forKey: favoritesKey)
        } catch {
            // ignore
        }
    }

    private func saveSelection() {
        do {
            let data = try JSONEncoder().encode(selection)
            UserDefaults.standard.set(data, forKey: selectionKey)
        } catch {
            // ignore
        }
    }

    private func sortFavorites() {
        favorites.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
    
    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey) else { return }

        do {
            favorites = try JSONDecoder().decode([FavoriteLocation].self, from: data)
            sortFavorites()
        } catch {
            favorites = []
        }
    }

    private func loadSelection() {
        guard let data = UserDefaults.standard.data(forKey: selectionKey) else {
            selection = .currentLocation
            return
        }

        do {
            selection = try JSONDecoder().decode(LaunchSelection.self, from: data)
        } catch {
            selection = .currentLocation
        }
    }
}
