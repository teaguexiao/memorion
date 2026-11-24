"""Pure transitions shared by the Firestore adapter and fault-injection tests."""
import hashlib
import json
import uuid

LEASE_SECONDS = 90
MAX_ATTEMPTS = 4
RETRY_DELAYS = (30, 120, 600)
TERMINAL = {'completed', 'failed', 'cancelled'}


class LeaseLost(Exception):
    pass


class JobConflict(Exception):
    pass


class JobFailure(Exception):
    def __init__(self, code, *, retryable=True, retry_after=0):
        super().__init__(code)
        self.code, self.retryable, self.retry_after = code, retryable, retry_after


def identity(developer_id, uid, started_at, recording_key=None):
    seed = json.dumps([developer_id, uid, 'audio_upload', recording_key or started_at], separators=(',', ':'))
    return str(uuid.UUID(hashlib.sha256(seed.encode()).hexdigest()[:32]))


def require_lease(job, token, now):
    if not job or job['status'] != 'processing' or job.get('lease_token') != token or job['lease_until'] <= now:
        raise LeaseLost()


def event(job, now, name):
    job['updated_at'] = now
    job['history'] = (job.get('history', []) + [{'at': now, 'event': name, 'stage': job['stage']}])[-20:]


def claim(job, now, token):
    if not job or job['status'] in TERMINAL or job['status'] == 'uploading':
        return False
    if job['status'] == 'processing' and job['lease_until'] > now:
        return False
    if job.get('next_attempt_at', 0) > now:
        return False
    # A killed process never reaches its exception handler. Count abandoned leases too.
    if job.get('stage_attempts', 0) >= MAX_ATTEMPTS:
        job.update(status='failed', error_code='worker_interrupted', retryable=True, dispatch_at=None)
        event(job, now, 'attempts_exhausted')
        return False
    job.update(status='processing', lease_token=token, lease_until=now + LEASE_SECONDS,
               stage_attempts=job.get('stage_attempts', 0) + 1,
               attempts=job.get('attempts', 0) + 1, dispatch_at=now + LEASE_SECONDS,
               heartbeat_at=now, error_code=None)
    event(job, now, 'claimed')
    return True


def renew(job, token, now):
    require_lease(job, token, now)
    job.update(lease_until=now + LEASE_SECONDS, heartbeat_at=now, dispatch_at=now + LEASE_SECONDS)


def advance(job, token, now, stage, checkpoint):
    require_lease(job, token, now)
    job['checkpoints'].update(checkpoint)
    job.update(stage=stage, stage_attempts=0)
    event(job, now, 'checkpoint')


def fail(job, token, now, error, jitter=0):
    require_lease(job, token, now)
    retry = error.retryable and job['stage_attempts'] < MAX_ATTEMPTS
    delay = max(RETRY_DELAYS[min(max(job['stage_attempts'] - 1, 0), 2)] + jitter, error.retry_after)
    job.update(status='retry_wait' if retry else 'failed', error_code=error.code,
               retryable=error.retryable, next_attempt_at=now + delay if retry else None,
               dispatch_at=now + delay if retry else None, lease_token=None, lease_until=0)
    event(job, now, 'retry_scheduled' if retry else 'failed')


def retry(job, now):
    if job['status'] not in {'failed', 'retry_wait'} or not job.get('retryable'):
        raise JobConflict('not_retryable')
    if now - (job.get('manual_retry_at') or 0) < 60:
        raise JobConflict('retry_too_soon')
    job.update(status='queued', stage_attempts=0, next_attempt_at=now, dispatch_at=now,
               manual_retry_at=now, error_code=None, lease_token=None, lease_until=0)
    event(job, now, 'manual_retry')


def public(job):
    keys = ('id', 'conversation_id', 'status', 'stage', 'started_at', 'duration_seconds',
            'created_at', 'updated_at', 'attempts', 'stage_attempts', 'error_code',
            'next_attempt_at', 'source', 'core_completed', 'parent_id', 'discarded')
    result = {key: job.get(key) for key in keys}
    result['can_retry'] = job['status'] in {'failed', 'retry_wait'} and bool(job.get('retryable'))
    return result
