"""Daily journal and insight jobs in Firestore: one record per user, day and pass.

The records double as the SQS outbox. Their format, leases and retry transitions are the
audio jobs' (`utils.audio_jobs.state`), so the recovery properties are the same: SQS can lose
or duplicate a message and the record still decides what runs. The API only writes here and
needs no SQS credentials.
"""
import json
import os
import time
import uuid

from google.cloud import firestore

from utils.audio_jobs import state
from utils.audio_jobs.store import JobStore, owner_key

DAILY_JOURNAL_JOBS_COLLECTION = os.getenv('DAILY_JOURNAL_JOBS_COLLECTION', 'daily_journal_jobs')
ACTIVE = frozenset({'queued', 'processing', 'retry_wait'})
_NAMESPACE = uuid.UUID('4ba89108-041b-4a92-8767-0d3ccf0837aa')


def job_mode(catch_up: bool, force_regenerate: bool) -> str:
    return 'force' if force_regenerate else ('catch_up' if catch_up else 'evening')


def job_id(developer_id: str, uid: str, date_str: str, mode: str) -> str:
    """Deterministic, so the same pass for the same day is one record however often it is asked for.

    The evening and the morning catch-up are separate records: the catch-up must still run
    when the evening job has finished.
    """
    seed = json.dumps([developer_id, uid, date_str, mode], separators=(',', ':'))
    return str(uuid.uuid5(_NAMESPACE, seed))


class JournalJobStore(JobStore):
    def __init__(self, db=None, clock=time.time, collection=None):
        super().__init__(db, clock, collection or DAILY_JOURNAL_JOBS_COLLECTION)

    def enqueue(self, developer_id, uid, date_str, *, catch_up, include_image, force_regenerate):
        """Queue a pass for a day, or return the one already waiting or running for it.

        A finished or failed record is replaced by a fresh one: asking again is how a day is
        retried, and the work itself is idempotent (it re-checks the entry before writing).
        """
        mode = job_mode(catch_up, force_regenerate)
        return self._enqueue(job_id(developer_id, uid, date_str, mode), {
            'kind': 'daily_journal', 'mode': mode, 'developer_id': developer_id, 'uid': uid, 'date': date_str,
            'catch_up': bool(catch_up), 'include_image': bool(include_image),
            'force_regenerate': bool(force_regenerate),
        })

    def enqueue_insight(self, developer_id, uid, date_str, *, window_days, dry_run, send_push):
        """Queue the day's insight run for a user (`date_str` is their local date), as `enqueue` does.

        A dry run is its own record, so trying one never stands in for, or blocks, the real run.
        """
        mode = 'insight_dry_run' if dry_run else 'insight'
        return self._enqueue(job_id(developer_id, uid, date_str, mode), {
            'kind': 'insight', 'mode': mode, 'developer_id': developer_id, 'uid': uid, 'date': date_str,
            'window_days': int(window_days), 'dry_run': bool(dry_run), 'send_push': bool(send_push),
        })

    def _enqueue(self, job_id, fields):
        ref = self.collection.document(job_id)

        @firestore.transactional
        def apply(tx):
            current = ref.get(transaction=tx).to_dict()
            if current and current.get('status') in ACTIVE:
                return current
            now = self.clock()
            job = {
                **fields, 'id': ref.id, 'owner_key': owner_key(fields['developer_id'], fields['uid']),
                'status': 'queued', 'stage': 'generate', 'is_root': False,
                'created_at': now, 'updated_at': now, 'dispatch_at': now, 'next_attempt_at': now,
                'attempts': 0, 'stage_attempts': 0, 'checkpoints': {}, 'history': [],
                'lease_token': None, 'lease_until': 0,
                'runs': (current or {}).get('runs', 0) + 1,
            }
            state.event(job, now, 'queued')
            tx.set(ref, job)
            return job

        return apply(self.db.transaction())

    def finish(self, job_id, token, result):
        def apply(job, now):
            state.require_lease(job, token, now)
            job.update(status='completed', result=result, dispatch_at=None,
                       lease_token=None, lease_until=0, error_code=None)
            state.event(job, now, 'completed')
            return job
        return self.change(job_id, apply)
