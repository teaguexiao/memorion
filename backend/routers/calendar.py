import logging
from datetime import datetime, timedelta, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

import database.developer_data as dev_db
from models.calendar_event import (
    CalendarConsentRequest,
    CalendarConsentResponse,
    CalendarDeleteResponse,
    CalendarEvent,
    CalendarSyncRequest,
    CalendarSyncResponse,
    CalendarSyncState,
)
from utils.other import endpoints as auth

router = APIRouter()
logger = logging.getLogger(__name__)

# One sync may not replace more than this much time, so a buggy or malicious
# client cannot wipe years of stored calendar in a single call. The app syncs a
# ~45-day window (see CalendarSyncService), well inside this.
MAX_WINDOW_DAYS = 400
MAX_EVENTS_PER_SYNC = 1000


def _as_utc(value: datetime) -> datetime:
    """Firestore range queries need tz-aware datetimes; naive input is read as UTC."""
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def resolve_calendar_consent(
    developer_id: str,
    uid: str,
    sync_state: Optional[dict] = None,
) -> bool:
    """Effective consent, inferring it for users who agreed before it was stored.

    An explicit record always wins. Absence is the interesting case: consent used
    to live only in the app's NSUserDefaults, so every pre-existing user has no
    `calendar_consent` doc, and reading that as "never agreed" would force all of
    them to consent one more time on the release that fixes this.

    Absence is therefore read as consent *iff events were actually synced*. That
    inference is sound rather than convenient: the client's gate in
    `CalendarSyncService.syncNow` ("no AI-sharing consent, skip") sits in front of
    every sync path and is deliberately not bypassable by `force`, so stored
    events prove the user agreed at some point. Withdrawal erases both the events
    and the sync state, so a user who turned the toggle off infers False.
    """
    consent = dev_db.get_calendar_consent(developer_id, uid)
    if consent is not None and 'granted' in consent:
        return bool(consent['granted'])

    if sync_state is None:
        sync_state = dev_db.get_calendar_sync_state(developer_id, uid)
    if not sync_state:
        return False
    return bool(sync_state.get('synced_at')) or (sync_state.get('event_count') or 0) > 0


