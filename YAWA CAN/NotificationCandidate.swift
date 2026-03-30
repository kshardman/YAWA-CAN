//
//  NotificationCandidate.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/26/26.
//

import Foundation

enum NotableForecastCategory: String, Codable, Hashable {
    case flooding
    case winterWeather
    case wind
    case thunder
    case heat
    case cold
    case airQuality
    case fog
    case specialStatement
    case unknown
}

enum AlertSeverityClass: String, Codable, Hashable {
    case statement
    case advisory
    case watch
    case warning
}

struct NotificationCandidate: Equatable, Hashable {
    enum Kind: String, Codable {
        case precipSoon
        case windyTomorrow
        case notableForecast
    }

    let id: String
    let kind: Kind
    let title: String
    let body: String
    let fireDate: Date
    let relevanceScore: Int
    let locationName: String
    let locationLatitude: Double
    let locationLongitude: Double
    let targetDateISO: String?
    let notableCategory: NotableForecastCategory?
    let severityClass: AlertSeverityClass?
    let sourceHeadline: String?
}
