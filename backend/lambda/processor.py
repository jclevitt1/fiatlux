"""
AWS Lambda handler for processing PDFs with Claude.

Triggered by:
- S3 events when new files are uploaded to raw/
- Direct invocation with job_id

This Lambda runs the appropriate agent (summarize, create_project, existing_project)
based on the folder structure or job type.
"""

import os
import sys
import json
import uuid
from datetime import datetime
from urllib.parse import unquote_plus

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import boto3
from anthropic import Anthropic

from models.job import Job, JobStatus, JobType
from storage.dynamodb import DynamoDBJobStore
from storage.s3 import S3Storage
from agents.summarize import SummarizeAgent
from agents.create_project import CreateProjectAgent
from agents.existing_project import ExistingProjectAgent

# Environment variables
S3_BUCKET = os.environ.get("S3_BUCKET", "fiatlux-storage")
JOBS_TABLE = os.environ.get("JOBS_TABLE", "fiatlux-jobs")
AWS_REGION = os.environ.get("AWS_REGION", "us-west-1")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY")

# Initialize services
job_store = DynamoDBJobStore(table_name=JOBS_TABLE, region=AWS_REGION)
storage = S3Storage(bucket_name=S3_BUCKET)

# Use synchronous Anthropic client for Lambda
anthropic_client = Anthropic(api_key=ANTHROPIC_API_KEY)


def lambda_handler(event, context):
    """
    Main Lambda handler for PDF processing.

    Can be triggered by:
    1. S3 event (new file in raw/) - auto-creates job and processes
    2. Direct invocation with job_id - processes existing job
    """
    print(f"Event: {json.dumps(event)}")

    # Check if this is an S3 event
    if 'Records' in event and event['Records']:
        for record in event['Records']:
            if record.get('eventSource') == 'aws:s3':
                handle_s3_event(record)
        return {'status': 'processed', 'records': len(event['Records'])}

    # Check if this is a direct invocation with job_id
    if 'job_id' in event:
        return handle_job_invocation(event['job_id'])

    # Unknown event type
    print(f"Unknown event type: {event}")
    return {'status': 'ignored', 'reason': 'Unknown event type'}


def handle_s3_event(record: dict):
    """Handle S3 event - new file uploaded to project_notes/."""
    bucket = record['s3']['bucket']['name']
    key = unquote_plus(record['s3']['object']['key'])

    print(f"Processing S3 event: bucket={bucket}, key={key}")

    # Only process PDFs in project_notes/
    if not key.lower().endswith('.pdf'):
        print(f"Ignoring non-PDF file: {key}")
        return

    # New structure: {user_id}/project_notes/{filename}.pdf
    if '/project_notes/' not in key:
        print(f"Ignoring file outside project_notes/: {key}")
        return

    # Extract user_id from path: {user_id}/project_notes/...
    path_parts = key.split('/')
    user_id = path_parts[0] if len(path_parts) >= 2 else "unknown"
    print(f"Extracted user_id: {user_id}")

    # Default to EXECUTE job type (AI decides what to do)
    job_type = JobType.EXECUTE

    # Create a job for this file
    job = Job(
        id=str(uuid.uuid4()),
        job_type=job_type,
        status=JobStatus.PENDING,
        raw_file_path=key,
        additional_text='',
        project_id=None  # Could extract from filename or metadata
    )

    job_store.create_job(job, user_id=user_id)
    print(f"Created job {job.id} for {key} (type: {job_type.value}, user: {user_id})")

    # Process the job
    process_job(job)


def handle_job_invocation(job_id: str):
    """Handle direct invocation with job_id."""
    print(f"Processing job: {job_id}")

    job = job_store.get_job(job_id)
    if not job:
        return {'status': 'error', 'error': f'Job not found: {job_id}'}

    if job.status != JobStatus.PENDING:
        return {'status': 'skipped', 'reason': f'Job already {job.status.value}'}

    process_job(job)

    return {'status': 'completed', 'job_id': job_id}


