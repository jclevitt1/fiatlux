//
//  NoteEditorView.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/19/26.
//

import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import PencilKit
#endif

#if os(macOS)
import AppKit
#endif

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss

    var note: Note?
    var store: NotesStore
    var parentFolderId: UUID?

    @State private var title: String = ""
    @State private var pages: [PageData] = [PageData()]
    @State private var noteId: UUID
    @State private var currentTool: DrawingTool = .pencil
    @State private var currentMode: NoteMode = .notes
    @State private var showingModeMenu: Bool = false
    @State private var exportMessage: String? = nil
    @State private var showingExportAlert: Bool = false
    @State private var currentPageIndex: Int = 0
    @State private var showingPageSettings: Bool = false
    @State private var isBackingUp: Bool = false
    @State private var backupMessage: String? = nil
    @State private var showingBackupAlert: Bool = false
    @State private var showingLayersPanel: Bool = false
    @State private var editingLayerName: UUID? = nil
    @State private var editingLayerText: String = ""

    #if os(iOS)
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    #endif

    // 8.5 x 11 ratio (11/8.5 = 1.294)
    private let pageAspectRatio: CGFloat = 11.0 / 8.5

    init(note: Note? = nil, store: NotesStore, parentFolder: Folder? = nil) {
        self.note = note
        self.store = store
        self.parentFolderId = parentFolder?.id
        _title = State(initialValue: note?.title ?? "")
        _pages = State(initialValue: note?.pages ?? [PageData()])
        _noteId = State(initialValue: note?.id ?? UUID())
        _currentMode = State(initialValue: note?.mode ?? .notes)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Title", text: $title)
                    .font(.headline)
                    #if os(macOS)
                    .textFieldStyle(.plain)
                    #endif

                Spacer()

                // Tool buttons
                HStack(spacing: 16) {
                    Button {
                        currentTool = .pencil
                    } label: {
                        Image(systemName: "pencil")
                            .font(.title2)
                            .foregroundStyle(currentTool == .pencil ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        currentTool = .eraser
                    } label: {
                        Image(systemName: "eraser")
                            .font(.title2)
                            .foregroundStyle(currentTool == .eraser ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .frame(height: 24)

                    Button {
                        exportToPDF()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export as PDF")

                    Button {
                        backupToGoogleDrive()
                    } label: {
                        if isBackingUp {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Backup to Google Drive")
                    .disabled(isBackingUp)

                    Button {
                        showingPageSettings.toggle()
                    } label: {
                        Image(systemName: pages[currentPageIndex].orientation.icon)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Page Settings")
                    .popover(isPresented: $showingPageSettings, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Page \(currentPageIndex + 1) Orientation")
                                .font(.headline)
                                .padding(.bottom, 4)

                            ForEach(PageOrientation.allCases, id: \.self) { orientation in
                                Button {
                                    pages[currentPageIndex].orientation = orientation
                                    showingPageSettings = false
                                } label: {
                                    HStack {
                                        Image(systemName: orientation.icon)
                                            .frame(width: 24)
                                        Text(orientation.rawValue)
                                        Spacer()
                                        if pages[currentPageIndex].orientation == orientation {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .frame(width: 200)
                    }

                    Button {
                        showingLayersPanel.toggle()
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.title2)
                            .foregroundStyle(showingLayersPanel ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Layers")
                }

                Spacer()
                    .frame(width: 24)

                // Mode selector
                Button {
                    showingModeMenu.toggle()
                } label: {
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .fill(currentMode.color.opacity(0.2))
                                .frame(width: 36, height: 36)
                            Image(systemName: currentMode.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(currentMode.color)
                        }
                        Text(currentMode.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingModeMenu, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(NoteMode.allCases, id: \.self) { mode in
                            Button {
                                currentMode = mode
                                showingModeMenu = false
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(mode.color.opacity(0.2))
                                            .frame(width: 32, height: 32)
                                        Image(systemName: mode.icon)
                                            .font(.system(size: 14))
                                            .foregroundStyle(mode.color)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.rawValue)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text(modeDescription(mode))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if mode == currentMode {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if mode != NoteMode.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .frame(width: 240)
                    .padding(.vertical, 8)
                }
            }
            .padding()

            Divider()

            // Multi-page notebook with layers
            #if os(iOS)
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let canvasSize = calculateCanvasSize(
                        availableWidth: geometry.size.width - (showingLayersPanel ? 220 : 0),
                        availableHeight: geometry.size.height,
                        orientation: pages[currentPageIndex].orientation
                    )

                    LayeredCanvasView(
                        page: $pages[currentPageIndex],
                        canvasView: $canvasView,
                        toolPicker: $toolPicker,
                        canvasSize: canvasSize
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        loadActiveLayerToCanvas()
                    }
                    .onChange(of: pages[currentPageIndex].activeLayerIndex) { _, _ in
                        saveCurrentLayerAndLoadNew()
                    }
                }

                if showingLayersPanel {
                    LayersPanelView(
                        page: $pages[currentPageIndex],
                        editingLayerName: $editingLayerName,
                        editingLayerText: $editingLayerText,
                        onLayerSwitch: { saveCurrentLayerAndLoadNew() }
                    )
                    .frame(width: 220)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showingLayersPanel)
            #else
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let availableWidth = geometry.size.width - (showingLayersPanel ? 260 : 40)
                    let availableHeight = geometry.size.height - 40

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 20) {
                                ForEach(pages.indices, id: \.self) { index in
                                    LayeredPageCanvasView(
                                        page: $pages[index],
                                        currentTool: $currentTool,
                                        availableWidth: availableWidth,
                                        availableHeight: availableHeight,
                                        onAppear: { currentPageIndex = index }
                                    )
                                    .id(index)
                                }

                                // Add page button
                                Button {
                                    pages.append(PageData())
                                } label: {
                                    HStack {
                                        Image(systemName: "plus.circle")
                                        Text("Add Page")
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding()
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                        }
                    }
                }

                if showingLayersPanel {
                    LayersPanelView(
                        page: $pages[currentPageIndex],
                        editingLayerName: $editingLayerName,
                        editingLayerText: $editingLayerText,
                        onLayerSwitch: {}
                    )
                    .frame(width: 220)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showingLayersPanel)
            #endif
        }
        .navigationTitle(title.isEmpty ? "New Note" : title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onDisappear {
            save()
        }
        .alert("Export PDF", isPresented: $showingExportAlert) {
            Button("OK") { }
        } message: {
            Text(exportMessage ?? "")
        }
        .alert("Backup", isPresented: $showingBackupAlert) {
            Button("OK") { }
        } message: {
            Text(backupMessage ?? "")
        }
    }

    private func save() {
        #if os(iOS)
        // Save current canvas drawing to active layer before persisting
        var savedPages = pages
        if currentPageIndex < savedPages.count {
            let activeIndex = savedPages[currentPageIndex].activeLayerIndex
            if activeIndex < savedPages[currentPageIndex].layers.count {
                savedPages[currentPageIndex].layers[activeIndex].drawingData = canvasView.drawing.dataRepresentation()
            }
        }
        #else
        let savedPages = pages
        #endif

        let savedNote = Note(
            id: noteId,
            title: title.isEmpty ? "Untitled" : title,
            pages: savedPages,
            mode: currentMode,
            createdAt: note?.createdAt ?? Date(),
            updatedAt: Date()
        )

        if note != nil {
            // Updating existing note
            store.updateNoteInPlace(savedNote)
        } else if let folderId = parentFolderId {
            // Adding to a folder (works for any nesting depth)
            store.addNote(savedNote, toFolderWithId: folderId)
        } else {
            // Adding to root
            store.addNote(savedNote)
        }
    }

    private func modeDescription(_ mode: NoteMode) -> String {
        switch mode {
        case .notes:
            return "Just taking notes"
        case .createProject:
            return "AI creates a new project"
        case .existingProject:
            return "AI works on existing code"
        }
    }

    private func exportToPDF() {
        let exportTitle = title.isEmpty ? "Untitled" : title

        #if os(iOS)
        // Save current canvas drawing to active layer before export
        var exportPages = pages
        if currentPageIndex < exportPages.count {
            let activeIndex = exportPages[currentPageIndex].activeLayerIndex
            if activeIndex < exportPages[currentPageIndex].layers.count {
                exportPages[currentPageIndex].layers[activeIndex].drawingData = canvasView.drawing.dataRepresentation()
            }
        }
        #else
        let exportPages = pages
        #endif

        // Save to app's documents directory (sandbox-safe)
        if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let filename = "\(exportTitle).pdf"
            let destinationURL = docsURL.appendingPathComponent(filename)

            // Remove existing file if present
            try? FileManager.default.removeItem(at: destinationURL)

            if let tempURL = PDFExporter.export(pages: exportPages, title: exportTitle) {
                do {
                    try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                    exportMessage = "PDF saved to:\n\(destinationURL.path)"
                    showingExportAlert = true

                    #if os(macOS)
                    // Try to reveal in Finder
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                    #endif
                } catch {
                    exportMessage = "Failed to save: \(error.localizedDescription)"
                    showingExportAlert = true
                }
            } else {
                exportMessage = "Failed to create PDF"
                showingExportAlert = true
            }
        } else {
            exportMessage = "Cannot access documents folder"
            showingExportAlert = true
        }
    }

    private func backupToGoogleDrive() {
        let backupTitle = title.isEmpty ? "Untitled" : title

        #if os(iOS)
        // Save current canvas drawing to active layer before backup
        var backupPages = pages
        if currentPageIndex < backupPages.count {
            let activeIndex = backupPages[currentPageIndex].activeLayerIndex
            if activeIndex < backupPages[currentPageIndex].layers.count {
                backupPages[currentPageIndex].layers[activeIndex].drawingData = canvasView.drawing.dataRepresentation()
            }
        }
        #else
        let backupPages = pages
        #endif

        // Generate PDF
        guard let pdfURL = PDFExporter.export(pages: backupPages, title: backupTitle) else {
            backupMessage = "Failed to create PDF for backup"
            showingBackupAlert = true
            return
        }

        // Read PDF data
        guard let pdfData = try? Data(contentsOf: pdfURL) else {
            backupMessage = "Failed to read PDF data"
            showingBackupAlert = true
            return
        }

        // Build path: use mode as subfolder
        let modeFolder = currentMode.rawValue.replacingOccurrences(of: " ", with: "_")
        let fileName = "\(backupTitle).pdf"
        let path = "\(modeFolder)/\(fileName)"

        isBackingUp = true

        Task {
            do {
                let response = try await BackendService.shared.uploadPDF(data: pdfData, path: path)

                // Auto-trigger processing (if backend is in webhook mode)
                let triggerResult = await BackendService.shared.trigger(filePath: response.path)

                await MainActor.run {
                    isBackingUp = false
                    if let trigger = triggerResult, trigger.triggered {
                        backupMessage = "Uploaded & processing:\n\(response.path)\nJob: \(trigger.job?.job_id ?? "unknown")"
                    } else {
                        backupMessage = "Uploaded to:\n\(response.path)\n(trigger not available)"
                    }
                    showingBackupAlert = true
                }
            } catch {
                await MainActor.run {
                    isBackingUp = false
                    backupMessage = "Backup failed: \(error.localizedDescription)"
                    showingBackupAlert = true
                }
            }
        }
    }

    #if os(iOS)
    private func calculateCanvasSize(availableWidth: CGFloat, availableHeight: CGFloat, orientation: PageOrientation) -> CGSize {
        let aspectRatio = orientation.aspectRatio

        if orientation == .portrait {
            let maxHeight = availableHeight * 0.95
            let widthFromHeight = maxHeight / aspectRatio

            if widthFromHeight <= availableWidth {
                return CGSize(width: widthFromHeight, height: maxHeight)
            } else {
                return CGSize(width: availableWidth, height: availableWidth * aspectRatio)
            }
        } else {
            return CGSize(width: availableWidth, height: availableWidth * aspectRatio)
        }
    }

    private func loadActiveLayerToCanvas() {
        guard currentPageIndex < pages.count else { return }
        let page = pages[currentPageIndex]
        guard let activeLayer = page.activeLayer else { return }

        if let drawing = try? PKDrawing(data: activeLayer.drawingData) {
            canvasView.drawing = drawing
        } else {
            canvasView.drawing = PKDrawing()
        }
    }

    private func saveCurrentLayerAndLoadNew() {
        guard currentPageIndex < pages.count else { return }

        // Save current drawing to active layer
        let activeIndex = pages[currentPageIndex].activeLayerIndex
        if activeIndex < pages[currentPageIndex].layers.count {
            pages[currentPageIndex].layers[activeIndex].drawingData = canvasView.drawing.dataRepresentation()
        }

        // Load new active layer
        loadActiveLayerToCanvas()
    }
    #endif
}

/// Layers panel sidebar for managing drawing layers
struct LayersPanelView: View {
    @Binding var page: PageData
    @Binding var editingLayerName: UUID?
    @Binding var editingLayerText: String
    var onLayerSwitch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button {
                    page.addLayer()
                    onLayerSwitch()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Add Layer")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Layer list (reverse order so top layer shows first)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(page.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                        LayerRowView(
                            layer: layer,
                            isActive: index == page.activeLayerIndex,
                            isEditing: editingLayerName == layer.id,
                            editingText: $editingLayerText,
                            onSelect: {
                                if index != page.activeLayerIndex {
                                    page.activeLayerIndex = index
                                    onLayerSwitch()
                                }
                            },
                            onToggleVisibility: {
                                page.layers[index].isVisible.toggle()
                            },
                            onStartRename: {
                                editingLayerName = layer.id
                                editingLayerText = layer.name
                            },
                            onFinishRename: {
                                if !editingLayerText.isEmpty {
                                    page.layers[index].name = editingLayerText
                                }
                                editingLayerName = nil
                            },
                            onDelete: {
                                page.deleteLayer(at: index)
                            },
                            canDelete: page.layers.count > 1
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Opacity slider for active layer
            if let activeIndex = page.layers.indices.contains(page.activeLayerIndex) ? page.activeLayerIndex : nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opacity: \(Int(page.layers[activeIndex].opacity * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $page.layers[activeIndex].opacity, in: 0...1)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color(white: 0.95))
    }
}

/// Individual layer row in the layers panel
struct LayerRowView: View {
    let layer: DrawingLayer
    let isActive: Bool
    let isEditing: Bool
    @Binding var editingText: String
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onStartRename: () -> Void
    let onFinishRename: () -> Void
    let onDelete: () -> Void
    let canDelete: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Visibility toggle
            Button {
                onToggleVisibility()
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(layer.isVisible ? .primary : .secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            // Layer name or edit field
            if isEditing {
                TextField("Layer name", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        onFinishRename()
                    }
            } else {
                Text(layer.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        onStartRename()
                    }
            }

            Spacer()

            // Delete button
            if canDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .opacity(isActive ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.blue.opacity(0.15) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}

#if os(macOS)
struct LayeredPageCanvasView: View {
    @Binding var page: PageData
    @Binding var currentTool: DrawingTool
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let onAppear: () -> Void

    private var canvasSize: CGSize {
        // aspectRatio is height/width: portrait=1.294 (tall), landscape=0.773 (wide)
        let aspectRatio = page.orientation.aspectRatio

        if page.orientation == .portrait {
            // Portrait: fit within available height, then compute width
            let maxHeight = availableHeight * 0.85  // Leave some margin
            let widthFromHeight = maxHeight / aspectRatio

            if widthFromHeight <= availableWidth {
                // Height-constrained
                return CGSize(width: widthFromHeight, height: maxHeight)
            } else {
                // Width-constrained (narrow window)
                return CGSize(width: availableWidth, height: availableWidth * aspectRatio)
            }
        } else {
            // Landscape: use available width, compute height
            return CGSize(width: availableWidth, height: availableWidth * aspectRatio)
        }
    }

    var body: some View {
        LayeredCanvasView(page: $page, currentTool: $currentTool, canvasSize: canvasSize)
            .onAppear(perform: onAppear)
    }
}
#endif

#Preview {
    NoteEditorView(store: NotesStore())
}
