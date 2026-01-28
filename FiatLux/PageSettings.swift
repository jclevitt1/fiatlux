//
//  PageSettings.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import Foundation

enum PageOrientation: String, Codable, CaseIterable {
    case portrait = "Portrait"
    case landscape = "Landscape"

    var aspectRatio: CGFloat {
        // Returns height/width ratio
        switch self {
        case .portrait: return 11.0 / 8.5   // 1.294 - taller than wide
        case .landscape: return 8.5 / 11.0  // 0.773 - wider than tall
        }
    }

    var icon: String {
        switch self {
        case .portrait: return "rectangle.portrait"
        case .landscape: return "rectangle"
        }
    }
}

struct PageData: Codable {
    var drawingData: Data
    var orientation: PageOrientation

    init(drawingData: Data = Data(), orientation: PageOrientation = .portrait) {
        self.drawingData = drawingData
        self.orientation = orientation
    }
}
