from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field, field_validator, model_validator


class CalendarEvent(BaseModel):
    """One occurrence of a device calendar event, as uploaded by the app.

    Deliberately skeleton-only — title, time, location, source calendar. The app
    does not send notes/attendees/URLs because those routinely hold meeting
    passwords and private detail the agent has no use for when reasoning about
    where the user is and when they are free.
    """

    instance_id: str = Field(description='Event identifier + instance start; unique per occurrence')
    title: str = Field(default='', description='Event title; may be empty for untitled events')
    starts_at: datetime
    ends_at: Optional[datetime] = None
    all_day: bool = False

    # A floating event is not tied to a time zone — EventKit's own example is
    # "lunch at noon". All-day events are floating too. Their absolute instant
    # shifts when the device time zone changes, so `starts_at` alone is wrong to
    # reason from: a user flying Beijing -> San Francisco changes nothing on
    # their calendar, yet every floating event's UTC instant moves. Render these
    # from `local_start`/`local_end` instead.
    is_floating: bool = False
    local_start: Optional[str] = Field(
        default=None, description='Local wall time: "2026-08-06" if all-day, else "2026-08-06T14:30:00"'
    )
    local_end: Optional[str] = None
    time_zone: Optional[str] = Field(default=None, description='IANA tz the event is pinned to; null if floating')

    is_recurring: bool = False
    status: str = Field(default='confirmed', description='confirmed | tentative | canceled | none')
    location: Optional[str] = None
    calendar_title: Optional[str] = Field(default=None, description='Source calendar, e.g. "Work"')
    last_modified_at: Optional[datetime] = None

    @field_validator('instance_id')
    @classmethod
    def _instance_id_not_blank(cls, value: str) -> str:
        cleaned = (value or '').strip()
        if not cleaned:
            raise ValueError('instance_id must not be blank')
        return cleaned

    @field_validator('local_start', 'local_end', 'time_zone')
    @classmethod
    def _cap_short_text(cls, value: Optional[str]) -> Optional[str]:
        # Client-formatted, so a long value means something is wrong upstream
        # rather than a legitimately verbose event. Truncate instead of raising:
        # one malformed field should not fail the whole sync.
        if value is None:
            return None
        return value[:64]

    @field_validator('title', 'location', 'calendar_title')
    @classmethod
    def _cap_text(cls, value: Optional[str]) -> Optional[str]:
        # Titles and locations are user data of unbounded length; cap so one
        # pathological event cannot bloat a Firestore document or a prompt.
        if value is None:
            return None
        return value[:500]


class CalendarSyncRequest(BaseModel):
    """A full replacement of the events inside one time window.

    The window is explicit rather than inferred from the events so an empty
    `events` list is meaningful: it says "nothing on my calendar in this range",
    which must clear anything previously stored there.
    """

    window_start: datetime
    window_end: datetime
    events: List[CalendarEvent] = Field(default_factory=list)
    timezone: Optional[str] = Field(default=None, description='IANA tz of the device at sync time')

    @model_validator(mode='after')
    def _validate_window(self) -> 'CalendarSyncRequest':
        if self.window_end <= self.window_start:
            raise ValueError('window_end must be after window_start')
        return self


class CalendarSyncResponse(BaseModel):
    written: int
    deleted: int
    synced_at: datetime


class CalendarDeleteResponse(BaseModel):
    deleted: int


class CalendarSyncState(BaseModel):
    """What the app shows under the calendar permission toggle.

    `consent_granted` is the toggle's source of truth, not the iOS permission:
    the system permission only says "this app may read the calendar", never "the
    events may be uploaded and handed to AI providers". It ships in this response
    so the app resolves both halves of the toggle in one request.
    """

    synced_at: Optional[datetime] = None
    event_count: int = 0
    window_start: Optional[datetime] = None
    window_end: Optional[datetime] = None
    timezone: Optional[str] = None
    consent_granted: bool = False


class CalendarConsentRequest(BaseModel):
    granted: bool = Field(description='True on agreeing to sync; False withdraws and erases stored events')


class CalendarConsentResponse(BaseModel):
    """Result of recording a consent decision.

    `deleted_events` is non-zero only on withdrawal — withdrawing consent and
    erasing the data are one operation, so the client can never end up with
    consent revoked but events still stored (or the reverse).
    """

    granted: bool
    updated_at: datetime
    deleted_events: int = 0
