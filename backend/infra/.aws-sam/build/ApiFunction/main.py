import os
import uuid
import base64
from datetime import datetime

# Load .env file if present
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass  # python-dotenv not installed, skip
from fastapi import FastAPI, HTTPException, BackgroundTasks, UploadFile, File, Form
from pydantic import BaseModel
from anthropic import AsyncAnthropic

from storage import GDriveStorage, S3Storage
from agents import SummarizeAgent, CreateProjectAgent, ExistingProjectAgent
from models import Job, JobStatus, JobType

app = FastAPI(
    title="FiatLux Backend",
    description="Backend service for FiatLux notes processing",
    version="0.2.0"
)

# Config
STORAGE_TYPE = os.getenv("STORAGE_TYPE", "gdrive")  # "gdrive" or "s3"
S3_BUCKET = os.getenv("S3_BUCKET", "")

# Initialize storage
if STORAGE_TYPE == "s3":
    storage = S3Storage(bucket_name=S3_BUCKET)
else:
    storage = GDriveStorage()

# Initialize Anthropic client
anthropic_client = AsyncAnthropic(
    api_key=os.getenv("ANTHROPIC_API_KEY")
)

# Initialize agents
summarize_agent = SummarizeAgent(storage, anthropic_client)
create_project_agent = CreateProjectAgent(storage, anthropic_client)
existing_project_agent = ExistingProjectAgent(storage, anthropic_client)

# In-memory job store (replace with Redis/DB in production)
jobs: dict[str, Job] = {}


# Request models
class SubmitJobRequest(BaseModel):
    job_type: str  # "summarize", "create_project", "existing_project"
    raw_file_path: str  # Path in raw/ folder
    additional_text: str = ""
    project_id: str | None = None  # Required for existing_project


class JobResponse(BaseModel):
    job_id: str
    status: str
    message: str


class JobStatusResponse(BaseModel):
    job_id: str
    job_type: str
    status: str
    raw_file_path: str
    output_path: str | None
    result: dict | None
    error: str | None
    created_at: str
    completed_at: str | None


# Health check (trigger info added at bottom of file)
_trigger_mode = os.getenv("TRIGGER_MODE", "none")


@app.get("/health")
async def health():
    return {"status": "healthy", "storage": STORAGE_TYPE, "trigger_mode": _trigger_mode}


# Submit a job
@app.post("/jobs", response_model=JobResponse)
async def submit_job(request: SubmitJobRequest, background_tasks: BackgroundTasks):
    """
    Submit a new processing job.

    Jobs run in the background. Poll /jobs/{job_id} for status.
    """
    # Validate job type
    try:
        job_type = JobType(request.job_type)
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid job_type. Must be one of: {[t.value for t in JobType]}"
        )

    # Validate raw_file_path starts with raw/
    if not request.raw_file_path.startswith("raw/"):
        raise HTTPException(
            status_code=400,
            detail="raw_file_path must start with 'raw/'"
        )

    # Validate project_id for existing_project
    if job_type == JobType.EXISTING_PROJECT and not request.project_id:
        raise HTTPException(
            status_code=400,
            detail="project_id is required for existing_project jobs"
        )

    # Create job
    job = Job(
        id=str(uuid.uuid4()),
        job_type=job_type,
        status=JobStatus.PENDING,
        raw_file_path=request.raw_file_path,
        additional_text=request.additional_text,
        project_id=request.project_id
    )

    jobs[job.id] = job

    # Run in background
    background_tasks.add_task(process_job, job.id)

    return JobResponse(
        job_id=job.id,
        status=job.status.value,
        message="Job submitted successfully"
    )


async def process_job(job_id: str):
    """Process a job in the background."""
    job = jobs.get(job_id)
    if not job:
        return

    job.status = JobStatus.PROCESSING
    job.started_at = datetime.utcnow()

    try:
        # Select agent based on job type
        if job.job_type == JobType.SUMMARIZE:
            result = await summarize_agent.run(job)
        elif job.job_type == JobType.CREATE_PROJECT:
            result = await create_project_agent.run(job)
        elif job.job_type == JobType.EXISTING_PROJECT:
            result = await existing_project_agent.run(job)
        else:
            raise ValueError(f"Unknown job type: {job.job_type}")

        if result.success:
            job.status = JobStatus.COMPLETED
            job.result = result.data
            job.output_path = result.data.get("output_path") or result.data.get("project_path")
        else:
            job.status = JobStatus.FAILED
            job.error = result.error

    except Exception as e:
        job.status = JobStatus.FAILED
        job.error = str(e)

    job.completed_at = datetime.utcnow()


# Get job status
@app.get("/jobs/{job_id}", response_model=JobStatusResponse)
async def get_job(job_id: str):
    """Get the status of a job."""
    job = jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    return JobStatusResponse(
        job_id=job.id,
        job_type=job.job_type.value,
        status=job.status.value,
        raw_file_path=job.raw_file_path,
        output_path=job.output_path,
        result=job.result,
        error=job.error,
        created_at=job.created_at.isoformat(),
        completed_at=job.completed_at.isoformat() if job.completed_at else None
    )


