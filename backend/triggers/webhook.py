"""
Webhook Trigger - receives HTTP calls to trigger jobs.

Can be called directly by the Swift app after upload, or by
external services like Zapier, IFTTT, etc.
"""

from typing import Any
from .base import Trigger, TriggerContext


class WebhookTrigger(Trigger):
    """
    Trigger that responds to webhook HTTP requests.

    Expected payload:
    {
        "file_path": "raw/Notes/my_note.pdf",
        "additional_text": "optional context",
        "project_id": "optional, for existing_project mode"
    }
    """

    async def should_trigger(self, event: Any) -> bool:
        """Validate webhook payload."""
        if not isinstance(event, dict):
            return False

        file_path = event.get("file_path", "")

        # Must have a file path
        if not file_path:
            return False

        # Must be in raw/
        if not file_path.startswith("raw/"):
            return False

        # Must be a PDF
        if not file_path.lower().endswith(".pdf"):
            return False

        return True

    async def get_context(self, event: Any) -> TriggerContext:
        """Extract context from webhook payload."""
        file_path = event["file_path"]

        return TriggerContext.from_path(
            path=file_path,
            additional_text=event.get("additional_text", ""),
            project_id=event.get("project_id"),
            metadata=event.get("metadata", {}),
        )


# FastAPI endpoint for webhook trigger
def create_webhook_endpoint(trigger: WebhookTrigger):
    """
    Create a FastAPI router for the webhook trigger.

    Usage in main.py:
        from triggers import WebhookTrigger, create_webhook_endpoint

        webhook_trigger = WebhookTrigger()
        app.include_router(create_webhook_endpoint(webhook_trigger))
    """
    from fastapi import APIRouter, HTTPException
    from pydantic import BaseModel

    router = APIRouter()

    class WebhookRequest(BaseModel):
        file_path: str
        additional_text: str = ""
        project_id: str | None = None
        metadata: dict = {}

    @router.post("/trigger")
    async def trigger_webhook(request: WebhookRequest):
        """
        Trigger a job via webhook.

        This is an alternative to polling - call this endpoint
        immediately after uploading a file to trigger processing.
        """
        event = request.model_dump()

        if not await trigger.should_trigger(event):
            raise HTTPException(status_code=400, detail="Invalid trigger payload")

        try:
            result = await trigger.process(event)
            return {"triggered": True, "job": result}
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))

    return router
