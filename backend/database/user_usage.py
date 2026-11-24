import hashlib
import threading
from datetime import datetime, timedelta, timezone
from typing import Optional
from google.api_core.exceptions import AlreadyExists, GoogleAPICallError, RetryError
from google.cloud import firestore
from google.cloud.firestore_v1 import FieldFilter

from ._client import db
from models.user_usage import (
    UsageStats,
    subscription_counter_covers_month,
    subscription_enforcement_start_at_utc,
)
from utils.audio_jobs.store import AUDIO_JOBS_COLLECTION


# Longer than the durable worker's 30-minute hard lifetime and the synchronous
# upload endpoint's bounded STT/LLM work. Before this lease expires, a retry
# must treat the original owner as live and cannot acquire refund authority.
TRANSCRIPTION_RESERVATION_STALE_AFTER = timedelta(hours=2)
USAGE_COUNTER_STATE_COLLECTION = 'system_state'
USAGE_COUNTER_STATE_DOCUMENT = 'subscription_usage_counter'
_usage_counter_started_at_cache = {}
_usage_counter_started_at_lock = threading.Lock()


def _usage_counter_state_ref():
    return db.collection(USAGE_COUNTER_STATE_COLLECTION).document(USAGE_COUNTER_STATE_DOCUMENT)


def ensure_subscription_usage_counter_started_at() -> Optional[datetime]:
    """Return the immutable server-side boundary for complete monthly counters.

    The first process running the monthly-counter code creates this marker. A
    later deployment can read it but cannot reset it, unlike an ECS task
    environment variable. A missing or malformed marker fails closed: the
    current month remains unenforced rather than trusting partial usage.
    """
    # The marker never changes. Cache per client object so every realtime
    # 30-second usage flush does not perform a known-failing create plus read.
    # Tests replace ``db`` with isolated emulator clients, hence the identity
    # key rather than one process-global scalar.
    project = getattr(db, 'project', None)
    database_string = getattr(db, '_database_string', None)
    # Real clients for the same Firestore database intentionally share the
    # immutable value. Lightweight test clients without these fields are held
    # directly, avoiding CPython ``id`` reuse after garbage collection.
    cache_key = (project, database_string) if project or database_string else db
    with _usage_counter_started_at_lock:
        if cache_key in _usage_counter_started_at_cache:
            return _usage_counter_started_at_cache[cache_key]
        marker_ref = _usage_counter_state_ref()
        started_at = datetime.now(timezone.utc)
        try:
            try:
                marker_ref.create({'started_at': started_at})
                value = started_at
            except AlreadyExists:
                snapshot = marker_ref.get()
                stored = (snapshot.to_dict() or {}).get('started_at') if snapshot.exists else None
                value = stored if isinstance(stored, datetime) else None
        except (GoogleAPICallError, RetryError):
            # Usage accounting must not abort realtime-session teardown or
            # audio persistence. Do not cache a transient outage; returning
            # None leaves the current month explicitly non-authoritative.
            return None
        _usage_counter_started_at_cache[cache_key] = value
        return value


def _get_user_ref(uid: str, developer_id: str = None):
    """Get user document reference, routing to developer_data path when developer_id is provided."""
    if developer_id:
        return db.collection('developer_data').document(developer_id).collection('users').document(uid)
    return db.collection('users').document(uid)


def update_hourly_usage(uid: str, date: datetime, updates: dict, developer_id: str = None):
    """Updates or creates usage stats for a specific hour using Firestore atomic increments."""
    user_ref = _get_user_ref(uid, developer_id)
    doc_id = f'{date.year}-{date.month:02d}-{date.day:02d}-{date.hour:02d}'
    hourly_usage_ref = user_ref.collection('hourly_usage').document(doc_id)
    month_id = f'{date.year}-{date.month:02d}'
    monthly_usage_ref = user_ref.collection('monthly_usage').document(month_id)

    update_doc = {'last_updated': datetime.utcnow()}
    has_increments = False

    for key, value in updates.items():
        if key in ['transcription_seconds', 'words_transcribed', 'insights_gained', 'memories_created'] and value > 0:
            update_doc[key] = firestore.Increment(value)
            has_increments = True

    if not has_increments:
        return

    # Add year, month, day, hour fields for querying
    update_doc['year'] = date.year
    update_doc['month'] = date.month
    update_doc['day'] = date.day
    update_doc['hour'] = date.hour
    update_doc['id'] = doc_id

    monthly_doc = {
        key: value for key, value in update_doc.items()
        if key in {'transcription_seconds', 'words_transcribed', 'insights_gained', 'memories_created'}
    }
    monthly_doc.update({'year': date.year, 'month': date.month, 'last_updated': update_doc['last_updated']})
    date_utc = date.replace(tzinfo=timezone.utc) if date.tzinfo is None else date.astimezone(timezone.utc)
    counter_started_at = ensure_subscription_usage_counter_started_at()
    if subscription_counter_covers_month(date_utc, counter_started_at):
        monthly_doc['counter_complete'] = True
    batch = db.batch()
    batch.set(hourly_usage_ref, update_doc, merge=True)
    batch.set(monthly_usage_ref, monthly_doc, merge=True)
    batch.commit()


