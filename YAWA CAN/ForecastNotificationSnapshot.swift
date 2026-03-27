//
//  ForecastNotificationSnapshot.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/26/26.
//


struct ForecastNotificationSnapshot: Codable, Equatable {
    struct HourlyPoint: Codable, Equatable {
        let timeISO: String
        let precipitationProbability: Double?
        let precipitationAmountMM: Double?
        let weatherCode: Int?
        let windSpeedKPH: Double?
        let windGustKPH: Double?
        let temperatureC: Double?
    }

    struct DailyPoint: Codable, Equatable {
        let dateISO: String
        let weatherCode: Int?
        let tempMinC: Double?
        let tempMaxC: Double?
        let precipitationProbabilityMax: Double?
        let precipitationAmountMM: Double?
        let windSpeedMaxKPH: Double?
        let windGustMaxKPH: Double?
    }

    let generatedAtISO: String
    let locationName: String
    let locationLatitude: Double
    let locationLongitude: Double
    let timezoneIdentifier: String

    let hourly: [HourlyPoint]
    let daily: [DailyPoint]
}