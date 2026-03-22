//
//  CurrentConditions.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation

struct CurrentConditions: Equatable {
    let temperatureC: Double

    /// “Feels like” temperature (Open-Meteo: `apparent_temperature`).
    let apparentTemperatureC: Double

    let windSpeedKph: Double
    /// Meteorological wind direction in degrees, where 0/360 = North, 90 = East.
    let windDirectionDegrees: Double

    /// Relative humidity (0–100).
    let humidityPercent: Double

    /// Sea-level pressure.
    let pressureKPa: Double

    /// Dew point (Open-Meteo: `dew_point_2m`).
    let dewPointC: Double

    let conditionText: String
    let symbolName: String

    /// 16-point compass direction (N, NNE, NE, ...)
    var windCompass: String {
        CurrentConditions.compassPoint(fromDegrees: windDirectionDegrees)
    }

    /// Convenience string used by UI, e.g. "NW 24 km/h".
    var windDisplay: String {
        "\(windCompass) \(Int(round(windSpeedKph))) km/h"
    }



    static func compassPoint(fromDegrees degrees: Double) -> String {
        // Normalize to 0..<360
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let dirs = [
            "N", "NNE", "NE", "ENE",
            "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW",
            "W", "WNW", "NW", "NNW"
        ]
        let idx = Int((d / 22.5).rounded()) % dirs.count
        return dirs[idx]
    }
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