def record_transcription_usage_once(
    uid: str,
    event_id: str,
    transcription_seconds: int,
    *,
    developer_id: str,
    occurred_at: Optional[datetime] = None,
    reservation_owner: Optional[str] = None,
    refund_guard_until: Optional[datetime] = None,
) -> bool:
    """Atomically record one batch transcription charge exactly once.

    Upload and worker retries reuse the same conversation/task id. A hashed
    event document makes the usage increment idempotent without exposing that
    identifier in aggregate usage documents.
    """
    return _record_transcription_usage_once(
        uid,
        event_id,
        transcription_seconds,
        developer_id=developer_id,
        occurred_at=occurred_at,
        reservation_owner=reservation_owner,
        refund_guard_until=refund_guard_until,
    ) == 'recorded'


def reserve_transcription_usage_once(
    uid: str,
    event_id: str,
    transcription_seconds: int,
    *,
    limit_seconds: int,
    developer_id: str,
    occurred_at: Optional[datetime] = None,
    reservation_owner: Optional[str] = None,
    refund_guard_until: Optional[datetime] = None,
) -> bool:
    """Atomically reserve batch usage unless it would exceed the month limit.

    A duplicate event is already reserved and therefore succeeds. Every new
    reservation reads the month and writes the shared current-hour document in
    one transaction, so concurrent uploads serialize instead of all observing
    the same stale total.
    """
    return reserve_transcription_usage_once_result(
        uid,
        event_id,
        transcription_seconds,
        limit_seconds=limit_seconds,
        developer_id=developer_id,
        occurred_at=occurred_at,
        reservation_owner=reservation_owner,
        refund_guard_until=refund_guard_until,
    ) != 'limit_exceeded'


def reserve_transcription_usage_once_result(
    uid: str,
    event_id: str,
    transcription_seconds: int,
    *,
    limit_seconds: int,
    developer_id: str,
    occurred_at: Optional[datetime] = None,
    reservation_owner: Optional[str] = None,
    refund_guard_until: Optional[datetime] = None,
) -> str:
    """Return recorded, recorded_unenforced, duplicate, or limit_exceeded."""
    return _record_transcription_usage_once(
        uid,
        event_id,
        transcription_seconds,
        developer_id=developer_id,
        occurred_at=occurred_at,
        limit_seconds=int(limit_seconds),
        reservation_owner=reservation_owner,
        refund_guard_until=refund_guard_until,
    )


