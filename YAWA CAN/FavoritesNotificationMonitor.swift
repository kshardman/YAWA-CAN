//
//  FavoritesNotificationMonitor.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/29/26.
//


import Foundation
import CoreLocation

struct MonitoredFavoriteLocation {
    let displayName: String
    let latitude: Double
    let longitude: Double
    let countryCode: String
}

@MainActor
final class FavoritesNotificationMonitor {
    private let weatherService = OpenMeteoWeatherService()
    private let alertService = CanadaAlertService()
    private let coordinator = NotificationCoordinator()

    func evaluateFavorites(_ favorites: [MonitoredFavoriteLocation]) async {
        let monitoredFavorites = Array(favorites.prefix(10))
        guard !monitoredFavorites.isEmpty else {
            print("[N1] favorites monitor: no favorites to evaluate")
            return
        }

        var allCandidates: [NotificationCandidate] = []

        for favorite in monitoredFavorites {
            do {
                let weather = try await weatherService.fetchWeather(
                    coordinate: CLLocationCoordinate2D(
                        latitude: favorite.latitude,
                        longitude: favorite.longitude
                    ),
                    locationName: favorite.displayName
                )

                let topAlert: WeatherAlert?
                if favorite.countryCode == "CA" {
                    let alerts = try await alertService.fetchAlerts(
                        withDelta: 0.20,
                        for: CLLocationCoordinate2D(
                            latitude: favorite.latitude,
                            longitude: favorite.longitude
                        ),
                        countryCode: favorite.countryCode
                    )
                    topAlert = alerts
                        .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
                        .first
                } else {
                    topAlert = nil
                }

                guard let snapshot = makeSnapshot(
                    weather: weather,
                    location: favorite,
                    alert: topAlert
                ) else {
                    print("[N1] favorites monitor: snapshot unavailable for \(favorite.displayName)")
                    continue
                }

                let prefs = NotificationStore().loadPreferences()
                let timeZone = TimeZone(identifier: snapshot.timezoneIdentifier) ?? .current
                var calendar = Calendar.current
                calendar.timeZone = timeZone

                let candidates = NotificationRuleEngine.evaluate(
                    snapshot: snapshot,
                    now: Date(),
                    calendar: calendar,
                    timeZone: timeZone,
                    preferences: prefs
                )

                if !candidates.isEmpty {
                    print("[N1] favorites monitor candidates for \(favorite.displayName): \(candidates.map { $0.id })")
                }

                allCandidates.append(contentsOf: candidates)
            } catch {
                print("[N1] favorites monitor error for \(favorite.displayName): \(error.localizedDescription)")
            }
        }

        guard !allCandidates.isEmpty else {
            print("[N1] favorites monitor: no candidates")
            return
        }

        let winner = allCandidates.sorted {
            if $0.relevanceScore != $1.relevanceScore {
                return $0.relevanceScore > $1.relevanceScore
            }
            return $0.fireDate < $1.fireDate
        }.first!

        print("[N1] favorites monitor winner id=\(winner.id)")

        let timeZone = TimeZone.current
        var calendar = Calendar.current
        calendar.timeZone = timeZone

        await coordinator.scheduleCandidateIfNeeded(
            winner,
            calendar: calendar,
            timeZone: timeZone,
            logPrefix: "favorites-monitor"
        )
    }

    private func makeSnapshot(
        weather: WeatherSnapshot,
        location: MonitoredFavoriteLocation,
        alert: WeatherAlert?
    ) -> ForecastNotificationSnapshot? {
        let alertSummary = alert.map {
            ForecastAlertSummary(
                title: $0.title,
                severity: $0.severity,
                areaName: $0.areaName,
                expiresAt: $0.expiresAt
            )
        }

        let hourlyCount = weather.hourlyTimeISO.count
        let hourly: [ForecastNotificationSnapshot.HourlyPoint] = (0..<hourlyCount).map { idx in
            ForecastNotificationSnapshot.HourlyPoint(
                timeISO: weather.hourlyTimeISO[idx],
                precipitationProbability: idx < weather.hourlyPrecipChancePercent.count
                    ? weather.hourlyPrecipChancePercent[idx]
                    : nil,
                precipitationAmountMM: nil,
                weatherCode: idx < weather.hourlyWeatherCodes.count
                    ? weather.hourlyWeatherCodes[idx]
                    : nil,
                windSpeedKPH: nil,
                windGustKPH: nil,
                temperatureC: idx < weather.hourlyTempsC.count
                    ? weather.hourlyTempsC[idx]
                    : nil
            )
        }

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.timeZone = TimeZone(identifier: weather.timeZoneID) ?? .current
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let daily: [ForecastNotificationSnapshot.DailyPoint] = weather.daily.map { day in
            ForecastNotificationSnapshot.DailyPoint(
                dateISO: dayFormatter.string(from: day.date),
                weatherCode: nil,
                tempMinC: day.lowC,
                tempMaxC: day.highC,
                precipitationProbabilityMax: Double(day.precipChancePercent),
                precipitationAmountMM: nil,
                windSpeedMaxKPH: nil,
                windGustMaxKPH: day.windGustKPH
            )
        }

        return ForecastNotificationSnapshot(
            generatedAtISO: ISO8601DateFormatter().string(from: Date()),
            locationName: location.displayName,
            locationLatitude: location.latitude,
            locationLongitude: location.longitude,
            forecastAlertSummary: alertSummary,
            timezoneIdentifier: weather.timeZoneID,
            hourly: hourly,
            daily: daily
        )
    }
}
