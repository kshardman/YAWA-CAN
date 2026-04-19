//
//  WeatherSnapshot.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation

// MARK: - Air Quality

struct AirQualityData: Codable, Equatable {
    let usAQI: Int
    let category: String
    let categoryColor: AQIColor
    let pm25: Double?

    enum AQIColor: String, Codable {
        case green, yellow, orange, red, purple, maroon
    }

    static func from(usAQI: Int, pm25: Double?) -> AirQualityData {
        let (category, color): (String, AQIColor) = {
            switch usAQI {
            case 0...50:   return ("Good", .green)
            case 51...100: return ("Moderate", .yellow)
            case 101...150: return ("Unhealthy for Sensitive Groups", .orange)
            case 151...200: return ("Unhealthy", .red)
            case 201...300: return ("Very Unhealthy", .purple)
            default:        return ("Hazardous", .maroon)
            }
        }()
        return AirQualityData(usAQI: usAQI, category: category, categoryColor: color, pm25: pm25)
    }
}

// MARK: - WeatherSnapshot

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
    let airQuality: AirQualityData?

    init(
        locationName: String,
        timeZoneID: String,
        current: CurrentConditions,
        daily: [DailyForecastDay],
        hourlyTempsC: [Double],
        hourlyTimeISO: [String],
        hourlyWeatherCodes: [Int],
        hourlyPrecipChancePercent: [Double],
        sun: SunTimes?,
        airQuality: AirQualityData? = nil
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
        self.airQuality = airQuality
    }
}
