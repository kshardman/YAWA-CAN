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
        service: OpenMeteoWeatherService,
        showLoading: Bool = true
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration

        if currentTask != nil {
            RefreshLog.log("vm cancelling previous load before generation=\(generation)")
        }
        currentTask?.cancel()

        if showLoading {
            isLoading = true
        }
        errorMessage = nil

        RefreshLog.log("vm load started generation=\(generation) lat=\(latitude) lon=\(longitude) showLoading=\(showLoading)")

        let task = Task(priority: .userInitiated) { [service] in
            do {
                let snapshot = try await service.fetchWeather(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    locationName: nil
                )
                guard !Task.isCancelled else {
                    RefreshLog.log("vm load cancelled generation=\(generation)")
                    return
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else {
                        RefreshLog.log("vm stale success dropped generation=\(generation) latest=\(self.loadGeneration)")
                        return
                    }
                    self.snapshot = snapshot
                    self.errorMessage = nil
                    self.isLoading = false
                    RefreshLog.log("vm load succeeded generation=\(generation)")
                }
            } catch is CancellationError {
                RefreshLog.log("vm load cancellation error generation=\(generation)")
                return
            } catch {
                guard !Task.isCancelled else {
                    RefreshLog.log("vm load cancelled after error generation=\(generation)")
                    return
                }

                await MainActor.run {
                    guard generation == self.loadGeneration else {
                        RefreshLog.log("vm stale failure dropped generation=\(generation) latest=\(self.loadGeneration)")
                        return
                    }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    RefreshLog.log("vm load failed generation=\(generation) error=\(error.localizedDescription)")
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
