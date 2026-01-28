//
//  TextBoxOverlayView.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/28/26.
//

import SwiftUI

/// Overlay view for displaying and interacting with text boxes on a canvas page.
/// Renders text boxes on top of the drawing layer.
struct TextBoxOverlayView: View {
    @Binding var textBoxes: [TextBox]
    @Binding var currentTool: DrawingTool
    let canvasSize: CGSize

    @State private var selectedTextBoxId: UUID? = nil
    @State private var editingTextBoxId: UUID? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var resizeHandle: ResizeHandle? = nil
    @State private var initialSize: CGSize = .zero
    @State private var showingFontSizePopover: Bool = false

    enum ResizeHandle {
        case bottomRight
        case bottomLeft
        case topRight
        case topLeft
    }

    var body: some View {
        ZStack {
            // Tap layer for creating new text boxes (only when text tool is active)
            if currentTool == .text {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if selectedTextBoxId == nil && editingTextBoxId == nil {
                            createTextBox(at: location)
                        } else {
                            // Deselect when tapping outside
                            selectedTextBoxId = nil
                            editingTextBoxId = nil
                        }
                    }
            }

            // Render each text box
            ForEach($textBoxes) { $textBox in
                TextBoxItemView(
                    textBox: $textBox,
                    canvasSize: canvasSize,
                    isSelected: selectedTextBoxId == textBox.id,
                    isEditing: editingTextBoxId == textBox.id,
                    onSelect: {
                        if currentTool == .text {
                            selectedTextBoxId = textBox.id
                        }
                    },
                    onStartEditing: {
                        if currentTool == .text {
                            editingTextBoxId = textBox.id
                            selectedTextBoxId = textBox.id
                        }
                    },
                    onEndEditing: {
                        editingTextBoxId = nil
                    },
                    onMove: { newPosition in
                        textBox.setPixelPosition(newPosition, in: canvasSize)
                    },
                    onResize: { newSize in
                        textBox.setPixelSize(newSize, in: canvasSize)
                    },
                    onDelete: {
                        textBoxes.removeAll { $0.id == textBox.id }
                        selectedTextBoxId = nil
                        editingTextBoxId = nil
                    },
                    onFontSizeChange: { newSize in
                        textBox.fontSize = newSize
                    }
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func createTextBox(at location: CGPoint) {
        let normalizedPosition = CGPoint(
            x: location.x / canvasSize.width,
            y: location.y / canvasSize.height
        )

        // Adjust position so the text box is centered on tap point
        let adjustedPosition = CGPoint(
            x: max(0, min(1 - TextBox.defaultSize.width, normalizedPosition.x - TextBox.defaultSize.width / 2)),
            y: max(0, min(1 - TextBox.defaultSize.height, normalizedPosition.y - TextBox.defaultSize.height / 2))
        )

        let newTextBox = TextBox(position: adjustedPosition)
        textBoxes.append(newTextBox)
        selectedTextBoxId = newTextBox.id
        editingTextBoxId = newTextBox.id
    }
}

/// Individual text box view with editing, moving, and resizing capabilities.
struct TextBoxItemView: View {
    @Binding var textBox: TextBox
    let canvasSize: CGSize
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onEndEditing: () -> Void
    let onMove: (CGPoint) -> Void
    let onResize: (CGSize) -> Void
    let onDelete: () -> Void
    let onFontSizeChange: (CGFloat) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var showingFontPopover: Bool = false
    @FocusState private var isTextFieldFocused: Bool

    private let handleSize: CGFloat = 12
    private let selectionPadding: CGFloat = 4

    var body: some View {
        let frame = textBox.pixelFrame(in: canvasSize)
        let scaledFont = textBox.scaledFontSize(for: canvasSize.width)

        ZStack(alignment: .topLeading) {
            // Background (if set)
            if let bgColor = textBox.backgroundColor {
                RoundedRectangle(cornerRadius: 4)
                    .fill(bgColor.color.opacity(bgColor == .clear ? 0 : 0.3))
            }

            // Text content
            if isEditing {
                TextEditor(text: $textBox.text)
                    .font(.system(size: scaledFont, weight: textBox.fontWeight.swiftUIWeight))
                    .foregroundColor(textBox.textColor.color)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($isTextFieldFocused)
                    .onAppear {
                        isTextFieldFocused = true
                    }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused {
                            onEndEditing()
                        }
                    }
            } else {
                Text(textBox.text.isEmpty ? "Tap to edit" : textBox.text)
                    .font(.system(size: scaledFont, weight: textBox.fontWeight.swiftUIWeight))
                    .foregroundColor(textBox.text.isEmpty ? .gray : textBox.textColor.color)
                    .multilineTextAlignment(textBox.alignment.swiftUIAlignment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignmentFromTextAlignment(textBox.alignment))
                    .padding(4)
            }

            // Selection border and handles
            if isSelected {
                // Selection border
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.blue, lineWidth: 2)
                    .padding(-selectionPadding)

                // Resize handles
                ForEach([Corner.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { corner in
                    ResizeHandleView(corner: corner, handleSize: handleSize)
                        .position(handlePosition(for: corner, in: frame.size))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    handleResize(corner: corner, translation: value.translation, frameSize: frame.size)
                                }
                        )
                }

                // Font size button (top-center)
                Button {
                    showingFontPopover = true
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.blue))
                }
                .buttonStyle(.plain)
                .position(x: frame.size.width / 2, y: -16)
                .popover(isPresented: $showingFontPopover) {
                    FontSizePopover(
                        fontSize: $textBox.fontSize,
                        fontWeight: $textBox.fontWeight,
                        textColor: $textBox.textColor
                    )
                }

                // Delete button (top-right)
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.red))
                }
                .buttonStyle(.plain)
                .position(x: frame.size.width + 16, y: -16)
            }
        }
        .frame(width: frame.size.width, height: frame.size.height)
        .position(
            x: frame.origin.x + frame.size.width / 2 + dragOffset.width,
            y: frame.origin.y + frame.size.height / 2 + dragOffset.height
        )
        .onTapGesture(count: 2) {
            onStartEditing()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if isSelected && !isEditing {
                        dragOffset = value.translation
                    }
                }
                .onEnded { value in
                    if isSelected && !isEditing {
                        let newPosition = CGPoint(
                            x: frame.origin.x + value.translation.width,
                            y: frame.origin.y + value.translation.height
                        )
                        onMove(newPosition)
                        dragOffset = .zero
                    }
                }
        )
    }

    private func alignmentFromTextAlignment(_ alignment: TextBox.TextAlignment) -> Alignment {
        switch alignment {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    private func handlePosition(for corner: Corner, in size: CGSize) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: -selectionPadding, y: -selectionPadding)
        case .topRight: return CGPoint(x: size.width + selectionPadding, y: -selectionPadding)
        case .bottomLeft: return CGPoint(x: -selectionPadding, y: size.height + selectionPadding)
        case .bottomRight: return CGPoint(x: size.width + selectionPadding, y: size.height + selectionPadding)
        }
    }

    private func handleResize(corner: Corner, translation: CGSize, frameSize: CGSize) {
        var newWidth = frameSize.width
        var newHeight = frameSize.height
        var newX = textBox.pixelPosition(in: canvasSize).x
        var newY = textBox.pixelPosition(in: canvasSize).y

        switch corner {
        case .bottomRight:
            newWidth += translation.width
            newHeight += translation.height
        case .bottomLeft:
            newWidth -= translation.width
            newX += translation.width
            newHeight += translation.height
        case .topRight:
            newWidth += translation.width
            newHeight -= translation.height
            newY += translation.height
        case .topLeft:
            newWidth -= translation.width
            newX += translation.width
            newHeight -= translation.height
            newY += translation.height
        }

        // Apply constraints
        let minPixelWidth = TextBox.minSize.width * canvasSize.width
        let minPixelHeight = TextBox.minSize.height * canvasSize.height

        if newWidth >= minPixelWidth && newHeight >= minPixelHeight {
            onMove(CGPoint(x: newX, y: newY))
            onResize(CGSize(width: newWidth, height: newHeight))
        }
    }

    enum Corner: Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}

