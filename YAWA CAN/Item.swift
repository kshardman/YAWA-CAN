//
//  Item.swift
//  YAWA CAN
//
//  Created by Keith Sharman on 3/9/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    // Kept intentionally: required for SwiftData @Model construction.
    // Periphery reports this as unused, but removing it breaks the model.
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