def _record_transcription_usage_once(
    uid: str,
    event_id: str,
    transcription_seconds: int,
    *,
    developer_id: str,
    occurred_at: Optional[datetime] = None,
    limit_seconds: Optional[int] = None,
    reservation_owner: Optional[str] = None,
    refund_guard_until: Optional[datetime] = None,
) -> str:
    seconds = int(transcription_seconds)
    if seconds <= 0:
        return 'duplicate'
    occurred_at = occurred_at or datetime.now(timezone.utc)
    if occurred_at.tzinfo is None:
        occurred_at = occurred_at.replace(tzinfo=timezone.utc)
    if refund_guard_until is not None and refund_guard_until.tzinfo is None:
        refund_guard_until = refund_guard_until.replace(tzinfo=timezone.utc)
    user_ref = _get_user_ref(uid, developer_id)
    event_key = hashlib.sha256(event_id.encode('utf-8')).hexdigest()
    event_ref = user_ref.collection('usage_events').document(event_key)
    hour_id = f'{occurred_at.year}-{occurred_at.month:02d}-{occurred_at.day:02d}-{occurred_at.hour:02d}'
    hour_ref = user_ref.collection('hourly_usage').document(hour_id)
    month_id = f'{occurred_at.year}-{occurred_at.month:02d}'
    month_ref = user_ref.collection('monthly_usage').document(month_id)
    # This immutable marker is cached per Firestore database. Reading it before
    # the transaction avoids making one global document a lock dependency for
    # every tenant's upload reservation.
    marker_started_at = ensure_subscription_usage_counter_started_at()
    transaction = db.transaction()

    @firestore.transactional
    def _record(transaction):
        event_snapshot = event_ref.get(transaction=transaction)
        if event_snapshot.exists:
            event = event_snapshot.to_dict() or {}
            recorded_at = event.get('recorded_at')
            if recorded_at and recorded_at.tzinfo is None:
                recorded_at = recorded_at.replace(tzinfo=timezone.utc)
            if not recorded_at or occurred_at - recorded_at < TRANSCRIPTION_RESERVATION_STALE_AFTER:
                if refund_guard_until is not None:
                    transaction.update(event_ref, {'refund_guard_until': refund_guard_until})
                return 'duplicate'
            # A stale owner may be gone, but the event's charge is still valid:
            # the associated job can remain in retry_wait or processing for
            # longer than this lease. Transfer refund ownership without moving
            # or deleting the original exactly-once counter entry.
            if reservation_owner is None:
                return 'duplicate'
            transaction.update(event_ref, {
                'reclaimed_at': occurred_at,
                'reservation_owner': reservation_owner,
                **({'refund_guard_until': refund_guard_until} if refund_guard_until is not None else {}),
            })
            return 'recorded'
        counter_covers_month = subscription_counter_covers_month(occurred_at, marker_started_at)
        month_snapshot = month_ref.get(transaction=transaction)
        month_data = (month_snapshot.to_dict() or {}) if month_snapshot.exists else {}
        counter_complete = bool(month_data.get('counter_complete')) or counter_covers_month
        used = int(month_data.get('transcription_seconds', 0))
        if limit_seconds is not None and counter_complete:
            # Enforcement must never rely on a known-partial month. The staged
            # production start matches the authoritative boundary above.
            if used + seconds > limit_seconds:
                return 'limit_exceeded'
        transaction.set(
            hour_ref,
            {
                'transcription_seconds': firestore.Increment(seconds),
                'last_updated': occurred_at,
                'year': occurred_at.year,
                'month': occurred_at.month,
                'day': occurred_at.day,
                'hour': occurred_at.hour,
                'id': hour_id,
            },
            merge=True,
        )
        month_update = {
            'transcription_seconds': firestore.Increment(seconds),
            'last_updated': occurred_at,
            'year': occurred_at.year,
            'month': occurred_at.month,
            'id': month_id,
        }
        if counter_covers_month:
            month_update['counter_complete'] = True
        transaction.set(month_ref, month_update, merge=True)
        transaction.set(
            event_ref,
            {
                'kind': 'batch_transcription',
                'transcription_seconds': seconds,
                'recorded_at': occurred_at,
                'hour_id': hour_id,
                'month_id': month_id,
                'reservation_owner': reservation_owner,
                **({'refund_guard_until': refund_guard_until} if refund_guard_until is not None else {}),
            },
        )
        return 'recorded' if counter_complete or limit_seconds is None else 'recorded_unenforced'

    return _record(transaction)


