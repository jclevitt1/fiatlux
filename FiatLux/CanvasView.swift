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

struct CanvasView: UIViewRepresentable {
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
