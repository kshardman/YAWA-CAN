//
//  StubWeatherService.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//


import Foundation
import CoreLocation

struct StubWeatherService: WeatherServiceProtocol {

    func fetchWeather(
        coordinate: CLLocationCoordinate2D,
        locationName: String?
    ) async throws -> WeatherSnapshot {

        // Simulate network latency so loading states are testable
        try? await Task.sleep(nanoseconds: 250_000_000)

        let name = locationName ?? "Toronto, ON"

        let current = CurrentConditions(
            temperatureC: 7.0,
            apparentTemperatureC: 5.0,
            windSpeedKph: 18.0,
            windDirectionDegrees: 315,
            humidityPercent: 62,
            pressureKPa: 101.6,
            dewPointC: 1.0,
            conditionText: "Partly Cloudy",
            symbolName: "cloud.sun.fill"
        )

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let daily: [DailyForecastDay] = (0..<7).map { offset in
            let date = cal.date(byAdding: .day, value: offset, to: today)!
            // simple believable pattern
            let high = 6.0 + Double((offset % 4) * 2)
            let low  = high - 6.0
            let pop  = [10, 20, 40, 60, 30, 15, 25][offset % 7]
            let sym  = pop >= 50 ? "cloud.rain.fill" : (offset % 2 == 0 ? "sun.max.fill" : "cloud.sun.fill")
            let text = pop >= 50 ? "Rain" : (sym == "sun.max.fill" ? "Sunny" : "Partly Cloudy")

            return DailyForecastDay(
                date: date,
                highC: high,
                lowC: low,
                precipChancePercent: pop,
                symbolName: sym,
                conditionText: text
            )
        }

        // 24-hour temps for the chart
        let hourlyTempsC: [Double] = (0..<24).map { h in
            // cool overnight, warmer afternoon
            let base = 3.0
            let swing = 6.0
            let t = base + swing * sin(Double(h) / 24.0 * 2.0 * Double.pi - Double.pi/2)
            return (t * 10).rounded() / 10
        }

        // Demo sunrise/sunset for the Sun card.
        let sunrise = cal.date(bySettingHour: 7, minute: 19, second: 0, of: today) ?? today.addingTimeInterval(7 * 3600)
        let sunset  = cal.date(bySettingHour: 18, minute: 55, second: 0, of: today) ?? today.addingTimeInterval(19 * 3600)
        let sun = SunTimes(sunrise: sunrise, sunset: sunset)

        return WeatherSnapshot(
            locationName: name,
            timeZoneID: TimeZone.current.identifier,
            current: current,
            daily: daily,
            hourlyTempsC: hourlyTempsC,
            sun: sun
        )
    }
}
