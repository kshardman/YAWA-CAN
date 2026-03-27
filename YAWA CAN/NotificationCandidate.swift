//
//  NotificationCandidate.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/26/26.
//
import Foundation

struct NotificationCandidate: Equatable, Hashable {
    enum Kind: String, Codable {
        case precipSoon
        case windyTomorrow
    }

    let id: String
    let kind: Kind
    let title: String
    let body: String
    let fireDate: Date
    let relevanceScore: Int
}