struct ResizeHandleView: View {
    let corner: TextBoxItemView.Corner
    let handleSize: CGFloat

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .overlay(
                Circle()
                    .stroke(Color.blue, lineWidth: 2)
            )
    }
}

struct FontSizePopover: View {
    @Binding var fontSize: CGFloat
    @Binding var fontWeight: TextBox.FontWeight
    @Binding var textColor: TextBox.TextBoxColor

    private let fontSizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Font size
            VStack(alignment: .leading, spacing: 4) {
                Text("Size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Button {
                        fontSize = max(8, fontSize - 2)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)

                    Text("\(Int(fontSize)) pt")
                        .frame(width: 50)
                        .font(.system(.body, design: .monospaced))

                    Button {
                        fontSize = min(72, fontSize + 2)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }

                // Quick size buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(fontSizes, id: \.self) { size in
                            Button {
                                fontSize = size
                            } label: {
                                Text("\(Int(size))")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(fontSize == size ? Color.blue : Color.gray.opacity(0.2))
                                    )
                                    .foregroundColor(fontSize == size ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            // Font weight
            VStack(alignment: .leading, spacing: 4) {
                Text("Weight")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(TextBox.FontWeight.allCases, id: \.self) { weight in
                        Button {
                            fontWeight = weight
                        } label: {
                            Text("Aa")
                                .font(.system(size: 14, weight: weight.swiftUIWeight))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(fontWeight == weight ? Color.blue : Color.gray.opacity(0.2))
                                )
                                .foregroundColor(fontWeight == weight ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Text color
            VStack(alignment: .leading, spacing: 4) {
                Text("Color")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 5), spacing: 4) {
                    ForEach(TextBox.TextBoxColor.allCases.filter { $0 != .clear && $0 != .white }, id: \.self) { color in
                        Button {
                            textColor = color
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(textColor == color ? Color.blue : Color.gray.opacity(0.3), lineWidth: textColor == color ? 3 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .frame(width: 220)
    }
}

#Preview {
    TextBoxOverlayView(
        textBoxes: .constant([
            TextBox(text: "Hello World", position: CGPoint(x: 0.1, y: 0.1))
        ]),
        currentTool: .constant(.text),
        canvasSize: CGSize(width: 400, height: 500)
    )
}
