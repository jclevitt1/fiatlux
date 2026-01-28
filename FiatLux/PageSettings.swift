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

/// A single drawing layer within a page
struct DrawingLayer: Codable, Identifiable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var opacity: CGFloat
    var zIndex: Int
    var drawingData: Data  // PKDrawing on iOS, [DrawingLine] JSON on macOS

    init(
        id: UUID = UUID(),
        name: String = "Layer 1",
        isVisible: Bool = true,
        opacity: CGFloat = 1.0,
        zIndex: Int = 0,
        drawingData: Data = Data()
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.zIndex = zIndex
        self.drawingData = drawingData
    }
}

struct PageData: Codable {
    var layers: [DrawingLayer]
    var activeLayerIndex: Int
    var orientation: PageOrientation

    /// Legacy single-layer access for backward compatibility
    var drawingData: Data {
        get { layers.first?.drawingData ?? Data() }
        set {
            if layers.isEmpty {
                layers = [DrawingLayer(drawingData: newValue)]
            } else {
                layers[0].drawingData = newValue
            }
        }
    }

    init(drawingData: Data = Data(), orientation: PageOrientation = .portrait) {
        self.layers = [DrawingLayer(drawingData: drawingData)]
        self.activeLayerIndex = 0
        self.orientation = orientation
    }

    init(layers: [DrawingLayer], activeLayerIndex: Int = 0, orientation: PageOrientation = .portrait) {
        self.layers = layers.isEmpty ? [DrawingLayer()] : layers
        self.activeLayerIndex = min(activeLayerIndex, max(0, layers.count - 1))
        self.orientation = orientation
    }

    /// Sorted layers by z-index for rendering (bottom to top)
    var sortedLayers: [DrawingLayer] {
        layers.sorted { $0.zIndex < $1.zIndex }
    }

    /// Get the currently active layer
    var activeLayer: DrawingLayer? {
        guard activeLayerIndex >= 0, activeLayerIndex < layers.count else { return nil }
        return layers[activeLayerIndex]
    }

    /// Add a new layer above the current active layer
    mutating func addLayer(name: String? = nil) {
        let newIndex = layers.count
        let newZIndex = (layers.map(\.zIndex).max() ?? -1) + 1
        let layerName = name ?? "Layer \(newIndex + 1)"
        let newLayer = DrawingLayer(name: layerName, zIndex: newZIndex)
        layers.append(newLayer)
        activeLayerIndex = newIndex
    }

    /// Delete a layer by index
    mutating func deleteLayer(at index: Int) {
        guard layers.count > 1, index >= 0, index < layers.count else { return }
        layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        }
    }

    /// Move layer from one position to another
    mutating func moveLayer(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < layers.count,
              destination >= 0, destination < layers.count else { return }

        let layer = layers.remove(at: source)
        layers.insert(layer, at: destination)

        // Update z-indices to match new order
        for (index, _) in layers.enumerated() {
            layers[index].zIndex = index
        }

        // Adjust active layer index if needed
        if activeLayerIndex == source {
            activeLayerIndex = destination
        } else if source < activeLayerIndex && destination >= activeLayerIndex {
            activeLayerIndex -= 1
        } else if source > activeLayerIndex && destination <= activeLayerIndex {
            activeLayerIndex += 1
        }
    }

    // Custom Codable to handle migration from old format
    enum CodingKeys: String, CodingKey {
        case layers, activeLayerIndex, orientation
        case drawingData  // Legacy key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try container.decode(PageOrientation.self, forKey: .orientation)

        // Try new format first
        if let layers = try? container.decode([DrawingLayer].self, forKey: .layers) {
            self.layers = layers.isEmpty ? [DrawingLayer()] : layers
            self.activeLayerIndex = try container.decodeIfPresent(Int.self, forKey: .activeLayerIndex) ?? 0
        } else if let legacyData = try? container.decode(Data.self, forKey: .drawingData) {
            // Migrate from old single-layer format
            self.layers = [DrawingLayer(name: "Layer 1", drawingData: legacyData)]
            self.activeLayerIndex = 0
        } else {
            self.layers = [DrawingLayer()]
            self.activeLayerIndex = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layers, forKey: .layers)
        try container.encode(activeLayerIndex, forKey: .activeLayerIndex)
        try container.encode(orientation, forKey: .orientation)
    }
}
