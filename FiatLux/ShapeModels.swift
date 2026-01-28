//
//  ShapeModels.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/28/26.
//

import SwiftUI

// MARK: - Shape Types

enum ShapeType: String, Codable, CaseIterable {
    case rectangle
    case circle
    case line
    case arrow

    var icon: String {
        switch self {
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.right"
        }
    }

    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        case .line: return "Line"
        case .arrow: return "Arrow"
        }
    }
}

// MARK: - Drawing Shape

struct DrawingShape: Codable, Identifiable {
    let id: UUID
    var type: ShapeType
    var startPoint: CGPoint
    var endPoint: CGPoint
    var strokeColor: CodableColor
    var strokeWidth: CGFloat
    var fillColor: CodableColor?

    init(
        id: UUID = UUID(),
        type: ShapeType,
        startPoint: CGPoint,
        endPoint: CGPoint,
        strokeColor: CodableColor = CodableColor(color: .black),
        strokeWidth: CGFloat = 3,
        fillColor: CodableColor? = nil
    ) {
        self.id = id
        self.type = type
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
    }

    var bounds: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    func path() -> Path {
        var path = Path()

        switch type {
        case .rectangle:
            path.addRect(bounds)

        case .circle:
            path.addEllipse(in: bounds)

        case .line:
            path.move(to: startPoint)
            path.addLine(to: endPoint)

        case .arrow:
            // Main line
            path.move(to: startPoint)
            path.addLine(to: endPoint)

            // Arrowhead
            let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
            let arrowLength: CGFloat = 15
            let arrowAngle: CGFloat = .pi / 6  // 30 degrees

            let arrow1 = CGPoint(
                x: endPoint.x - arrowLength * cos(angle - arrowAngle),
                y: endPoint.y - arrowLength * sin(angle - arrowAngle)
            )
            let arrow2 = CGPoint(
                x: endPoint.x - arrowLength * cos(angle + arrowAngle),
                y: endPoint.y - arrowLength * sin(angle + arrowAngle)
            )

            path.move(to: endPoint)
            path.addLine(to: arrow1)
            path.move(to: endPoint)
            path.addLine(to: arrow2)
        }

        return path
    }

    func contains(point: CGPoint) -> Bool {
        let expandedBounds = bounds.insetBy(dx: -10, dy: -10)
        return expandedBounds.contains(point)
    }
}

// MARK: - Codable Color

struct CodableColor: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(color: Color) {
        // Default to black - in production would resolve color
        self.red = 0
        self.green = 0
        self.blue = 0
        self.alpha = 1
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    static let black = CodableColor(red: 0, green: 0, blue: 0)
    static let blue = CodableColor(red: 0.2, green: 0.4, blue: 0.9)
    static let red = CodableColor(red: 0.9, green: 0.2, blue: 0.2)
}

// MARK: - Shape Recognition

struct ShapeRecognizer {

    /// Minimum points needed for recognition
    static let minPoints = 10

    /// Analyze a freehand stroke and return a recognized shape if confident
    static func recognize(points: [CGPoint], threshold: Double = 0.75) -> DrawingShape? {
        guard points.count >= minPoints else { return nil }

        let bounds = calculateBounds(points)
        guard bounds.width > 10 && bounds.height > 10 else { return nil }

        // Try each shape type and pick best match
        var bestMatch: (ShapeType, Double)? = nil

        let lineScore = scoreLine(points)
        if lineScore > threshold {
            bestMatch = (.line, lineScore)
        }

        let rectangleScore = scoreRectangle(points, bounds: bounds)
        if rectangleScore > threshold && rectangleScore > (bestMatch?.1 ?? 0) {
            bestMatch = (.rectangle, rectangleScore)
        }

        let circleScore = scoreCircle(points, bounds: bounds)
        if circleScore > threshold && circleScore > (bestMatch?.1 ?? 0) {
            bestMatch = (.circle, circleScore)
        }

        let arrowScore = scoreArrow(points)
        if arrowScore > threshold && arrowScore > (bestMatch?.1 ?? 0) {
            bestMatch = (.arrow, arrowScore)
        }

        guard let (type, _) = bestMatch else { return nil }

        // Create clean shape from recognized type
        return createShape(type: type, from: points, bounds: bounds)
    }

    // MARK: - Scoring Functions

    private static func scoreLine(_ points: [CGPoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }

        // Calculate how close all points are to the line between first and last
        let lineLength = distance(first, last)
        guard lineLength > 20 else { return 0 }

        var totalDeviation: CGFloat = 0
        for point in points {
            let deviation = pointToLineDistance(point: point, lineStart: first, lineEnd: last)
            totalDeviation += deviation
        }

        let avgDeviation = totalDeviation / CGFloat(points.count)
        let normalizedDeviation = avgDeviation / lineLength

        // Lower deviation = higher score
        return max(0, 1 - Double(normalizedDeviation * 5))
    }

