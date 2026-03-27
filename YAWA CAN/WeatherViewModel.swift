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

    private let notificationStore = NotificationStore()
    private let notificationCoordinator = NotificationCoordinator()

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

                await self.handleSuccessfulLoad(
                    snapshot: snapshot,
                    latitude: latitude,
                    longitude: longitude,
                    locationName: locationName
                )
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
    private func handleSuccessfulLoad(
        snapshot: WeatherSnapshot,
        latitude: Double,
        longitude: Double,
        locationName: String?
    ) async {
        let resolvedName = locationName ?? "Unknown Location"
        print("[N1] WeatherViewModel load succeeded for \(resolvedName)")

        guard let notificationSnapshot = makeNotificationSnapshot(
            from: snapshot,
            latitude: latitude,
            longitude: longitude,
            locationName: resolvedName
        ) else {
            print("[N1] notification snapshot mapping unavailable")
            return
        }

        notificationStore.saveSnapshot(notificationSnapshot)
        print("[N1] notification snapshot saved for \(notificationSnapshot.locationName)")

        await notificationCoordinator.reevaluateAndScheduleIfNeeded(
            snapshot: notificationSnapshot,
            selectedLocationKey: notificationSnapshot.locationName
        )
    }

    private func makeNotificationSnapshot(
        from snapshot: WeatherSnapshot,
        latitude: Double,
        longitude: Double,
        locationName: String
    ) -> ForecastNotificationSnapshot? {

        let timezoneIdentifier = snapshot.timeZoneID

        // Hourly
        let hourlyCount = snapshot.hourlyTimeISO.count
        let hourly: [ForecastNotificationSnapshot.HourlyPoint] = (0..<hourlyCount).map { idx in
            ForecastNotificationSnapshot.HourlyPoint(
                timeISO: snapshot.hourlyTimeISO[idx],
                precipitationProbability: idx < snapshot.hourlyPrecipChancePercent.count
                    ? snapshot.hourlyPrecipChancePercent[idx]
                    : nil,
                precipitationAmountMM: nil, // not available in YC
                weatherCode: idx < snapshot.hourlyWeatherCodes.count
                    ? snapshot.hourlyWeatherCodes[idx]
                    : nil,
                windSpeedKPH: nil,
                windGustKPH: nil,
                temperatureC: idx < snapshot.hourlyTempsC.count
                    ? snapshot.hourlyTempsC[idx]
                    : nil
            )
        }

        // Daily
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let daily: [ForecastNotificationSnapshot.DailyPoint] = snapshot.daily.map { day in
            ForecastNotificationSnapshot.DailyPoint(
                dateISO: dayFormatter.string(from: day.date),
                weatherCode: nil,
                tempMinC: day.lowC,
                tempMaxC: day.highC,
                precipitationProbabilityMax: Double(day.precipChancePercent),
                precipitationAmountMM: nil,
                windSpeedMaxKPH: nil,
                windGustMaxKPH: nil
            )
        }

        return ForecastNotificationSnapshot(
            generatedAtISO: ISO8601DateFormatter().string(from: Date()),
            locationName: locationName,
            locationLatitude: latitude,
            locationLongitude: longitude,
            timezoneIdentifier: timezoneIdentifier,
            hourly: hourly,
            daily: daily
        )
    }
}
