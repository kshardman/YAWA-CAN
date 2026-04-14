//
//  OpenMeteoWeatherService.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation
import CoreLocation

// MARK: - Shared URLSession with tighter timeouts

private let openMeteoSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest  = 15
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
}()

// MARK: - Static date formatters (DateFormatter is expensive to init)

private let openMeteoDateTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return f
}()

struct OpenMeteoWeatherService: WeatherServiceProtocol {

    func fetchWeather(
        coordinate: CLLocationCoordinate2D,
        locationName: String?,
        forecastDays: Int = 7
    ) async throws -> WeatherSnapshot {

        let days = (forecastDays >= 10) ? 10 : 7
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",  value: String(coordinate.latitude)),
            .init(name: "longitude", value: String(coordinate.longitude)),
            .init(name: "current",   value: "temperature_2m,apparent_temperature,dew_point_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m,weather_code,cloud_cover"),
            .init(name: "hourly",    value: "temperature_2m,precipitation_probability,weather_code,cloud_cover"),
            .init(name: "daily",     value: "sunrise,sunset,temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code,cloud_cover_mean,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant"),
            .init(name: "forecast_days",       value: String(days)),
            .init(name: "timezone",            value: "auto"),
            .init(name: "temperature_unit",    value: "celsius"),
            .init(name: "wind_speed_unit",     value: "kmh"),
            .init(name: "precipitation_unit",  value: "mm")
        ]

        guard let url = comps.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await openMeteoSession.data(from: url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)

        let name = locationName ?? "Unknown"

        // Current
        let code = decoded.current.weather_code
        let mapped = mapWeather(code: code)
        let refinedCurrent = refineCurrentSky(
            mapped: mapped,
            weatherCode: code,
            cloudCoverPercent: decoded.current.cloud_cover,
            temperatureC: decoded.current.temperature_2m
        )

        let pressureKPa = decoded.current.pressure_msl / 10.0

        let current = CurrentConditions(
            temperatureC: decoded.current.temperature_2m,
            apparentTemperatureC: decoded.current.apparent_temperature,
            windSpeedKph: decoded.current.wind_speed_10m,
            windDirectionDegrees: decoded.current.wind_direction_10m,
            humidityPercent: Double(decoded.current.relative_humidity_2m),
            pressureKPa: pressureKPa,
            dewPointC: decoded.current.dew_point_2m,
            conditionText: refinedCurrent.text,
            symbolName: refinedCurrent.symbol
        )

        let daily = makeDaily(decoded, maxDays: days)

