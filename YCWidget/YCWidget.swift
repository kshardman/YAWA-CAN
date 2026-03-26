//
//  YCWidget.swift
//  YCWidget
//
//  Created by Keith Sharman on 3/26/26.
//

import WidgetKit
import SwiftUI

private enum YCWidgetStorage {
    static let appGroupID = "group.com.widgetal.yawacan"
    static let weatherSnapshotKey = "yc.widget.weatherSnapshot"
}

struct YCWidgetEntry: TimelineEntry {
    let date: Date
    let payload: WidgetWeatherPayload
}

struct WidgetWeatherPayload {
    struct HourPoint: Hashable {
        let timeLabel: String
        let temperatureText: String
        let symbolName: String
        let isNow: Bool
    }

    let locationName: String
    let temperatureText: String
    let conditionText: String
    let symbolName: String
    let highText: String
    let lowText: String
    let hourly: [HourPoint]
    let isPlaceholder: Bool

    static let placeholder = WidgetWeatherPayload(
        locationName: "Yawa Canada",
        temperatureText: "12°",
        conditionText: "Cloudy",
        symbolName: "cloud.fill",
        highText: "16°",
        lowText: "7°",
        hourly: [
            HourPoint(timeLabel: "12 PM", temperatureText: "12°", symbolName: "cloud.fill", isNow: false),
            HourPoint(timeLabel: "3 PM", temperatureText: "13°", symbolName: "cloud.fill", isNow: false),
            HourPoint(timeLabel: "6 PM", temperatureText: "11°", symbolName: "cloud.fill", isNow: false)
        ],
        isPlaceholder: true
    )
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> YCWidgetEntry {
        YCWidgetEntry(date: Date(), payload: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (YCWidgetEntry) -> Void) {
        let payload = loadPayload() ?? .placeholder
        completion(YCWidgetEntry(date: Date(), payload: payload))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<YCWidgetEntry>) -> Void) {
        let entry = YCWidgetEntry(date: Date(), payload: loadPayload() ?? .placeholder)
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private func loadPayload() -> WidgetWeatherPayload? {
        guard let defaults = UserDefaults(suiteName: YCWidgetStorage.appGroupID) else {
            return nil
        }
        guard let data = defaults.data(forKey: YCWidgetStorage.weatherSnapshotKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let snapshot = try? decoder.decode(WeatherSnapshot.self, from: data) else {
            return nil
        }

        return WidgetWeatherPayload(snapshot: snapshot)
    }
}

private extension WidgetWeatherPayload {
    init(snapshot: WeatherSnapshot) {
        self.locationName = Self.shortLocationName(from: snapshot.locationName)
        self.temperatureText = Self.tempText(from: snapshot.current.temperatureC, locationName: snapshot.locationName)
        self.conditionText = snapshot.current.conditionText
        self.symbolName = Self.currentSymbolName(from: snapshot)
        self.highText = Self.tempText(from: snapshot.daily.first?.highC, locationName: snapshot.locationName)
        self.lowText = Self.tempText(from: snapshot.daily.first?.lowC, locationName: snapshot.locationName)
        self.hourly = Self.hourlyPoints(from: snapshot)
        self.isPlaceholder = false
    }

    static func tempText(from value: Double?, locationName: String?) -> String {
        guard let value else { return "--°" }

        let useFahrenheit = usesFahrenheit(for: locationName)
        let temp: Double = useFahrenheit ? ((value * 9.0 / 5.0) + 32.0) : value
        return "\(Int(temp.rounded()))°"
    }

    static func usesFahrenheit(for locationName: String?) -> Bool {
        guard let locationName, !locationName.isEmpty else { return false }

        let upper = locationName.uppercased()
        let usStateTokens: Set<String> = [
            "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN","IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT","VT","VA","WA","WV","WI","WY","DC"
        ]

        let parts = upper
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let last = parts.last {
            if usStateTokens.contains(last) { return true }
            if last == "USA" || last == "UNITED STATES" || last == "UNITED STATES OF AMERICA" { return true }
        }

        return false
    }

    static func shortLocationName(from full: String?) -> String {
        guard let full, !full.isEmpty else { return "Location" }
        let first = full.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (first?.isEmpty == false) ? first! : full
    }

    static func widgetCalendar(timeZoneID: String?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZoneID, let tz = TimeZone(identifier: timeZoneID) {
            calendar.timeZone = tz
        }
        return calendar
    }

    static func hourlyPoints(from snapshot: WeatherSnapshot) -> [HourPoint] {
        let triples = Array(zip(zip(snapshot.hourlyTimeISO, snapshot.hourlyTempsC), snapshot.hourlyWeatherCodes))
        guard !triples.isEmpty else { return [] }

        let now = Date()
        let indexedDates = triples.enumerated().compactMap { index, triple -> (Int, Date)? in
            let ((iso, _), _) = triple
            guard let date = parsedDate(from: iso, timeZoneID: snapshot.timeZoneID) else { return nil }
            return (index, date)
        }
        guard !indexedDates.isEmpty else { return [] }

        let baseIndex: Int = {
            if let firstFuture = indexedDates.first(where: { $0.1 >= now }) {
                return firstFuture.0
            }
            return indexedDates.min(by: { abs($0.1.timeIntervalSince(now)) < abs($1.1.timeIntervalSince(now)) })?.0 ?? 0
        }()

        let alignedIndex: Int = {
            let calendar = widgetCalendar(timeZoneID: snapshot.timeZoneID)
            let baseDate = indexedDates.first(where: { $0.0 == baseIndex })?.1 ?? now
            let hour = calendar.component(.hour, from: baseDate)
            let remainder = hour % 3
            let delta = remainder == 0 ? 0 : (3 - remainder)
            let targetHour = (hour + delta) % 24

            if let aligned = indexedDates.first(where: { $0.0 >= baseIndex && calendar.component(.hour, from: $0.1) == targetHour }) {
                return aligned.0
            }
            return baseIndex
        }()

        let selectedIndices = [alignedIndex, alignedIndex + 3, alignedIndex + 6].filter { $0 < triples.count }

        return selectedIndices.map { index in
            let ((iso, temp), code) = triples[index]
            let date = parsedDate(from: iso, timeZoneID: snapshot.timeZoneID)
            return HourPoint(
                timeLabel: hourLabel(from: iso, useNowLabel: false, timeZoneID: snapshot.timeZoneID),
                temperatureText: tempText(from: temp, locationName: snapshot.locationName),
                symbolName: polishedHourlySymbolName(for: code, at: date, sun: snapshot.sun),
                isNow: false
            )
        }
    }

    static func parsedDate(from isoString: String, timeZoneID: String? = nil) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        if let timeZoneID, let tz = TimeZone(identifier: timeZoneID) {
            localFormatter.timeZone = tz
        }

        return formatter.date(from: isoString)
            ?? fallbackFormatter.date(from: isoString)
            ?? localFormatter.date(from: isoString)
    }

    static func currentSymbolName(from snapshot: WeatherSnapshot) -> String {
        let now = Date()
        let isNight: Bool = {
            guard let sun = snapshot.sun else { return false }
            return now < sun.sunrise || now >= sun.sunset
        }()

        switch snapshot.current.symbolName {
        case "sun.max.fill":
            return isNight ? "moon.stars.fill" : "sun.max.fill"
        case "cloud.sun.fill":
            return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case "cloud.sun.rain.fill":
            return isNight ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill"
        case "cloud.fill":
            return isNight ? "cloud.moon.fill" : "cloud.fill"
        default:
            return snapshot.current.symbolName
        }
    }

    static func polishedHourlySymbolName(for code: Int, at date: Date?, sun: SunTimes?) -> String {
        switch symbolName(for: code, at: date, sun: sun) {
        case "sun.max.fill":
            return "sun.max.fill"
        case "moon.stars.fill":
            return "moon.stars.fill"
        case "cloud.fill":
            return "cloud.fill"
        case "cloud.sun.fill":
            return "cloud.sun.fill"
        case "cloud.moon.fill":
            return "cloud.moon.fill"
        case "cloud.sun.rain.fill":
            return "cloud.sun.rain.fill"
        case "cloud.moon.rain.fill":
            return "cloud.moon.rain.fill"
        default:
            return symbolName(for: code, at: date, sun: sun)
        }
    }

    static func symbolName(for code: Int, at date: Date?, sun: SunTimes?) -> String {
        let isNight: Bool = {
            guard let date, let sun else { return false }
            return date < sun.sunrise || date >= sun.sunset
        }()

        switch code {
        case 0:
            return isNight ? "moon.stars.fill" : "sun.max.fill"
        case 1:
            return isNight ? "moon.stars.fill" : "sun.max.fill"
        case 2:
            return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55, 56, 57:
            return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82:
            return isNight ? "cloud.moon.rain.fill" : "cloud.sun.rain.fill"
        case 71, 73, 75, 77, 85, 86:
            return "cloud.snow.fill"
        case 95, 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return isNight ? "cloud.moon.fill" : "cloud.fill"
        }
    }

    static func hourLabel(from isoString: String, useNowLabel: Bool, timeZoneID: String? = nil) -> String {
        let date = parsedDate(from: isoString, timeZoneID: timeZoneID)

        guard let date else {
            return useNowLabel ? "Now" : "--"
        }

        if useNowLabel {
            return "Now"
        }

        let out = DateFormatter()
        out.dateFormat = "ha"
        if let timeZoneID, let tz = TimeZone(identifier: timeZoneID) {
            out.timeZone = tz
        }
        return out.string(from: date)
            .replacingOccurrences(of: "AM", with: " AM")
            .replacingOccurrences(of: "PM", with: " PM")
    }
}

struct YCWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var entry: YCWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.payload.locationName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(YAWATheme.widgetSecondaryTextColor(for: colorScheme))
                .lineLimit(1)