def release_transcription_usage_once(
    uid: str,
    event_id: str,
    *,
    developer_id: str,
    failed_job_id: Optional[str] = None,
    reservation_owner: Optional[str] = None,
    upload_job_id: Optional[str] = None,
    upload_token: Optional[str] = None,
    job_collection: str = AUDIO_JOBS_COLLECTION,
) -> bool:
    """Refund one reserved batch charge, idempotently."""
    if reservation_owner is None and failed_job_id is None:
        return False
    if (upload_job_id is None) != (upload_token is None):
        return False
    user_ref = _get_user_ref(uid, developer_id)
    event_key = hashlib.sha256(event_id.encode('utf-8')).hexdigest()
    event_ref = user_ref.collection('usage_events').document(event_key)
    transaction = db.transaction()

    @firestore.transactional
    def _release(transaction):
        snapshot = event_ref.get(transaction=transaction)
        if not snapshot.exists:
            return False
        event = snapshot.to_dict() or {}
        if reservation_owner is not None and event.get('reservation_owner') != reservation_owner:
            return False
        if upload_job_id is not None:
            upload_snapshot = db.collection(job_collection).document(upload_job_id).get(transaction=transaction)
            if not upload_snapshot.exists:
                return False
            upload_job = upload_snapshot.to_dict() or {}
            if (
                upload_job.get('status') != 'uploading'
                or upload_job.get('upload_token') != upload_token
                or upload_job.get('audio')
                or upload_job.get('usage_committed')
                or upload_job.get('developer_id') != developer_id
                or upload_job.get('uid') != uid
            ):
                return False
        if failed_job_id is not None:
            refund_guard_until = event.get('refund_guard_until')
            if isinstance(refund_guard_until, datetime):
                if refund_guard_until.tzinfo is None:
                    refund_guard_until = refund_guard_until.replace(tzinfo=timezone.utc)
                if refund_guard_until > datetime.now(timezone.utc):
                    return False
            job_snapshot = db.collection(job_collection).document(failed_job_id).get(transaction=transaction)
            if not job_snapshot.exists:
                return False
            job = job_snapshot.to_dict() or {}
            if (
                job.get('status') != 'failed'
                or job.get('stage') not in {'validate', 'transcribe'}
                or job.get('developer_id') != developer_id
                or job.get('uid') != uid
            ):
                return False
            recorded_at = event.get('recorded_at')
            job_updated_at = job.get('updated_at')
            if recorded_at and isinstance(job_updated_at, (int, float)):
                if recorded_at.tzinfo is None:
                    recorded_at = recorded_at.replace(tzinfo=timezone.utc)
                if recorded_at > datetime.fromtimestamp(job_updated_at, timezone.utc):
                    # A manual retry created this reservation after the failure
                    # snapshot; an old dispatch must not refund the new attempt.
                    return False
        seconds = int(event.get('transcription_seconds', 0))
        hour_id = event.get('hour_id')
        month_id = event.get('month_id')
        hour_ref = user_ref.collection('hourly_usage').document(hour_id) if hour_id else None
        month_ref = user_ref.collection('monthly_usage').document(month_id) if month_id else None
        hour_snapshot = hour_ref.get(transaction=transaction) if hour_ref else None
        month_snapshot = month_ref.get(transaction=transaction) if month_ref else None
        if seconds > 0 and hour_id:
            if hour_snapshot.exists:
                transaction.update(
                    hour_ref,
                    {
                        'transcription_seconds': firestore.Increment(-seconds),
                        'last_updated': datetime.now(timezone.utc),
                    },
                )
        # The monthly counter includes the event even if its hourly document
        # was externally deleted. Refund it independently; otherwise the
        # authoritative counter would retain usage that the hourly fallback no
        # longer contains.
        if seconds > 0 and month_ref and month_snapshot.exists:
            transaction.update(
                month_ref,
                {
                    'transcription_seconds': firestore.Increment(-seconds),
                    'last_updated': datetime.now(timezone.utc),
                },
            )
        transaction.delete(event_ref)
        return True

    return _release(transaction)


def batch_update_hourly_usage(uid: str, hourly_updates: dict):
    """Backfill historical hourly stats without bypassing authoritative months."""
    batch_size = 400
    items = list(hourly_updates.items())
    counter_start = subscription_enforcement_start_at_utc()
    if counter_start is None:
        raise ValueError('A valid subscription enforcement start is required for usage backfills')
    historical_items = []
    for date, updates in items:
        date_utc = date.replace(tzinfo=timezone.utc) if date.tzinfo is None else date.astimezone(timezone.utc)
        if date_utc < counter_start:
            historical_items.append((date, updates))
    items = historical_items

    for i in range(0, len(items), batch_size):
        batch = db.batch()
        chunk = items[i : i + batch_size]
        for date, updates in chunk:
            doc_id = f'{date.year}-{date.month:02d}-{date.day:02d}-{date.hour:02d}'
            hourly_usage_ref = db.collection('users').document(uid).collection('hourly_usage').document(doc_id)

            update_doc = updates.copy()
            # Add year, month, day, hour fields for querying
            update_doc['year'] = date.year
            update_doc['month'] = date.month
            update_doc['day'] = date.day
            update_doc['hour'] = date.hour
            update_doc['id'] = doc_id
            update_doc['last_updated'] = datetime.utcnow()

            batch.set(hourly_usage_ref, update_doc, merge=True)
        batch.commit()


