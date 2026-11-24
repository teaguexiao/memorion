import math
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import AwareDatetime, BaseModel, Field

from utils.other import endpoints as auth
from utils.audio_jobs.store import JobStore, owner_key
from utils.audio_jobs.state import public, JobConflict
from utils.subscription import (
    MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR,
    release_transcription_credits_developer,
    reserve_transcription_credits_developer_result,
)

router = APIRouter()


class RecordingLookup(BaseModel):
    recording_key: str = Field(min_length=1, max_length=160)
    started_at: AwareDatetime


class RecordingLookupRequest(BaseModel):
    recordings: list[RecordingLookup] = Field(min_length=1, max_length=20)


@router.post('/v1/audio-jobs/lookup', tags=['audio-jobs'])
def lookup_recordings(request: RecordingLookupRequest, user: tuple = Depends(auth.get_current_user_context)):
    """Read-only, account-scoped receipt recovery before a device transfer."""
    if len({item.recording_key for item in request.recordings}) != len(request.recordings):
        raise HTTPException(422, 'Recording keys must be unique')
    store = JobStore()
    with ThreadPoolExecutor(max_workers=min(8, len(request.recordings))) as pool:
        items = list(pool.map(lambda item: store.lookup_recording(*user, item.recording_key, item.started_at),
                              request.recordings))
    return {'items': items}


def with_followups(store, job, children=None):
    result = public(job)
    result['followups'] = [public(child) for child in (store.followups(job['id']) if children is None else children)
                           if child['owner_key'] == job['owner_key']]
    return result


@router.get('/v1/audio-jobs', tags=['audio-jobs'])
def list_audio_jobs(limit: int = Query(50, ge=1, le=100), before: str | None = None,
                    user: tuple = Depends(auth.get_current_user_context)):
    store = JobStore()
    try:
        jobs = store.list_for_owner(*user, limit=limit, before=before)
    except KeyError:
        raise HTTPException(404, 'Cursor not found')
    children = store.followups_for_jobs([job['id'] for job in jobs])
    return {'items': [with_followups(store, job, children[job['id']]) for job in jobs], 'next_cursor': jobs[-1]['id'] if len(jobs) == limit else None}


@router.get('/v1/audio-jobs/active', tags=['audio-jobs'])
def active_audio_jobs(user: tuple = Depends(auth.get_current_user_context)):
    # Root publication makes the conversation ready. Ancillary follow-ups must
    # not keep the conversation's processing indicator alive after publication.
    return {'items': [public(job) for job in JobStore().active_for_owner(*user)]}


@router.get('/v1/audio-jobs/{job_id}', tags=['audio-jobs'])
def get_audio_job(job_id: str, user: tuple = Depends(auth.get_current_user_context)):
    job = JobStore().get(job_id)
    if not job or job['owner_key'] != owner_key(*user):
        raise HTTPException(404, 'Task not found')
    return with_followups(JobStore(), job)


@router.post('/v1/audio-jobs/{job_id}/retry', tags=['audio-jobs'])
def retry_audio_job(job_id: str, user: tuple = Depends(auth.get_current_user_context)):
    store = JobStore()
    developer_id, uid = user
    job = store.get(job_id)
    if not job or job.get('owner_key') != owner_key(developer_id, uid):
        raise HTTPException(404, 'Task not found')
    try:
        if job.get('status') not in {'failed', 'retry_wait'} or not job.get('retryable'):
            raise JobConflict('not_retryable')
        if store.clock() - (job.get('manual_retry_at') or 0) < 60:
            raise JobConflict('retry_too_soon')
        event_id = f"audio-upload:{job['id']}"
        reservation = None
        reservation_owner = None
        # Once STT completed, retries only redo downstream stages and must keep
        # the original transcription charge rather than reclaiming/refunding it.
        if job.get('is_root') and job.get('stage') in {'validate', 'transcribe'}:
            duration_seconds = job.get('duration_seconds') or (job.get('audio') or {}).get('duration_seconds')
            if not duration_seconds:
                raise JobConflict('duration_unavailable_reupload_required')
            reservation_owner = uuid.uuid4().hex
            reservation = reserve_transcription_credits_developer_result(
                developer_id,
                uid,
                event_id,
                math.ceil(float(duration_seconds)),
                reservation_owner=reservation_owner,
                # Fence a reconciler refund until this request either queues
                # the job or dies. The guard expires so a crashed request
                # cannot permanently retain a failed reservation.
                refund_guard_until=datetime.now(timezone.utc) + timedelta(minutes=2),
            )
            if not reservation.allowed:
                raise HTTPException(
                    429,
                    {
                        'code': reservation.error_code or MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR,
                        'message': 'Monthly cloud transcription allowance exceeded. Upgrade to Pro to continue.',
                    },
                )
        try:
            retried = store.retry(job_id, developer_id, uid)
        except KeyError:
            if reservation is not None and reservation.newly_reserved:
                release_transcription_credits_developer(
                    developer_id, uid, event_id, reservation_owner=reservation_owner
                )
            raise HTTPException(404, 'Task not found')
        except Exception:
            current = store.get(job_id)
            # ``retry_wait`` is itself a durable, automatically dispatched
            # attempt. Its reservation must remain attached to the job even if
            # this manual transition races another caller; otherwise the next
            # worker run receives unmetered transcription. Terminal failures
            # can be refunded here, and terminal workers also have the
            # failed_job_id fence for eventual cleanup.
            if reservation is not None and reservation.newly_reserved and (
                not current or current.get('status') == 'failed'
            ):
                release_transcription_credits_developer(
                    developer_id, uid, event_id, reservation_owner=reservation_owner
                )
            raise
        return public(retried)
    except JobConflict as error:
        raise HTTPException(409, str(error))
