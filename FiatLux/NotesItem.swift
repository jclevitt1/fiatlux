//
//  NotesItem.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import Foundation

enum NotesItem: Identifiable, Hashable {
    case note(Note)
    case project(Project)  // Renamed from folder

    var id: UUID {
        switch self {
        case .note(let note): return note.id
        case .project(let project): return project.id
        }
    }

    var name: String {
        switch self {
        case .note(let note): return note.title
        case .project(let project): return project.name
        }
    }

    var updatedAt: Date {
        switch self {
        case .note(let note): return note.updatedAt
        case .project(let project): return project.updatedAt
        }
    }

    static func == (lhs: NotesItem, rhs: NotesItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// Custom Codable to handle migration from "folder" to "project"
extension NotesItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case note
        case project
        case folder  // Legacy key for backward compatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let note = try container.decodeIfPresent(Note.self, forKey: .note) {
            self = .note(note)
        } else if let project = try container.decodeIfPresent(Project.self, forKey: .project) {
            self = .project(project)
        } else if let folder = try container.decodeIfPresent(Project.self, forKey: .folder) {
            // Legacy: decode old "folder" as "project"
            self = .project(folder)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unable to decode NotesItem - no note, project, or folder key found"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .note(let note):
            try container.encode(note, forKey: .note)
        case .project(let project):
            try container.encode(project, forKey: .project)
        }
    }
}

struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var items: [NotesItem]
    var createdAt: Date
    var updatedAt: Date
    var cloudProjectId: String?  // Link to cloud project (populated after first execute)

    init(id: UUID = UUID(), name: String = "New Project", items: [NotesItem] = [],
         createdAt: Date = Date(), updatedAt: Date = Date(), cloudProjectId: String? = nil) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cloudProjectId = cloudProjectId
    }

    static func == (lhs: Project, rhs: Project) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
