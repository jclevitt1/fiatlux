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
            print("DEBUG PDFExporter: Processing page \(pageIndex), data size: \(pageData.drawingData.count), orientation: \(pageData.orientation.rawValue)")

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

            // Find bounds of all content (lines + shapes)
            var minX: CGFloat = .greatestFiniteMagnitude
            var minY: CGFloat = .greatestFiniteMagnitude
            var maxX: CGFloat = 0
            var maxY: CGFloat = 0

            // Decode the drawing lines
            let lines = (try? JSONDecoder().decode([DrawingLine].self, from: pageData.drawingData)) ?? []
            print("DEBUG PDFExporter: Decoded \(lines.count) lines, \(pageData.shapes.count) shapes")

            for line in lines {
                for point in line.points {
                    minX = min(minX, point.x)
                    minY = min(minY, point.y)
                    maxX = max(maxX, point.x)
                    maxY = max(maxY, point.y)
                }
            }

            for shape in pageData.shapes {
                let bounds = shape.bounds
                minX = min(minX, bounds.minX)
                minY = min(minY, bounds.minY)
                maxX = max(maxX, bounds.maxX)
                maxY = max(maxY, bounds.maxY)
            }

            // Canvas aspect ratio depends on page orientation
            let canvasRatio: CGFloat = pageData.orientation.aspectRatio
            let estimatedCanvasWidth = max(maxX + 20, 400)
            let estimatedCanvasHeight = estimatedCanvasWidth * canvasRatio

            // Scale to fit PDF while maintaining aspect ratio
            let scale = min(pageWidth / estimatedCanvasWidth, pageHeight / estimatedCanvasHeight)

            // Draw lines
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
                        y: pageHeight - (firstPoint.y * scale)
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

            // Draw shapes
            for shape in pageData.shapes {
                pdfContext.setStrokeColor(CGColor(
                    red: shape.strokeColor.red,
                    green: shape.strokeColor.green,
                    blue: shape.strokeColor.blue,
                    alpha: shape.strokeColor.alpha
                ))
                pdfContext.setLineWidth(shape.strokeWidth * scale)

                // Transform helper for PDF coordinates
                func pdfPoint(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: p.x * scale, y: pageHeight - (p.y * scale))
                }

                switch shape.type {
                case .rectangle:
                    let bounds = shape.bounds
                    let pdfBounds = CGRect(
                        x: bounds.minX * scale,
                        y: pageHeight - (bounds.maxY * scale),
                        width: bounds.width * scale,
                        height: bounds.height * scale
                    )
                    if let fill = shape.fillColor {
                        pdfContext.setFillColor(CGColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha))
                        pdfContext.fill(pdfBounds)
                    }
                    pdfContext.stroke(pdfBounds)

                case .circle:
                    let bounds = shape.bounds
                    let pdfBounds = CGRect(
                        x: bounds.minX * scale,
                        y: pageHeight - (bounds.maxY * scale),
                        width: bounds.width * scale,
                        height: bounds.height * scale
                    )
                    if let fill = shape.fillColor {
                        pdfContext.setFillColor(CGColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: fill.alpha))
                        pdfContext.fillEllipse(in: pdfBounds)
                    }
                    pdfContext.strokeEllipse(in: pdfBounds)

                case .line:
                    pdfContext.beginPath()
                    pdfContext.move(to: pdfPoint(shape.startPoint))
                    pdfContext.addLine(to: pdfPoint(shape.endPoint))
                    pdfContext.strokePath()

                case .arrow:
                    // Main line
                    let start = pdfPoint(shape.startPoint)
                    let end = pdfPoint(shape.endPoint)
                    pdfContext.beginPath()
                    pdfContext.move(to: start)
                    pdfContext.addLine(to: end)
                    pdfContext.strokePath()

                    // Arrowhead
                    let angle = atan2(end.y - start.y, end.x - start.x)
                    let arrowLength: CGFloat = 15 * scale
                    let arrowAngle: CGFloat = .pi / 6

                    let arrow1 = CGPoint(
                        x: end.x - arrowLength * cos(angle - arrowAngle),
                        y: end.y - arrowLength * sin(angle - arrowAngle)
                    )
                    let arrow2 = CGPoint(
                        x: end.x - arrowLength * cos(angle + arrowAngle),
                        y: end.y - arrowLength * sin(angle + arrowAngle)
                    )

                    pdfContext.beginPath()
                    pdfContext.move(to: end)
                    pdfContext.addLine(to: arrow1)
                    pdfContext.move(to: end)
                    pdfContext.addLine(to: arrow2)
                    pdfContext.strokePath()
                }
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
    static let pageWidth: CGFloat = 612
    static let pageHeight: CGFloat = 792

    static func export(pages: [Data], title: String) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title).pdf")

        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        do {
            try pdfRenderer.writePDF(to: tempURL) { context in
                for pageData in pages {
                    context.beginPage()

                    // Try to render as PKDrawing
                    if let drawing = try? PKDrawing(data: pageData) {
                        let image = drawing.image(from: drawing.bounds, scale: 1.0)
                        let rect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
                        image.draw(in: rect)
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
