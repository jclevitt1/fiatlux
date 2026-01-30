import os

from .base import StorageProvider
from .s3 import S3Storage
from .dynamodb import DynamoDBJobStore, ProjectStore

__all__ = [
    "StorageProvider",
    "S3Storage",
    "DynamoDBJobStore",
    "ProjectStore",
]

# Only import GDrive if not in Lambda (avoids google dependency in Lambda)
if os.environ.get("AWS_LAMBDA_FUNCTION_NAME") is None:
    try:
        from .gdrive import GDriveStorage
        __all__.append("GDriveStorage")
    except ImportError:
        # google libraries not installed, skip GDrive support
        pass
