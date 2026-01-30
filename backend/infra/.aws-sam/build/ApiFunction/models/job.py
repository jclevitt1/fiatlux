from enum import Enum
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


class JobStatus(Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"


class JobType(Enum):
    SUMMARIZE = "summarize"
    CREATE_PROJECT = "create_project"
    EXISTING_PROJECT = "existing_project"
    EXECUTE = "execute"  # AI decides what to do based on note content


@dataclass
class Job:
    """
    Represents a processing job.

    Jobs are triggered by new files appearing in raw/ folder.
    """
    id: str
    job_type: JobType
    status: JobStatus = JobStatus.PENDING

    # Input
    raw_file_path: str = ""          # Path in raw/ folder
    additional_text: str = ""         # Optional context from user
    project_id: str | None = None     # For existing_project jobs
    project_name: str | None = None   # For execute jobs - name of the project

    # Output
    output_path: str | None = None    # Where results are written
    result: dict[str, Any] = field(default_factory=dict)
    error: str | None = None

    # Timestamps
    created_at: datetime = field(default_factory=datetime.utcnow)
    started_at: datetime | None = None
    completed_at: datetime | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "job_type": self.job_type.value,
            "status": self.status.value,
            "raw_file_path": self.raw_file_path,
            "additional_text": self.additional_text,
            "project_id": self.project_id,
            "project_name": self.project_name,
            "output_path": self.output_path,
            "result": self.result,
            "error": self.error,
            "created_at": self.created_at.isoformat(),
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Job":
        return cls(
            id=data["id"],
            job_type=JobType(data["job_type"]),
            status=JobStatus(data["status"]),
            raw_file_path=data.get("raw_file_path", ""),
            additional_text=data.get("additional_text", ""),
            project_id=data.get("project_id"),
            project_name=data.get("project_name"),
            output_path=data.get("output_path"),
            result=data.get("result", {}),
            error=data.get("error"),
            created_at=datetime.fromisoformat(data["created_at"]),
            started_at=datetime.fromisoformat(data["started_at"]) if data.get("started_at") else None,
            completed_at=datetime.fromisoformat(data["completed_at"]) if data.get("completed_at") else None,
        )
