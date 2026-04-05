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

private struct EvaluatedFavoriteCandidate {
    let candidate: NotificationCandidate
    let alertExpiresAt: Date?
    let favoriteOrder: Int

    var isOfficialAlert: Bool {
        candidate.kind == .notableForecast
    }
}

@MainActor
final class FavoritesNotificationMonitor {
    private let weatherService = OpenMeteoWeatherService()
    private let alertService = CanadaAlertService()
    private let coordinator = NotificationCoordinator()

    private func notificationTargetKey(for location: MonitoredFavoriteLocation) -> String {
        "\(location.displayName)|\(location.latitude)|\(location.longitude)"
    }

    func evaluateFavorites(_ favorites: [MonitoredFavoriteLocation]) async {
        let monitoredFavorites = favorites
        guard !monitoredFavorites.isEmpty else {
            AppLogger.log("[N1] favorites monitor: no favorites to evaluate")
            return
        }

        var didFindAnyCandidates = false
        var localWinners: [EvaluatedFavoriteCandidate] = []

        for (favoriteOrder, favorite) in monitoredFavorites.enumerated() {
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
                    AppLogger.log("[N1] favorites monitor: snapshot unavailable for \(favorite.displayName)")
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
                    AppLogger.log("[N1] favorites monitor candidates for \(favorite.displayName): \(candidates.map { $0.id })")
                }

                let evaluatedCandidates = candidates.map {
                    EvaluatedFavoriteCandidate(
                        candidate: $0,
                        alertExpiresAt: topAlert?.expiresAt,
                        favoriteOrder: favoriteOrder
                    )
                }

                for entry in evaluatedCandidates {
                    AppLogger.log("[N1] favorites monitor candidate detail id=\(entry.candidate.id) score=\(entry.candidate.relevanceScore) fireDate=\(entry.candidate.fireDate) expiresAt=\(entry.alertExpiresAt?.description ?? "nil") favoriteOrder=\(entry.favoriteOrder)")
                }

                if !evaluatedCandidates.isEmpty {
                    didFindAnyCandidates = true

                    let winningEntry = evaluatedCandidates.sorted {
                        if $0.isOfficialAlert != $1.isOfficialAlert {
                            return $0.isOfficialAlert && !$1.isOfficialAlert
                        }

                        if $0.candidate.relevanceScore != $1.candidate.relevanceScore {
                            return $0.candidate.relevanceScore > $1.candidate.relevanceScore
                        }

                        switch ($0.alertExpiresAt, $1.alertExpiresAt) {
                        case let (lhs?, rhs?) where lhs != rhs:
                            return lhs < rhs
                        case (_?, nil):
                            return true
                        case (nil, _?):
                            return false
                        default:
                            break
                        }

                        if $0.candidate.fireDate != $1.candidate.fireDate {
                            return $0.candidate.fireDate < $1.candidate.fireDate
                        }

                        if $0.favoriteOrder != $1.favoriteOrder {
                            return $0.favoriteOrder < $1.favoriteOrder
                        }

                        return $0.candidate.id < $1.candidate.id
                    }.first!

                    let winner = winningEntry.candidate

                    AppLogger.log("[N1] favorites monitor local winner id=\(winner.id)")
                    AppLogger.log("[N1] favorites monitor local winner officialAlert=\(winningEntry.isOfficialAlert)")
                    AppLogger.log("[N1] favorites monitor local winner location=\(winner.locationName) favoriteOrder=\(winningEntry.favoriteOrder) expiresAt=\(winningEntry.alertExpiresAt?.description ?? "nil")")

                    localWinners.append(winningEntry)
                }
            } catch {
                AppLogger.log("[N1] favorites monitor error for \(favorite.displayName): \(error.localizedDescription)")
            }
        }

        if !didFindAnyCandidates {
            AppLogger.log("[N1] favorites monitor: no candidates")
        }

        guard !localWinners.isEmpty else { return }

        let sortedWinners = localWinners.sorted {
            if $0.isOfficialAlert != $1.isOfficialAlert {
                return $0.isOfficialAlert && !$1.isOfficialAlert
            }

            if $0.candidate.relevanceScore != $1.candidate.relevanceScore {
                return $0.candidate.relevanceScore > $1.candidate.relevanceScore
            }

            switch ($0.alertExpiresAt, $1.alertExpiresAt) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            if $0.candidate.fireDate != $1.candidate.fireDate {
                return $0.candidate.fireDate < $1.candidate.fireDate
            }

            if $0.favoriteOrder != $1.favoriteOrder {
                return $0.favoriteOrder < $1.favoriteOrder
            }

            return $0.candidate.id < $1.candidate.id
        }

        AppLogger.log("[N1] favorites monitor scheduling allWinners=\(sortedWinners.count)")

        let localTimeZone = TimeZone.current
        var localCalendar = Calendar.current
        localCalendar.timeZone = localTimeZone

        for winningEntry in sortedWinners {
            let winner = winningEntry.candidate
            AppLogger.log("[N1] favorites monitor scheduled winner id=\(winner.id)")
            let targetKey = notificationTargetKey(for: monitoredFavorites[winningEntry.favoriteOrder])
            await coordinator.scheduleCandidateIfNeeded(
                winner,
                targetKey: targetKey,
                calendar: localCalendar,
                timeZone: localTimeZone,
                logPrefix: "favorites-monitor"
            )
        }
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
                issuedAt: $0.issuedAt,
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