def get_today_usage_stats(uid: str, date: datetime, developer_id: str = None) -> dict:
    """Aggregates hourly usage stats for a given day from Firestore."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')

    query = (
        hourly_usage_collection.where(filter=FieldFilter('year', '==', date.year))
        .where(filter=FieldFilter('month', '==', date.month))
        .where(filter=FieldFilter('day', '==', date.day))
    )
    return _aggregate_stats(query)


def _aggregate_stats(query) -> dict:
    docs = query.stream()
    stats = {
        'transcription_seconds': 0,
        'words_transcribed': 0,
        'insights_gained': 0,
        'memories_created': 0,
    }
    for doc in docs:
        data = doc.to_dict()
        stats['transcription_seconds'] += data.get('transcription_seconds', 0)
        stats['words_transcribed'] += data.get('words_transcribed', 0)
        stats['insights_gained'] += data.get('insights_gained', 0)
        stats['memories_created'] += data.get('memories_created', 0)
    return stats


def get_monthly_usage_stats(uid: str, date: datetime, developer_id: str = None) -> dict:
    """Aggregates hourly usage stats for a given month from Firestore."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')

    query = hourly_usage_collection.where(filter=FieldFilter('year', '==', date.year)).where(
        filter=FieldFilter('month', '==', date.month)
    )
    return _aggregate_stats(query)


def get_monthly_transcription_seconds(uid: str, date: datetime, developer_id: str = None) -> int:
    """Read the low-contention monthly counter, falling back for pre-counter data."""
    user_ref = _get_user_ref(uid, developer_id)
    month_id = f'{date.year}-{date.month:02d}'
    snapshot = user_ref.collection('monthly_usage').document(month_id).get()
    if snapshot.exists and (snapshot.to_dict() or {}).get('counter_complete'):
        return int((snapshot.to_dict() or {}).get('transcription_seconds', 0))
    return int(get_monthly_usage_stats(uid, date, developer_id).get('transcription_seconds', 0))


def get_monthly_transcription_quota_state(
    uid: str,
    date: datetime,
    developer_id: str = None,
) -> tuple[bool, int]:
    """Read quota authority and usage from one low-contention document."""
    user_ref = _get_user_ref(uid, developer_id)
    month_id = f'{date.year}-{date.month:02d}'
    snapshot = user_ref.collection('monthly_usage').document(month_id).get()
    data = (snapshot.to_dict() or {}) if snapshot.exists else {}
    if data.get('counter_complete'):
        return True, int(data.get('transcription_seconds', 0))
    counter_started_at = ensure_subscription_usage_counter_started_at()
    authoritative = subscription_counter_covers_month(date, counter_started_at)
    return authoritative, int(data.get('transcription_seconds', 0)) if authoritative else 0


def get_yearly_usage_stats(uid: str, date: datetime, developer_id: str = None) -> dict:
    """Aggregates hourly usage stats for a given year from Firestore."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')
    query = hourly_usage_collection.where(filter=FieldFilter('year', '==', date.year))
    return _aggregate_stats(query)


def get_all_time_usage_stats(uid: str, developer_id: str = None) -> dict:
    """Aggregates all hourly usage stats for a user from Firestore."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')
    return _aggregate_stats(hourly_usage_collection)


def get_hourly_history_for_today(uid: str, date: datetime, developer_id: str = None) -> list[dict]:
    """Gets hourly usage for a specific day by aggregating hourly data."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')
    query = (
        hourly_usage_collection.where(filter=FieldFilter('year', '==', date.year))
        .where(filter=FieldFilter('month', '==', date.month))
        .where(filter=FieldFilter('day', '==', date.day))
    )
    docs = query.stream()
    hourly_totals = {}
    for doc in docs:
        data = doc.to_dict()
        hour = data.get('hour', 0)
        if hour not in hourly_totals:
            hourly_totals[hour] = {
                'transcription_seconds': 0,
                'words_transcribed': 0,
                'insights_gained': 0,
                'memories_created': 0,
            }

        hourly_totals[hour]['transcription_seconds'] += data.get('transcription_seconds', 0)
        hourly_totals[hour]['words_transcribed'] += data.get('words_transcribed', 0)
        hourly_totals[hour]['insights_gained'] += data.get('insights_gained', 0)
        hourly_totals[hour]['memories_created'] += data.get('memories_created', 0)

    history = [
        {'date': f"{date.year}-{date.month:02d}-{date.day:02d}T{hour:02d}:00:00Z", **stats}
        for hour, stats in hourly_totals.items()
    ]
    history.sort(key=lambda x: x['date'])
    return history


def get_daily_history_for_month(uid: str, date: datetime, developer_id: str = None) -> list[dict]:
    """Gets daily usage for a specific month by aggregating hourly data."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')
    query = hourly_usage_collection.where(filter=FieldFilter('year', '==', date.year)).where(
        filter=FieldFilter('month', '==', date.month)
    )
    docs = query.stream()
    daily_totals = {}
    for doc in docs:
        data = doc.to_dict()
        day = data.get('day', 0)
        if day not in daily_totals:
            daily_totals[day] = {
                'transcription_seconds': 0,
                'words_transcribed': 0,
                'insights_gained': 0,
                'memories_created': 0,
            }

        daily_totals[day]['transcription_seconds'] += data.get('transcription_seconds', 0)
        daily_totals[day]['words_transcribed'] += data.get('words_transcribed', 0)
        daily_totals[day]['insights_gained'] += data.get('insights_gained', 0)
        daily_totals[day]['memories_created'] += data.get('memories_created', 0)

    history = [{'date': f"{date.year}-{date.month:02d}-{day:02d}", **stats} for day, stats in daily_totals.items()]
    history.sort(key=lambda x: x['date'])
    return history


