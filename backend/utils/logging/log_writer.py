"""
Async batch writer for API logs.

This module provides a high-performance, non-blocking log writer
that batches log entries and writes them to Firestore efficiently.
"""

import asyncio
import logging
from datetime import datetime
from typing import Dict, List, Optional

from models.api_log import APILogEntry

logger = logging.getLogger(__name__)

# Global log writer instance
_log_writer: Optional["LogBatchWriter"] = None


class LogBatchWriter:
    """
    Async batch writer for API logs.

    Features:
    - In-memory buffer with configurable size
    - Time-based flush (every N seconds)
    - Size-based flush (every M logs)
    - Graceful shutdown handling
    - Retry logic for transient failures
    """

    def __init__(
        self,
        batch_size: int = 50,
        flush_interval_seconds: float = 5.0,
        max_retries: int = 3,
    ):
        """
        Initialize the log batch writer.

        Args:
            batch_size: Maximum entries before auto-flush
            flush_interval_seconds: Maximum time between flushes
            max_retries: Number of retry attempts for failed writes
        """
        self.batch_size = batch_size
        self.flush_interval = flush_interval_seconds
        self.max_retries = max_retries

        self._buffer: List[APILogEntry] = []
        self._lock = asyncio.Lock()
        self._flush_task: Optional[asyncio.Task] = None
        self._running = False
        self._last_flush = datetime.utcnow()

    async def start(self) -> None:
        """Start the background flush task."""
        if self._running:
            return

        self._running = True
        self._flush_task = asyncio.create_task(self._periodic_flush())
        logger.info(
            f"LogBatchWriter started (batch_size={self.batch_size}, "
            f"flush_interval={self.flush_interval}s)"
        )

    async def stop(self) -> None:
        """Stop the writer and flush remaining entries."""
        self._running = False

        if self._flush_task:
            self._flush_task.cancel()
            try:
                await self._flush_task
            except asyncio.CancelledError:
                pass
            self._flush_task = None

        # Final flush
        await self._flush()
        logger.info("LogBatchWriter stopped")

    async def add(self, entry: APILogEntry) -> None:
        """
        Add a log entry to the buffer (non-blocking).

        Args:
            entry: The APILogEntry to buffer
        """
        async with self._lock:
            self._buffer.append(entry)

            # Auto-flush if buffer is full
            if len(self._buffer) >= self.batch_size:
                # Schedule flush without blocking
                asyncio.create_task(self._flush_safe())

    async def _periodic_flush(self) -> None:
        """Background task that periodically flushes the buffer."""
        while self._running:
            try:
                await asyncio.sleep(self.flush_interval)
                await self._flush_safe()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Error in periodic flush: {e}")

    async def _flush_safe(self) -> None:
        """Flush with error handling."""
        try:
            await self._flush()
        except Exception as e:
            logger.error(f"Error during flush: {e}")

    async def _flush(self) -> None:
        """Flush buffer to Firestore."""
        async with self._lock:
            if not self._buffer:
                return

            entries = self._buffer.copy()
            self._buffer.clear()

        if not entries:
            return

        # Group entries by developer_id and date for efficient batch writes
        grouped = self._group_entries(entries)

        for (developer_id, date), logs in grouped.items():
            await self._write_batch_with_retry(developer_id, date, logs)

        self._last_flush = datetime.utcnow()
        logger.debug(f"Flushed {len(entries)} log entries")

    def _group_entries(
        self, entries: List[APILogEntry]
    ) -> Dict[tuple, List[APILogEntry]]:
        """
        Group entries by developer_id and date.

        Args:
            entries: List of log entries to group

        Returns:
            Dictionary mapping (developer_id, date) to list of entries
        """
        grouped: Dict[tuple, List[APILogEntry]] = {}

        for entry in entries:
            date = entry.timestamp.strftime("%Y-%m-%d")
            key = (entry.developer_id, date)

            if key not in grouped:
                grouped[key] = []
            grouped[key].append(entry)

        return grouped

    async def _write_batch_with_retry(
        self, developer_id: str, date: str, entries: List[APILogEntry]
    ) -> None:
        """
        Write a batch of entries with retry logic.

        Args:
            developer_id: The developer ID
            date: The date string (YYYY-MM-DD)
            entries: List of entries to write
        """
        import database.api_logs as api_logs_db

        for attempt in range(self.max_retries):
            try:
                await asyncio.to_thread(
                    api_logs_db.batch_write_logs, developer_id, date, entries
                )
                return
            except Exception as e:
                if attempt < self.max_retries - 1:
                    wait_time = 2**attempt  # Exponential backoff
                    logger.warning(
                        f"Batch write failed (attempt {attempt + 1}/{self.max_retries}), "
                        f"retrying in {wait_time}s: {e}"
                    )
                    await asyncio.sleep(wait_time)
                else:
                    logger.error(
                        f"Batch write failed after {self.max_retries} attempts "
                        f"for developer {developer_id} on {date}: {e}"
                    )
                    # TODO: Consider writing to a dead-letter queue
                    raise

    @property
    def buffer_size(self) -> int:
        """Get current buffer size."""
        return len(self._buffer)

    @property
    def is_running(self) -> bool:
        """Check if writer is running."""
        return self._running


def get_log_writer() -> Optional[LogBatchWriter]:
    """Get the global log writer instance."""
    return _log_writer


def init_log_writer(
    batch_size: int = 50,
    flush_interval_seconds: float = 5.0,
    max_retries: int = 3,
) -> LogBatchWriter:
    """
    Initialize the global log writer instance.

    Should be called once during application startup.

    Args:
        batch_size: Maximum entries before auto-flush
        flush_interval_seconds: Maximum time between flushes
        max_retries: Number of retry attempts for failed writes

    Returns:
        The initialized LogBatchWriter
    """
    global _log_writer

    if _log_writer is not None:
        logger.warning("Log writer already initialized")
        return _log_writer

    _log_writer = LogBatchWriter(
        batch_size=batch_size,
        flush_interval_seconds=flush_interval_seconds,
        max_retries=max_retries,
    )

    return _log_writer


async def shutdown_log_writer() -> None:
    """Shutdown the global log writer instance."""
    global _log_writer

    if _log_writer is not None:
        await _log_writer.stop()
        _log_writer = None
