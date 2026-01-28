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

    var isShapeTool: Bool {
        switch self {
        case .shape, .shapePen: return true
        default: return false
        }
    }
}

#if os(iOS)
import PencilKit

/// Manages tool persistence across app sessions
class ToolPersistence {
    private static let toolKey = "FiatLux.selectedTool"

    static func save(tool: PKTool) {
        if let inkingTool = tool as? PKInkingTool {
            let data: [String: Any] = [
                "type": "inking",
                "inkType": inkingTool.inkType.rawValue,
                "color": inkingTool.color.hexString,
                "width": inkingTool.width
            ]
            UserDefaults.standard.set(data, forKey: toolKey)
        } else if tool is PKEraserTool {
            let data: [String: Any] = ["type": "eraser"]
            UserDefaults.standard.set(data, forKey: toolKey)
        }
    }

    static func restore() -> PKTool? {
        guard let data = UserDefaults.standard.dictionary(forKey: toolKey),
              let type = data["type"] as? String else {
            return nil
        }

        if type == "inking",
           let inkTypeRaw = data["inkType"] as? String,
           let inkType = PKInkingTool.InkType(rawValue: inkTypeRaw),
           let colorHex = data["color"] as? String,
           let width = data["width"] as? CGFloat {
            let color = UIColor(hex: colorHex) ?? .black
            return PKInkingTool(inkType, color: color, width: width)
        } else if type == "eraser" {
            return PKEraserTool(.bitmap)
        }

        return nil
    }
}

/// Helper extensions for color persistence
extension UIColor {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
    }

    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r, g, b, a: CGFloat
        if hexSanitized.count == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - iOS Hybrid Canvas (PencilKit + Shapes)

struct CanvasView: View {
    @Binding var canvasView: PKCanvasView
    @Binding var currentTool: DrawingTool
    @Binding var shapes: [DrawingShape]

    @State private var shapeStart: CGPoint? = nil
    @State private var shapeEnd: CGPoint? = nil
    @State private var recognizedShape: DrawingShape? = nil
    @State private var showRecognitionPrompt: Bool = false
    @State private var freehandPoints: [CGPoint] = []

    var body: some View {
        ZStack {
            // PencilKit canvas for regular drawing (hidden during shape mode)
            PencilKitCanvas(canvasView: $canvasView)
                .allowsHitTesting(!currentTool.isShapeTool)

            // Shape overlay
            Canvas { context, size in
                // Draw all shapes
                for shape in shapes {
                    let shapePath = shape.path()
                    if let fill = shape.fillColor {
                        context.fill(shapePath, with: .color(fill.color))
                    }
                    context.stroke(shapePath, with: .color(shape.strokeColor.color), lineWidth: shape.strokeWidth)
                }

                // Preview shape being drawn
                if case .shape(let shapeType) = currentTool,
                   let start = shapeStart, let end = shapeEnd {
                    let previewShape = DrawingShape(type: shapeType, startPoint: start, endPoint: end)
                    let previewPath = previewShape.path()
                    context.stroke(previewPath, with: .color(.blue.opacity(0.7)), style: StrokeStyle(lineWidth: 3, dash: [5, 3]))
                }

                // Freehand preview for shape pen
                if currentTool == .shapePen && !freehandPoints.isEmpty {
                    var path = Path()
                    if let first = freehandPoints.first {
                        path.move(to: first)
                        for point in freehandPoints.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    context.stroke(path, with: .color(.black), lineWidth: 3)
                }
            }
            .allowsHitTesting(currentTool.isShapeTool)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDragChanged(value)
                    }
                    .onEnded { value in
                        handleDragEnded(value)
                    }
            )

            // Shape recognition prompt
            if showRecognitionPrompt, let recognized = recognizedShape {
                VStack {
                    Spacer()
                    shapeRecognitionPrompt(shape: recognized)
                        .padding()
                }
            }
        }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        switch currentTool {
        case .shape:
            if shapeStart == nil {
                shapeStart = value.startLocation
            }
            shapeEnd = value.location

        case .shapePen:
            freehandPoints.append(value.location)

        default:
            break
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        switch currentTool {
        case .shape(let shapeType):
            if let start = shapeStart, let end = shapeEnd {
                let newShape = DrawingShape(type: shapeType, startPoint: start, endPoint: end)
                shapes.append(newShape)
            }
            shapeStart = nil
            shapeEnd = nil

        case .shapePen:
            if !freehandPoints.isEmpty {
                if let recognized = ShapeRecognizer.recognize(points: freehandPoints) {
                    recognizedShape = recognized
                    showRecognitionPrompt = true
                }
                freehandPoints = []
            }

        default:
            break
        }
    }

