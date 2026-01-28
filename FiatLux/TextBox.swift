//
//  TextBox.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/28/26.
//

import Foundation
import SwiftUI

/// A text box that can be placed on a note page.
/// Position and size are stored as fractions of page dimensions (0-1)
/// to allow resolution-independent rendering.
struct TextBox: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var position: CGPoint      // Normalized (0-1) position of top-left corner
    var size: CGSize           // Normalized (0-1) size
    var fontSize: CGFloat      // Points (rendered relative to page size)
    var fontWeight: FontWeight
    var textColor: TextBoxColor
    var backgroundColor: TextBoxColor?
    var alignment: TextAlignment

    enum FontWeight: String, Codable, CaseIterable {
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "Semibold"
        case bold = "Bold"

        var swiftUIWeight: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    enum TextBoxColor: String, Codable, CaseIterable {
        case black = "Black"
        case darkGray = "Dark Gray"
        case gray = "Gray"
        case blue = "Blue"
        case red = "Red"
        case green = "Green"
        case orange = "Orange"
        case purple = "Purple"
        case white = "White"
        case clear = "Clear"

        var color: Color {
            switch self {
            case .black: return .black
            case .darkGray: return Color(white: 0.3)
            case .gray: return .gray
            case .blue: return .blue
            case .red: return .red
            case .green: return .green
            case .orange: return .orange
            case .purple: return .purple
            case .white: return .white
            case .clear: return .clear
            }
        }
    }

    enum TextAlignment: String, Codable, CaseIterable {
        case leading = "Left"
        case center = "Center"
        case trailing = "Right"

        var swiftUIAlignment: SwiftUI.TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    // Default sizes
    static let defaultFontSize: CGFloat = 16
    static let defaultSize = CGSize(width: 0.3, height: 0.1)
    static let minSize = CGSize(width: 0.05, height: 0.03)

    init(
        id: UUID = UUID(),
        text: String = "",
        position: CGPoint = CGPoint(x: 0.1, y: 0.1),
        size: CGSize = TextBox.defaultSize,
        fontSize: CGFloat = TextBox.defaultFontSize,
        fontWeight: FontWeight = .regular,
        textColor: TextBoxColor = .black,
        backgroundColor: TextBoxColor? = nil,
        alignment: TextAlignment = .leading
    ) {
        self.id = id
        self.text = text
        self.position = position
        self.size = size
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.alignment = alignment
    }

    /// Convert normalized position to pixel position for a given canvas size
    func pixelPosition(in canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: position.x * canvasSize.width,
            y: position.y * canvasSize.height
        )
    }

    /// Convert normalized size to pixel size for a given canvas size
    func pixelSize(in canvasSize: CGSize) -> CGSize {
        CGSize(
            width: size.width * canvasSize.width,
            height: size.height * canvasSize.height
        )
    }

    /// Convert normalized frame to pixel frame for a given canvas size
    func pixelFrame(in canvasSize: CGSize) -> CGRect {
        CGRect(
            origin: pixelPosition(in: canvasSize),
            size: pixelSize(in: canvasSize)
        )
    }

    /// Scale font size relative to canvas width (base reference: 800px)
    func scaledFontSize(for canvasWidth: CGFloat) -> CGFloat {
        fontSize * (canvasWidth / 800.0)
    }

    /// Update position from pixel coordinates
    mutating func setPixelPosition(_ point: CGPoint, in canvasSize: CGSize) {
        position = CGPoint(
            x: max(0, min(1 - size.width, point.x / canvasSize.width)),
            y: max(0, min(1 - size.height, point.y / canvasSize.height))
        )
    }

    /// Update size from pixel dimensions
    mutating func setPixelSize(_ newSize: CGSize, in canvasSize: CGSize) {
        size = CGSize(
            width: max(TextBox.minSize.width, min(1 - position.x, newSize.width / canvasSize.width)),
            height: max(TextBox.minSize.height, min(1 - position.y, newSize.height / canvasSize.height))
        )
    }
}
