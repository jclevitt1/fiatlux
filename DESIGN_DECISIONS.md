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

### [2026-01-28] iOS Pen Colors/Sizes - Use PKToolPicker
**Context:** Need to add pen color and size customization to the drawing canvas on iOS.
**Decision:** Use Apple's built-in `PKToolPicker` rather than building a custom color/size picker UI. The tool picker is accessed via `PKToolPicker.shared(for: window)` and tool selection is persisted to UserDefaults.
**Rationale:**
1. PKToolPicker provides comprehensive tool selection: multiple pen types (pen, marker, pencil, crayon), full color picker with presets and custom colors, size slider, eraser options, and ruler
2. Native iOS look and feel that users expect
3. Automatic Apple Pencil integration (pressure sensitivity, tilt)
4. Less code to maintain vs custom UI
**Alternatives Considered:**
- Custom color/size picker overlay: More work, less native feel, would need to re-implement features PKToolPicker provides for free
- Hybrid approach with custom buttons: Would conflict with PKToolPicker's own tool selection
**Implementation Notes:**
- Tool selection persisted via `ToolPersistence` class using UserDefaults
- Color stored as hex string for serialization
- macOS still uses custom toolbar since PKToolPicker is iOS-only

### [2026-01-28] Shape Drawing Implementation
**Context:** Need to add shape tools (rectangle, circle, line, arrow) to the drawing canvas for iPad.
**Decision:** Implemented shapes as a separate data structure (`DrawingShape`) stored alongside freehand lines in `PageData`. Shape recognition uses explicit user confirmation prompt rather than auto-conversion.
**Rationale:**
1. Separating shapes from lines allows proper rendering, selection, and editing of shapes
2. Explicit confirmation for shape recognition prevents frustrating auto-corrections when user intentionally draws rough shapes
3. Shapes stored with their own stroke/fill colors enables future color picker integration
4. The `ShapeRecognizer` uses scoring algorithms (line deviation, perimeter distance, radius variance) with a configurable threshold (default 0.75) to balance between catching intended shapes and avoiding false positives
**Alternatives Considered:**
- Auto-convert without prompt (rejected: user frustration on false positives)
- Real-time recognition as you draw (rejected: too distracting, performance concerns)
- PencilKit shapes only on iOS (rejected: want consistent experience across platforms)

### [2026-01-28] Shape Tool Architecture
**Context:** How should shape tools integrate with existing pencil/eraser workflow?
**Decision:** Extended `DrawingTool` enum with `.shape(ShapeType)` and `.shapePen` cases. Shape drawing uses drag gesture from start to end point. Shape pen mode draws freehand then offers conversion.
**Rationale:**
1. Consistent tool switching pattern - shapes feel like other drawing tools
2. Drag-to-draw is intuitive for shapes (same as most drawing apps)
3. Shape pen provides best of both worlds - freehand feel with clean output option
4. Shapes render in Canvas alongside lines, maintaining z-order by draw sequence
**Alternatives Considered:**
- Separate shape layer (rejected: adds complexity, breaks mental model of "one canvas")
- Modal shape mode with separate gestures (rejected: context switching overhead)
- Ruler tool for straight lines (deferred: shape pen + line tool covers use case for now)

---

## Pending Decisions

- **Layer Architecture**: How do layers interact with text boxes? Separate systems or text as special layer type?
- **User Auth Provider**: Clerk confirmed as preference, but need to finalize JWT validation approach in Lambda.
- **Ruler Tool**: Should we add a separate ruler/straightedge tool or is shape pen + line shape sufficient?
- **Shape Selection**: Need to add ability to select, move, resize shapes after drawing
