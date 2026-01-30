# Tabulae (FiatLux)

**Domain:** usepen.dev (marketing site), tabulae.dev (app)
**App Name:** FiatLux (internal/repo name)

A GoodNotes-like note-taking app with AI-powered processing. Takes handwritten notes → summarizes them, generates projects, or modifies existing projects.

> "From tablets to code, since the beginning of writing."

## Project Structure

```
FiatLux/
├── FiatLux/                    # Swift macOS/iOS app
│   ├── FiatLuxApp.swift        # App entry point
│   ├── ContentView.swift       # Main navigation
│   ├── NoteEditorView.swift    # Note editor with canvas + Execute button
│   ├── CanvasView.swift        # Drawing canvas (macOS custom, iOS PencilKit)
│   ├── Note.swift              # Note model with NoteMode enum
│   ├── Folder.swift            # Folder model
│   ├── NotesItem.swift         # Union type for Note|Folder
│   ├── NotesStore.swift        # @Observable data store
│   ├── PageSettings.swift      # PageOrientation, PageData
│   ├── PDFExporter.swift       # Export notes to PDF
│   ├── BackendService.swift    # HTTP client for backend API
│   ├── AuthManager.swift       # Clerk auth state + Keychain storage
│   └── SignInView.swift        # Sign-in UI (email/password, Apple)
│
└── backend/                    # Python FastAPI backend
    ├── main.py                 # Local dev API endpoints
    ├── run.py                  # CLI for running locally
    ├── requirements.txt
    ├── credentials.json        # Google OAuth client (not committed)
    ├── agents/
    │   ├── base.py             # BaseAgent class
    │   ├── summarize.py        # Mode 1: Notes → Summary
    │   ├── create_project.py   # Mode 2: Notes → New Project
    │   └── existing_project.py # Mode 3: Notes → Modify Existing
    ├── storage/
    │   ├── base.py             # StorageProvider interface + upload_to_raw()
    │   ├── gdrive.py           # Google Drive implementation
    │   ├── s3.py               # S3 implementation
    │   └── dynamodb.py         # DynamoDB job store (for Lambda)
    ├── triggers/
    │   ├── base.py             # Abstract Trigger class + TriggerContext
    │   ├── s3_event.py         # S3 bucket notification trigger
    │   ├── polling.py          # Periodic storage scanning trigger
    │   └── webhook.py          # HTTP webhook trigger
    ├── models/
    │   └── job.py              # Job model (status tracking)
    ├── utils/
    │   └── pdf.py              # PDF → base64 images for Claude vision
    ├── lambda/
    │   ├── api_handler.py      # Lambda: /upload, /jobs, /health
    │   ├── processor.py        # Lambda: S3-triggered Claude processing
    │   └── requirements.txt    # Lambda-specific deps
    └── infra/
        ├── template.yaml       # SAM/CloudFormation template
        ├── samconfig.toml      # SAM deployment config
        ├── Dockerfile.processor # Docker for processor Lambda (includes poppler)
        └── deploy.sh           # Deployment script
```

## Three Modes

The app has three modes for notes (defined in `Note.swift`):

1. **Notes** (blue) - Just taking notes. Worker summarizes them.
2. **Create Project** (green) - AI creates a new project from the notes.
3. **Existing Project** (orange) - AI modifies an existing project based on notes.

## Backend Architecture

### Storage (User-Scoped)
All data is scoped by Clerk user_id:
- `raw/{user_id}/` - Original PDFs (upload only, read by workers)
- `notes/{user_id}/` - Processed summaries
- `projects/{user_id}/{project_id}/` - Generated code projects

Project metadata stored in DynamoDB, files in S3.

### API Endpoints

All endpoints except `/health` require Clerk JWT in `Authorization: Bearer <token>` header.

```
# Health
GET  /health                        # Health check (public)

# Jobs
POST /jobs                          # Submit a job
GET  /jobs/{job_id}                 # Get job status
GET  /jobs                          # List user's jobs

# Upload
POST /upload                        # Upload PDF to raw/{user_id}/

# Projects (DynamoDB + S3)
GET  /projects                      # List user's projects (?search=query)
GET  /projects/{project_id}         # Get project details
POST /projects                      # Create a new project
PUT  /projects/{project_id}         # Update project metadata
DELETE /projects/{project_id}       # Delete project
GET  /projects/{project_id}/files   # List files in project

# Local dev only
POST /trigger                       # Webhook trigger (optional)
```

