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

---

## Pending Decisions

- **Layer Architecture**: How do layers interact with text boxes? Separate systems or text as special layer type?
- **Shape Recognition**: Real-time recognition vs explicit "convert to shape" action?
- **User Auth Provider**: Clerk confirmed as preference, but need to finalize JWT validation approach in Lambda.
