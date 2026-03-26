//
//  YCWidgetBundle.swift
//  YCWidget
//
//  Created by Keith Sharman on 3/26/26.
//

import WidgetKit
import SwiftUI

@main
struct YCWidgetBundle: WidgetBundle {
    var body: some Widget {
        YCWidget()
        YCWidgetControl()
    }
}
