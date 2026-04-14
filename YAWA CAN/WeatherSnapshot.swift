//
//  WeatherSnapshot.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation

struct WeatherSnapshot: Codable, Equatable {
    let timeZoneID: String
    let locationName: String
    let current: CurrentConditions
    let daily: [DailyForecastDay]
    let hourlyTempsC: [Double]
    let hourlyTimeISO: [String]
    let hourlyWeatherCodes: [Int]
    let hourlyPrecipChancePercent: [Double]
    let sun: SunTimes?

    init(
        locationName: String,
        timeZoneID: String,
        current: CurrentConditions,
        daily: [DailyForecastDay],
        hourlyTempsC: [Double],
        hourlyTimeISO: [String],
        hourlyWeatherCodes: [Int],
        hourlyPrecipChancePercent: [Double],
        sun: SunTimes?
    ) {
        self.locationName = locationName
        self.timeZoneID = timeZoneID
        self.current = current
        self.daily = daily
        self.hourlyTempsC = hourlyTempsC
        self.hourlyTimeISO = hourlyTimeISO
        self.hourlyWeatherCodes = hourlyWeatherCodes
        self.hourlyPrecipChancePercent = hourlyPrecipChancePercent
        self.sun = sun
    }
}

