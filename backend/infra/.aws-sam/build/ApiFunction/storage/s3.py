import boto3
from botocore.exceptions import ClientError

from .base import StorageProvider, StorageFile, RawFolderWriteError


class S3Storage(StorageProvider):
    """
    S3 storage implementation.

    Folder structure (user-scoped):
        {user_id}/project_notes/    - Uploaded PDFs + summaries
        {user_id}/project_files/    - Generated code projects
    """

    def __init__(self, bucket_name: str, prefix: str = ""):
        """
        Args:
            bucket_name: S3 bucket name
            prefix: Optional prefix for all paths (e.g., "client_123/")
        """
        self.bucket_name = bucket_name
        self.prefix = prefix.strip("/")
        self._client = boto3.client('s3')

    def _full_path(self, path: str) -> str:
        """Get full S3 key with prefix."""
        path = path.strip("/")
        if self.prefix:
            return f"{self.prefix}/{path}"
        return path

    async def fetch_file(self, file_id: str) -> bytes:
        """Fetch file content. In S3, file_id is the key."""
        response = self._client.get_object(Bucket=self.bucket_name, Key=file_id)
        return response['Body'].read()

    async def fetch_file_by_path(self, path: str) -> bytes:
        """Fetch file content by path."""
        key = self._full_path(path)
        try:
            response = self._client.get_object(Bucket=self.bucket_name, Key=key)
            return response['Body'].read()
        except ClientError as e:
            if e.response['Error']['Code'] == 'NoSuchKey':
                raise FileNotFoundError(f"File not found: {path}")
            raise

    async def list_files(self, folder_path: str) -> list[StorageFile]:
        """List files in a folder (prefix)."""
        prefix = self._full_path(folder_path)
        if not prefix.endswith("/"):
            prefix += "/"

        paginator = self._client.get_paginator('list_objects_v2')
        files = []

        for page in paginator.paginate(Bucket=self.bucket_name, Prefix=prefix, Delimiter='/'):
            for obj in page.get('Contents', []):
                key = obj['Key']
                name = key.rsplit('/', 1)[-1]
                if name:  # Skip the folder itself
                    files.append(StorageFile(
                        id=key,
                        name=name,
                        path=key[len(self.prefix):].lstrip('/') if self.prefix else key,
                        mime_type=None,  # S3 doesn't store this in listing
                        size=obj.get('Size')
                    ))

        return files

    async def get_file_info(self, file_id: str) -> StorageFile:
        """Get metadata about a file."""
        response = self._client.head_object(Bucket=self.bucket_name, Key=file_id)
        name = file_id.rsplit('/', 1)[-1]

        return StorageFile(
            id=file_id,
            name=name,
            path=file_id[len(self.prefix):].lstrip('/') if self.prefix else file_id,
            mime_type=response.get('ContentType'),
            size=response.get('ContentLength')
        )

    async def write_file(self, path: str, content: bytes, mime_type: str = "application/octet-stream") -> StorageFile:
        """Write content to a file."""
        key = self._full_path(path)

        self._client.put_object(
            Bucket=self.bucket_name,
            Key=key,
            Body=content,
            ContentType=mime_type
        )

        return StorageFile(
            id=key,
            name=path.rsplit('/', 1)[-1],
            path=path,
            mime_type=mime_type,
            size=len(content)
        )

    async def delete_file(self, file_id: str) -> bool:
        """Delete a file."""
        self._client.delete_object(Bucket=self.bucket_name, Key=file_id)
        return True

    async def upload_to_raw(self, path: str, content: bytes, mime_type: str = "application/pdf") -> StorageFile:
        """
        Upload a file to the raw/ folder.

        Path should NOT include 'raw/' prefix.
        Example: upload_to_raw("MyNotes/note1.pdf", pdf_bytes)
        """
        full_path = f"raw/{path.strip('/')}"
        key = self._full_path(full_path)

        self._client.put_object(
            Bucket=self.bucket_name,
            Key=key,
            Body=content,
            ContentType=mime_type
        )

        return StorageFile(
            id=key,
            name=path.rsplit('/', 1)[-1],
            path=full_path,
            mime_type=mime_type,
            size=len(content)
        )