def get_monthly_history_for_year(uid: str, date: datetime, developer_id: str = None) -> list[dict]:
    """Gets monthly usage for a specific year by aggregating hourly data."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')
    query = hourly_usage_collection.where(filter=FieldFilter('year', '==', date.year))
    docs = query.stream()
    monthly_totals = {}
    for doc in docs:
        data = doc.to_dict()
        month = data.get('month', 0)
        if month not in monthly_totals:
            monthly_totals[month] = {
                'transcription_seconds': 0,
                'words_transcribed': 0,
                'insights_gained': 0,
                'memories_created': 0,
            }

        monthly_totals[month]['transcription_seconds'] += data.get('transcription_seconds', 0)
        monthly_totals[month]['words_transcribed'] += data.get('words_transcribed', 0)
        monthly_totals[month]['insights_gained'] += data.get('insights_gained', 0)
        monthly_totals[month]['memories_created'] += data.get('memories_created', 0)

    history = [{'date': f"{date.year}-{month:02d}-01", **stats} for month, stats in monthly_totals.items()]
    history.sort(key=lambda x: x['date'])
    return history


def get_yearly_history(uid: str, developer_id: str = None) -> list[dict]:
    """Gets yearly usage for all time by aggregating hourly data."""
    user_ref = _get_user_ref(uid, developer_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')
    docs = hourly_usage_collection.stream()
    yearly_totals = {}
    for doc in docs:
        data = doc.to_dict()
        year = data.get('year', 0)
        if year not in yearly_totals:
            yearly_totals[year] = {
                'transcription_seconds': 0,
                'words_transcribed': 0,
                'insights_gained': 0,
                'memories_created': 0,
            }

        yearly_totals[year]['transcription_seconds'] += data.get('transcription_seconds', 0)
        yearly_totals[year]['words_transcribed'] += data.get('words_transcribed', 0)
        yearly_totals[year]['insights_gained'] += data.get('insights_gained', 0)
        yearly_totals[year]['memories_created'] += data.get('memories_created', 0)

    history = [{'date': f"{year}-01-01", **stats} for year, stats in yearly_totals.items()]
    history.sort(key=lambda x: x['date'])
    return history


def get_current_user_usage(uid: str, period: str, developer_id: str = None) -> dict:
    """Gets usage for the current user for a specific period from Firestore."""
    now = datetime.utcnow()
    response = {}

    if period == 'today':
        response['today'] = UsageStats(**get_today_usage_stats(uid, now, developer_id)).dict()
        response['history'] = get_hourly_history_for_today(uid, now, developer_id)
    elif period == 'monthly':
        response['monthly'] = UsageStats(**get_monthly_usage_stats(uid, now, developer_id)).dict()
        response['history'] = get_daily_history_for_month(uid, now, developer_id)
    elif period == 'yearly':
        response['yearly'] = UsageStats(**get_yearly_usage_stats(uid, now, developer_id)).dict()
        response['history'] = get_monthly_history_for_year(uid, now, developer_id)
    elif period == 'all_time':
        response['all_time'] = UsageStats(**get_all_time_usage_stats(uid, developer_id)).dict()
        response['history'] = get_yearly_history(uid, developer_id)

    return response