# List all jobs (for debugging)
@app.get("/jobs")
async def list_jobs():
    """List all jobs (most recent first)."""
    return [
        {
            "job_id": j.id,
            "job_type": j.job_type.value,
            "status": j.status.value,
            "created_at": j.created_at.isoformat()
        }
        for j in sorted(jobs.values(), key=lambda x: x.created_at, reverse=True)
    ]


# Upload endpoint - the ONLY way to write to raw/
class UploadRequest(BaseModel):
    path: str  # Path under raw/, e.g., "MyNotes/note1.pdf"
    content_base64: str  # Base64-encoded PDF content
    mime_type: str = "application/pdf"


class UploadResponse(BaseModel):
    success: bool
    file_id: str
    path: str
    size: int


# =============================================================================
# Project Browser
# =============================================================================

class ProjectInfo(BaseModel):
    project_id: str  # Folder name under projects/
    name: str  # Display name
    file_count: int
    last_modified: str | None = None


class ProjectListResponse(BaseModel):
    projects: list[ProjectInfo]


@app.get("/projects", response_model=ProjectListResponse)
async def list_projects(search: str | None = None):
    """
    List all available projects from storage.

    Projects are discovered by listing folders under projects/.
    Optional search parameter filters by project name.
    """
    try:
        files = await storage.list_files("projects")

        # Group files by top-level project folder
        project_files: dict[str, list] = {}
        for f in files:
            # Extract project folder from path (projects/project_name/...)
            parts = f.path.split("/")
            if len(parts) >= 2:
                project_id = parts[1]  # projects/{project_id}/...
                if project_id not in project_files:
                    project_files[project_id] = []
                project_files[project_id].append(f)

        # Build project info list
        projects = []
        for project_id, files in project_files.items():
            # Apply search filter if provided
            if search and search.lower() not in project_id.lower():
                continue

            projects.append(ProjectInfo(
                project_id=project_id,
                name=project_id.replace("_", " ").replace("-", " "),
                file_count=len(files),
                last_modified=None  # Could extract from file metadata if needed
            ))

        # Sort alphabetically
        projects.sort(key=lambda p: p.name.lower())

        return ProjectListResponse(projects=projects)

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list projects: {e}")


class ProjectFilesResponse(BaseModel):
    project_id: str
    files: list[dict]


@app.get("/projects/{project_id}/files", response_model=ProjectFilesResponse)
async def get_project_files(project_id: str):
    """
    List files in a specific project.
    """
    try:
        files = await storage.list_files(f"projects/{project_id}")

        return ProjectFilesResponse(
            project_id=project_id,
            files=[
                {
                    "id": f.id,
                    "name": f.name,
                    "path": f.path,
                    "mime_type": f.mime_type,
                    "size": f.size
                }
                for f in files
            ]
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list project files: {e}")


@app.post("/upload", response_model=UploadResponse)
async def upload_file(request: UploadRequest):
    """
    Upload a PDF to the raw/ folder.

    This is the ONLY way to write to raw/. Workers cannot write here.

    The path should NOT include 'raw/' prefix - it will be added automatically.
    Example: path="MyNotes/note1.pdf" -> saves to raw/MyNotes/note1.pdf
    """
    try:
        content = base64.b64decode(request.content_base64)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid base64 content: {e}")

    if not request.path:
        raise HTTPException(status_code=400, detail="path is required")

    # Ensure it's a PDF (or allow other types)
    if not request.path.lower().endswith('.pdf'):
        raise HTTPException(status_code=400, detail="Only PDF files are allowed")

    try:
        result = await storage.upload_to_raw(
            path=request.path,
            content=content,
            mime_type=request.mime_type
        )

        return UploadResponse(
            success=True,
            file_id=result.id,
            path=result.path,
            size=result.size or len(content)
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Upload failed: {e}")


# =============================================================================
# Trigger Configuration (set via run.py or environment variables)
# =============================================================================

TRIGGER_MODE = os.getenv("TRIGGER_MODE", "none")
POLLING_INTERVAL = int(os.getenv("POLLING_INTERVAL", "60"))

# Webhook trigger - add /trigger endpoint
if TRIGGER_MODE == "webhook":
    from triggers import WebhookTrigger
    from triggers.webhook import create_webhook_endpoint

    webhook_trigger = WebhookTrigger(executor_url="http://localhost:8000")
    app.include_router(create_webhook_endpoint(webhook_trigger), tags=["trigger"])
    print(f"[main] Webhook trigger enabled at POST /trigger")

# Polling trigger - start background task
if TRIGGER_MODE == "polling":
    from triggers import PollingTrigger
    import asyncio

    polling_trigger = PollingTrigger(
        storage=storage,
        executor_url="http://localhost:8000",
        poll_interval=POLLING_INTERVAL,
    )

    @app.on_event("startup")
    async def start_polling():
        asyncio.create_task(polling_trigger.start())
        print(f"[main] Polling trigger started (interval: {POLLING_INTERVAL}s)")

    @app.on_event("shutdown")
    async def stop_polling():
        polling_trigger.stop()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
