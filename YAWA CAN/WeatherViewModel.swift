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
    @Published var snapshot: WeatherSnapshot?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var currentTask: Task<Void, Never>?
    private var loadGeneration: Int = 0

    deinit {
        currentTask?.cancel()
    }

    func load(
        latitude: Double,
        longitude: Double,
        locationName: String?,
        service: OpenMeteoWeatherService,
        showLoading: Bool = true
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        if currentTask != nil {
        }
        currentTask?.cancel()

        if showLoading {
            isLoading = true
        }
        errorMessage = nil

        let task = Task(priority: .userInitiated) { [service] in
            do {
                let snapshot = try await service.fetchWeather(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    locationName: locationName
                )
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else {
                        return
                    }
                    self.snapshot = snapshot
                    YCWidgetShared.save(snapshot: snapshot)
                    self.errorMessage = nil
                    self.isLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else {
                        return
                    }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }

        currentTask = task
        await task.value

        if currentTask == task {
            currentTask = nil
        }
    }
}
