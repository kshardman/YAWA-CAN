//
//  CurrentConditions.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//


import Foundation

struct CurrentConditions: Equatable {
    let temperatureC: Double
    let windSpeedKph: Double
    let humidityPercent: Double
    let pressureKPa: Double
    let conditionText: String
    let symbolName: String
}

struct DailyForecastDay: Identifiable, Equatable {
    var id: Date { Calendar.current.startOfDay(for: date) }
    let date: Date
    let highC: Double
    let lowC: Double
    let precipChancePercent: Int
    let symbolName: String
    let conditionText: String
}

struct SunTimes: Equatable {
    let sunrise: Date
    let sunset: Date
}


