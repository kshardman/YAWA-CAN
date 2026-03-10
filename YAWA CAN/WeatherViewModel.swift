//
//  WeatherViewModel.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//


import Foundation
import CoreLocation
import Combine

@MainActor
final class WeatherViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var snapshot: WeatherSnapshot?

    private let service: WeatherServiceProtocol

    init() {
        self.service = OpenMeteoWeatherService()
    }

    init(service: WeatherServiceProtocol) {
        self.service = service
    }

    func load(for coordinate: CLLocationCoordinate2D, locationName: String? = nil) async {
        isLoading = true
        errorMessage = nil
        do {
            let snap = try await service.fetchWeather(coordinate: coordinate, locationName: locationName)
            snapshot = snap
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = "Weather unavailable. Please try again."
        }
    }
}
