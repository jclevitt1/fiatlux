import json
from anthropic import AsyncAnthropic

from .base import BaseAgent, AgentResult
from storage.base import StorageProvider
from models.job import Job
from utils.pdf import pdf_to_base64_images


class CreateProjectAgent(BaseAgent):
    """
    Mode 2: Create Project
    Takes notes and generates a new project from scratch.
    """

    def __init__(self, storage: StorageProvider, anthropic_client: AsyncAnthropic):
        super().__init__(storage)
        self.client = anthropic_client

    async def run(self, job: Job) -> AgentResult:
        """
        Process notes and generate a new project.

        Job fields used:
            - raw_file_path: Path to PDF in raw/ folder
            - additional_text: Optional context/instructions
        """
        try:
            # Fetch and convert PDF
            pdf_bytes = await self.storage.fetch_file_by_path(job.raw_file_path)
            images = pdf_to_base64_images(pdf_bytes)

            if not images:
                return AgentResult(success=False, data=None, error="PDF has no pages")

            # Phase 1: Extract requirements from the notes
            requirements = await self._extract_requirements(images, job.additional_text)

            # Phase 2: Generate project structure
            structure = await self._generate_structure(requirements)

            # Phase 3: Generate code files
            files = await self._generate_files(requirements, structure)

            # Phase 4: Write files to storage
            project_name = structure.get("name", "new-project")
            base_path = f"projects/{project_name}"

            written_files = []
            for file_path, content in files.items():
                full_path = f"{base_path}/{file_path}"
                await self.storage.write_file(
                    full_path,
                    content.encode("utf-8"),
                    mime_type="text/plain"
                )
                written_files.append(full_path)

            return AgentResult(
                success=True,
                data={
                    "project_name": project_name,
                    "project_path": base_path,
                    "requirements": requirements,
                    "structure": structure,
                    "files_written": written_files
                }
            )

        except FileNotFoundError as e:
            return AgentResult(success=False, data=None, error=str(e))
        except Exception as e:
            return AgentResult(success=False, data=None, error=str(e))

    async def _extract_requirements(self, images: list[str], additional_text: str) -> dict:
        """Extract structured requirements from note images."""
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

        additional = f"\n\nAdditional context: {additional_text}" if additional_text else ""

        content.append({
            "type": "text",
            "text": f"""Analyze these handwritten notes describing a software project.{additional}

Extract and structure:
1. **Project Overview** - What is being built (1-2 sentences)
2. **Core Features** - Main functionality (bulleted list)
3. **Technical Requirements** - Languages, frameworks, dependencies
4. **Data Models** - Key entities and their relationships
5. **API/Endpoints** - If applicable
6. **Constraints** - Performance, security, or other requirements

Be specific and thorough. This will be used to generate code."""
        })

        message = await self.client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=4096,
            messages=[{"role": "user", "content": content}]
        )

        return {"raw": message.content[0].text}

    async def _generate_structure(self, requirements: dict) -> dict:
        """Generate project directory structure."""
        message = await self.client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=2048,
            messages=[{
                "role": "user",
                "content": f"""Based on these requirements, generate a project structure.

Requirements:
{requirements['raw']}

Return ONLY valid JSON:
{{
    "name": "project-name-kebab-case",
    "type": "web-app|api|cli|library",
    "language": "python|typescript|etc",
    "framework": "fastapi|express|none|etc",
    "directories": ["src", "tests", "etc"],
    "files": ["src/main.py", "README.md", "etc"]
}}"""
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
            return {
                "name": "new-project",
                "type": "unknown",
                "language": "python",
                "directories": ["src"],
                "files": ["src/main.py", "README.md"]
            }

    async def _generate_files(self, requirements: dict, structure: dict) -> dict:
        """Generate actual code files."""
        files = {}

        for file_path in structure.get("files", []):
            message = await self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=4096,
                messages=[{
                    "role": "user",
                    "content": f"""Generate code for this file.

Project: {structure.get('name')}
Type: {structure.get('type')}
Language: {structure.get('language')}
Framework: {structure.get('framework', 'none')}

Requirements:
{requirements['raw']}

All project files: {structure.get('files')}

Generate ONLY the code for: {file_path}
No markdown, no explanations, just the raw file content."""
                }]
            )

            content = message.content[0].text

            # Strip markdown if Claude wrapped it anyway
            if content.startswith("```"):
                lines = content.split("\n")
                if lines[-1].strip() == "```":
                    content = "\n".join(lines[1:-1])
                else:
                    content = "\n".join(lines[1:])

            files[file_path] = content

        return files
