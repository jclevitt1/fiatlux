//
//  Note.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import Foundation
import SwiftUI

#if os(iOS)
import PencilKit
#endif

// NoteMode removed - no longer needed
// Notes are now just notes, execution happens via the Execute button

struct Note: Identifiable, Hashable {
    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var id: UUID
    var title: String
    var pages: [PageData]  // Array of page data with orientation
    var createdAt: Date
    var updatedAt: Date

    // Legacy support for old Data format
    var drawingData: Data {
        get { pages.first?.drawingData ?? Data() }
        set {
            if pages.isEmpty {
                pages = [PageData(drawingData: newValue)]
            } else {
                pages[0].drawingData = newValue
            }
        }
    }

    init(id: UUID = UUID(), title: String = "", pages: [PageData] = [PageData()],
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.pages = pages.isEmpty ? [PageData()] : pages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    #if os(iOS)
    var drawing: PKDrawing {
        get {
            (try? PKDrawing(data: drawingData)) ?? PKDrawing()
        }
        set {
            drawingData = newValue.dataRepresentation()
        }
    }
    #endif
}

// Custom Codable to handle migration (ignore old mode/selectedProject fields)
extension Note: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, pages, createdAt, updatedAt
        // Old keys (ignored during decode, not encoded):
        // mode, selectedProjectId, selectedProjectName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        pages = try container.decodeIfPresent([PageData].self, forKey: .pages) ?? [PageData()]
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Ensure at least one page
        if pages.isEmpty {
            pages = [PageData()]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(pages, forKey: .pages)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
