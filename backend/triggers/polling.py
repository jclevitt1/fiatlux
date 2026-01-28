"""
Polling Trigger - periodically checks storage for new/unprocessed files.

Useful for development or when event-based triggers aren't available.
"""

import asyncio
from datetime import datetime
from typing import Any
from .base import Trigger, TriggerContext


class PollingTrigger(Trigger):
    """
    Trigger that polls storage for new files.

    Maintains a set of processed files to avoid re-processing.
    """

    def __init__(
        self,
        storage,  # StorageProvider instance
        executor_url: str = "http://localhost:8000",
        poll_interval: int = 60,  # seconds
    ):
        super().__init__(executor_url)
        self.storage = storage
        self.poll_interval = poll_interval
        self.processed_files: set[str] = set()
        self._running = False

    async def should_trigger(self, event: Any) -> bool:
        """
        Check if this file should be processed.

        Event is a file path string.
        """
        if not isinstance(event, str):
            return False

        # Skip if already processed
        if event in self.processed_files:
            return False

        # Must be PDF in raw/
        if not event.startswith("raw/") or not event.lower().endswith(".pdf"):
            return False

        return True

    async def get_context(self, event: Any) -> TriggerContext:
        """Create context from file path."""
        return TriggerContext.from_path(path=event)

    async def scan_once(self) -> list[dict]:
        """
        Scan storage once for new files.

        Returns list of job responses for triggered files.
        """
        results = []
        mode_folders = ["Notes", "Create_Project", "Existing_Project"]

        for folder in mode_folders:
            path = f"raw/{folder}"
            try:
                files = await self.storage.list_files(path)
                for f in files:
                    if f.path.lower().endswith(".pdf"):
                        result = await self.process(f.path)
                        if result:
                            self.processed_files.add(f.path)
                            results.append(result)
            except FileNotFoundError:
                # Folder doesn't exist yet, that's fine
                continue

        return results

    async def start(self):
        """Start the polling loop."""
        self._running = True
        print(f"[PollingTrigger] Starting with {self.poll_interval}s interval")

        while self._running:
            try:
                results = await self.scan_once()
                if results:
                    print(f"[PollingTrigger] Triggered {len(results)} jobs")
            except Exception as e:
                print(f"[PollingTrigger] Error: {e}")

            await asyncio.sleep(self.poll_interval)

    def stop(self):
        """Stop the polling loop."""
        self._running = False
        print("[PollingTrigger] Stopped")
