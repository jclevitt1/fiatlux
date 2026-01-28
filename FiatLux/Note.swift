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

enum NoteMode: String, Codable, CaseIterable {
    case notes = "Notes"
    case createProject = "Create Project"
    case existingProject = "Existing Project"

    var icon: String {
        switch self {
        case .notes: return "note.text"
        case .createProject: return "plus.square"
        case .existingProject: return "folder"
        }
    }

    var color: Color {
        switch self {
        case .notes: return .blue
        case .createProject: return .green
        case .existingProject: return .orange
        }
    }
}

struct Note: Identifiable, Codable, Hashable {
    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    var id: UUID
    var title: String
    var pages: [PageData]  // Array of page data with orientation
    var mode: NoteMode
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

    init(id: UUID = UUID(), title: String = "", pages: [PageData] = [PageData()], mode: NoteMode = .notes, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.pages = pages.isEmpty ? [PageData()] : pages
        self.mode = mode
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
