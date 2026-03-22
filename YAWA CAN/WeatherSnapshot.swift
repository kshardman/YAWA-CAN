//
//  WeatherSnapshot.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation

struct WeatherSnapshot: Equatable {
    let timeZoneID: String
    let current: CurrentConditions
    let daily: [DailyForecastDay]
    let hourlyTempsC: [Double]
    let hourlyTimeISO: [String]
    let hourlyPrecipChancePercent: [Double]
    let sun: SunTimes?
}

