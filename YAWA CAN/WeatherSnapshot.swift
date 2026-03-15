//
//  WeatherSnapshot.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation

struct WeatherSnapshot: Equatable {
    let locationName: String
    /// IANA time zone identifier for the location (e.g., "America/Toronto").
    let timeZoneID: String

    let current: CurrentConditions
    let daily: [DailyForecastDay]
    let hourlyTempsC: [Double]
    let hourlyPrecipChancePercent: [Double]

    /// Sunrise/sunset for the day (when available from the data source).
    let sun: SunTimes?
}

// Optional convenience formatting (handy for the UI)
extension DailyForecastDay {
    var dayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "EEE"
        return f.string(from: date)
    }
}
