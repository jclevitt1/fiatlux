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
    @State private var store = NotesStore()
    @State private var isCreatingNote = false
    @State private var showingAddMenu = false
    @State private var folderName = ""
    @State private var showingFolderAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Tap + to create your first note or folder")
                    )
                } else {
                    List {
                        ForEach(store.items) { item in
                            switch item {
                            case .note(let note):
                                NavigationLink(value: item) {
                                    NoteRowView(note: note)
                                }
                            case .folder(let folder):
                                NavigationLink(value: item) {
                                    FolderRowView(folder: folder)
                                }
                            }
                        }
                        .onDelete(perform: store.delete)
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isCreatingNote = true
                        } label: {
                            Label("New Note", systemImage: "note.text.badge.plus")
                        }

                        Button {
                            folderName = ""
                            showingFolderAlert = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
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
                case .folder(let folder):
                    FolderView(folder: folder, store: store)
                }
            }
            .navigationDestination(isPresented: $isCreatingNote) {
                NoteEditorView(store: store)
            }
            .alert("New Folder", isPresented: $showingFolderAlert) {
                TextField("Folder name", text: $folderName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    if !folderName.isEmpty {
                        store.addFolder(Folder(name: folderName))
                    }
                }
            } message: {
                Text("Enter a name for the new folder")
            }
        }
    }
}

struct FolderRowView: View {
    let folder: Folder

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 60, height: 60)
                Image(systemName: "folder.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                Text("\(folder.items.count) item\(folder.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(folder.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FolderView: View {
    let folderId: UUID
    let initialFolder: Folder
    var store: NotesStore

    @State private var isCreatingNote = false
    @State private var folderName = ""
    @State private var showingFolderAlert = false

    init(folder: Folder, store: NotesStore) {
        self.folderId = folder.id
        self.initialFolder = folder
        self.store = store
    }

    // Find the current folder from store (refreshes on changes)
    private var currentFolder: Folder {
        findFolder(id: folderId, in: store.items) ?? initialFolder
    }

    private func findFolder(id: UUID, in items: [NotesItem]) -> Folder? {
        for item in items {
            switch item {
            case .folder(let folder):
                if folder.id == id { return folder }
                if let found = findFolder(id: id, in: folder.items) { return found }
            case .note:
                continue
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if currentFolder.items.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("Tap + to add notes or folders")
                )
            } else {
                List {
                    ForEach(currentFolder.items) { item in
                        switch item {
                        case .note(let note):
                            NavigationLink(value: item) {
                                NoteRowView(note: note)
                            }
                        case .folder(let subfolder):
                            NavigationLink(value: item) {
                                FolderRowView(folder: subfolder)
                            }
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
        }
        .navigationTitle(currentFolder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isCreatingNote = true
                    } label: {
                        Label("New Note", systemImage: "note.text.badge.plus")
                    }

                    Button {
                        folderName = ""
                        showingFolderAlert = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
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
            case .folder(let subfolder):
                FolderView(folder: subfolder, store: store)
            }
        }
        .navigationDestination(isPresented: $isCreatingNote) {
            NoteEditorView(store: store, parentFolder: currentFolder)
        }
        .alert("New Folder", isPresented: $showingFolderAlert) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                if !folderName.isEmpty {
                    var updated = currentFolder
                    updated.items.insert(.folder(Folder(name: folderName)), at: 0)
                    store.updateFolder(updated)
                }
            }
        } message: {
            Text("Enter a name for the new folder")
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        var updated = currentFolder
        updated.items.remove(atOffsets: offsets)
        store.updateFolder(updated)
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
                Text(note.title)
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
}
