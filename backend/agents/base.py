from abc import ABC, abstractmethod
from typing import Any
from dataclasses import dataclass

from storage.base import StorageProvider
from models.job import Job


@dataclass
class AgentResult:
    success: bool
    data: Any
    error: str | None = None


class BaseAgent(ABC):
    """Base class for all agents."""

    def __init__(self, storage: StorageProvider):
        self.storage = storage

    @abstractmethod
    async def run(self, job: Job) -> AgentResult:
        """
        Execute the agent's main logic.

        Args:
            job: The job to process (contains raw_file_path, additional_text, etc.)

        Returns:
            AgentResult with success status and data/error
        """
        pass
