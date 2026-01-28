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

### [2026-01-28] Lasso Selection - Use Native PKLassoTool
**Context:** Implementing freeform selection for iPad to allow users to select, move, and delete drawn content.
**Decision:** Use PencilKit's native `PKLassoTool` rather than implementing custom selection logic.
**Rationale:**
1. PKLassoTool provides complete built-in functionality: freeform selection path, stroke selection, visual handles, move/resize/delete
2. Consistent with iOS design patterns and user expectations from other drawing apps
3. Much less code to maintain vs custom implementation
4. Native performance and gesture handling
5. Future-proof as Apple improves PencilKit
**Alternatives Considered:** Custom selection implementation with gesture recognizers and hit-testing, but this would be significant effort for inferior results.

### [2026-01-28] Lasso Selection - Toolbar Integration
**Context:** How should the lasso tool be accessed - via PKToolPicker only, or also via custom toolbar?
**Decision:** Add lasso button to custom toolbar alongside pencil/eraser, syncing with PKCanvasView.tool.
**Rationale:**
1. Consistent toolbar experience across all tools (pencil, eraser, lasso all in same toolbar)
2. PKToolPicker still available as alternative for power users
3. Clear visual state indication of which tool is active
4. Custom toolbar is visible at all times vs PKToolPicker which can be dismissed
**Alternatives Considered:** Using only PKToolPicker for lasso (already has it built-in), but this creates inconsistent UX where some tools are in custom toolbar and lasso is only in PKToolPicker.

### [2026-01-28] Lasso Selection - Interaction with Future Shapes/Text
**Context:** Task requires considering how selection interacts with shapes and text boxes (to be implemented later).
**Decision:** PKLassoTool only selects PKStrokes (ink). Future shapes/text should be implemented as separate overlay layers with their own selection system.
**Rationale:**
1. PKLassoTool operates on PKDrawing strokes only - it cannot select arbitrary UI elements
2. Shapes (rectangles, circles) and text boxes should be SwiftUI views overlaid on the canvas
3. Each shape/text box can have its own tap-to-select gesture and drag handle
4. This mirrors how professional apps (GoodNotes, Notability) handle mixed content
5. "Select all" functionality could be added later to select both strokes and objects
**Implications:**
- Shapes/text boxes will need separate selection state and gesture handling
- Consider adding "object mode" vs "drawing mode" toggle in future
- May need unified selection when implementing layers (select all content on a layer)
**Alternatives Considered:** Rasterizing shapes into PKDrawing so PKLassoTool can select them, but this loses shape editability.

---

## Pending Decisions

- **Layer Architecture**: How do layers interact with text boxes? Separate systems or text as special layer type?
- **Shape Recognition**: Real-time recognition vs explicit "convert to shape" action?
- **User Auth Provider**: Clerk confirmed as preference, but need to finalize JWT validation approach in Lambda.
- **Unified Selection**: Should there be a way to select both strokes AND shapes/text at once? If so, how?
