//
//  NotesItem.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import Foundation

enum NotesItem: Identifiable, Codable, Hashable {
    case note(Note)
    case folder(Folder)

    var id: UUID {
        switch self {
        case .note(let note): return note.id
        case .folder(let folder): return folder.id
        }
    }

    var name: String {
        switch self {
        case .note(let note): return note.title
        case .folder(let folder): return folder.name
        }
    }

    var updatedAt: Date {
        switch self {
        case .note(let note): return note.updatedAt
        case .folder(let folder): return folder.updatedAt
        }
    }

    static func == (lhs: NotesItem, rhs: NotesItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct Folder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var items: [NotesItem]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String = "New Folder", items: [NotesItem] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func == (lhs: Folder, rhs: Folder) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