def detect_job_type(s3_key: str) -> JobType:
    """Detect job type from S3 key path."""
    key_lower = s3_key.lower()

    if '/create_project/' in key_lower or '/createproject/' in key_lower:
        return JobType.CREATE_PROJECT
    elif '/existing_project/' in key_lower or '/existingproject/' in key_lower:
        return JobType.EXISTING_PROJECT
    else:
        # Default to summarize (Notes mode)
        return JobType.SUMMARIZE


def process_job(job: Job):
    """Process a job using the appropriate agent."""
    print(f"Processing job {job.id} (type: {job.job_type.value})")

    # Update status to processing
    job.status = JobStatus.PROCESSING
    job.started_at = datetime.utcnow()
    job_store.update_job(job)

    try:
        # Select and run agent
        # Note: Agents expect AsyncAnthropic but we're using sync Anthropic
        # We'll need to create sync wrappers or modify agents

        import asyncio

        if job.job_type == JobType.SUMMARIZE:
            agent = SummarizeAgentSync(storage, anthropic_client)
        elif job.job_type == JobType.CREATE_PROJECT:
            agent = CreateProjectAgentSync(storage, anthropic_client)
        elif job.job_type == JobType.EXISTING_PROJECT:
            agent = ExistingProjectAgentSync(storage, anthropic_client)
        elif job.job_type == JobType.EXECUTE:
            # EXECUTE: AI decides what to do based on note content
            # For now, route to CreateProjectAgent with project_name
            agent = ExecuteAgentSync(storage, anthropic_client)
        else:
            raise ValueError(f"Unknown job type: {job.job_type}")

        result = agent.run_sync(job)

        if result.success:
            job.status = JobStatus.COMPLETED
            job.result = result.data
            job.output_path = result.data.get('output_path') or result.data.get('project_path')
            print(f"Job {job.id} completed successfully: {job.output_path}")
        else:
            job.status = JobStatus.FAILED
            job.error = result.error
            print(f"Job {job.id} failed: {job.error}")

    except Exception as e:
        job.status = JobStatus.FAILED
        job.error = str(e)
        print(f"Job {job.id} error: {e}")
        import traceback
        traceback.print_exc()

    job.completed_at = datetime.utcnow()
    job_store.update_job(job)


# Synchronous wrappers for agents (Lambda doesn't play well with asyncio in some cases)

class SummarizeAgentSync:
    """Synchronous wrapper for SummarizeAgent."""

    def __init__(self, storage: S3Storage, client: Anthropic):
        self.storage = storage
        self.client = client

    def run_sync(self, job: Job):
        """Synchronous version of run."""
        from agents.base import AgentResult
        from utils.pdf import pdf_to_base64_images

        try:
            # Fetch PDF from S3
            import asyncio
            loop = asyncio.new_event_loop()
            pdf_bytes = loop.run_until_complete(self.storage.fetch_file_by_path(job.raw_file_path))

            # Convert to images
            images = pdf_to_base64_images(pdf_bytes)

            if not images:
                return AgentResult(success=False, data=None, error="PDF has no pages")

            # Build message content
            content = []
            for img_b64 in images:
                content.append({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": img_b64
                    }
                })

            additional = f"\n\nAdditional context: {job.additional_text}" if job.additional_text else ""
            content.append({
                "type": "text",
                "text": f"""Analyze these handwritten notes and provide a structured summary.{additional}

Provide:
1. **Main Points** - Key ideas and concepts
2. **Details** - Important specifics, data, or examples
3. **Action Items** - Tasks or next steps (if any)
4. **Questions/Open Items** - Unresolved items or things to follow up on (if any)

Be thorough but concise. Capture everything important."""
            })

            # Call Claude (synchronous)
            message = self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=4096,
                messages=[{"role": "user", "content": content}]
            )

            summary = message.content[0].text

            # Determine output path - new structure: {user_id}/project_notes/{name}_summary.md
            # Input: {user_id}/project_notes/{name}.pdf
            output_path = job.raw_file_path.rsplit(".", 1)[0] + "_summary.md"

            # Write summary to S3
            loop.run_until_complete(self.storage.write_file(
                output_path,
                summary.encode("utf-8"),
                mime_type="text/markdown"
            ))
            loop.close()

            return AgentResult(
                success=True,
                data={
                    "summary": summary,
                    "output_path": output_path,
                    "pages_processed": len(images)
                }
            )

        except Exception as e:
            return AgentResult(success=False, data=None, error=str(e))


