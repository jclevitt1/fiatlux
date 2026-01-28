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

            // Multi-page notebook
            #if os(iOS)
            CanvasView(canvasView: $canvasView, toolPicker: $toolPicker)
                .onAppear {
                    if let note = note {
                        canvasView.drawing = note.drawing
                    }
                }
            #else
            GeometryReader { geometry in
                let availableWidth = geometry.size.width - 40  // padding
                let availableHeight = geometry.size.height - 40

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(pages.indices, id: \.self) { index in
                                PageCanvasView(
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
        let savedPages = [canvasView.drawing.dataRepresentation()]
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
        let exportPages = [canvasView.drawing.dataRepresentation()]
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
        let backupPages = [canvasView.drawing.dataRepresentation()]
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
}

#if os(macOS)
struct PageCanvasView: View {
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
        CanvasView(drawingData: $page.drawingData, currentTool: $currentTool)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .onAppear(perform: onAppear)
    }
}
#endif

#Preview {
    NoteEditorView(store: NotesStore())
}