### Triggers

Triggers detect new files and invoke workers. Abstract `Trigger` class with:
- `should_trigger(event) -> bool` - Decide whether to process
- `get_context(event) -> TriggerContext` - Extract file path, mode, metadata
- `execute(context) -> dict` - Submit job to `/jobs` endpoint

**Implementations:**
- **S3EventTrigger**: Responds to S3 bucket notifications (for Lambda)
- **PollingTrigger**: Periodically scans storage for new files
- **WebhookTrigger**: HTTP endpoint called after upload

**Mode Detection via Folder Structure:**
```
raw/Notes/my_note.pdf         → summarize job
raw/Create_Project/idea.pdf   → create_project job
raw/Existing_Project/fix.pdf  → existing_project job
```

### Job Flow
1. PDF exists in `raw/path/to/note.pdf`
2. Submit job: `POST /jobs {"job_type": "summarize", "raw_file_path": "raw/path/to/note.pdf"}`
3. Agent fetches PDF → converts to images → sends to Claude vision → processes → writes to storage
4. Poll `GET /jobs/{job_id}` until `status: "completed"`

### Agents
- **SummarizeAgent**: PDF → Claude vision reads handwriting → structured summary → writes to `notes/`
- **CreateProjectAgent**: PDF → extract requirements → generate structure → generate code files → writes to `projects/`
- **ExistingProjectAgent**: Same as Create but with `_collect_context` phase that reads existing project files first

## Key Design Decisions

1. **UX never calls workers directly** - Swift app just uploads to storage. Separate triggers invoke workers.
2. **Claude vision for handwriting** - No OCR. PDFs converted to images, sent directly to Claude.
3. **Storage abstraction** - Can swap GDrive/S3 via env var `STORAGE_TYPE`.
4. **Jobs are async** - Submit job, get job_id, poll for completion.

## Running the Backend

```bash
cd backend
source venv/bin/activate  # Use virtual environment
pip install -r requirements.txt

# Basic API only (no trigger)
ANTHROPIC_API_KEY=sk-xxx python run.py

# With webhook trigger endpoint (POST /trigger)
ANTHROPIC_API_KEY=sk-xxx python run.py -t webhook

# With polling trigger (scans storage every 30s)
ANTHROPIC_API_KEY=sk-xxx python run.py -t polling -i 30

# With auto-reload for development
ANTHROPIC_API_KEY=sk-xxx python run.py -t webhook -r

# For S3 storage instead of GDrive
STORAGE_TYPE=s3 S3_BUCKET=my-bucket ANTHROPIC_API_KEY=sk-xxx python run.py
```

Requires `poppler` for PDF conversion: `brew install poppler`

Or use `.env` file (auto-loaded via python-dotenv):
```bash
# backend/.env
ANTHROPIC_API_KEY=sk-ant-xxx
GDRIVE_ROOT_FOLDER=FiatLux
```

## Status: MVP Working ✓

End-to-end flow tested and working:
```
Swift App → Draw notes → Upload to GDrive → Trigger → Claude Vision → Project generated → GDrive
```

## AWS Lambda Infrastructure

**Region:** us-west-1

### Architecture
```
Swift App → API Gateway → Lambda (API) → S3 (raw/{user_id}/)
     ↑                         ↓              ↓ S3 Event
   Clerk JWT              DynamoDB       Lambda (Processor) → Claude API
                      (Jobs + Projects)       ↓
                                         S3 (projects/{user_id}/{project_id}/)
```

### Components
| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| API | API Gateway HTTP API + Lambda | All endpoints with Clerk JWT auth |
| Processor | Lambda (Docker) | S3-triggered Claude processing |
| Storage | S3 | raw/, notes/, projects/ (user-scoped) |
| Jobs | DynamoDB | Job status tracking |
| Projects | DynamoDB | Project metadata + S3 pointers |
| Auth | Clerk | JWT verification via JWKS |

