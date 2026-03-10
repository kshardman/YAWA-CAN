//
//  WidgetSnapshot.swift
//  YAWA
//
//  Created by Keith Sharman on 2/1/26.
//


import Foundation

struct WidgetSnapshot: Codable {
    var locationName: String
    var temperatureText: String   // already formatted, e.g. "34°"
    var symbolName: String        // SF Symbol name, e.g. "cloud.sun.fill"
    var windText: String?         // e.g. "NW 18" or "CALM" (optional for backward compatibility)
    var updatedAt: Date
}
