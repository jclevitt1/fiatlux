//
//  CanvasView.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import SwiftUI

enum DrawingTool: Equatable {
    case pencil
    case eraser
    case shape(ShapeType)
    case shapePen  // Freehand with shape recognition
    case text
    case lasso

    var isShapeTool: Bool {
        switch self {
        case .shape, .shapePen: return true
        default: return false
        }
    }
}

#if os(iOS)
import PencilKit

/// Renders a PKDrawing to a UIImage for layer compositing
func renderDrawingToImage(drawing: PKDrawing, size: CGSize, scale: CGFloat = UIScreen.main.scale) -> UIImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    return drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
}

/// iOS Layered Canvas - uses PKCanvasView for active layer, renders others as images
struct LayeredCanvasView: View {
    @Binding var page: PageData
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @Binding var currentTool: DrawingTool
    let canvasSize: CGSize

    var body: some View {
        ZStack {
            // Render layers from bottom to top
            ForEach(page.sortedLayers) { layer in
                if layer.isVisible {
                    if layer.id == page.activeLayer?.id {
                        // Active layer - live PKCanvasView
                        CanvasViewRepresentable(
                            canvasView: $canvasView,
                            toolPicker: $toolPicker,
                            currentTool: $currentTool
                        )
                        .opacity(layer.opacity)
                    } else {
                        // Non-active layer - render as static image
                        LayerImageView(layer: layer, size: canvasSize)
                            .opacity(layer.opacity)
                    }
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color.white)
        .clipped()
    }
}

/// Renders a non-active layer as a static image
struct LayerImageView: View {
    let layer: DrawingLayer
    let size: CGSize

    var body: some View {
        if let drawing = try? PKDrawing(data: layer.drawingData),
           let image = renderDrawingToImage(drawing: drawing, size: size) {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
        }
    }
}

/// UIViewRepresentable wrapper for PKCanvasView
struct CanvasViewRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @Binding var currentTool: DrawingTool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear  // Transparent for layering
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvasView.isOpaque = false

        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = pkTool(for: currentTool)
    }

    private func pkTool(for tool: DrawingTool) -> PKTool {
        switch tool {
        case .pencil:
            return PKInkingTool(.pen, color: .black, width: 5)
        case .eraser:
            return PKEraserTool(.bitmap)
        case .lasso:
            return PKLassoTool()
        case .text, .shape, .shapePen:
            // These are handled by overlay views, use pen as fallback
            return PKInkingTool(.pen, color: .black, width: 5)
        }
    }
}

/// Legacy single-layer canvas for backward compatibility
struct CanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @Binding var currentTool: DrawingTool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .white
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)

        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = pkTool(for: currentTool)
    }

    private func pkTool(for tool: DrawingTool) -> PKTool {
        switch tool {
        case .pencil:
            return PKInkingTool(.pen, color: .black, width: 5)
        case .eraser:
            return PKEraserTool(.bitmap)
        case .lasso:
            return PKLassoTool()
        case .text, .shape, .shapePen:
            // These are handled by overlay views, use pen as fallback
            return PKInkingTool(.pen, color: .black, width: 5)
        }
    }
}

#else
// macOS - custom drawing using SwiftUI Canvas with layer support

struct DrawingLine: Codable {
    var points: [CGPoint]
}

/// macOS Layered Canvas - renders all layers using SwiftUI Canvas
struct LayeredCanvasView: View {
    @Binding var page: PageData
    @Binding var currentTool: DrawingTool
    let canvasSize: CGSize

    @State private var currentLine: [CGPoint] = []
    @State private var eraserPosition: CGPoint? = nil

    private let eraserRadius: CGFloat = 20

