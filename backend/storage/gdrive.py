import os
import base64
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload
import io
import pickle

from .base import StorageProvider, StorageFile, RawFolderWriteError


class GDriveStorage(StorageProvider):
    """
    Google Drive storage implementation.

    Expected folder structure in root folder (default: FiatLux):
        raw/        - Original PDFs (read-only)
        notes/      - Processed summaries
        projects/   - Generated projects
    """

    SCOPES = ['https://www.googleapis.com/auth/drive']

    def __init__(
        self,
        credentials_path: str = "credentials.json",
        token_path: str = "token.pickle",
        root_folder_name: str | None = None,
    ):
        self.credentials_path = credentials_path
        self.token_path = token_path
        # Root folder name - defaults to GDRIVE_ROOT_FOLDER env var or "FiatLux"
        self.root_folder_name = root_folder_name or os.getenv("GDRIVE_ROOT_FOLDER", "FiatLux")
        self._service = None
        self._folder_cache: dict[str, str] = {}  # path -> folder_id
        self._root_folder_id: str | None = None

    @property
    def service(self):
        """Lazy-load the Drive service."""
        if self._service is None:
            self._service = self._build_service()
        return self._service

    @property
    def root_folder_id(self) -> str:
        """Get or create the root folder ID."""
        if self._root_folder_id is None:
            self._root_folder_id = self._get_or_create_root_folder()
        return self._root_folder_id

    def _get_or_create_root_folder(self) -> str:
        """Get or create the root folder (e.g., 'FiatLux') in Google Drive."""
        # Search for existing folder
        query = f"name='{self.root_folder_name}' and mimeType='application/vnd.google-apps.folder' and trashed=false and 'root' in parents"
        results = self.service.files().list(q=query, fields="files(id, name)").execute()
        files = results.get('files', [])

        if files:
            folder_id = files[0]['id']
            print(f"[GDriveStorage] Using existing folder: {self.root_folder_name} ({folder_id})")
            return folder_id

        # Create new folder
        file_metadata = {
            'name': self.root_folder_name,
            'mimeType': 'application/vnd.google-apps.folder',
        }
        folder = self.service.files().create(body=file_metadata, fields='id').execute()
        folder_id = folder['id']
        print(f"[GDriveStorage] Created new folder: {self.root_folder_name} ({folder_id})")
        return folder_id

    def _build_service(self):
        """Build and authenticate the Drive service."""
        creds = None

        # Load existing token
        if os.path.exists(self.token_path):
            with open(self.token_path, 'rb') as token:
                creds = pickle.load(token)

        # Refresh or get new credentials
        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                flow = InstalledAppFlow.from_client_secrets_file(
                    self.credentials_path, self.SCOPES
                )
                creds = flow.run_local_server(port=0)

            # Save token for next run
            with open(self.token_path, 'wb') as token:
                pickle.dump(creds, token)

        return build('drive', 'v3', credentials=creds)

    async def _get_folder_id(self, folder_path: str) -> str | None:
        """Get folder ID from path, relative to GoodNotes folder."""
        if folder_path in self._folder_cache:
            return self._folder_cache[folder_path]

        parts = folder_path.strip("/").split("/")
        current_id = self.root_folder_id

        for part in parts:
            if not part:
                continue

            query = f"name='{part}' and '{current_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
            results = self.service.files().list(q=query, fields="files(id, name)").execute()
            files = results.get('files', [])

            if not files:
                return None

            current_id = files[0]['id']

        self._folder_cache[folder_path] = current_id
        return current_id

    async def _create_folder_path(self, folder_path: str) -> str:
        """Create folder path if it doesn't exist, return folder ID."""
        # Block raw folder creation (shouldn't happen, but safety)
        self._assert_not_raw(folder_path)

        parts = folder_path.strip("/").split("/")
        current_id = self.root_folder_id
        current_path = ""

        for part in parts:
            if not part:
                continue

            current_path = f"{current_path}/{part}" if current_path else part

            # Check cache first
            if current_path in self._folder_cache:
                current_id = self._folder_cache[current_path]
                continue

            # Check if folder exists
            query = f"name='{part}' and '{current_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
            results = self.service.files().list(q=query, fields="files(id, name)").execute()
            files = results.get('files', [])

            if files:
                current_id = files[0]['id']
            else:
                # Create folder
                file_metadata = {
                    'name': part,
                    'mimeType': 'application/vnd.google-apps.folder',
                    'parents': [current_id]
                }
                folder = self.service.files().create(body=file_metadata, fields='id').execute()
                current_id = folder['id']

            self._folder_cache[current_path] = current_id

        return current_id

    async def fetch_file(self, file_id: str) -> bytes:
        """Fetch file content by ID."""
        request = self.service.files().get_media(fileId=file_id)
        content = request.execute()
        return content

    async def fetch_file_by_path(self, path: str) -> bytes:
        """Fetch file content by path relative to GoodNotes folder."""
        parts = path.strip("/").rsplit("/", 1)

        if len(parts) == 2:
            folder_path, file_name = parts
            folder_id = await self._get_folder_id(folder_path)
        else:
            file_name = parts[0]
            folder_id = self.root_folder_id

        if not folder_id:
            raise FileNotFoundError(f"Folder not found: {folder_path}")

        query = f"name='{file_name}' and '{folder_id}' in parents and trashed=false"
        results = self.service.files().list(q=query, fields="files(id)").execute()
        files = results.get('files', [])

        if not files:
            raise FileNotFoundError(f"File not found: {path}")

        return await self.fetch_file(files[0]['id'])

    async def list_files(self, folder_path: str) -> list[StorageFile]:
        """List files in a folder."""
        folder_id = await self._get_folder_id(folder_path)

        if not folder_id:
            return []

        query = f"'{folder_id}' in parents and trashed=false"
        results = self.service.files().list(
            q=query,
            fields="files(id, name, mimeType, size)"
        ).execute()

        return [
            StorageFile(
                id=f['id'],
                name=f['name'],
                path=f"{folder_path}/{f['name']}",
                mime_type=f.get('mimeType'),
                size=int(f['size']) if f.get('size') else None
            )
            for f in results.get('files', [])
        ]

    async def get_file_info(self, file_id: str) -> StorageFile:
        """Get metadata about a file."""
        result = self.service.files().get(
            fileId=file_id,
            fields="id, name, mimeType, size, parents"
        ).execute()

        return StorageFile(
            id=result['id'],
            name=result['name'],
            path="",  # Would need to resolve full path
            mime_type=result.get('mimeType'),
            size=int(result['size']) if result.get('size') else None
        )

    async def write_file(self, path: str, content: bytes, mime_type: str = "application/octet-stream") -> StorageFile:
        """Write content to a file."""
        # Block writes to raw/
        self._assert_not_raw(path)

        parts = path.strip("/").rsplit("/", 1)

        if len(parts) == 2:
            folder_path, file_name = parts
            folder_id = await self._create_folder_path(folder_path)
        else:
            file_name = parts[0]
            folder_id = self.root_folder_id

        # Check if file already exists
        query = f"name='{file_name}' and '{folder_id}' in parents and trashed=false"
        results = self.service.files().list(q=query, fields="files(id)").execute()
        existing = results.get('files', [])

        media = MediaIoBaseUpload(io.BytesIO(content), mimetype=mime_type)

        if existing:
            # Update existing file
            result = self.service.files().update(
                fileId=existing[0]['id'],
                media_body=media
            ).execute()
        else:
            # Create new file
            file_metadata = {
                'name': file_name,
                'parents': [folder_id]
            }
            result = self.service.files().create(
                body=file_metadata,
                media_body=media,
                fields='id, name, mimeType, size'
            ).execute()

        return StorageFile(
            id=result['id'],
            name=result.get('name', file_name),
            path=path,
            mime_type=result.get('mimeType'),
            size=int(result['size']) if result.get('size') else len(content)
        )

    async def delete_file(self, file_id: str) -> bool:
        """Delete a file (trash it)."""
        # Get file info to check if in raw/
        info = await self.get_file_info(file_id)

        # We'd need to resolve the full path to check - for now, be conservative
        # In production, resolve full path and check against raw/

        self.service.files().trash(fileId=file_id).execute()
        return True

    async def upload_to_raw(self, path: str, content: bytes, mime_type: str = "application/pdf") -> StorageFile:
        """
        Upload a file to the raw/ folder.

        Path should NOT include 'raw/' prefix.
        Example: upload_to_raw("MyNotes/note1.pdf", pdf_bytes)
        """
        # Ensure raw folder exists
        raw_folder_id = await self._get_or_create_raw_folder()

        # Build full path with raw/ prefix for internal tracking
        full_path = f"raw/{path.strip('/')}"
        parts = path.strip("/").rsplit("/", 1)

        if len(parts) == 2:
            subfolder_path, file_name = parts
            # Create subfolder path under raw/
            folder_id = await self._create_folder_path_under_raw(subfolder_path, raw_folder_id)
        else:
            file_name = parts[0]
            folder_id = raw_folder_id

        # Check if file already exists
        query = f"name='{file_name}' and '{folder_id}' in parents and trashed=false"
        results = self.service.files().list(q=query, fields="files(id)").execute()
        existing = results.get('files', [])

        media = MediaIoBaseUpload(io.BytesIO(content), mimetype=mime_type)

        if existing:
            # Update existing file
            result = self.service.files().update(
                fileId=existing[0]['id'],
                media_body=media
            ).execute()
        else:
            # Create new file
            file_metadata = {
                'name': file_name,
                'parents': [folder_id]
            }
            result = self.service.files().create(
                body=file_metadata,
                media_body=media,
                fields='id, name, mimeType, size'
            ).execute()

        return StorageFile(
            id=result['id'],
            name=result.get('name', file_name),
            path=full_path,
            mime_type=result.get('mimeType'),
            size=int(result['size']) if result.get('size') else len(content)
        )

    async def _get_or_create_raw_folder(self) -> str:
        """Get or create the raw/ folder under GoodNotes."""
        if "raw" in self._folder_cache:
            return self._folder_cache["raw"]

        # Check if raw folder exists
        query = f"name='raw' and '{self.root_folder_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
        results = self.service.files().list(q=query, fields="files(id)").execute()
        files = results.get('files', [])

        if files:
            folder_id = files[0]['id']
        else:
            # Create raw folder
            file_metadata = {
                'name': 'raw',
                'mimeType': 'application/vnd.google-apps.folder',
                'parents': [self.root_folder_id]
            }
            folder = self.service.files().create(body=file_metadata, fields='id').execute()
            folder_id = folder['id']

        self._folder_cache["raw"] = folder_id
        return folder_id

    async def _create_folder_path_under_raw(self, subfolder_path: str, raw_folder_id: str) -> str:
        """Create subfolder path under raw/, return final folder ID."""
        parts = subfolder_path.strip("/").split("/")
        current_id = raw_folder_id
        current_path = "raw"

        for part in parts:
            if not part:
                continue

            current_path = f"{current_path}/{part}"

            # Check cache
            if current_path in self._folder_cache:
                current_id = self._folder_cache[current_path]
                continue

            # Check if folder exists
            query = f"name='{part}' and '{current_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
            results = self.service.files().list(q=query, fields="files(id)").execute()
            files = results.get('files', [])

            if files:
                current_id = files[0]['id']
            else:
                # Create folder
                file_metadata = {
                    'name': part,
                    'mimeType': 'application/vnd.google-apps.folder',
                    'parents': [current_id]
                }
                folder = self.service.files().create(body=file_metadata, fields='id').execute()
                current_id = folder['id']

            self._folder_cache[current_path] = current_id

        return current_id
