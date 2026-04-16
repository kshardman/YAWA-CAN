//
//  NotificationPreferences.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/26/26.
//


import Foundation

struct NotificationPreferences: Codable, Equatable {
    var forecastAlertsEnabled: Bool
    var hasSeenEducation: Bool

    static let `default` = NotificationPreferences(
        forecastAlertsEnabled: true,
        hasSeenEducation: false
    )
}
