//
//  OpenMeteoWeatherService.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation
import CoreLocation

struct OpenMeteoWeatherService: WeatherServiceProtocol {

    func fetchWeather(
        coordinate: CLLocationCoordinate2D,
        locationName: String?,
        forecastDays: Int = 7
    ) async throws -> WeatherSnapshot {

        // Open-Meteo forecast endpoint (free)
        // Units: °C, km/h, precipitation mm (default), pressure comes back as hPa -> convert to kPa
        let days = (forecastDays >= 10) ? 10 : 7
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(coordinate.latitude)),
            .init(name: "longitude", value: String(coordinate.longitude)),

            // current conditions
            .init(name: "current", value: "temperature_2m,apparent_temperature,dew_point_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m,weather_code"),

            // hourly temps for chart
            .init(name: "hourly", value: "temperature_2m"),

            // daily forecast
            .init(name: "daily", value: "sunrise,sunset,temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),

            .init(name: "forecast_days", value: String(days)),
            .init(name: "timezone", value: "auto"),

            // enforce units
            .init(name: "temperature_unit", value: "celsius"),
            .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "precipitation_unit", value: "mm")
        ]

        let url = comps.url!
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        let name = locationName ?? "Unknown"

        // Current
        let code = decoded.current.weather_code
        let mapped = mapWeather(code: code)

        let pressureKPa = decoded.current.pressure_msl / 10.0 // hPa -> kPa

        let current = CurrentConditions(
            temperatureC: decoded.current.temperature_2m,
            apparentTemperatureC: decoded.current.apparent_temperature,
            windSpeedKph: decoded.current.wind_speed_10m,
            windDirectionDegrees: decoded.current.wind_direction_10m,
            humidityPercent: Double(decoded.current.relative_humidity_2m),
            pressureKPa: pressureKPa,
            dewPointC: decoded.current.dew_point_2m,
            conditionText: mapped.text,
            symbolName: mapped.symbol
        )

        // Daily (7/10)
        let daily = makeDaily(decoded, maxDays: days)

        // Hourly temps: keep the full hourly forecast range so the UI can slice by day.
        let hourlyTemps = decoded.hourly.temperature_2m

        let sun: SunTimes? = {
            guard
                let sr = decoded.daily.sunrise.first,
                let ss = decoded.daily.sunset.first,
                let sunrise = parseOpenMeteoDateTime(sr, timeZoneID: decoded.timezone),
                let sunset  = parseOpenMeteoDateTime(ss, timeZoneID: decoded.timezone)
            else { return nil }
            return SunTimes(sunrise: sunrise, sunset: sunset)
        }()
        
        return WeatherSnapshot(
            locationName: name,
            timeZoneID: decoded.timezone,
            current: current,
            daily: daily,
            hourlyTempsC: hourlyTemps,
            sun: sun
        )
    }

    private func parseOpenMeteoDateTime(_ s: String, timeZoneID: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return f.date(from: s)
    }
    
    // MARK: - Mapping + builders

    private func roundPrecipToNearest10(_ value: Int?) -> Int {
        let v = value ?? 0
        // round to nearest 10
        let rounded = Int((Double(v) / 10.0).rounded() * 10.0)
        return min(100, max(0, rounded))
    }

    private func makeDaily(_ decoded: OpenMeteoResponse, maxDays: Int) -> [DailyForecastDay] {
        let times = decoded.daily.time
        let highs = decoded.daily.temperature_2m_max
        let lows  = decoded.daily.temperature_2m_min
        let pops  = decoded.daily.precipitation_probability_max
        let codes = decoded.daily.weather_code

        let available = min(times.count, highs.count, lows.count, pops.count, codes.count)
        let count = min(available, max(1, maxDays))

        let tz = TimeZone(identifier: decoded.timezone) ?? .current

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = "yyyy-MM-dd"

        let cal = Calendar(identifier: .gregorian)

        return (0..<count).compactMap { i in
            guard let dayDate = df.date(from: times[i]) else { return nil }

            // Anchor at noon local time to avoid “yesterday” in other zones.
            let date = cal.date(bySettingHour: 12, minute: 0, second: 0, of: dayDate) ?? dayDate

            let mapped = mapWeather(code: codes[i])
            let precipChance = roundPrecipToNearest10(pops[i])

            let softenedConditionText: String
            switch codes[i] {
            case 51, 53, 55, 56, 57, 61, 63:
                softenedConditionText = precipChance < 30 ? "Mostly cloudy" : mapped.text
            case 80:
                softenedConditionText = precipChance < 30 ? "Partly cloudy" : mapped.text
            default:
                softenedConditionText = mapped.text
            }

            return DailyForecastDay(
                date: date,
                highC: highs[i],
                lowC: lows[i],
                precipChancePercent: precipChance,
                symbolName: mapped.symbol,
                conditionText: softenedConditionText
            )
        }
    }

    private func mapWeather(code: Int) -> (symbol: String, text: String) {
        // WMO weather codes (Open-Meteo uses these)
        switch code {
        case 0: return ("sun.max.fill", "Clear")
        case 1: return ("sun.max.fill", "Mostly clear")
        case 2: return ("cloud.sun.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Mostly cloudy")

        case 45, 48: return ("cloud.fog.fill", "Fog")

        case 51, 53, 55: return ("cloud.drizzle.fill", "Drizzle")
        case 56, 57: return ("cloud.drizzle.fill", "Freezing drizzle")

        case 61, 63, 65: return ("cloud.rain.fill", "Rain")
        case 66, 67: return ("cloud.rain.fill", "Freezing rain")

        case 71, 73, 75: return ("cloud.snow.fill", "Snow")
        case 77: return ("cloud.snow.fill", "Snow grains")

        case 80, 81, 82: return ("cloud.heavyrain.fill", "Rain showers")
        case 85, 86: return ("cloud.snow.fill", "Snow showers")

        case 95: return ("cloud.bolt.rain.fill", "Thunderstorm")
        case 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorm w/ hail")

        default: return ("cloud.fill", "Weather")
        }
    }
}

// MARK: - Open-Meteo response types

private struct OpenMeteoResponse: Decodable {
    let timezone: String
    let current: Current
    let hourly: Hourly
    let daily: Daily

    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let dew_point_2m: Double
        let relative_humidity_2m: Int
        let pressure_msl: Double
        let wind_speed_10m: Double
        let wind_direction_10m: Double
        let weather_code: Int
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double]
    }

    struct Daily: Decodable {
        let time: [String]
        let sunrise: [String]
        let sunset: [String]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int?]
        let weather_code: [Int]
    }
}
