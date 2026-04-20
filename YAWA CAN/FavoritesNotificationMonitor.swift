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

    private func bestAlertForNotification(from alerts: [WeatherAlert]) -> WeatherAlert? {
        alerts.sorted { lhs, rhs in
            let lhsSeverity = severityRank(for: lhs)
            let rhsSeverity = severityRank(for: rhs)
            if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity }

            let lhsCategory = categoryRank(for: lhs)
            let rhsCategory = categoryRank(for: rhs)
            if lhsCategory != rhsCategory { return lhsCategory > rhsCategory }

            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (l?, r?) where l != r:
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            switch (lhs.issuedAt, rhs.issuedAt) {
            case let (l?, r?) where l != r:
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.title < rhs.title
            }
        }.first
    }

    private func severityRank(for alert: WeatherAlert) -> Int {
        switch alert.severity.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "warning":
            return 4
        case "watch":
            return 3
        case "advisory":
            return 2
        case "statement":
            return 1
        default:
            return 0
        }
    }

    private func categoryRank(for alert: WeatherAlert) -> Int {
        let text = "\(alert.title) \(alert.severity)".lowercased()

        if text.contains("flood") { return 8 }
        if text.contains("freezing rain") || text.contains("ice") || text.contains("icy") || text.contains("winter") || text.contains("snow") || text.contains("blizzard") { return 7 }
        if text.contains("thunder") || text.contains("storm") { return 6 }
        if text.contains("wind") { return 5 }
        if text.contains("heat") { return 4 }
        if text.contains("cold") || text.contains("freeze") || text.contains("frost") { return 3 }
        if text.contains("air quality") || text.contains("smoke") { return 2 }
        if text.contains("fog") { return 1 }
        return 0
    }

    func evaluateFavorites(_ favorites: [MonitoredFavoriteLocation]) async {
        let monitoredFavorites = favorites
        guard !monitoredFavorites.isEmpty else {
            #if DEBUG
            AppLogger.log("[N1] favorites monitor: no favorites to evaluate")
            #endif
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
                    let coordinate = CLLocationCoordinate2D(
                        latitude: favorite.latitude,
                        longitude: favorite.longitude
                    )

                    let tightAlerts = try await alertService.fetchAlerts(
                        withDelta: 0.15,
                        for: coordinate,
                        countryCode: favorite.countryCode
                    )

                    let candidateAlerts: [WeatherAlert]
                    if tightAlerts.isEmpty {
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor no alerts in tight range for \(favorite.displayName) (Δ0.15) — widening to Δ0.75")
                        #endif
                        candidateAlerts = try await alertService.fetchAlerts(
                            withDelta: 0.75,
                            for: coordinate,
                            countryCode: favorite.countryCode
                        )
                    } else {
                        candidateAlerts = tightAlerts
                    }

                    if candidateAlerts.isEmpty {
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor no Canada alerts found for \(favorite.displayName)")
                        #endif
                    }

                    topAlert = bestAlertForNotification(from: candidateAlerts)

                    if let topAlert {
                        let expiresText = topAlert.expiresAt?.description ?? "nil"
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor selected top alert for \(favorite.displayName): title=\(topAlert.title) severity=\(topAlert.severity) expiresAt=\(expiresText)")
                        #endif
                    } else {
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor top alert unavailable for \(favorite.displayName)")
                        #endif
                    }
                } else {
                    topAlert = nil
                }

                guard let snapshot = makeSnapshot(
                    weather: weather,
                    location: favorite,
                    alert: topAlert
                ) else {
                    #if DEBUG
                    AppLogger.log("[N1] favorites monitor: snapshot unavailable for \(favorite.displayName)")
                    #endif
                    continue
                }

                let prefs = NotificationStore().loadPreferences()
                #if DEBUG
                AppLogger.log("[N1] favorites monitor prefs for \(favorite.displayName): forecastAlertsEnabled=\(prefs.forecastAlertsEnabled)")
                #endif
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
                    #if DEBUG
                    AppLogger.log("[N1] favorites monitor candidates for \(favorite.displayName): \(candidates.map { $0.id })")
                    #endif
                }

                if candidates.isEmpty {
                    if !prefs.forecastAlertsEnabled {
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor no candidates for \(favorite.displayName): forecastAlertsEnabled=false")
                        #endif
                    } else if topAlert == nil {
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor no candidates for \(favorite.displayName): no qualifying alert summary attached")
                        #endif
                    } else {
                        #if DEBUG
                        AppLogger.log("[N1] favorites monitor no candidates for \(favorite.displayName): selected alert did not qualify for notableForecast")
                        #endif
                    }
                }

                let evaluatedCandidates = candidates.map {
                    EvaluatedFavoriteCandidate(
                        candidate: $0,
                        alertExpiresAt: topAlert?.expiresAt,
                        favoriteOrder: favoriteOrder
                    )
                }

                for entry in evaluatedCandidates {
                    #if DEBUG
                    AppLogger.log("[N1] favorites monitor candidate detail id=\(entry.candidate.id) score=\(entry.candidate.relevanceScore) fireDate=\(entry.candidate.fireDate) expiresAt=\(entry.alertExpiresAt?.description ?? "nil") favoriteOrder=\(entry.favoriteOrder)")
                    #endif
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

                    #if DEBUG
                    AppLogger.log("[N1] favorites monitor local winner id=\(winner.id)")
                    #endif
                    #if DEBUG
                    AppLogger.log("[N1] favorites monitor local winner officialAlert=\(winningEntry.isOfficialAlert)")
                    #endif
                    #if DEBUG
                    AppLogger.log("[N1] favorites monitor local winner location=\(winner.locationName) favoriteOrder=\(winningEntry.favoriteOrder) expiresAt=\(winningEntry.alertExpiresAt?.description ?? "nil")")
                    #endif

                    localWinners.append(winningEntry)
                }
            } catch {
                #if DEBUG
                AppLogger.log("[N1] favorites monitor error for \(favorite.displayName): \(error.localizedDescription)")
                #endif
            }
        }

        if !didFindAnyCandidates {
            #if DEBUG
            AppLogger.log("[N1] favorites monitor: no candidates")
            #endif
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

        #if DEBUG
        AppLogger.log("[N1] favorites monitor scheduling allWinners=\(sortedWinners.count)")
        #endif

        let localTimeZone = TimeZone.current
        var localCalendar = Calendar.current
        localCalendar.timeZone = localTimeZone

        for winningEntry in sortedWinners {
            let winner = winningEntry.candidate
            #if DEBUG
            AppLogger.log("[N1] favorites monitor scheduled winner id=\(winner.id)")
            #endif
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
