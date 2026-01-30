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
    var parentProjectId: UUID?
    var parentProjectName: String?

    @State private var title: String = ""
    @State private var pages: [PageData] = [PageData()]
    @State private var noteId: UUID
    @State private var currentTool: DrawingTool = .pencil
    @State private var exportMessage: String? = nil
    @State private var showingExportAlert: Bool = false
    @State private var currentPageIndex: Int = 0
    @State private var showingPageSettings: Bool = false
    @State private var isBackingUp: Bool = false
    @State private var backupMessage: String? = nil
    @State private var showingBackupAlert: Bool = false
    @State private var showingExecuteConfirm: Bool = false
    @State private var isExecuting: Bool = false
    @State private var executeMessage: String? = nil
    @State private var showingExecuteResult: Bool = false

    #if os(iOS)
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    #endif

    // 8.5 x 11 ratio (11/8.5 = 1.294)
    private let pageAspectRatio: CGFloat = 11.0 / 8.5

    init(note: Note? = nil, store: NotesStore, parentProject: Project? = nil) {
        self.note = note
        self.store = store
        self.parentProjectId = parentProject?.id
        self.parentProjectName = parentProject?.name
        _title = State(initialValue: note?.title ?? "")
        _pages = State(initialValue: note?.pages ?? [PageData()])
        _noteId = State(initialValue: note?.id ?? UUID())
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

                // Execute button (main action)
                Button {
                    showingExecuteConfirm = true
                } label: {
                    if isExecuting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing...")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.15))
                        .foregroundColor(.purple)
                        .cornerRadius(8)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.body)
                            Text("Execute")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                .buttonStyle(.plain)
                .help("Upload and process with Claude")
                .disabled(isExecuting)

                // Upload only button (secondary)
                Button {
                    backupToCloud()
                } label: {
                    if isBackingUp {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Upload only (no processing)")
                .disabled(isBackingUp || isExecuting)

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

                    Button {
                        currentTool = .text
                    } label: {
                        Image(systemName: "textformat")
                            .font(.title2)
                            .foregroundStyle(currentTool == .text ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Text Tool")

                    Button {
                        currentTool = .lasso
                    } label: {
                        Image(systemName: "lasso")
                            .font(.title2)
                            .foregroundStyle(currentTool == .lasso ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Lasso Select")

                    Menu {
                        Button { currentTool = .shape(.rectangle) } label: {
                            Label("Rectangle", systemImage: "rectangle")
                        }
                        Button { currentTool = .shape(.circle) } label: {
                            Label("Circle", systemImage: "circle")
                        }
                        Button { currentTool = .shape(.line) } label: {
                            Label("Line", systemImage: "line.diagonal")
                        }
                        Button { currentTool = .shape(.arrow) } label: {
                            Label("Arrow", systemImage: "arrow.right")
                        }
                        Divider()
                        Button { currentTool = .shapePen } label: {
                            Label("Shape Pen", systemImage: "pencil.and.scribble")
                        }
                    } label: {
                        Image(systemName: currentTool.isShapeTool ? "square.on.circle.fill" : "square.on.circle")
                            .font(.title2)
                            .foregroundStyle(currentTool.isShapeTool ? .blue : .secondary)
                    }
                    .help("Shapes")

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
            }
            .padding()

            Divider()

            // Multi-page notebook
            #if os(iOS)
            ZStack(alignment: .topTrailing) {
                CanvasView(canvasView: $canvasView, toolPicker: $toolPicker, currentTool: $currentTool)
                    .onAppear {
                        if let note = note {
                            canvasView.drawing = note.drawing
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 2)
                    )

                // Orientation indicator badge
                HStack(spacing: 4) {
                    Image(systemName: pages[currentPageIndex].orientation == .portrait ? "rectangle.portrait.fill" : "rectangle.fill")
                        .font(.caption2)
                    Text(pages[currentPageIndex].orientation == .portrait ? "Portrait" : "Landscape")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(4)
                .padding(12)
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
        .alert("Execute?", isPresented: $showingExecuteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Execute") {
                executeNote()
            }
        } message: {
            Text(executeConfirmMessage)
        }
        .alert("Execution Result", isPresented: $showingExecuteResult) {
            Button("OK") { }
        } message: {
            Text(executeMessage ?? "")
        }
    }

    private var executeConfirmMessage: String {
        if let projectName = parentProjectName {
            return "This will upload your notes to the project '\(projectName)' and process them with Claude AI."
        }
        return "This will upload your notes and process them with Claude AI."
    }

    private func save() {
        #if os(iOS)
        // Update current page's active layer with canvas drawing
        var updatedPages = pages
        if !updatedPages.isEmpty {
            updatedPages[currentPageIndex].layers[updatedPages[currentPageIndex].activeLayerIndex].drawingData = canvasView.drawing.dataRepresentation()
        }
        let savedPages = updatedPages
        #else
        let savedPages = pages
        #endif

        let savedNote = Note(
            id: noteId,
            title: title.isEmpty ? "Untitled" : title,
            pages: savedPages,
            createdAt: note?.createdAt ?? Date(),
            updatedAt: Date()
        )

        if note != nil {
            // Updating existing note
            store.updateNoteInPlace(savedNote)
        } else if let projectId = parentProjectId {
            // Adding to a project (works for any nesting depth)
            store.addNote(savedNote, toProjectWithId: projectId)
        } else {
            // Adding to root
            store.addNote(savedNote)
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

    private func backupToCloud() {
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

        // Build path: project_name/note_title.pdf or just note_title.pdf
        let fileName = "\(backupTitle).pdf"
        let path: String
        if let projectName = parentProjectName {
            path = "\(projectName)/\(fileName)"
        } else {
            path = fileName
        }

        isBackingUp = true

        Task {
            do {
                let response = try await BackendService.shared.uploadPDF(data: pdfData, path: path)

                await MainActor.run {
                    isBackingUp = false
                    backupMessage = "Uploaded to:\n\(response.path)"
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

    private func executeNote() {
        let executeTitle = title.isEmpty ? "Untitled" : title

        #if os(iOS)
        let executePages = [canvasView.drawing.dataRepresentation()]
        #else
        let executePages = pages
        #endif

        // Generate PDF
        guard let pdfURL = PDFExporter.export(pages: executePages, title: executeTitle) else {
            executeMessage = "Failed to create PDF"
            showingExecuteResult = true
            return
        }

        // Read PDF data
        guard let pdfData = try? Data(contentsOf: pdfURL) else {
            executeMessage = "Failed to read PDF data"
            showingExecuteResult = true
            return
        }

        // Build path: project_name/note_title.pdf or just note_title.pdf
        let fileName = "\(executeTitle).pdf"
        let path: String
        if let projectName = parentProjectName {
            path = "\(projectName)/\(fileName)"
        } else {
            path = fileName
        }

        isExecuting = true

        Task {
            do {
                // Step 1: Upload PDF
                let uploadResponse = try await BackendService.shared.uploadPDF(data: pdfData, path: path)

                // Step 2: Execute (AI decides what to do)
                // Use parent project name, or fall back to note title
                let projectName = parentProjectName ?? executeTitle
                let executeResponse = try await BackendService.shared.execute(
                    filePath: uploadResponse.path,
                    projectName: projectName
                )

                // Step 3: Wait for completion (with timeout)
                let finalJob = try await BackendService.shared.waitForJob(
                    jobId: executeResponse.jobId,
                    pollInterval: 2.0,
                    timeout: 300  // 5 minutes
                )

                await MainActor.run {
                    isExecuting = false

                    if finalJob.status == "completed" {
                        var message = "✓ Execution completed!\n"
                        if let outputPath = finalJob.output_path {
                            message += "Output: \(outputPath)"
                        }
                        executeMessage = message
                    } else {
                        executeMessage = "✗ Processing failed:\n\(finalJob.error ?? "Unknown error")"
                    }
                    showingExecuteResult = true
                }
            } catch {
                await MainActor.run {
                    isExecuting = false
                    executeMessage = "Execution failed:\n\(error.localizedDescription)"
                    showingExecuteResult = true
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
        ZStack(alignment: .topTrailing) {
            CanvasView(drawingData: $page.drawingData, currentTool: $currentTool)
                .frame(width: canvasSize.width, height: canvasSize.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 2)
                )
                .onAppear(perform: onAppear)

            // Orientation indicator badge
            HStack(spacing: 4) {
                Image(systemName: page.orientation == .portrait ? "rectangle.portrait.fill" : "rectangle.fill")
                    .font(.caption2)
                Text(page.orientation == .portrait ? "Portrait" : "Landscape")
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .foregroundColor(.white)
            .cornerRadius(4)
            .padding(8)
        }
    }
}
#endif

#Preview {
    NoteEditorView(store: NotesStore())
}
