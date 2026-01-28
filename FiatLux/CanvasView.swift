//
//  CanvasView.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import SwiftUI

enum DrawingTool {
    case pencil
    case eraser
    case lasso
}

#if os(iOS)
import PencilKit

struct CanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    @Binding var currentTool: DrawingTool

    // Store the current pen color/width to restore when switching back from lasso
    var penColor: UIColor = .black
    var penWidth: CGFloat = 5

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .white
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: penColor, width: penWidth)

        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Sync the tool based on currentTool selection
        let newTool: PKTool
        switch currentTool {
        case .pencil:
            newTool = PKInkingTool(.pen, color: penColor, width: penWidth)
        case .eraser:
            newTool = PKEraserTool(.bitmap)
        case .lasso:
            newTool = PKLassoTool()
        }

        // Only update if the tool type actually changed to avoid interrupting user actions
        if !toolsMatch(uiView.tool, newTool) {
            uiView.tool = newTool
        }
    }

    // Helper to check if tools are the same type
    private func toolsMatch(_ tool1: PKTool, _ tool2: PKTool) -> Bool {
        switch (tool1, tool2) {
        case (is PKLassoTool, is PKLassoTool):
            return true
        case (is PKEraserTool, is PKEraserTool):
            return true
        case (let ink1 as PKInkingTool, let ink2 as PKInkingTool):
            return ink1.inkType == ink2.inkType
        default:
            return false
        }
    }
}
#else
// macOS - simple drawing using SwiftUI Canvas
struct CanvasView: View {
    @Binding var drawingData: Data
    @Binding var currentTool: DrawingTool
    @State private var lines: [DrawingLine] = []
    @State private var currentLine: [CGPoint] = []
    @State private var eraserPosition: CGPoint? = nil

    private let eraserRadius: CGFloat = 20

    struct DrawingLine: Codable {
        var points: [CGPoint]
    }

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