### Data Model

**S3 Structure (user-scoped):**
```
fiatlux-storage-{stage}-{account}/
├── raw/{user_id}/                      # User uploads (PDFs)
│   ├── Notes/my_note.pdf
│   ├── Create_Project/idea.pdf
│   └── Existing_Project/fix.pdf
├── notes/{user_id}/                    # Processed summaries
└── projects/{user_id}/{project_id}/    # Generated code projects
    ├── src/
    ├── README.md
    └── ...
```

**DynamoDB Tables:**

```
fiatlux-jobs-{stage}
├── job_id (PK)           # UUID
├── user_id               # Clerk user ID (for GSI)
├── job_type              # summarize | create_project | existing_project
├── status                # pending | processing | completed | failed
├── raw_file_path         # S3 path to source PDF
├── project_id            # (optional) target project
├── output_path           # S3 path to result
├── result                # JSON result data
├── error                 # Error message if failed
├── created_at            # ISO timestamp
├── completed_at          # ISO timestamp
└── ttl                   # Auto-expire after 7 days

GSI: user-jobs-index (user_id HASH, created_at RANGE)
```

```
fiatlux-projects-{stage}
├── user_id (PK)          # Clerk user ID (partition key)
├── project_id (SK)       # UUID (sort key)
├── name                  # Project name
├── description           # Project description
├── s3_uri                # Full S3 URI: s3://bucket/projects/{user_id}/{project_id}/
├── s3_prefix             # S3 prefix: projects/{user_id}/{project_id}/
├── language              # Primary language (python, java, swift, etc.)
├── framework             # Framework (fastapi, spring, swiftui, etc.)
├── source_job_id         # Job that created this project
├── file_count            # Number of files
├── total_size_bytes      # Total size
├── created_at            # ISO timestamp
├── updated_at            # ISO timestamp
├── last_accessed_at      # ISO timestamp
└── metadata              # Flexible JSON for extras

GSI: project-lookup-index (project_id HASH) - lookup by project_id only
GSI: user-recent-index (user_id HASH, updated_at RANGE) - recent projects
```

### Deploying to AWS

```bash
cd backend/infra

# Use the deploy script (recommended)
./deploy.sh dev    # or prod

# Manual deployment
sam build && sam deploy \
  --parameter-overrides Stage=dev \
    AnthropicApiKey=$ANTHROPIC_API_KEY \
    ClerkPublishableKey=$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY \
    ClerkSecretKey=$CLERK_SECRET_KEY \
  --resolve-s3 --resolve-image-repos
```

**Prerequisites:**
- AWS CLI configured (`aws configure`)
- SAM CLI installed (`brew install aws-sam-cli`)
- Docker running (for processor Lambda build)
- Environment variables (or `backend/.env` file):
  ```bash
  ANTHROPIC_API_KEY=sk-ant-xxx
  NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_test_xxx
  CLERK_SECRET_KEY=sk_test_xxx
  ```

### After Deployment

**Get API URL:**
```bash
aws cloudformation describe-stacks \
  --stack-name fiatlux-backend-dev \
  --region us-west-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' \
  --output text
```

**Update Swift app:**
```swift
// In BackendService.swift, update Environment.dev URL
BackendService.shared = BackendService(
    environment: .dev,
    authToken: AuthManager.shared.sessionToken
)
```

### Authentication (Clerk)

The API uses Clerk JWT tokens for authentication:

1. **iOS app** signs in via `AuthManager.swift` → gets JWT from Clerk
2. **JWT** sent in `Authorization: Bearer <token>` header
3. **Lambda** verifies JWT using Clerk's JWKS endpoint
4. **user_id** extracted from `sub` claim, used to scope all data

**Clerk Setup:**
- Publishable key: `pk_test_cXVpY2stdG9ydG9pc2UtMzMuY2xlcmsuYWNjb3VudHMuZGV2JA`
- JWKS URL auto-derived from publishable key
- Tokens stored in iOS Keychain via `KeychainHelper`

