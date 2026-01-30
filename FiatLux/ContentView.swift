//
//  ContentView.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import SwiftUI

#if os(iOS)
import PencilKit
#endif

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var store = NotesStore()
    @State private var isCreatingNote = false
    @State private var showingAddMenu = false
    @State private var projectName = ""
    @State private var showingProjectAlert = false
    @State private var showingUserMenu = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Tap + to create your first note or project")
                    )
                } else {
                    List {
                        ForEach(store.items) { item in
                            switch item {
                            case .note(let note):
                                NavigationLink(value: item) {
                                    NoteRowView(note: note)
                                }
                            case .project(let project):
                                NavigationLink(value: item) {
                                    ProjectRowView(project: project)
                                }
                            }
                        }
                        .onDelete(perform: store.delete)
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        if let user = authManager.currentUser {
                            Text(user.displayName)
                                .font(.headline)
                            Text(user.email)
                                .font(.caption)

                            Divider()
                        }

                        Button(role: .destructive) {
                            authManager.signOut()
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        if let user = authManager.currentUser {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 32, height: 32)
                                Text(user.initials)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Image(systemName: "person.circle")
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isCreatingNote = true
                        } label: {
                            Label("New Note", systemImage: "note.text.badge.plus")
                        }

                        Button {
                            projectName = ""
                            showingProjectAlert = true
                        } label: {
                            Label("New Project", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: NotesItem.self) { item in
                switch item {
                case .note(let note):
                    NoteEditorView(note: note, store: store)
                case .project(let project):
                    ProjectView(project: project, store: store)
                }
            }
            .navigationDestination(isPresented: $isCreatingNote) {
                NoteEditorView(store: store)
            }
            .alert("New Project", isPresented: $showingProjectAlert) {
                TextField("Project name", text: $projectName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    if !projectName.isEmpty {
                        store.addProject(Project(name: projectName))
                    }
                }
            } message: {
                Text("Enter a name for the new project")
            }
        }
    }
}

struct ProjectRowView: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 60, height: 60)
                Image(systemName: "folder.fill")
                    .font(.title)
                    .foregroundStyle(.purple)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                Text("\(project.items.count) item\(project.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(project.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ProjectView: View {
    let projectId: UUID
    let initialProject: Project
    var store: NotesStore

    @State private var isCreatingNote = false
    @State private var projectName = ""
    @State private var showingProjectAlert = false

    init(project: Project, store: NotesStore) {
        self.projectId = project.id
        self.initialProject = project
        self.store = store
    }

    // Find the current project from store (refreshes on changes)
    private var currentProject: Project {
        findProject(id: projectId, in: store.items) ?? initialProject
    }

    private func findProject(id: UUID, in items: [NotesItem]) -> Project? {
        for item in items {
            switch item {
            case .project(let project):
                if project.id == id { return project }
                if let found = findProject(id: id, in: project.items) { return found }
            case .note:
                continue
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if currentProject.items.isEmpty {
                VStack(spacing: 20) {
                    // Check Project Files link (placeholder)
                    if currentProject.cloudProjectId != nil {
                        checkProjectFilesLink
                    }

                    Spacer()

                    ContentUnavailableView(
                        "Empty Project",
                        systemImage: "folder",
                        description: Text("Tap + to add notes")
                    )

                    Spacer()
                }
            } else {
                List {
                    // Check Project Files link at top
                    if currentProject.cloudProjectId != nil {
                        Section {
                            checkProjectFilesLink
                        }
                    }

                    Section {
                        ForEach(currentProject.items) { item in
                            switch item {
                            case .note(let note):
                                NavigationLink(value: item) {
                                    NoteRowView(note: note)
                                }
                            case .project(let subproject):
                                NavigationLink(value: item) {
                                    ProjectRowView(project: subproject)
                                }
                            }
                        }
                        .onDelete(perform: deleteItems)
                    }
                }
            }
        }
        .navigationTitle(currentProject.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isCreatingNote = true
                    } label: {
                        Label("New Note", systemImage: "note.text.badge.plus")
                    }

                    Button {
                        projectName = ""
                        showingProjectAlert = true
                    } label: {
                        Label("New Sub-Project", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: NotesItem.self) { item in
            switch item {
            case .note(let note):
                NoteEditorView(note: note, store: store, parentProject: currentProject)
            case .project(let subproject):
                ProjectView(project: subproject, store: store)
            }
        }
        .navigationDestination(isPresented: $isCreatingNote) {
            NoteEditorView(store: store, parentProject: currentProject)
        }
        .alert("New Sub-Project", isPresented: $showingProjectAlert) {
            TextField("Project name", text: $projectName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                if !projectName.isEmpty {
                    var updated = currentProject
                    updated.items.insert(.project(Project(name: projectName)), at: 0)
                    store.updateProject(updated)
                }
            }
        } message: {
            Text("Enter a name for the new sub-project")
        }
    }

    private var checkProjectFilesLink: some View {
        Button {
            // TODO: Navigate to project files viewer
        } label: {
            HStack {
                Image(systemName: "folder.circle")
                    .foregroundStyle(.blue)
                Text("Check Project Files")
                    .foregroundStyle(.primary)
                Spacer()
                Text("Coming Soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func deleteItems(at offsets: IndexSet) {
        var updated = currentProject
        updated.items.remove(atOffsets: offsets)
        store.updateProject(updated)
    }
}

struct NoteRowView: View {
    let note: Note

    var body: some View {
        HStack(spacing: 12) {
            // Drawing thumbnail
            #if os(iOS)
            if !note.drawing.bounds.isEmpty {
                let image = note.drawing.image(from: note.drawing.bounds, scale: 1.0)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .background(Color.white)
                    .cornerRadius(8)
                    .shadow(radius: 1)
            } else {
                placeholderThumbnail
            }
            #else
            placeholderThumbnail
            #endif

            VStack(alignment: .leading, spacing: 4) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var placeholderThumbnail: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 60, height: 60)
            .overlay(
                Image(systemName: "scribble")
                    .foregroundStyle(.secondary)
            )
    }
}

#Preview {
    ContentView()
        .environment(AuthManager.shared)
}
