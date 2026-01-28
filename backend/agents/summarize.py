from anthropic import AsyncAnthropic

from .base import BaseAgent, AgentResult
from storage.base import StorageProvider
from models.job import Job
from utils.pdf import pdf_to_base64_images


class SummarizeAgent(BaseAgent):
    """
    Mode 1: Notes
    Takes raw PDF from storage and produces a summary.
    """

    def __init__(self, storage: StorageProvider, anthropic_client: AsyncAnthropic):
        super().__init__(storage)
        self.client = anthropic_client

    async def run(self, job: Job) -> AgentResult:
        """
        Process a PDF and generate a summary.

        Job fields used:
            - raw_file_path: Path to PDF in raw/ folder
            - additional_text: Optional context/instructions
        """
        try:
            # Fetch PDF from storage
            pdf_bytes = await self.storage.fetch_file_by_path(job.raw_file_path)

            # Convert to images for Claude vision
            images = pdf_to_base64_images(pdf_bytes)

            if not images:
                return AgentResult(
                    success=False,
                    data=None,
                    error="PDF has no pages"
                )

            # Build message content with images
            content = []

            # Add each page as an image
            for i, img_b64 in enumerate(images):
                content.append({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": img_b64
                    }
                })

            # Add the prompt
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

            # Call Claude with vision
            message = await self.client.messages.create(
                model="claude-sonnet-4-20250514",
                max_tokens=4096,
                messages=[{"role": "user", "content": content}]
            )

            summary = message.content[0].text

            # Determine output path (mirror structure in notes/)
            # raw/folder/file.pdf -> notes/folder/file.md
            output_path = job.raw_file_path.replace("raw/", "notes/", 1)
            output_path = output_path.rsplit(".", 1)[0] + ".md"

            # Write summary to storage
            await self.storage.write_file(
                output_path,
                summary.encode("utf-8"),
                mime_type="text/markdown"
            )

            return AgentResult(
                success=True,
                data={
                    "summary": summary,
                    "output_path": output_path,
                    "pages_processed": len(images)
                }
            )

        except FileNotFoundError as e:
            return AgentResult(success=False, data=None, error=str(e))
        except Exception as e:
            return AgentResult(success=False, data=None, error=str(e))