            Spacer(minLength: 6)

            HStack(alignment: .center, spacing: 8) {
                Image(systemName: entry.payload.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
                    .foregroundStyle(YAWATheme.symbolColor(entry.payload.symbolName, scheme: colorScheme))

                Text(entry.payload.temperatureText)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(YAWATheme.widgetPrimaryTempColor(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 6)

            Text(entry.payload.conditionText)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 8) {
                Text("H \(entry.payload.highText)")
                Text("L \(entry.payload.lowText)")
            }
            .font(.caption)
            .foregroundStyle(YAWATheme.widgetSecondaryTextColor(for: colorScheme))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetCardBackground(colorScheme: colorScheme)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.payload.locationName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(YAWATheme.widgetSecondaryTextColor(for: colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 6)

                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: entry.payload.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .font(.title2)
                        .foregroundStyle(YAWATheme.symbolColor(entry.payload.symbolName, scheme: colorScheme))

                    Text(entry.payload.temperatureText)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(YAWATheme.widgetPrimaryTempColor(for: colorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer(minLength: 6)

                Text(entry.payload.conditionText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(YAWATheme.textPrimary(for: colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 8) {
                    Text("H \(entry.payload.highText)")
                    Text("L \(entry.payload.lowText)")
                }
                .font(.caption)
                .foregroundStyle(YAWATheme.widgetSecondaryTextColor(for: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(YAWATheme.widgetDividerColor(for: colorScheme).opacity(0.30))
                .frame(width: 1)
                .padding(.vertical, 14)

            HStack(spacing: 12) {
                ForEach(entry.payload.hourly, id: \.self) { hour in
                    VStack(spacing: 6) {
                        Text(hour.timeLabel)
                            .font(.caption2)
                            .foregroundStyle(YAWATheme.widgetSecondaryTextColor(for: colorScheme).opacity(colorScheme == .dark ? 0.96 : 0.92))

                        Image(systemName: hour.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .font(.subheadline)
                            .frame(height: 18)
                            .foregroundStyle(YAWATheme.symbolColor(hour.symbolName, scheme: colorScheme).opacity(colorScheme == .dark ? 0.95 : 0.91))

                        Text(hour.temperatureText)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(YAWATheme.widgetSecondaryTextColor(for: colorScheme).opacity(colorScheme == .dark ? 0.98 : 0.94))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .offset(y: 3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetCardBackground(colorScheme: colorScheme)
    }
}

private extension View {
    @ViewBuilder
    func widgetCardBackground(colorScheme: ColorScheme) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(YAWATheme.widgetBackground(for: colorScheme), for: .widget)
        } else {
            self.background(YAWATheme.widgetBackground(for: colorScheme))
        }
    }
}

struct YCWidget: Widget {
    let kind: String = "YCWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            YCWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Current Weather")
        .description("Shows current conditions and a compact forecast.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    YCWidget()
} timeline: {
    YCWidgetEntry(date: .now, payload: .placeholder)
}

#Preview(as: .systemMedium) {
    YCWidget()
} timeline: {
    YCWidgetEntry(date: .now, payload: .placeholder)
}
