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

### [2026-01-28] DynamoDB User System Schema Design
**Context:** Need to track users and their projects for multi-tenant support. Users authenticate via Clerk, projects are generated from notes and stored in S3.

**Decision:** Two-table design with GSIs for secondary access patterns.

**Users Table (fiatlux-users):**
| Attribute | Type | Description |
|-----------|------|-------------|
| user_id (PK) | String | Clerk user ID (sub claim from JWT) |
| email | String | User's email address |
| display_name | String | Optional display name |
| created_at | String (ISO8601) | Creation timestamp |
| updated_at | String (ISO8601) | Last update timestamp |

GSI: `email-index` (email → user) for lookup by email.

**Projects Table (fiatlux-projects):**
| Attribute | Type | Description |
|-----------|------|-------------|
| project_id (PK) | String | UUID |
| user_id | String | Clerk user ID (owner) |
| name | String | Display name |
| s3_path | String | Path in S3 (e.g., "projects/user123/my-app/") |
| description | String | Optional description |
| status | String | pending/processing/ready/failed |
| source_note_path | String | Original note that created this |
| created_at | String (ISO8601) | Creation timestamp |
| updated_at | String (ISO8601) | Last update timestamp |

GSIs:
- `user-index` (user_id → projects) for listing user's projects
- `s3-path-index` (s3_path → project) for resolving project from S3 events

**Rationale:**
1. **Two tables vs single table**: Separate tables are clearer and sufficient for our access patterns. Single-table design adds complexity without benefit here - we don't need transactional operations across users and projects.
2. **user_id from Clerk**: Using Clerk's `sub` claim directly as PK means no mapping table needed. User record created on first authenticated request.
3. **Projects don't store file list**: Project files live in S3 at s3_path. The projects table is metadata only - no need to sync file lists.
4. **PAY_PER_REQUEST billing**: Low initial traffic, don't want to over-provision. Can switch to provisioned if needed.
5. **s3_path GSI**: When S3 events trigger processing, we need to find the project record. This GSI enables that lookup.
6. **No projects list in users table**: Originally considered storing `projects: [project_id, ...]` in user record. Rejected because: (a) 400KB item limit could become problematic, (b) requires updating user record on every project change, (c) GSI query is cleaner.

**Alternatives Considered:**
- **Single table design**: PK=user_id, SK=PROJECT#{project_id}. Rejected - over-engineering for current needs, harder to reason about.
- **Projects list in user record**: Simpler reads but write amplification and size limits.
- **Separate jobs table per user**: Rejected - jobs are ephemeral, don't need user scoping at DB level.

---

## Pending Decisions

- **Layer Architecture**: How do layers interact with text boxes? Separate systems or text as special layer type?
- **User Auth Provider**: Clerk confirmed as preference, but need to finalize JWT validation approach in Lambda.
- **Ruler Tool**: Should we add a separate ruler/straightedge tool or is shape pen + line shape sufficient?
- **Shape Selection**: Need to add ability to select, move, resize shapes after drawing