class CreateProjectAgentSync:
    """Synchronous wrapper for CreateProjectAgent."""

    def __init__(self, storage: S3Storage, client: Anthropic):
        self.storage = storage
        self.client = client

    def run_sync(self, job: Job):
        """Synchronous version of run."""
        from agents.base import AgentResult
        from utils.pdf import pdf_to_base64_images
        import asyncio

        try:
            loop = asyncio.new_event_loop()
            pdf_bytes = loop.run_until_complete(self.storage.fetch_file_by_path(job.raw_file_path))

            images = pdf_to_base64_images(pdf_bytes)
            if not images:
                return AgentResult(success=False, data=None, error="PDF has no pages")

            # Phase 1: Extract requirements
            content = []
            for img_b64 in images:
                content.append({
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/png", "data": img_b64}
                })

            content.append({
                "type": "text",
                "text": """Analyze these handwritten notes that describe a software project.

Extract:
1. **Project Name** - A suitable name for this project
2. **Description** - What the project does
3. **Tech Stack** - Languages, frameworks, tools mentioned
4. **Features** - List of features/requirements
5. **File Structure** - Suggest a file/folder structure

Format as JSON:
```json
{
  "project_name": "...",
  "description": "...",
  "tech_stack": ["..."],
  "features": ["..."],
  "file_structure": ["path/to/file.ext", ...]
}
```"""
            })

            message = self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=4096,
                messages=[{"role": "user", "content": content}]
            )

            requirements_text = message.content[0].text

            # Parse JSON from response
            import re
            json_match = re.search(r'```json\s*(.*?)\s*```', requirements_text, re.DOTALL)
            if json_match:
                requirements = json.loads(json_match.group(1))
            else:
                requirements = json.loads(requirements_text)

            # Extract user_id from path: {user_id}/project_notes/...
            path_parts = job.raw_file_path.split('/')
            user_id = path_parts[0] if len(path_parts) >= 2 else "unknown"

            project_name = requirements.get("project_name", "project").replace(" ", "_")
            # New structure: {user_id}/project_files/{project_name}/
            project_path = f"{user_id}/project_files/{project_name}"

            # Phase 2: Generate files
            files_created = []
            for file_path in requirements.get("file_structure", []):
                full_path = f"{project_path}/{file_path}"

                # Generate file content
                gen_content = [{
                    "type": "text",
                    "text": f"""Generate the content for: {file_path}

Project: {requirements.get('description', '')}
Tech Stack: {', '.join(requirements.get('tech_stack', []))}
Features: {', '.join(requirements.get('features', []))}

Generate complete, working code. No placeholders."""
                }]

                gen_message = self.client.messages.create(
                    model="claude-sonnet-4-20250514",
                    max_tokens=8192,
                    messages=[{"role": "user", "content": gen_content}]
                )

                file_content = gen_message.content[0].text

                # Extract code from markdown if present
                code_match = re.search(r'```(?:\w+)?\s*(.*?)\s*```', file_content, re.DOTALL)
                if code_match:
                    file_content = code_match.group(1)

                # Write to S3
                loop.run_until_complete(self.storage.write_file(
                    full_path,
                    file_content.encode("utf-8"),
                    mime_type="text/plain"
                ))
                files_created.append(full_path)

            loop.close()

            return AgentResult(
                success=True,
                data={
                    "project_name": project_name,
                    "project_path": project_path,
                    "files_created": files_created,
                    "requirements": requirements
                }
            )

        except Exception as e:
            return AgentResult(success=False, data=None, error=str(e))


