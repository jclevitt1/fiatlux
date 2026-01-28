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

### [2026-01-28] Project Browser Architecture
**Context:** Existing Project mode requires users to select which project to modify. Need to browse and select from available projects stored in S3/GDrive.
**Decision:**
1. **No separate project metadata store** - Projects are discovered by listing `projects/` folder in storage. Project ID = folder name.
2. **Client-side filtering** - Search/filter happens in Swift app, not backend. API returns all projects, client filters.
3. **Project selection stored on Note** - `selectedProjectId` and `selectedProjectName` fields added to Note model.
4. **Popover UI on macOS** - ProjectBrowserView shown in popover from toolbar button, not modal sheet.
5. **Required before upload** - For existingProject mode, backup is blocked until a project is selected.
**Rationale:**
1. Avoids schema complexity. Storage is source of truth. File counts derived at query time.
2. Project lists are small (<1000). Client-side filtering simpler and snappier than round-trip searches.
3. Note knows its target project. Persists with note on save. Available when triggering job.
4. Consistent with mode selector popover UX. Less intrusive than modal.
5. Prevents accidental uploads without target. Clear error message guides user.
**Alternatives Considered:**
- DynamoDB for project metadata: Adds complexity, sync issues. Rejected.
- Server-side search: Adds latency for small lists. Rejected.
- Project selection in trigger payload only: Loses context if note reopened. Rejected.

---

## Pending Decisions

- **Layer Architecture**: How do layers interact with text boxes? Separate systems or text as special layer type?
- **Shape Recognition**: Real-time recognition vs explicit "convert to shape" action?
- **User Auth Provider**: Clerk confirmed as preference, but need to finalize JWT validation approach in Lambda.
