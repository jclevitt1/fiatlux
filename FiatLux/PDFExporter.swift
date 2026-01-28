//
//  PDFExporter.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// FileDocument wrapper for PDF export
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        // Not used for export-only
        self.url = URL(fileURLWithPath: "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        print("DEBUG PDFFile: Creating file wrapper for \(url)")
        do {
            let data = try Data(contentsOf: url)
            print("DEBUG PDFFile: Read \(data.count) bytes")
            return FileWrapper(regularFileWithContents: data)
        } catch {
            print("DEBUG PDFFile: Error reading file: \(error)")
            throw error
        }
    }
}

#if os(macOS)
import AppKit

struct PDFExporter {
    // 8.5 x 11 inches at 72 DPI
    static let portraitWidth: CGFloat = 612
    static let portraitHeight: CGFloat = 792
    static let landscapeWidth: CGFloat = 792
    static let landscapeHeight: CGFloat = 612

    // Legacy support for [Data] (converts to [PageData] with portrait orientation)
    static func export(pages: [Data], title: String) -> URL? {
        let pageDataArray = pages.map { PageData(drawingData: $0, orientation: .portrait) }
        return export(pages: pageDataArray, title: title)
    }

    static func export(pages: [PageData], title: String) -> URL? {
        print("DEBUG PDFExporter: Starting export for '\(title)'")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title).pdf")
        print("DEBUG PDFExporter: Temp URL = \(tempURL)")

        // Use first page's orientation for initial media box (will be overridden per page)
        var mediaBox = CGRect(x: 0, y: 0, width: portraitWidth, height: portraitHeight)
        guard let pdfContext = CGContext(tempURL as CFURL, mediaBox: &mediaBox, nil) else {
            print("DEBUG PDFExporter: Failed to create CGContext")
            return nil
        }
        print("DEBUG PDFExporter: CGContext created successfully")

        for (pageIndex, pageData) in pages.enumerated() {
            print("DEBUG PDFExporter: Processing page \(pageIndex), layers: \(pageData.layers.count), orientation: \(pageData.orientation.rawValue)")

            // Set page dimensions based on orientation
            let pageWidth: CGFloat
            let pageHeight: CGFloat
            if pageData.orientation == .landscape {
                pageWidth = landscapeWidth
                pageHeight = landscapeHeight
            } else {
                pageWidth = portraitWidth
                pageHeight = portraitHeight
            }

            var pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

            pdfContext.beginPage(mediaBox: &pageRect)
            print("DEBUG PDFExporter: Page \(pageIndex) begun")

            // Fill white background
            pdfContext.setFillColor(CGColor.white)
            pdfContext.fill(pageRect)

            // Render each visible layer from bottom to top
            for layer in pageData.sortedLayers {
                guard layer.isVisible else { continue }

                // Apply layer opacity
                pdfContext.setAlpha(layer.opacity)

                // Decode the drawing lines
                if let lines = try? JSONDecoder().decode([DrawingLine].self, from: layer.drawingData) {
                    print("DEBUG PDFExporter: Layer '\(layer.name)' has \(lines.count) lines")

                    // Find the bounds of all drawing content
                    var minX: CGFloat = .greatestFiniteMagnitude
                    var minY: CGFloat = .greatestFiniteMagnitude
                    var maxX: CGFloat = 0
                    var maxY: CGFloat = 0

                    for line in lines {
                        for point in line.points {
                            minX = min(minX, point.x)
                            minY = min(minY, point.y)
                            maxX = max(maxX, point.x)
                            maxY = max(maxY, point.y)
                        }
                    }

                    // Canvas aspect ratio depends on page orientation
                    let canvasRatio: CGFloat = pageData.orientation.aspectRatio
                    let estimatedCanvasWidth = max(maxX + 20, 400)  // At least some minimum
                    let estimatedCanvasHeight = estimatedCanvasWidth * canvasRatio

                    // Scale to fit PDF while maintaining aspect ratio
                    let scale = min(pageWidth / estimatedCanvasWidth, pageHeight / estimatedCanvasHeight)

                    pdfContext.setStrokeColor(CGColor.black)
                    pdfContext.setLineWidth(3 * scale)
                    pdfContext.setLineCap(.round)
                    pdfContext.setLineJoin(.round)

                    for line in lines {
                        if line.points.count >= 2 {
                            pdfContext.beginPath()
                            let firstPoint = line.points[0]

                            pdfContext.move(to: CGPoint(
                                x: firstPoint.x * scale,
                                y: pageHeight - (firstPoint.y * scale) // Flip Y for PDF
                            ))

                            for point in line.points.dropFirst() {
                                pdfContext.addLine(to: CGPoint(
                                    x: point.x * scale,
                                    y: pageHeight - (point.y * scale)
                                ))
                            }
                            pdfContext.strokePath()
                        }
                    }
                }

                // Reset alpha for next layer
                pdfContext.setAlpha(1.0)
            }

            pdfContext.endPage()
            print("DEBUG PDFExporter: Page \(pageIndex) ended")
        }

