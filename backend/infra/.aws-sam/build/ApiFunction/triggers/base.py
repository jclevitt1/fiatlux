"""
Abstract Trigger class for invoking workers.

Triggers watch for events (file uploads, webhooks, schedules) and
invoke the appropriate worker when conditions are met.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any


class TriggerMode(Enum):
    """Maps folder structure to job types."""
    NOTES = "notes"  # -> summarize job
    CREATE_PROJECT = "create_project"  # -> create_project job
    EXISTING_PROJECT = "existing_project"  # -> existing_project job

    @classmethod
    def from_path(cls, path: str) -> "TriggerMode":
        """
        Parse mode from file path.

        Expected structure: raw/{mode}/{filename}.pdf
        Examples:
            raw/Notes/my_note.pdf -> NOTES
            raw/Create_Project/idea.pdf -> CREATE_PROJECT
            raw/Existing_Project/update.pdf -> EXISTING_PROJECT
        """
        parts = path.strip("/").split("/")
        if len(parts) < 2:
            raise ValueError(f"Invalid path structure: {path}")

        # Second part is the mode folder (after "raw/")
        mode_folder = parts[1].lower().replace(" ", "_")

        mode_map = {
            "notes": cls.NOTES,
            "create_project": cls.CREATE_PROJECT,
            "existing_project": cls.EXISTING_PROJECT,
        }

        if mode_folder not in mode_map:
            raise ValueError(f"Unknown mode folder: {parts[1]}")

        return mode_map[mode_folder]

    def to_job_type(self) -> str:
        """Convert to job type string for API."""
        job_type_map = {
            TriggerMode.NOTES: "summarize",
            TriggerMode.CREATE_PROJECT: "create_project",
            TriggerMode.EXISTING_PROJECT: "existing_project",
        }
        return job_type_map[self]


@dataclass
class TriggerContext:
    """Context passed from trigger to executor."""
    raw_file_path: str  # e.g., "raw/Notes/my_note.pdf"
    mode: TriggerMode
    triggered_at: datetime = field(default_factory=datetime.utcnow)
    additional_text: str = ""
    project_id: str | None = None  # Required for existing_project mode
    metadata: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_path(cls, path: str, **kwargs) -> "TriggerContext":
        """Create context from file path, auto-detecting mode."""
        mode = TriggerMode.from_path(path)
        return cls(raw_file_path=path, mode=mode, **kwargs)


class Trigger(ABC):
    """
    Abstract base class for triggers.

    Triggers are responsible for:
    1. Detecting when a new file/event should be processed
    2. Creating a TriggerContext with the relevant info
    3. Calling the executor (submitting a job)

    Subclasses implement the detection logic for different event sources:
    - S3EventTrigger: Listens to S3 bucket notifications
    - PollingTrigger: Periodically checks storage for new files
    - WebhookTrigger: Receives HTTP webhook calls
    """

    def __init__(self, executor_url: str = "http://localhost:8000"):
        """
        Args:
            executor_url: Base URL of the backend API to submit jobs to.
        """
        self.executor_url = executor_url

    @abstractmethod
    async def should_trigger(self, event: Any) -> bool:
        """
        Evaluate whether this event should trigger a job.

        Args:
            event: Event data (format depends on trigger type)

        Returns:
            True if a job should be submitted, False otherwise.
        """
        pass

    @abstractmethod
    async def get_context(self, event: Any) -> TriggerContext:
        """
        Extract TriggerContext from the event.

        Args:
            event: Event data that passed should_trigger

        Returns:
            TriggerContext with file path, mode, and metadata.
        """
        pass

    async def execute(self, context: TriggerContext) -> dict:
        """
        Submit a job to the executor.

        Args:
            context: TriggerContext with job details

        Returns:
            Response from the jobs API.
        """
        import httpx

        payload = {
            "job_type": context.mode.to_job_type(),
            "raw_file_path": context.raw_file_path,
            "additional_text": context.additional_text,
        }

        if context.project_id:
            payload["project_id"] = context.project_id

        async with httpx.AsyncClient() as client:
            response = await client.post(
                f"{self.executor_url}/jobs",
                json=payload
            )
            response.raise_for_status()
            return response.json()

    async def process(self, event: Any) -> dict | None:
        """
        Full trigger pipeline: check -> extract context -> execute.

        Args:
            event: Raw event data

        Returns:
            Job response if triggered, None if skipped.
        """
        if not await self.should_trigger(event):
            return None

        context = await self.get_context(event)
        return await self.execute(context)
