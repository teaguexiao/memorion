"""Fetch conversations by their recording time, independent of upload time.

Chapters and date-based retrieval belong to started_at. Offline audio may arrive
weeks later; the former +/-36 hour created_at window silently lost late uploads.
Query started_at directly and let chaptering decide exact local-day membership.
"""

import logging
from datetime import date as date_cls, datetime, time, timedelta, timezone
from typing import List, Optional

from utils.timeline.chaptering import _as_utc, filter_convos_for_local_day

logger = logging.getLogger(__name__)

# Bound reads for both a local day and potentially large retrieval windows.
MAX_FETCH = 500
RECORDING_QUERY_VERSION = 'started-at-1'

_DEFAULT_TZ = timezone.utc


class DayQueryLimitExceeded(RuntimeError):
    """The candidate query may be incomplete; do not replace a stored day."""


def _resolve_tz(tz_name: Optional[str]):
    """User's IANA timezone, falling back to UTC. Prefers stdlib zoneinfo.

    The rest of the backend uses `pytz`, but zoneinfo is in the stdlib and needs
    no install; either works here because the only operation is
    `astimezone().date()`. pytz is tried second so this keeps working on hosts
    where zoneinfo's tz database is absent.
    """
    if not tz_name:
        return _DEFAULT_TZ
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(tz_name)
    except Exception:
        pass
    try:
        import pytz

        return pytz.timezone(tz_name)
    except Exception:
        logger.warning('[timeline] unknown timezone %r, falling back to UTC', tz_name)
        return _DEFAULT_TZ


def parse_day(date_str: str) -> date_cls:
    """Parse a YYYY-MM-DD path parameter into a date, raising ValueError on junk."""
    return datetime.strptime(date_str, '%Y-%m-%d').date()


def _local_day_utc_bounds(day: date_cls, tz):
    """The [start, end) UTC instants of `day` in timezone `tz`."""
    start_local = datetime.combine(day, time.min)
    end_local = datetime.combine(day + timedelta(days=1), time.min)
    if hasattr(tz, 'localize'):  # pytz
        start_local = tz.localize(start_local)
        end_local = tz.localize(end_local)
    else:  # zoneinfo / datetime.timezone
        start_local = start_local.replace(tzinfo=tz)
        end_local = end_local.replace(tzinfo=tz)
    return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)


def get_day_conversations(dev_db, developer_id: str, external_user_id: str, day: date_cls, tz=None,
                          require_complete: bool = False) -> List[dict]:
    """Conversations whose `started_at` falls on `day` in the user's timezone.

    `tz` may be passed in (the caller usually already resolved it for the
    chaptering call); otherwise it is looked up. Discarded conversations are kept
    here and dropped downstream by `chaptering`, so a caller inspecting raw
    coverage still sees them.
    """
    if tz is None:
        tz = _resolve_tz(dev_db.get_user_timezone(developer_id, external_user_id))

    day_start_utc, day_end_utc = _local_day_utc_bounds(day, tz)

    candidates = dev_db.get_conversations_by_recording_time(
        developer_id,
        external_user_id,
        limit=MAX_FETCH,
        start_date=day_start_utc,
        end_date=day_end_utc,
        include_transcript_segments=True,
    )
    if len(candidates) >= MAX_FETCH:
        if require_complete:
            raise DayQueryLimitExceeded('Recording query reached its limit; existing summaries were preserved')
        # Silent truncation here would read as "quiet day"; say so instead.
        logger.warning(
            '[timeline] hit MAX_FETCH=%d for %s/%s on %s; day may be under-reported',
            MAX_FETCH, developer_id, external_user_id, day,
        )

    # Day membership is decided by `chaptering`, not reimplemented here: two
    # copies of "which day does this belong to" would drift apart, and the pure
    # module is the one with tests pinning the cross-midnight and timezone cases.
    return filter_convos_for_local_day(candidates, tz, day)


def get_conversations_in_range(
    dev_db,
    developer_id: str,
    external_user_id: str,
    start: Optional[datetime] = None,
    end: Optional[datetime] = None,
    limit: int = 20,
    include_segments: bool = False,
) -> List[dict]:
    """Conversations whose `started_at` falls in [start, end], newest first.

    Uses the same started_at query as the timeline, so delayed device uploads
    remain searchable by recording date. Discarded items are filtered below,
    before result limiting; the database needs only a started_at index.

    Segments default to False: compressed transcripts and chunk subcollections
    are unnecessary unless retrieval filters by speaker.

    At least one bound is required. An unbounded call would degrade into "fetch
    this user's whole history", which is never what the caller wants — callers
    without a date should be doing semantic search instead.
    """
    start_utc, end_utc = _as_utc(start), _as_utc(end)
    if start_utc is None and end_utc is None:
        return []

    candidates = dev_db.get_conversations_by_recording_time(
        developer_id,
        external_user_id,
        limit=MAX_FETCH,
        start_date=start_utc,
        end_date=end_utc,
        include_transcript_segments=include_segments,
    )
    if len(candidates) >= MAX_FETCH:
        # Silent truncation would read as "that's all there was"; say so instead.
        logger.warning(
            '[memory_search] hit MAX_FETCH=%d for %s/%s in [%s, %s]; range may be under-reported',
            MAX_FETCH, developer_id, external_user_id, start_utc, end_utc,
        )

    kept = []
    for convo in candidates or ():
        if convo.get('discarded', False):
            continue
        started_at = _as_utc(convo.get('started_at'))
        if started_at is None:
            continue
        if start_utc and started_at < start_utc:
            continue
        if end_utc and started_at > end_utc:
            continue
        kept.append(convo)

    kept.sort(key=lambda c: (_as_utc(c.get('started_at')), c.get('id') or ''), reverse=True)
    return kept[:limit] if limit else kept
