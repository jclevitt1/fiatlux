"""
S3 Event Trigger - responds to S3 bucket notifications.

Use with AWS Lambda or any service that receives S3 events.
"""

from typing import Any
from .base import Trigger, TriggerContext


class S3EventTrigger(Trigger):
    """
    Trigger that responds to S3 object creation events.

    Expected event format (from S3 -> Lambda -> this trigger):
    {
        "Records": [
            {
                "s3": {
                    "bucket": {"name": "my-bucket"},
                    "object": {"key": "raw/Notes/my_note.pdf"}
                }
            }
        ]
    }
    """

    def __init__(self, executor_url: str = "http://localhost:8000", bucket_filter: str | None = None):
        super().__init__(executor_url)
        self.bucket_filter = bucket_filter

    async def should_trigger(self, event: Any) -> bool:
        """Check if this is a valid S3 event for a PDF in raw/."""
        if not isinstance(event, dict):
            return False

        records = event.get("Records", [])
        if not records:
            return False

        for record in records:
            s3_info = record.get("s3", {})
            bucket_name = s3_info.get("bucket", {}).get("name", "")
            object_key = s3_info.get("object", {}).get("key", "")

            # Check bucket filter
            if self.bucket_filter and bucket_name != self.bucket_filter:
                continue

            # Check if it's a PDF in raw/ folder
            if object_key.startswith("raw/") and object_key.lower().endswith(".pdf"):
                return True

        return False

    async def get_context(self, event: Any) -> TriggerContext:
        """Extract context from S3 event."""
        records = event.get("Records", [])

        for record in records:
            s3_info = record.get("s3", {})
            object_key = s3_info.get("object", {}).get("key", "")

            if object_key.startswith("raw/") and object_key.lower().endswith(".pdf"):
                return TriggerContext.from_path(
                    path=object_key,
                    metadata={
                        "bucket": s3_info.get("bucket", {}).get("name"),
                        "event_name": record.get("eventName"),
                    }
                )

        raise ValueError("No valid S3 object found in event")
