# FiatLux Design Decisions

This document tracks critical design decisions made during development. Agents should append new decisions with date, context, decision, and rationale.

---

## Format

```
### [YYYY-MM-DD] Decision Title
**Context:** Why this decision was needed
**Decision:** What was decided
**Rationale:** Why this choice over alternatives
**Alternatives Considered:** What else was considered
```

---

## Decisions

### [2026-01-28] Project Structure - Gastown Rig Setup
**Context:** FiatLux needed to be integrated into gastown for multi-agent development.
**Decision:** Added FiatLux as a rig at `/Users/jeremylevitt/gt/fiatlux/` with git remote `git@github-jclevitt1:jclevitt1/fiatlux.git`
**Rationale:** Enables parallel development with polecats, proper issue tracking via beads, and merge queue management.
**Alternatives Considered:** Direct development without gastown coordination.

### [2026-01-28] Feature Prioritization Order
**Context:** Multiple features requested for iPad app (colors, shapes, text, lasso, layers, project browser, user system).
**Decision:** Start with simpler features first: pen colors/sizes → shapes → text boxes → lasso → layers. User system and project browser in parallel track.
**Rationale:**
1. Pen colors/sizes is lowest complexity, provides quick win
2. Layers is highest complexity and affects architecture of other features
3. User system is backend-heavy, can progress independently of UI features
**Alternatives Considered:** Starting with user system first to establish foundation, but this blocks UI progress.

### [2026-01-28] Platform Target - iPad Primary
**Context:** Previous development focused on macOS due to iPad connectivity issues. User confirmed iPad access returning.
**Decision:** iPad (iOS) is primary platform. macOS support maintained but secondary.
**Rationale:** Original vision is iPad note-taking app. PencilKit on iOS provides superior drawing experience vs custom canvas on macOS.
**Alternatives Considered:** macOS-first, but that deviates from core use case.

### [2026-01-28] Layer Architecture for iPad
**Context:** Need to implement multi-layer drawing support for iPad. PencilKit (iOS) is inherently single-layer - each PKCanvasView can only hold one PKDrawing.
**Decision:** Hybrid rendering approach:
- Active layer uses live PKCanvasView for real-time drawing
- Non-active layers render as static UIImage overlays
- Layers composite via ZStack with proper z-ordering
- On layer switch: save current PKDrawing to layer data, load new layer into PKCanvasView

**Rationale:**
1. PencilKit provides the best Apple Pencil experience (pressure, tilt, palm rejection)
2. Static image rendering for non-active layers is performant
3. User can only draw on one layer at a time anyway
4. Maintains full editability when switching back to a layer

**Alternatives Considered:**
- Multiple PKCanvasView instances (complex touch handling, memory intensive)
- Pure image-based layers (loses stroke editability)
- Custom drawing without PencilKit (inferior pencil experience)

**Implementation Details:**
- `DrawingLayer` struct: id, name, isVisible, opacity, zIndex, drawingData
- `PageData.layers: [DrawingLayer]` with activeLayerIndex
- `LayeredCanvasView` handles rendering and layer compositing
- `LayersPanelView` provides UI for visibility, reordering, add/delete
- PDF export composites all visible layers respecting opacity

### [2026-01-28] Layer Data Model Design
**Context:** How to structure layer data for persistence and cross-platform compatibility.
**Decision:** Each layer stores raw drawing data (PKDrawing bytes on iOS, JSON DrawingLine array on macOS) with metadata.

**Data Structure:**
```swift
struct DrawingLayer: Codable, Identifiable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var opacity: CGFloat
    var zIndex: Int
    var drawingData: Data
}
```

**Rationale:**
1. Platform-specific drawing formats are already different (PencilKit vs custom)
2. Metadata (visibility, opacity, z-index) is universal
3. Auto-migration from old single-layer format via custom Codable init

**Alternatives Considered:**
- Unified drawing format (would require custom renderer, lose PencilKit benefits)
- Separate layer files (complex file management)

### [2026-01-28] Layers as Drawing-Only (Not Text/Shapes)
**Context:** How do layers interact with future text boxes and shapes?
**Decision:** Layers are drawing-only. Text boxes and shapes will be separate overlay systems on top of layers.

**Rationale:**
1. Text boxes have different interaction model (tap to edit, resize handles)
2. Shapes may need special manipulation (rotation, corner dragging)
3. Keeping systems separate simplifies implementation
4. Can add "flatten to layer" feature later if needed

**Alternatives Considered:**
- Text as special layer type (complex, mixing paradigms)
- Everything on layers (loses specialized UI for each type)

---

## Pending Decisions

- **Shape Recognition**: Real-time recognition vs explicit "convert to shape" action?
- **User Auth Provider**: Clerk confirmed as preference, but need to finalize JWT validation approach in Lambda.
