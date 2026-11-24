import os
from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field


SUBSCRIPTION_ENFORCEMENT_START_AT = os.getenv(
    'SUBSCRIPTION_ENFORCEMENT_START_AT',
    '2026-10-01T00:00:00Z',
)
def subscription_enforcement_start_at_utc(value=None):
    """Return the first complete UTC month covered by the configured rollout."""
    raw = SUBSCRIPTION_ENFORCEMENT_START_AT if value is None else value
    try:
        parsed = datetime.fromisoformat(raw.replace('Z', '+00:00'))
    except (TypeError, ValueError, OverflowError):
        return None
    parsed = parsed.astimezone(timezone.utc) if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    if parsed.day == 1 and parsed.hour == 0 and parsed.minute == 0 and parsed.second == 0 and parsed.microsecond == 0:
        return parsed
    return datetime(parsed.year + 1, 1, 1, tzinfo=timezone.utc) if parsed.month == 12 else datetime(
        parsed.year, parsed.month + 1, 1, tzinfo=timezone.utc
    )


def subscription_counter_covers_month(date, counter_started_at=None) -> bool:
    """Only trust monthly counters whose durable marker predates that UTC month."""
    raw = counter_started_at
    if isinstance(raw, datetime):
        started = raw.astimezone(timezone.utc) if raw.tzinfo else raw.replace(tzinfo=timezone.utc)
    else:
        try:
            started = datetime.fromisoformat(raw.replace('Z', '+00:00'))
        except (AttributeError, TypeError, ValueError, OverflowError):
            return False
        started = started.astimezone(timezone.utc) if started.tzinfo else started.replace(tzinfo=timezone.utc)
    current = date.astimezone(timezone.utc) if date.tzinfo else date.replace(tzinfo=timezone.utc)
    month_start = datetime(current.year, current.month, 1, tzinfo=timezone.utc)
    enforcement_start = subscription_enforcement_start_at_utc()
    return enforcement_start is not None and month_start >= enforcement_start and started <= month_start


class UsageStats(BaseModel):
    """Represents a set of usage metrics for a period."""

    transcription_seconds: int = 0
    words_transcribed: int = 0
    insights_gained: int = 0
    memories_created: int = 0


class UsagePeriod(str, Enum):
    TODAY = "today"
    MONTHLY = "monthly"
    YEARLY = "yearly"
    ALL_TIME = "all_time"


class UsageHistoryPoint(UsageStats):
    date: str


class UserUsageResponse(BaseModel):
    """The response model for the user usage API endpoint."""

    today: Optional[UsageStats] = None
    monthly: Optional[UsageStats] = None
    yearly: Optional[UsageStats] = None
    all_time: Optional[UsageStats] = None
    history: Optional[List[UsageHistoryPoint]] = None


class HourlyUsage(UsageStats):
    """Represents the hourly usage data stored in the database."""

    uid: str
    year: int
    month: int
    day: int
    hour: int
    last_updated: datetime = Field(default_factory=datetime.utcnow)
