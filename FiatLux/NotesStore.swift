//
//  NotesStore.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import Foundation

@Observable
class NotesStore {
    var items: [NotesItem] = []

    private let saveKey = "FiatLux.items"

    init() {
        load()
    }

    // MARK: - Add items

    func addNote(_ note: Note) {
        items.insert(.note(note), at: 0)
        save()
    }

    func addNote(_ note: Note, toFolderWithId folderId: UUID) {
        if addNoteToFolder(note, folderId: folderId, in: &items) {
            save()
        }
    }

    private func addNoteToFolder(_ note: Note, folderId: UUID, in items: inout [NotesItem]) -> Bool {
        for (index, item) in items.enumerated() {
            if case .folder(var folder) = item {
                if folder.id == folderId {
                    folder.items.insert(.note(note), at: 0)
                    folder.updatedAt = Date()
                    items[index] = .folder(folder)
                    return true
                }
                if addNoteToFolder(note, folderId: folderId, in: &folder.items) {
                    folder.updatedAt = Date()
                    items[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    func addFolder(_ folder: Folder) {
        items.insert(.folder(folder), at: 0)
        save()
    }

    // MARK: - Update items

    func update(_ note: Note) {
        if let index = findNoteIndex(note.id, in: &items) {
            var updated = note
            updated.updatedAt = Date()
            items[index] = .note(updated)
            save()
        }
    }

    func updateFolder(_ folder: Folder) {
        // Try to update at root level first
        if let index = items.firstIndex(where: { $0.id == folder.id }) {
            var updated = folder
            updated.updatedAt = Date()
            items[index] = .folder(updated)
            save()
            return
        }
        // Otherwise search recursively
        if updateFolderRecursively(folder, in: &items) {
            save()
        }
    }

    private func updateFolderRecursively(_ folder: Folder, in items: inout [NotesItem]) -> Bool {
        for (index, item) in items.enumerated() {
            if case .folder(var parentFolder) = item {
                // Check if this folder contains the target
                if let childIndex = parentFolder.items.firstIndex(where: { $0.id == folder.id }) {
                    var updated = folder
                    updated.updatedAt = Date()
                    parentFolder.items[childIndex] = .folder(updated)
                    parentFolder.updatedAt = Date()
                    items[index] = .folder(parentFolder)
                    return true
                }
                // Recurse deeper
                if updateFolderRecursively(folder, in: &parentFolder.items) {
                    parentFolder.updatedAt = Date()
                    items[index] = .folder(parentFolder)
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Delete items

    func delete(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func deleteItem(_ item: NotesItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - Helper to find note recursively

    private func findNoteIndex(_ id: UUID, in items: inout [NotesItem]) -> Int? {
        for (index, item) in items.enumerated() {
            switch item {
            case .note(let note):
                if note.id == id { return index }
            case .folder(var folder):
                if let nestedIndex = findNoteIndex(id, in: &folder.items) {
                    var updatedFolder = folder
                    if case .note(var note) = folder.items[nestedIndex] {
                        note.updatedAt = Date()
                        updatedFolder.items[nestedIndex] = .note(note)
                        updatedFolder.updatedAt = Date()
                        items[index] = .folder(updatedFolder)
                    }
                    return nil // Handled in nested
                }
            }
        }
        return nil
    }

    func updateNoteInPlace(_ note: Note) {
        updateNoteRecursively(note, in: &items)
        save()
    }

    private func updateNoteRecursively(_ note: Note, in items: inout [NotesItem]) -> Bool {
        for (index, item) in items.enumerated() {
            switch item {
            case .note(let existingNote):
                if existingNote.id == note.id {
                    items[index] = .note(note)
                    return true
                }
            case .folder(var folder):
                if updateNoteRecursively(note, in: &folder.items) {
                    folder.updatedAt = Date()
                    items[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([NotesItem].self, from: data) {
            items = decoded
        }
    }
}