        let hourlyTimes  = decoded.hourly.time
        let hourlyTemps  = decoded.hourly.temperature_2m
        let hourlyCodes  = decoded.hourly.weather_code
        let hourlyPrecip = decoded.hourly.precipitation_probability

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
            hourlyTimeISO: hourlyTimes,
            hourlyWeatherCodes: hourlyCodes,
            hourlyPrecipChancePercent: hourlyPrecip,
            sun: sun
        )
    }

    private func parseOpenMeteoDateTime(_ s: String, timeZoneID: String) -> Date? {
        openMeteoDateTimeFormatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return openMeteoDateTimeFormatter.date(from: s)
    }
    
    // MARK: - Mapping + builders

    private func roundPrecipToNearest10(_ value: Int?) -> Int {
        let v = value ?? 0
        // round to nearest 10
        let rounded = Int((Double(v) / 10.0).rounded() * 10.0)
        return min(100, max(0, rounded))
    }

    private func makeDaily(_ decoded: OpenMeteoResponse, maxDays: Int) -> [DailyForecastDay] {
        let times          = decoded.daily.time
        let highs          = decoded.daily.temperature_2m_max
        let lows           = decoded.daily.temperature_2m_min
        let pops           = decoded.daily.precipitation_probability_max
        let codes          = decoded.daily.weather_code
        let clouds         = decoded.daily.cloud_cover_mean
        let windSpeeds     = decoded.daily.wind_speed_10m_max
        let gusts          = decoded.daily.wind_gusts_10m_max
        let windDirections = decoded.daily.wind_direction_10m_dominant
        let sunrises       = decoded.daily.sunrise
        let sunsets        = decoded.daily.sunset

        let available = min(times.count, highs.count, lows.count, pops.count, codes.count,
                            clouds.count, windSpeeds.count, gusts.count, windDirections.count,
                            sunrises.count, sunsets.count)
        let count = min(available, max(1, maxDays))

        let tz = TimeZone(identifier: decoded.timezone) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        // Parse all hourly dates once — avoids re-parsing 168 strings per day (O(n²) → O(n)).
        let hourlyDates: [Date] = decoded.hourly.time.compactMap {
            parseOpenMeteoDateTime($0, timeZoneID: decoded.timezone)
        }

        return (0..<count).compactMap { i in
            let parts = times[i].split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }

            var comps = DateComponents()
            comps.calendar = cal
            comps.timeZone = tz
            comps.year  = parts[0]
            comps.month = parts[1]
            comps.day   = parts[2]
            comps.hour = 12; comps.minute = 0; comps.second = 0

            guard let date = cal.date(from: comps) else { return nil }

            let precipChance = roundPrecipToNearest10(pops[i])

            // Find the hourly entry closest to noon for this day.
            let noonCodeAndCloud: (code: Int, cloud: Int?) = {
                var bestIndex: Int?
                var bestDistance: TimeInterval = .greatestFiniteMagnitude

                for (idx, hourlyDate) in hourlyDates.enumerated() {
                    guard cal.isDate(hourlyDate, inSameDayAs: date) else { continue }
                    let distance = abs(hourlyDate.timeIntervalSince(date))
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = idx
                    }
                }

                if let idx = bestIndex,
                   idx < decoded.hourly.weather_code.count,
                   idx < decoded.hourly.cloud_cover.count {
                    return (decoded.hourly.weather_code[idx], decoded.hourly.cloud_cover[idx])
                }
                return (codes[i], Int(clouds[i].rounded()))
            }()

            let mapped = mapWeather(code: noonCodeAndCloud.code)
            let refinedDaily = refineDailySky(
                mapped: mapped,
                weatherCode: noonCodeAndCloud.code,
                precipChancePercent: precipChance,
                cloudCoverPercent: noonCodeAndCloud.cloud ?? Int(clouds[i].rounded()),
                highC: highs[i]
            )

            return DailyForecastDay(
                date: date,
                highC: highs[i],
                lowC: lows[i],
                precipChancePercent: precipChance,
                windSpeedKPH: windSpeeds[i],
                windGustKPH: gusts[i],
                windDirectionDegrees: windDirections[i],
                sunrise: parseOpenMeteoDateTime(sunrises[i], timeZoneID: decoded.timezone),
                sunset:  parseOpenMeteoDateTime(sunsets[i],  timeZoneID: decoded.timezone),
                symbolName:    refinedDaily.symbol,
                conditionText: refinedDaily.text
            )
        }
    }

    private func refineCurrentSky(
        mapped: (symbol: String, text: String),
        weatherCode: Int,
        cloudCoverPercent: Int?,
        temperatureC: Double
    ) -> (symbol: String, text: String) {
        let isFreezing = temperatureC <= 0

        switch weatherCode {
        case 0, 1, 2, 3:
            // Basic sky — refine by cloud cover, no precip correction needed.
            guard let cloud = cloudCoverPercent else { return mapped }

            if cloud <= 15 {
                return ("sun.max.fill", "Clear")
            } else if cloud <= 40 {
                return ("sun.max.fill", "Mostly clear")
            } else if cloud <= 70 {
                return ("cloud.sun.fill", "Partly cloudy")
            } else {
                return ("cloud.fill", "Mostly cloudy")
            }

        case 51, 53, 55:
            // Drizzle — remap to freezing drizzle when at or below 0°C.
            guard isFreezing else { return mapped }
            return (mapped.symbol, weatherCode == 51 ? "Light freezing drizzle" : "Freezing drizzle")

        case 61, 63, 65:
            // Rain — remap to snow when at or below 0°C.
            guard isFreezing else { return mapped }
            switch weatherCode {
            case 61: return ("cloud.snow.fill", "Light snow")
            case 65: return ("cloud.snow.fill", "Heavy snow")
            default: return ("cloud.snow.fill", "Snow")
            }

        case 80, 81, 82:
            // Rain showers — remap to snow showers when at or below 0°C.
            guard isFreezing else { return mapped }
            switch weatherCode {
            case 80: return ("cloud.snow.fill", "Light snow showers")
            case 82: return ("cloud.snow.fill", "Heavy snow showers")
            default: return ("cloud.snow.fill", "Snow showers")
            }

        default:
            return mapped
        }
    }

    private func refineDailySky(
        mapped: (symbol: String, text: String),
        weatherCode: Int,
        precipChancePercent: Int,
        cloudCoverPercent: Int?,
        highC: Double
    ) -> (symbol: String, text: String) {
        // Choose the right precip type based on temperature.
        let isFreezing = highC <= 0
        let likelySymbol = isFreezing ? "cloud.snow.fill"      : "cloud.rain.fill"
        let likelyText   = isFreezing ? "Snow likely"          : "Rain likely"
        let possibleText = isFreezing ? "Snow possible"        : "Rain possible"

        // High daily precip chance should override misleading sun/clear presentation.
        if precipChancePercent >= 80 {
            return (likelySymbol, likelyText)
        }

        // Keep active precip/fog/thunder wording when conditions are meaningful.
        switch weatherCode {
        case 45, 48, 56, 57, 66, 67, 71, 73, 75, 77, 85, 86, 95, 96, 99:
            return mapped

        case 51, 53, 55, 61, 63, 65, 80, 81, 82:
            // If precip chance is low, let cloud cover soften overly pessimistic sky wording.
            guard precipChancePercent < 30, let cloud = cloudCoverPercent else { return mapped }

            if cloud <= 15 {
                return ("sun.max.fill", "Clear")
            } else if cloud <= 40 {
                return ("sun.max.fill", "Mostly clear")
            } else if cloud <= 70 {
                return ("cloud.sun.fill", "Partly cloudy")
            } else {
                return ("cloud.fill", "Mostly cloudy")
            }

        case 0, 1, 2, 3:
            if precipChancePercent >= 60 {
                return (likelySymbol, possibleText)
            }

            guard let cloud = cloudCoverPercent else { return mapped }

            if cloud <= 12 {
                return ("sun.max.fill", "Clear")
            } else if cloud <= 37 {
                return ("sun.max.fill", "Mostly clear")
            } else if cloud <= 62 {
                return ("cloud.sun.fill", "Partly cloudy")
            } else {
                return ("cloud.fill", "Mostly cloudy")
            }

        default:
            return mapped
        }
    }

    private func mapWeather(code: Int) -> (symbol: String, text: String) {
        // WMO weather codes (Open-Meteo uses these)
        switch code {
        case 0: return ("sun.max.fill", "Clear")
        case 1: return ("sun.max.fill", "Mostly clear")
        case 2: return ("cloud.sun.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Mostly cloudy")

        case 45: return ("cloud.fog.fill", "Foggy")
        case 48: return ("cloud.fog.fill", "Rime fog")

        case 51: return ("cloud.drizzle.fill", "Light drizzle")
        case 53: return ("cloud.drizzle.fill", "Drizzle")
        case 55: return ("cloud.drizzle.fill", "Heavy drizzle")
        case 56: return ("cloud.drizzle.fill", "Light freezing drizzle")
        case 57: return ("cloud.drizzle.fill", "Freezing drizzle")

        case 61: return ("cloud.rain.fill", "Light rain")
        case 63: return ("cloud.rain.fill", "Rain")
        case 65: return ("cloud.rain.fill", "Heavy rain")
        case 66: return ("cloud.rain.fill", "Light freezing rain")
        case 67: return ("cloud.rain.fill", "Freezing rain")

        case 71: return ("cloud.snow.fill", "Light snow")
        case 73: return ("cloud.snow.fill", "Snow")
        case 75: return ("cloud.snow.fill", "Heavy snow")
        case 77: return ("cloud.snow.fill", "Snow grains")

        case 80: return ("cloud.heavyrain.fill", "Light showers")
        case 81: return ("cloud.heavyrain.fill", "Showers")
        case 82: return ("cloud.heavyrain.fill", "Heavy showers")
        case 85: return ("cloud.snow.fill", "Light snow showers")
        case 86: return ("cloud.snow.fill", "Snow showers")

        case 95: return ("cloud.bolt.rain.fill", "Thunderstorm")
        case 96: return ("cloud.bolt.rain.fill", "Thunderstorm with hail")
        case 99: return ("cloud.bolt.rain.fill", "Thunderstorm with hail")

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
        let cloud_cover: Int?
    }

    struct Hourly: Decodable {
        let time: [String]
        let temperature_2m: [Double]
        let precipitation_probability: [Double]
        let weather_code: [Int]
        let cloud_cover: [Int?]
    }

    struct Daily: Decodable {
        let time: [String]
        let sunrise: [String]
        let sunset: [String]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int?]
        let weather_code: [Int]
        let cloud_cover_mean: [Double]
        let wind_speed_10m_max: [Double]
        let wind_gusts_10m_max: [Double]
        let wind_direction_10m_dominant: [Double]
    }
}

