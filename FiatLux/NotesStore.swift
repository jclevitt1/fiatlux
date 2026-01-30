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

    func addNote(_ note: Note, toProjectWithId projectId: UUID) {
        if addNoteToProject(note, projectId: projectId, in: &items) {
            save()
        }
    }

    private func addNoteToProject(_ note: Note, projectId: UUID, in items: inout [NotesItem]) -> Bool {
        for (index, item) in items.enumerated() {
            if case .project(var project) = item {
                if project.id == projectId {
                    project.items.insert(.note(note), at: 0)
                    project.updatedAt = Date()
                    items[index] = .project(project)
                    return true
                }
                if addNoteToProject(note, projectId: projectId, in: &project.items) {
                    project.updatedAt = Date()
                    items[index] = .project(project)
                    return true
                }
            }
        }
        return false
    }

    func addProject(_ project: Project) {
        items.insert(.project(project), at: 0)
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

    func updateProject(_ project: Project) {
        // Try to update at root level first
        if let index = items.firstIndex(where: { $0.id == project.id }) {
            var updated = project
            updated.updatedAt = Date()
            items[index] = .project(updated)
            save()
            return
        }
        // Otherwise search recursively
        if updateProjectRecursively(project, in: &items) {
            save()
        }
    }

    private func updateProjectRecursively(_ project: Project, in items: inout [NotesItem]) -> Bool {
        for (index, item) in items.enumerated() {
            if case .project(var parentProject) = item {
                // Check if this project contains the target
                if let childIndex = parentProject.items.firstIndex(where: { $0.id == project.id }) {
                    var updated = project
                    updated.updatedAt = Date()
                    parentProject.items[childIndex] = .project(updated)
                    parentProject.updatedAt = Date()
                    items[index] = .project(parentProject)
                    return true
                }
                // Recurse deeper
                if updateProjectRecursively(project, in: &parentProject.items) {
                    parentProject.updatedAt = Date()
                    items[index] = .project(parentProject)
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
            case .project(var project):
                if let nestedIndex = findNoteIndex(id, in: &project.items) {
                    var updatedProject = project
                    if case .note(var note) = project.items[nestedIndex] {
                        note.updatedAt = Date()
                        updatedProject.items[nestedIndex] = .note(note)
                        updatedProject.updatedAt = Date()
                        items[index] = .project(updatedProject)
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
            case .project(var project):
                if updateNoteRecursively(note, in: &project.items) {
                    project.updatedAt = Date()
                    items[index] = .project(project)
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