        pdfContext.closePDF()
        print("DEBUG PDFExporter: PDF closed")
        print("DEBUG PDFExporter: File exists at \(tempURL.path): \(FileManager.default.fileExists(atPath: tempURL.path))")
        return tempURL
    }

    // Drawing line structure (must match CanvasView)
    struct DrawingLine: Codable {
        var points: [CGPoint]
    }
}

#else
import UIKit
import PencilKit

struct PDFExporter {
    static let portraitWidth: CGFloat = 612
    static let portraitHeight: CGFloat = 792
    static let landscapeWidth: CGFloat = 792
    static let landscapeHeight: CGFloat = 612

    // Legacy support for [Data] (converts to [PageData] with portrait orientation)
    static func export(pages: [Data], title: String) -> URL? {
        let pageDataArray = pages.map { PageData(drawingData: $0, orientation: .portrait) }
        return export(pages: pageDataArray, title: title)
    }

    static func export(pages: [PageData], title: String) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title).pdf")

        // Get max dimensions needed
        let maxWidth = pages.contains { $0.orientation == .landscape } ? landscapeWidth : portraitWidth
        let maxHeight = pages.contains { $0.orientation == .portrait } ? portraitHeight : landscapeHeight

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: maxWidth, height: maxHeight))

        do {
            try pdfRenderer.writePDF(to: tempURL) { context in
                for pageData in pages {
                    // Set page dimensions based on orientation
                    let pageWidth: CGFloat
                    let pageHeight: CGFloat
                    if pageData.orientation == .landscape {
                        pageWidth = landscapeWidth
                        pageHeight = landscapeHeight
                    } else {
                        pageWidth = portraitWidth
                        pageHeight = portraitHeight
                    }

                    let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
                    context.beginPage(withBounds: pageRect, pageInfo: [:])

                    // Fill white background
                    UIColor.white.setFill()
                    UIRectFill(pageRect)

                    // Composite all visible layers
                    for layer in pageData.sortedLayers {
                        guard layer.isVisible else { continue }

                        if let drawing = try? PKDrawing(data: layer.drawingData) {
                            // Calculate scale to fit drawing in page
                            let drawingBounds = drawing.bounds
                            guard !drawingBounds.isEmpty else { continue }

                            let scaleX = pageWidth / max(drawingBounds.width, pageWidth)
                            let scaleY = pageHeight / max(drawingBounds.height, pageHeight)
                            let scale = min(scaleX, scaleY, 1.0)

                            // Render the drawing to an image
                            let image = drawing.image(from: drawingBounds, scale: UIScreen.main.scale)

                            // Apply layer opacity
                            let destRect = CGRect(
                                x: 0,
                                y: 0,
                                width: drawingBounds.width * scale,
                                height: drawingBounds.height * scale
                            )

                            image.draw(in: destRect, blendMode: .normal, alpha: layer.opacity)
                        }
                    }
                }
            }
            return tempURL
        } catch {
            print("PDF export error: \(error)")
            return nil
        }
    }
}
#endif