**Auth Flow:**
```
iOS App → SignInView → Clerk API → JWT Token
                                      ↓
                              Keychain Storage
                                      ↓
                              BackendService (Authorization header)
                                      ↓
                              Lambda → verify_jwt() → user_id
```

## Roadmap

### Phase 1: Cloud Infrastructure (NEARLY COMPLETE)
- [x] Create Lambda handlers (API + Processor)
- [x] Create SAM template (Lambda, API Gateway, S3, DynamoDB)
- [x] Docker-based processor Lambda (includes poppler)
- [x] DynamoDB job store with user_id scoping
- [x] DynamoDB projects table (user_id + project_id composite key)
- [x] Clerk JWT authentication on all endpoints
- [x] iOS AuthManager + SignInView
- [x] Execute button in iOS app
- [ ] Deploy to AWS and test end-to-end
- [ ] Test iOS → Lambda → Claude → project generation flow

### Phase 2: Website (IN PROGRESS)
- [ ] Build web UI at usepen.dev (using Loveable)
- [ ] Landing page: "Write something, get it done"
- [ ] Project browser (list projects from DynamoDB)
- [ ] Code viewer/editor (Claude Code-like experience)
- [ ] Auth integration (Clerk - same as iOS)

### Phase 3: Publish App
- [ ] TestFlight beta distribution
- [ ] Reddit posts for PMF validation
- [ ] Polish UI/UX based on feedback
- [ ] App Store submission

### Phase 4: RALPH Integration
- [ ] Integrate RALPH for larger projects with specs
- [ ] Multi-agent orchestration (architect, coder, reviewer)
- [ ] Better project structure generation

### Future: Agentic Loop for Large Projects
**Problem:** Single Claude API call has ~64k output token limit. Large projects with many files can exceed this.

**Solution (like Claude Code):** Use an agentic loop:
1. **First call:** Generate file manifest (list of files + brief descriptions)
2. **Loop:** Generate each file one at a time, passing context from previous files
3. **Continuation:** If a single file is huge, use `stop_reason` to detect truncation and continue

This allows generating arbitrarily large projects without hitting token limits. Not needed for MVP but required for RALPH-scale projects.

### Future: Hardware (Smart Pen)
- See `hardware/poc1/` for ESP32 + camera prototype plans
- Defensible moat vs software-only

## Google Drive Storage

The backend uses a **FiatLux** folder in Google Drive (auto-created on first run).

### Folder Structure
```
FiatLux/                      # Root folder (configurable via GDRIVE_ROOT_FOLDER env)
├── raw/                      # Original PDFs (upload only, read by workers)
│   ├── Notes/                # Mode: summarize
│   ├── Create_Project/       # Mode: create_project
│   └── Existing_Project/     # Mode: existing_project
├── notes/                    # Processed summaries (written by SummarizeAgent)
└── projects/                 # Generated code (written by CreateProject/ExistingProject)
```

### Legacy GoodNotes Folder (READ-ONLY reference)
For reading original iPad notes, use the **GoodNotes** folder:
- **Folder ID**: `1tQcVVQ8qb-WjRM-Gm0jccb19b3Z7EBM7`
- Contains: Bandify, Claude Execute Now, ConverseLead, Ideas, etc.

### Usage
- FiatLux backend writes to `FiatLux/` folder (new)
- GoodNotes folder is for reading legacy iPad notes only
- GoodNotes-Summaries contains processed/summarized content (mirrors the same tree structure)
- **DEFAULT**: Use GoodNotes-Summaries as source of truth unless user explicitly asks for originals

## Swift App Notes

- **macOS target** is primary (iPad connection issues during development)
- Custom `CanvasView` for macOS drawing (PencilKit is iOS-only)
- Per-page orientation support (portrait/landscape)
- Multi-page notebooks with scroll
- PDF export working
- Data persisted via UserDefaults (NotesStore)
- **Cloud backup button** - uploads PDF to GDrive, auto-triggers processing
- Network entitlement enabled for localhost API calls
- Portrait pages constrained by available height (look like real paper)

## Hardware: Smart Pen (Future)

Long-term vision: physical pen that captures handwriting → syncs to backend → AI processes.