class ExistingProjectAgentSync:
    """Synchronous wrapper for ExistingProjectAgent."""

    def __init__(self, storage: S3Storage, client: Anthropic):
        self.storage = storage
        self.client = client

    def run_sync(self, job: Job):
        """Synchronous version of run."""
        from agents.base import AgentResult
        from utils.pdf import pdf_to_base64_images
        import asyncio

        try:
            if not job.project_id:
                return AgentResult(success=False, data=None, error="project_id is required")

            loop = asyncio.new_event_loop()

            # Extract user_id from path: {user_id}/project_notes/...
            path_parts = job.raw_file_path.split('/')
            user_id = path_parts[0] if len(path_parts) >= 2 else "unknown"

            # Fetch existing project files - new structure: {user_id}/project_files/{project_id}/
            project_path = f"{user_id}/project_files/{job.project_id}"
            existing_files = loop.run_until_complete(self.storage.list_files(project_path))

            project_context = []
            for f in existing_files[:10]:  # Limit to avoid token overflow
                try:
                    content = loop.run_until_complete(self.storage.fetch_file_by_path(f.path))
                    project_context.append(f"### {f.name}\n```\n{content.decode('utf-8')[:2000]}\n```")
                except Exception:
                    pass

            # Fetch and analyze PDF
            pdf_bytes = loop.run_until_complete(self.storage.fetch_file_by_path(job.raw_file_path))
            images = pdf_to_base64_images(pdf_bytes)

            if not images:
                return AgentResult(success=False, data=None, error="PDF has no pages")

            # Build prompt with project context
            content = []
            for img_b64 in images:
                content.append({
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/png", "data": img_b64}
                })

            context_text = "\n\n".join(project_context) if project_context else "No existing files found."

            content.append({
                "type": "text",
                "text": f"""Analyze these handwritten notes that describe changes to an existing project.

## Existing Project Files:
{context_text}

## Your Task:
1. Understand what changes are requested in the notes
2. Identify which files need to be modified or created
3. Generate the updated/new file contents

Respond with a JSON object:
```json
{{
  "summary": "Brief description of changes",
  "files_to_modify": [
    {{"path": "relative/path.ext", "content": "full file content"}}
  ],
  "files_to_create": [
    {{"path": "relative/path.ext", "content": "full file content"}}
  ]
}}
```"""
            })

            message = self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=8192,
                messages=[{"role": "user", "content": content}]
            )

            response_text = message.content[0].text

            # Parse response
            import re
            json_match = re.search(r'```json\s*(.*?)\s*```', response_text, re.DOTALL)
            if json_match:
                changes = json.loads(json_match.group(1))
            else:
                changes = json.loads(response_text)

            files_updated = []

            # Apply modifications
            for file_mod in changes.get("files_to_modify", []):
                full_path = f"{project_path}/{file_mod['path']}"
                loop.run_until_complete(self.storage.write_file(
                    full_path,
                    file_mod["content"].encode("utf-8"),
                    mime_type="text/plain"
                ))
                files_updated.append(full_path)

            # Create new files
            for file_new in changes.get("files_to_create", []):
                full_path = f"{project_path}/{file_new['path']}"
                loop.run_until_complete(self.storage.write_file(
                    full_path,
                    file_new["content"].encode("utf-8"),
                    mime_type="text/plain"
                ))
                files_updated.append(full_path)

            loop.close()

            return AgentResult(
                success=True,
                data={
                    "project_path": project_path,
                    "summary": changes.get("summary", ""),
                    "files_updated": files_updated
                }
            )

        except Exception as e:
            return AgentResult(success=False, data=None, error=str(e))