    @ViewBuilder
    private func shapeRecognitionPrompt(shape: DrawingShape) -> some View {
        HStack(spacing: 12) {
            Image(systemName: shape.type.icon)
                .font(.title2)

            Text("Convert to \(shape.type.displayName)?")
                .font(.subheadline)

            Button("Yes") {
                shapes.append(shape)
                showRecognitionPrompt = false
                recognizedShape = nil
            }
            .buttonStyle(.borderedProminent)

            Button("No") {
                showRecognitionPrompt = false
                recognizedShape = nil
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - PencilKit UIViewRepresentable

struct PencilKitCanvas: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .white
        canvasView.drawingPolicy = .anyInput

        // Restore persisted tool or use default
        if let savedTool = ToolPersistence.restore() {
            canvasView.tool = savedTool
        } else {
            canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
        }

        // Get the shared tool picker for this window scene
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first {
            let toolPicker = PKToolPicker.shared(for: window)
            toolPicker?.setVisible(true, forFirstResponder: canvasView)
            toolPicker?.addObserver(canvasView)
            toolPicker?.addObserver(context.coordinator)

            // Set the tool picker's selected tool to match canvas
            toolPicker?.selectedTool = canvasView.tool
        }

        canvasView.becomeFirstResponder()
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    class Coordinator: NSObject, PKToolPickerObserver {
        func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
            ToolPersistence.save(tool: toolPicker.selectedTool)
        }
    }
}
#else
// macOS - simple drawing using SwiftUI Canvas
struct CanvasView: View {
    @Binding var drawingData: Data
    @Binding var currentTool: DrawingTool
    @Binding var shapes: [DrawingShape]
    @State private var lines: [DrawingLine] = []
    @State private var currentLine: [CGPoint] = []
    @State private var eraserPosition: CGPoint? = nil
    @State private var shapeStart: CGPoint? = nil
    @State private var shapeEnd: CGPoint? = nil
    @State private var recognizedShape: DrawingShape? = nil
    @State private var showRecognitionPrompt: Bool = false

    private let eraserRadius: CGFloat = 20

    struct DrawingLine: Codable {
        var points: [CGPoint]
    }

    var body: some View {
        ZStack {
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

                // Draw all shapes
                for shape in shapes {
                    let shapePath = shape.path()
                    if let fill = shape.fillColor {
                        context.fill(shapePath, with: .color(fill.color))
                    }
                    context.stroke(shapePath, with: .color(shape.strokeColor.color), lineWidth: shape.strokeWidth)
                }

                // Current line being drawn (pencil or shapePen)
                if currentTool == .pencil || currentTool == .shapePen {
                    var currentPath = Path()
                    if let first = currentLine.first {
                        currentPath.move(to: first)
                        for point in currentLine.dropFirst() {
                            currentPath.addLine(to: point)
                        }
                    }
                    context.stroke(currentPath, with: .color(.black), lineWidth: 3)
                }

                // Preview shape being drawn
                if case .shape(let shapeType) = currentTool,
                   let start = shapeStart, let end = shapeEnd {
                    let previewShape = DrawingShape(type: shapeType, startPoint: start, endPoint: end)
                    let previewPath = previewShape.path()
                    context.stroke(previewPath, with: .color(.blue.opacity(0.7)), style: StrokeStyle(lineWidth: 3, dash: [5, 3]))
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
                        handleDragChanged(value)
                    }
                    .onEnded { value in
                        handleDragEnded(value)
                    }
            )

            // Shape recognition prompt overlay
            if showRecognitionPrompt, let recognized = recognizedShape {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        shapeRecognitionPrompt(shape: recognized)
                            .padding()
                        Spacer()
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            loadDrawing()
        }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        switch currentTool {
        case .pencil:
            currentLine.append(value.location)

        case .shapePen:
            currentLine.append(value.location)

        case .eraser:
            eraserPosition = value.location
            eraseAt(value.location)

        case .shape:
            if shapeStart == nil {
                shapeStart = value.startLocation
            }
            shapeEnd = value.location
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        switch currentTool {
        case .pencil:
            if !currentLine.isEmpty {
                lines.append(DrawingLine(points: currentLine))
                currentLine = []
            }
            saveDrawing()

        case .shapePen:
            if !currentLine.isEmpty {
                // Try to recognize shape
                if let recognized = ShapeRecognizer.recognize(points: currentLine) {
                    recognizedShape = recognized
                    showRecognitionPrompt = true
                } else {
                    // No shape recognized, keep as freehand
                    lines.append(DrawingLine(points: currentLine))
                    saveDrawing()
                }
                currentLine = []
            }

        case .eraser:
            saveDrawing()

        case .shape(let shapeType):
            if let start = shapeStart, let end = shapeEnd {
                let newShape = DrawingShape(type: shapeType, startPoint: start, endPoint: end)
                shapes.append(newShape)
            }
            shapeStart = nil
            shapeEnd = nil
        }
    }

    @ViewBuilder
    private func shapeRecognitionPrompt(shape: DrawingShape) -> some View {
        HStack(spacing: 12) {
            Image(systemName: shape.type.icon)
                .font(.title2)

            Text("Convert to \(shape.type.displayName)?")
                .font(.subheadline)

            Button("Yes") {
                shapes.append(shape)
                showRecognitionPrompt = false
                recognizedShape = nil
            }
            .buttonStyle(.borderedProminent)

            Button("No") {
                // Keep original freehand stroke
                if !currentLine.isEmpty {
                    lines.append(DrawingLine(points: currentLine))
                    saveDrawing()
                }
                showRecognitionPrompt = false
                recognizedShape = nil
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func eraseAt(_ point: CGPoint) {
        // Erase lines
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
        lines = newLines

        // Erase shapes that contain the point
        shapes.removeAll { shape in
            shape.contains(point: point)
        }
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