    private static func scoreRectangle(_ points: [CGPoint], bounds: CGRect) -> Double {
        // Check if points follow the perimeter of a rectangle
        var perimeterScore: CGFloat = 0

        for point in points {
            let distToPerimeter = distanceToRectPerimeter(point: point, rect: bounds)
            perimeterScore += min(distToPerimeter, 20)
        }

        let avgDistance = perimeterScore / CGFloat(points.count)
        let normalizedDistance = avgDistance / max(bounds.width, bounds.height)

        // Also check aspect ratio - reject very thin shapes
        let aspectRatio = min(bounds.width, bounds.height) / max(bounds.width, bounds.height)
        if aspectRatio < 0.1 { return 0 }

        // Check if stroke is closed (ends near start)
        let closedness = closedStrokeScore(points)

        return max(0, Double(1 - normalizedDistance * 3)) * closedness
    }

    private static func scoreCircle(_ points: [CGPoint], bounds: CGRect) -> Double {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let avgRadius = (bounds.width + bounds.height) / 4

        guard avgRadius > 10 else { return 0 }

        var radiusVariance: CGFloat = 0
        for point in points {
            let dist = distance(point, center)
            radiusVariance += abs(dist - avgRadius)
        }

        let avgVariance = radiusVariance / CGFloat(points.count)
        let normalizedVariance = avgVariance / avgRadius

        // Check if roughly circular (not too elongated)
        let aspectRatio = min(bounds.width, bounds.height) / max(bounds.width, bounds.height)
        if aspectRatio < 0.6 { return 0 }

        // Check if stroke is closed
        let closedness = closedStrokeScore(points)

        return max(0, Double(1 - normalizedVariance * 2)) * closedness
    }

    private static func scoreArrow(_ points: [CGPoint]) -> Double {
        // Arrow: mostly a line with a direction change at the end
        let lineScore = scoreLine(points)
        if lineScore < 0.5 { return 0 }

        // Check for direction changes near the end (arrowhead)
        guard points.count > 5 else { return 0 }

        let lastQuarter = Array(points.suffix(points.count / 4))
        guard lastQuarter.count >= 3 else { return lineScore * 0.5 }

        // Look for sharp angle changes
        var hasDirectionChange = false
        for i in 1..<lastQuarter.count - 1 {
            let angle = angleChange(lastQuarter[i-1], lastQuarter[i], lastQuarter[i+1])
            if angle > .pi / 4 {  // > 45 degrees
                hasDirectionChange = true
                break
            }
        }

        return hasDirectionChange ? lineScore * 1.1 : lineScore * 0.7
    }

    // MARK: - Helper Functions

    private static func calculateBounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }

        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y

        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        sqrt(pow(p2.x - p1.x, 2) + pow(p2.y - p1.y, 2))
    }

    private static func pointToLineDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else { return distance(point, lineStart) }

        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared))
        let projection = CGPoint(x: lineStart.x + t * dx, y: lineStart.y + t * dy)

        return distance(point, projection)
    }

    private static func distanceToRectPerimeter(point: CGPoint, rect: CGRect) -> CGFloat {
        // Distance to nearest edge of rectangle
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)

        if dx == 0 && dy == 0 {
            // Point is inside - find distance to nearest edge
            let distToLeft = point.x - rect.minX
            let distToRight = rect.maxX - point.x
            let distToTop = point.y - rect.minY
            let distToBottom = rect.maxY - point.y
            return min(distToLeft, distToRight, distToTop, distToBottom)
        }

        return sqrt(dx * dx + dy * dy)
    }

    private static func closedStrokeScore(_ points: [CGPoint]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let closeDistance = distance(first, last)
        let bounds = calculateBounds(points)
        let maxDim = max(bounds.width, bounds.height)

        guard maxDim > 0 else { return 0 }

        let normalizedDistance = closeDistance / maxDim
        return max(0, min(1, Double(1 - normalizedDistance)))
    }

    private static func angleChange(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let v2 = CGPoint(x: p3.x - p2.x, y: p3.y - p2.y)

        let dot = v1.x * v2.x + v1.y * v2.y
        let cross = v1.x * v2.y - v1.y * v2.x

        return abs(atan2(cross, dot))
    }

    private static func createShape(type: ShapeType, from points: [CGPoint], bounds: CGRect) -> DrawingShape {
        switch type {
        case .rectangle:
            return DrawingShape(
                type: .rectangle,
                startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)
            )

        case .circle:
            return DrawingShape(
                type: .circle,
                startPoint: CGPoint(x: bounds.minX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)
            )

        case .line, .arrow:
            guard let first = points.first, let last = points.last else {
                return DrawingShape(type: type, startPoint: .zero, endPoint: .zero)
            }
            return DrawingShape(type: type, startPoint: first, endPoint: last)
        }
    }
}

// Note: CGPoint already conforms to Codable via CoreGraphics