**Design decisions:**
- Local storage + batch sync (NOT real-time Bluetooth streaming)
- Module on end opposite ink tip
- Camera for: tracking, pen lift detection, page recognition
- Global shutter camera preferred (MT9V034 or similar)
- Pressure sensor (FSR) for stroke weight

**POC1 parts (ordered/to order):**
- ESP32-S3-WROOM-1 N16R8 (16MB flash, 8MB PSRAM) ✓
- MT9V034 global shutter camera (need to find)
- FSR 402 pressure sensor
- W25Q128 flash storage
- TP4056 + LiPo battery

See `hardware/poc1/` for diagrams and pin assignments.

**Why hardware matters:** Software-only has no moat (just pipes to Claude). Hardware + software = defensible vertical integration.

## Context from Previous Sessions

### Session: Jan 29, 2026 (Latest)
- **Fixed SAM deployment issues**
  - Removed Runtime from Globals (conflicted with Docker-based ProcessorFunction)
  - Fixed circular dependency (S3 bucket ↔ Lambda) using `!Sub` instead of `!Ref`
  - Added `DependsOn: ProcessorS3Permission` to StorageBucket
- **Added Projects DynamoDB table**
  - Composite key: `user_id` (partition) + `project_id` (sort)
  - GSIs: `project-lookup-index`, `user-recent-index`
  - Fields: name, description, s3_uri, language, framework, file_count, etc.
- **Added full CRUD for projects**
  - GET/POST/PUT/DELETE /projects endpoints
  - GET /projects/{id}/files - lists S3 files, updates stats
- **User_id scoping throughout**
  - Jobs table now has user_id + GSI for user queries
  - S3 paths scoped: `raw/{user_id}/`, `projects/{user_id}/{project_id}/`
  - All endpoints verify ownership before returning data
- **Clerk auth fully integrated**
  - iOS: AuthManager.swift + SignInView.swift
  - Lambda: JWT verification via JWKS
  - Keychain storage for tokens
- **New domain:** usepen.dev for marketing website

### Session: Jan 24, 2026
- **Built full AWS Lambda infrastructure**
- Created `lambda/api_handler.py` - API Gateway handler for /upload, /jobs, /health
- Created `lambda/processor.py` - S3-triggered processor that runs Claude agents
- Created `storage/dynamodb.py` - DynamoDB job store for Lambda
- Created `infra/template.yaml` - SAM template (Lambda, API Gateway, S3, DynamoDB)
- Created `infra/Dockerfile.processor` - Docker image with poppler for PDF processing
- Created `infra/deploy.sh` - One-command deployment script
- Updated `BackendService.swift` with environment switching (local/dev/prod)
- Added job polling support (`getJob`, `waitForJob`)
- Added API key authentication to API Gateway
- Updated `BackendService.swift` to support `x-api-key` header
- Philosophy: "Don't design things that should scale in house, just give it to AWS"

### Session: Jan 22, 2026
- **End-to-end flow working!** Handwritten notes → GDrive → Claude → Java project
- Added `BackendService.swift` for API communication
- Added `/upload` endpoint to write PDFs to `raw/`
- Added network entitlement to Swift app (sandbox fix)
- Fixed portrait canvas sizing (constrain by height, not just width)
- Created Trigger abstraction (`triggers/base.py`, `s3_event.py`, `polling.py`, `webhook.py`)
- Added `run.py` CLI for trigger mode selection (`-t webhook`, `-t polling`)
- Changed GDrive storage to use `FiatLux/` folder (configurable, auto-created)
- Added auto-trigger after upload (Swift calls `/trigger` automatically)
- Added `python-dotenv` support for `.env` files
- **Chose domain: tabulae.dev** ($20, Latin for "tablets")

### Earlier Sessions
- Built the Swift notes app with drawing, folders, modes, PDF export
- Fixed portrait/landscape orientation bug (aspect ratio: portrait=11/8.5, landscape=8.5/11)
- Built the Python backend with three agents
- Added storage abstraction with raw/ read-only protection
- User's vision: async distributed system inspired by AWS Keyspaces architecture
- Hardware pen exploration: ESP32-S3 + global shutter camera + FSR
