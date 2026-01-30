import json
from anthropic import AsyncAnthropic

from .base import BaseAgent, AgentResult
from storage.base import StorageProvider
from models.job import Job
from utils.pdf import pdf_to_base64_images


class ExistingProjectAgent(BaseAgent):
    """
    Mode 3: Existing Project
    Same as CreateProjectAgent but with collect_context phase
    to understand the existing codebase before making changes.
    """

    def __init__(self, storage: StorageProvider, anthropic_client: AsyncAnthropic):
        super().__init__(storage)
        self.client = anthropic_client

    async def run(self, job: Job) -> AgentResult:
        """
        Process notes and modify an existing project.

        Job fields used:
            - raw_file_path: Path to PDF in raw/ folder
            - additional_text: Optional context/instructions
            - project_id: Reference to existing project (path in projects/)
        """
        try:
            if not job.project_id:
                return AgentResult(
                    success=False,
                    data=None,
                    error="project_id is required for existing project mode"
                )

            # Fetch and convert PDF
            pdf_bytes = await self.storage.fetch_file_by_path(job.raw_file_path)
            images = pdf_to_base64_images(pdf_bytes)

            if not images:
                return AgentResult(success=False, data=None, error="PDF has no pages")

            # Phase 0: Collect context from existing project
            project_context = await self._collect_context(job.project_id)

            # Phase 1: Plan the changes
            change_plan = await self._plan_changes(images, job.additional_text, project_context)

            # Phase 2: Generate the changes
            changes = await self._generate_changes(change_plan, project_context)

            # Phase 3: Apply changes to storage
            applied_changes = []
            for file_change in changes.get("files", []):
                path = file_change.get("path", "")
                action = file_change.get("action", "")
                content = file_change.get("content")

                full_path = f"projects/{job.project_id}/{path}"

                if action == "create" or action == "modify":
                    await self.storage.write_file(
                        full_path,
                        content.encode("utf-8") if content else b"",
                        mime_type="text/plain"
                    )
                    applied_changes.append({"path": full_path, "action": action})
                elif action == "delete":
                    # Note: Would need file_id for deletion - skip for now
                    applied_changes.append({"path": full_path, "action": "delete_skipped"})

            return AgentResult(
                success=True,
                data={
                    "project_id": job.project_id,
                    "change_plan": change_plan,
                    "changes_applied": applied_changes
                }
            )

        except FileNotFoundError as e:
            return AgentResult(success=False, data=None, error=str(e))
        except Exception as e:
            return AgentResult(success=False, data=None, error=str(e))

    async def _collect_context(self, project_id: str) -> dict:
        """
        Collect context about the existing project.

        Reads project files from storage and builds context.
        """
        project_path = f"projects/{project_id}"

        try:
            files = await self.storage.list_files(project_path)
        except Exception:
            return {
                "project_id": project_id,
                "exists": False,
                "files": [],
                "contents": {}
            }

        # Read contents of key files (limit to reasonable size)
        contents = {}
        for f in files[:20]:  # Limit to first 20 files
            if f.size and f.size > 50000:  # Skip files > 50KB
                continue

            try:
                file_content = await self.storage.fetch_file_by_path(f.path)
                contents[f.path] = file_content.decode("utf-8", errors="ignore")
            except Exception:
                continue

        return {
            "project_id": project_id,
            "exists": True,
            "files": [f.path for f in files],
            "contents": contents
        }

    async def _plan_changes(self, images: list[str], additional_text: str, context: dict) -> dict:
        """Plan what changes need to be made."""
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

        # Build context summary
        if context.get("exists"):
            context_summary = f"""Existing project files:
{chr(10).join(context.get('files', []))}

File contents:
"""
            for path, file_content in context.get("contents", {}).items():
                # Truncate long files
                truncated = file_content[:2000] + "..." if len(file_content) > 2000 else file_content
                context_summary += f"\n--- {path} ---\n{truncated}\n"
        else:
            context_summary = "Project does not exist yet or has no files."

        additional = f"\n\nAdditional context: {additional_text}" if additional_text else ""

        content.append({
            "type": "text",
            "text": f"""Analyze these handwritten notes describing changes to an existing project.{additional}

{context_summary}

Create a change plan:
1. **Summary** - What changes are requested
2. **Files to Modify** - List each with specific changes needed
3. **Files to Create** - New files needed
4. **Files to Delete** - If any
5. **Dependencies** - New packages or config changes
6. **Risks** - Breaking changes or things to watch out for"""
        })

        message = await self.client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=4096,
            messages=[{"role": "user", "content": content}]
        )

        return {"raw": message.content[0].text}

    async def _generate_changes(self, change_plan: dict, context: dict) -> dict:
        """Generate the actual code changes."""
        context_files = "\n".join(context.get("files", []))

        message = await self.client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=8192,
            messages=[{
                "role": "user",
                "content": f"""Generate code changes based on this plan.

Change Plan:
{change_plan['raw']}

Existing Files:
{context_files}

Return ONLY valid JSON:
{{
    "files": [
        {{
            "path": "relative/path/to/file",
            "action": "create|modify|delete",
            "content": "full file content or null for delete"
        }}
    ]
}}

For modifications, include the COMPLETE new file content, not just the changes."""
            }]
        )

        response_text = message.content[0].text

        try:
            if "```json" in response_text:
                response_text = response_text.split("```json")[1].split("```")[0]
            elif "```" in response_text:
                response_text = response_text.split("```")[1].split("```")[0]

            return json.loads(response_text.strip())
        except json.JSONDecodeError:
            return {"files": [], "error": "Failed to parse changes", "raw": response_text}
