//
//  WeatherServiceProtocol.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//


import Foundation
import CoreLocation

protocol WeatherServiceProtocol {
    func fetchWeather(
        coordinate: CLLocationCoordinate2D,
        locationName: String?
    ) async throws -> WeatherSnapshot
}