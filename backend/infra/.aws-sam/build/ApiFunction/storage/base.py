from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import BinaryIO


class RawFolderWriteError(Exception):
    """Raised when attempting to write to the raw/ folder."""
    pass


@dataclass
class StorageFile:
    """Represents a file in storage."""
    id: str
    name: str
    path: str
    mime_type: str | None = None
    size: int | None = None


class StorageProvider(ABC):
    """
    Abstract storage provider.

    Folder structure:
        raw/        - Original PDFs. READ-ONLY. Never write here.
        notes/      - Processed summaries and notes
        projects/   - Generated projects
    """

    # Protected folder - no writes allowed
    RAW_FOLDER = "raw"

    def _assert_not_raw(self, path: str) -> None:
        """Raise error if trying to write to raw folder."""
        normalized = path.strip("/").lower()
        if normalized.startswith(self.RAW_FOLDER):
            raise RawFolderWriteError(
                f"Cannot write to '{self.RAW_FOLDER}/' folder. It is read-only."
            )

    # Read operations (allowed anywhere)

    @abstractmethod
    async def fetch_file(self, file_id: str) -> bytes:
        """Fetch file content by ID."""
        pass

    @abstractmethod
    async def fetch_file_by_path(self, path: str) -> bytes:
        """Fetch file content by path."""
        pass

    @abstractmethod
    async def list_files(self, folder_path: str) -> list[StorageFile]:
        """List files in a folder."""
        pass

    @abstractmethod
    async def get_file_info(self, file_id: str) -> StorageFile:
        """Get metadata about a file."""
        pass

    # Write operations (blocked for raw/)

    @abstractmethod
    async def write_file(self, path: str, content: bytes, mime_type: str = "application/octet-stream") -> StorageFile:
        """
        Write content to a file.

        Raises:
            RawFolderWriteError: If path is in the raw/ folder.
        """
        pass

    @abstractmethod
    async def delete_file(self, file_id: str) -> bool:
        """
        Delete a file.

        Note: Implementations should check if file is in raw/ and block deletion.
        """
        pass

    # Special method for upload endpoint only - bypasses raw/ protection

    @abstractmethod
    async def upload_to_raw(self, path: str, content: bytes, mime_type: str = "application/pdf") -> StorageFile:
        """
        Upload a file to the raw/ folder.

        This is the ONLY way to write to raw/. Used exclusively by the upload endpoint.
        Path should NOT include 'raw/' prefix - it will be added automatically.

        Example: upload_to_raw("MyNotes/note1.pdf", pdf_bytes)
                 -> saves to raw/MyNotes/note1.pdf
        """
        pass
