//
//  WidgetSnapshotStore.swift
//  YAWA
//
//  Created by Keith Sharman on 2/1/26.
//


import Foundation

enum WidgetSnapshotStore {
    static let appGroupID = "group.com.kpsorg.YAWA"
    static let fileName = "widget_snapshot.json"

    static func write(_ snapshot: WidgetSnapshot) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let url = containerURL.appendingPathComponent(fileName)

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            // optional: log in DEBUG
        }
    }

    static func read() -> WidgetSnapshot? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }

        let url = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}