    var body: some View {
        Canvas { context, size in
            // Render layers from bottom to top by z-index
            for layer in page.sortedLayers {
                guard layer.isVisible else { continue }

                context.opacity = layer.opacity

                if layer.id == page.activeLayer?.id {
                    // Active layer - include current line being drawn
                    drawLayer(layer, context: context, includeCurrentLine: true)
                } else {
                    // Non-active layer
                    drawLayer(layer, context: context, includeCurrentLine: false)
                }

                context.opacity = 1.0
            }

            // Eraser cursor
            if currentTool == .eraser, let pos = eraserPosition {
                let rect = CGRect(
                    x: pos.x - eraserRadius,
                    y: pos.y - eraserRadius,
                    width: eraserRadius * 2,
                    height: eraserRadius * 2
                )
                context.stroke(Circle().path(in: rect), with: .color(.gray), lineWidth: 2)
                context.fill(Circle().path(in: rect), with: .color(.white.opacity(0.3)))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color.white)
        .border(Color.gray.opacity(0.3), width: 1)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if currentTool == .eraser {
                    eraserPosition = location
                }
            case .ended:
                eraserPosition = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if currentTool == .pencil {
                        currentLine.append(value.location)
                    } else {
                        eraserPosition = value.location
                        eraseAt(value.location)
                    }
                }
                .onEnded { _ in
                    if currentTool == .pencil && !currentLine.isEmpty {
                        appendLineToActiveLayer()
                        currentLine = []
                    }
                }
        )
    }

    private func drawLayer(_ layer: DrawingLayer, context: GraphicsContext, includeCurrentLine: Bool) {
        let lines = decodeLines(from: layer.drawingData)

        for line in lines {
            var path = Path()
            if let first = line.points.first {
                path.move(to: first)
                for point in line.points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            context.stroke(path, with: .color(.black), lineWidth: 3)
        }

        // Draw current line being drawn (only for active layer)
        if includeCurrentLine && currentTool == .pencil {
            var currentPath = Path()
            if let first = currentLine.first {
                currentPath.move(to: first)
                for point in currentLine.dropFirst() {
                    currentPath.addLine(to: point)
                }
            }
            context.stroke(currentPath, with: .color(.black), lineWidth: 3)
        }
    }

    private func appendLineToActiveLayer() {
        guard page.activeLayerIndex >= 0, page.activeLayerIndex < page.layers.count else { return }

        var lines = decodeLines(from: page.layers[page.activeLayerIndex].drawingData)
        lines.append(DrawingLine(points: currentLine))

        if let encoded = try? JSONEncoder().encode(lines) {
            page.layers[page.activeLayerIndex].drawingData = encoded
        }
    }

    private func eraseAt(_ point: CGPoint) {
        guard page.activeLayerIndex >= 0, page.activeLayerIndex < page.layers.count else { return }

        var lines = decodeLines(from: page.layers[page.activeLayerIndex].drawingData)
        var newLines: [DrawingLine] = []

        for line in lines {
            var currentSegment: [CGPoint] = []

            for linePoint in line.points {
                if distance(from: linePoint, to: point) > eraserRadius {
                    currentSegment.append(linePoint)
                } else {
                    if currentSegment.count >= 2 {
                        newLines.append(DrawingLine(points: currentSegment))
                    }
                    currentSegment = []
                }
            }

            if currentSegment.count >= 2 {
                newLines.append(DrawingLine(points: currentSegment))
            }
        }

        if let encoded = try? JSONEncoder().encode(newLines) {
            page.layers[page.activeLayerIndex].drawingData = encoded
        }
    }

    private func decodeLines(from data: Data) -> [DrawingLine] {
        (try? JSONDecoder().decode([DrawingLine].self, from: data)) ?? []
    }

    private func distance(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
        sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2))
    }
}

/// Legacy single-layer canvas for backward compatibility
struct CanvasView: View {
    @Binding var drawingData: Data
    @Binding var currentTool: DrawingTool
    @State private var lines: [DrawingLine] = []
    @State private var currentLine: [CGPoint] = []
    @State private var eraserPosition: CGPoint? = nil

    private let eraserRadius: CGFloat = 20

    var body: some View {
        Canvas { context, size in
            // Draw all lines
            for line in lines {
                var path = Path()
                if let first = line.points.first {
                    path.move(to: first)
                    for point in line.points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                context.stroke(path, with: .color(.black), lineWidth: 3)
            }

            // Current line being drawn (pencil only)
            if currentTool == .pencil {
                var currentPath = Path()
                if let first = currentLine.first {
                    currentPath.move(to: first)
                    for point in currentLine.dropFirst() {
                        currentPath.addLine(to: point)
                    }
                }
                context.stroke(currentPath, with: .color(.black), lineWidth: 3)
            }

            // Eraser cursor
            if currentTool == .eraser, let pos = eraserPosition {
                let rect = CGRect(
                    x: pos.x - eraserRadius,
                    y: pos.y - eraserRadius,
                    width: eraserRadius * 2,
                    height: eraserRadius * 2
                )
                context.stroke(Circle().path(in: rect), with: .color(.gray), lineWidth: 2)
                context.fill(Circle().path(in: rect), with: .color(.white.opacity(0.3)))
            }
        }
        .background(Color.white)
        .border(Color.gray.opacity(0.3), width: 1)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if currentTool == .eraser {
                    eraserPosition = location
                }
            case .ended:
                eraserPosition = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if currentTool == .pencil {
                        currentLine.append(value.location)
                    } else {
                        // Eraser mode - remove points near cursor
                        eraserPosition = value.location
                        eraseAt(value.location)
                    }
                }
                .onEnded { _ in
                    if currentTool == .pencil {
                        if !currentLine.isEmpty {
                            lines.append(DrawingLine(points: currentLine))
                            currentLine = []
                        }
                    }
                    saveDrawing()
                }
        )
        .onAppear {
            loadDrawing()
        }
    }

    private func eraseAt(_ point: CGPoint) {
        // Split lines where points are erased, creating new separate line segments
        var newLines: [DrawingLine] = []

        for line in lines {
            var currentSegment: [CGPoint] = []

            for linePoint in line.points {
                if distance(from: linePoint, to: point) > eraserRadius {
                    // Point is outside eraser - keep it
                    currentSegment.append(linePoint)
                } else {
                    // Point is inside eraser - split here
                    if currentSegment.count >= 2 {
                        newLines.append(DrawingLine(points: currentSegment))
                    }
                    currentSegment = []
                }
            }

            // Don't forget the last segment
            if currentSegment.count >= 2 {
                newLines.append(DrawingLine(points: currentSegment))
            }
        }

        lines = newLines
    }

    private func distance(from p1: CGPoint, to p2: CGPoint) -> CGFloat {
        sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2))
    }

    private func saveDrawing() {
        if let data = try? JSONEncoder().encode(lines) {
            drawingData = data
        }
    }

    private func loadDrawing() {
        if let decoded = try? JSONDecoder().decode([DrawingLine].self, from: drawingData) {
            lines = decoded
        }
    }
}
#endif