class ExecuteAgentSync:
    """
    Agent for EXECUTE jobs - AI analyzes notes and creates/modifies project.

    Uses project_name from job to determine output location.
    """

    def __init__(self, storage: S3Storage, client: Anthropic):
        self.storage = storage
        self.client = client

    def run_sync(self, job: Job):
        """Process notes and create/update project."""
        from agents.base import AgentResult
        from utils.pdf import pdf_to_base64_images
        import asyncio
        import re

        try:
            loop = asyncio.new_event_loop()
            pdf_bytes = loop.run_until_complete(self.storage.fetch_file_by_path(job.raw_file_path))

            images = pdf_to_base64_images(pdf_bytes)
            if not images:
                return AgentResult(success=False, data=None, error="PDF has no pages")

            # Extract user_id from path: {user_id}/project_notes/...
            path_parts = job.raw_file_path.split('/')
            user_id = path_parts[0] if len(path_parts) >= 2 else "unknown"

            project_name = (job.project_name or "project").replace(" ", "_")
            # New structure: {user_id}/project_files/{project_name}/
            project_path = f"{user_id}/project_files/{project_name}"

            print(f"[Execute] Processing for user {user_id}, project: {project_name}, output: {project_path}")

            # Phase 1: Analyze notes and extract requirements
            content = []
            for img_b64 in images:
                content.append({
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/png", "data": img_b64}
                })

            content.append({
                "type": "text",
                "text": f"""Analyze these handwritten notes for a software project called "{project_name}".

Extract the requirements and generate a complete project structure.

Respond with JSON:
```json
{{
  "description": "Brief description of what this project does",
  "tech_stack": ["language", "framework", ...],
  "features": ["feature1", "feature2", ...],
  "files": [
    {{"path": "relative/path.ext", "content": "full file content"}}
  ]
}}
```

Generate complete, working code for all files. No placeholders or TODOs."""
            })

            # Use streaming for large max_tokens (SDK requires it for >10min operations)
            response_text = ""
            stop_reason = None

            with self.client.messages.stream(
                model="claude-sonnet-4-20250514",
                max_tokens=64000,  # Model maximum - no artificial limit
                messages=[{"role": "user", "content": content}]
            ) as stream:
                for text in stream.text_stream:
                    response_text += text
                # Get final message for stop_reason
                final_message = stream.get_final_message()
                stop_reason = final_message.stop_reason

            print(f"[Execute] Response length: {len(response_text)}, stop_reason: {stop_reason}")

            # Check if response was truncated
            if stop_reason == "max_tokens":
                print("[Execute] WARNING: Response was truncated due to max_tokens limit")

            # Parse JSON from response
            json_match = re.search(r'```json\s*(.*?)\s*```', response_text, re.DOTALL)
            json_str = json_match.group(1) if json_match else response_text

            try:
                project_spec = json.loads(json_str)
            except json.JSONDecodeError as e:
                print(f"[Execute] JSON parse error: {e}")
                print(f"[Execute] JSON string (last 500 chars): ...{json_str[-500:]}")
                # If truncated, try to salvage what we can
                if stop_reason == "max_tokens":
                    raise ValueError(f"Response truncated - increase max_tokens or simplify request. JSON error: {e}")
                raise

            # Write files to S3
            files_created = []
            for file_info in project_spec.get("files", []):
                file_path = file_info.get("path", "")
                file_content = file_info.get("content", "")

                if file_path and file_content:
                    full_path = f"{project_path}/{file_path}"
                    loop.run_until_complete(self.storage.write_file(
                        full_path,
                        file_content.encode("utf-8"),
                        mime_type="text/plain"
                    ))
                    files_created.append(full_path)
                    print(f"[Execute] Created file: {full_path}")

            loop.close()

            return AgentResult(
                success=True,
                data={
                    "project_name": project_name,
                    "project_path": project_path,
                    "user_id": user_id,
                    "description": project_spec.get("description", ""),
                    "files_created": files_created,
                    "tech_stack": project_spec.get("tech_stack", []),
                    "features": project_spec.get("features", [])
                }
            )

        except Exception as e:
            import traceback
            traceback.print_exc()
            return AgentResult(success=False, data=None, error=str(e))