@router.post('/v1/calendar/sync', tags=['calendar'], response_model=CalendarSyncResponse)
def sync_calendar_events(data: CalendarSyncRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    """Replace the stored calendar for one time window with what the device sees.

    Read-only on the device side: the app never writes to the user's calendar,
    it only mirrors it here so the chat agent can reason about upcoming plans.
    """
    developer_id, uid = ctx
    if not developer_id:
        # Admin-key auth has no developer scope, and every write in this module
        # is tenant-scoped under developer_data/{developer_id}.
        raise HTTPException(status_code=400, detail='developer scope required')

    # Consent gate. Only an *explicit* refusal blocks: a missing record means an
    # older app build that gated locally, and it gets backfilled below once the
    # sync succeeds. Refusing on absence would break calendar sync for every
    # client that has not shipped the consent endpoint yet.
    consent = dev_db.get_calendar_consent(developer_id, uid)
    if consent is not None and not consent.get('granted'):
        raise HTTPException(status_code=409, detail='calendar consent not granted')

    window_start = _as_utc(data.window_start)
    window_end = _as_utc(data.window_end)

    if (window_end - window_start) > timedelta(days=MAX_WINDOW_DAYS):
        raise HTTPException(status_code=400, detail=f'window must not exceed {MAX_WINDOW_DAYS} days')
    if len(data.events) > MAX_EVENTS_PER_SYNC:
        raise HTTPException(status_code=400, detail=f'at most {MAX_EVENTS_PER_SYNC} events per sync')

    # Events outside the declared window would be deleted by the next sync of
    # their real window, and they make the window semantics a lie. Drop them.
    kept: List[dict] = []
    dropped = 0
    for event in data.events:
        starts_at = _as_utc(event.starts_at)
        if not (window_start <= starts_at < window_end):
            dropped += 1
            continue
        payload = event.model_dump(exclude_none=True)
        payload['starts_at'] = starts_at
        if event.ends_at is not None:
            payload['ends_at'] = _as_utc(event.ends_at)
        if event.last_modified_at is not None:
            payload['last_modified_at'] = _as_utc(event.last_modified_at)
        kept.append(payload)

    if dropped:
        logger.warning('[calendar] uid=%s dropped %s events outside declared window', uid, dropped)

    try:
        counts = dev_db.replace_calendar_events(developer_id, uid, window_start, window_end, kept)
    except Exception:
        logger.exception('[calendar] sync failed uid=%s', uid)
        raise HTTPException(status_code=500, detail='failed to store calendar events')

    synced_at = datetime.now(timezone.utc)
    try:
        dev_db.set_calendar_sync_state(
            developer_id,
            uid,
            {
                'synced_at': synced_at,
                'event_count': counts['written'],
                'window_start': window_start,
                'window_end': window_end,
                'timezone': data.timezone,
            },
        )
    except Exception:
        # The events are already stored; a missing state doc only degrades the
        # "synced N events" line in the app.
        logger.exception('[calendar] failed to record sync state uid=%s', uid)

    if consent is None:
        # Backfill the decision this sync just proved (see the gate above), so the
        # next reinstall restores the toggle from the server instead of re-asking.
        try:
            dev_db.set_calendar_consent(developer_id, uid, True)
            logger.info('[calendar] uid=%s backfilled consent from successful sync', uid)
        except Exception:
            logger.exception('[calendar] failed to backfill consent uid=%s', uid)

    logger.info(
        '[calendar] uid=%s synced written=%s deleted=%s window=%s..%s',
        uid, counts['written'], counts['deleted'], window_start.isoformat(), window_end.isoformat(),
    )
    return CalendarSyncResponse(written=counts['written'], deleted=counts['deleted'], synced_at=synced_at)


@router.get('/v1/calendar/events', tags=['calendar'], response_model=List[CalendarEvent])
def list_calendar_events(
    start: Optional[datetime] = Query(None, description='ISO-8601 lower bound on starts_at'),
    end: Optional[datetime] = Query(None, description='ISO-8601 upper bound on starts_at'),
    limit: int = Query(100, ge=1, le=500),
    ctx: tuple = Depends(auth.get_current_user_context),
):
    """Read back what was synced — the verification path for this feature."""
    developer_id, uid = ctx
    if not developer_id:
        raise HTTPException(status_code=400, detail='developer scope required')

    events = dev_db.get_calendar_events(
        developer_id,
        uid,
        start=_as_utc(start) if start else None,
        end=_as_utc(end) if end else None,
        limit=limit,
    )
    return [CalendarEvent(**e) for e in events]


@router.delete('/v1/calendar/events', tags=['calendar'], response_model=CalendarDeleteResponse)
def delete_calendar_events(ctx: tuple = Depends(auth.get_current_user_context)):
    """Erase all synced calendar data — the withdraw-consent path.

    The app calls this when the user turns the calendar toggle off. Revoking the
    iOS permission alone would only stop future syncs and leave everything
    already uploaded in place, which is not a withdrawal of consent.
    """
    developer_id, uid = ctx
    if not developer_id:
        raise HTTPException(status_code=400, detail='developer scope required')

    try:
        deleted = dev_db.delete_all_calendar_events(developer_id, uid)
    except Exception:
        logger.exception('[calendar] delete failed uid=%s', uid)
        raise HTTPException(status_code=500, detail='failed to delete calendar events')

    # Erasing the data *is* the withdrawal, so record it. Without this the next
    # sync would be allowed through and silently re-upload everything, and
    # `resolve_calendar_consent` would keep inferring from an empty sync state.
    try:
        dev_db.set_calendar_consent(developer_id, uid, False)
    except Exception:
        logger.exception('[calendar] failed to record revocation uid=%s', uid)

    logger.info('[calendar] uid=%s deleted all calendar events count=%s', uid, deleted)
    return CalendarDeleteResponse(deleted=deleted)


@router.post('/v1/calendar/consent', tags=['calendar'], response_model=CalendarConsentResponse)
def set_calendar_consent(data: CalendarConsentRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    """Record whether the user agrees to their calendar being synced to us.

    Separate from the iOS calendar permission on purpose: that permission only
    grants *reading the device calendar*, never uploading it or handing it to AI
    providers, which App Review 5.1.2(i) requires explicit prior permission for.

    Withdrawal erases the stored events in the same call. One request rather than
    two means the client cannot leave a half state behind — consent revoked with
    events still stored reads to the user as "I turned it off and you kept my
    data", and the reverse silently keeps syncing.
    """
    developer_id, uid = ctx
    if not developer_id:
        raise HTTPException(status_code=400, detail='developer scope required')

    deleted = 0
    if not data.granted:
        try:
            deleted = dev_db.delete_all_calendar_events(developer_id, uid)
        except Exception:
            logger.exception('[calendar] consent withdrawal failed to erase uid=%s', uid)
            # Do not record the revocation: the client shows an error and retries.
            # Recording it here would tell the user their data is gone while it is
            # still stored, and the 409 gate would then block the retry's re-sync.
            raise HTTPException(status_code=500, detail='failed to delete calendar events')

    try:
        state = dev_db.set_calendar_consent(developer_id, uid, data.granted)
    except Exception:
        logger.exception('[calendar] failed to record consent uid=%s granted=%s', uid, data.granted)
        raise HTTPException(status_code=500, detail='failed to record consent')

    logger.info('[calendar] uid=%s consent granted=%s deleted=%s', uid, data.granted, deleted)
    return CalendarConsentResponse(granted=data.granted, updated_at=state['updated_at'], deleted_events=deleted)


@router.get('/v1/calendar/sync-state', tags=['calendar'], response_model=CalendarSyncState)
def get_calendar_sync_state(ctx: tuple = Depends(auth.get_current_user_context)):
    """Consent plus last successful sync — everything the toggle needs, in one call."""
    developer_id, uid = ctx
    if not developer_id:
        raise HTTPException(status_code=400, detail='developer scope required')

    state = dict(dev_db.get_calendar_sync_state(developer_id, uid) or {})
    granted = resolve_calendar_consent(developer_id, uid, sync_state=state)
    # Consent is a sibling field, never part of the sync state doc; drop any stale
    # copy so it cannot collide with the resolved value below.
    state.pop('consent_granted', None)
    return CalendarSyncState(**state, consent_granted=granted)
