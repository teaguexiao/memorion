"""Atomic job records, leases and outbox in the existing Firestore database."""
import copy
import hashlib
import json
import os
import random
import time
import uuid
import zlib
from datetime import datetime, timezone

from google.api_core.exceptions import FailedPrecondition, Aborted
from google.cloud import firestore
from google.cloud.firestore_v1 import FieldFilter

from . import state


AUDIO_JOBS_COLLECTION = os.getenv('AUDIO_JOBS_COLLECTION', 'audio_processing_jobs')


def owner_key(developer_id, uid):
    return hashlib.sha256(json.dumps([developer_id, uid]).encode()).hexdigest()


class JobStore:
    def __init__(self, db=None, clock=time.time, collection=None):
        if db is None:
            from database._client import db
        self.db, self.clock = db, clock
        self.collection = db.collection(collection or AUDIO_JOBS_COLLECTION)

    def get(self, job_id):
        return self.collection.document(job_id).get().to_dict()

    def lookup_recording(self, developer_id, uid, recording_key, started_at):
        """Recover an upload receipt without transferring the audio again.

        Exact recording time is also the upload endpoint's legacy idempotency
        key. It survives reinstall/device identifier changes; no fuzzy matching.
        Only metadata is read, including discarded and soft-deleted recordings.
        """
        started_at = started_at.astimezone(timezone.utc)
        anchor = started_at.isoformat()
        owner = owner_key(developer_id, uid)
        result = {'recording_key': recording_key, 'started_at': anchor, 'can_upload': False}
        job = self.get(state.identity(developer_id, uid, anchor, recording_key))
        if job and (job.get('owner_key') != owner or job.get('started_at') != anchor):
            return {**result, 'reason': 'identity_conflict'}
        if not job:
            query = (self.collection
                     .where(filter=FieldFilter('owner_key', '==', owner))
                     .where(filter=FieldFilter('is_root', '==', True))
                     .where(filter=FieldFilter('started_at', '==', anchor)).limit(2))
            candidates = [snap.to_dict() for snap in query.stream()]
            if len(candidates) > 1:
                return {**result, 'reason': 'ambiguous'}
            job = candidates[0] if candidates else None
        if job and job.get('audio'):
            return {**result, 'conversation_id': job['conversation_id'],
                    'processing': job['status'] != 'completed',
                    'duration_seconds': job.get('duration_seconds'), 'job': state.public(job)}

        # Pre-queue uploads have a conversation but no public audio job. Avoid
        # reading/decompressing their transcripts just to recover a receipt.
        query = (self.db.collection('developer_data').document(developer_id)
                 .collection('users').document(uid).collection('conversations')
                 .where(filter=FieldFilter('source', '==', 'audio_upload'))
                 .where(filter=FieldFilter('started_at', '==', started_at))
                 .select(['status', 'started_at', 'finished_at', 'deleted']).limit(2))
        conversations = list(query.stream())
        if len(conversations) > 1:
            return {**result, 'reason': 'ambiguous'}
        if conversations:
            snapshot = conversations[0]
            conversation = snapshot.to_dict()
            end = conversation.get('finished_at')
            return {**result, 'conversation_id': snapshot.id,
                    'processing': not conversation.get('deleted') and conversation.get('status') in {'processing', 'in_progress'},
                    'duration_seconds': max(0, (end - started_at).total_seconds()) if end else None}
        if job and (job.get('upload_until', 0) > self.clock() or job.get('usage_committed')):
            return {**result, 'reason': 'upload_in_progress'}
        return {**result, 'can_upload': True}

    def change(self, job_id, transition):
        ref = self.collection.document(job_id)
        # Single-document compare-and-swap avoids read-lock upgrade contention
        # between duplicate deliveries while still fencing every lease mutation.
        for attempt in range(8):
            snapshot = ref.get()
            job = snapshot.to_dict()
            before = copy.deepcopy(job)
            result = transition(job, self.clock())
            if job is None or job == before:
                return result
            try:
                ref.update(job, option=self.db.write_option(last_update_time=snapshot.update_time))
                return result
            except (FailedPrecondition, Aborted):
                if attempt == 7:
                    raise
                time.sleep(random.uniform(0.01, 0.05) * (attempt + 1))

    def reserve(self, job_id, metadata):
        ref = self.collection.document(job_id)
        token = uuid.uuid4().hex

        @firestore.transactional
        def apply(tx):
            job = ref.get(transaction=tx).to_dict()
            now = self.clock()
            if job and job.get('audio'):
                return job, None
            if job and job.get('upload_until', 0) > now:
                raise state.JobConflict('upload_in_progress')
            job = {**metadata, 'id': job_id, 'conversation_id': job_id,
                   'owner_key': owner_key(metadata['developer_id'], metadata['uid']),
                   'status': 'uploading', 'stage': 'validate', 'created_at': now,
                   'updated_at': now, 'upload_token': token, 'upload_until': now + 600,
                   'checkpoints': {}, 'attempts': 0, 'stage_attempts': 0,
                   'core_completed': False, 'is_root': bool(metadata.get('is_root', True)),
                   'usage_committed': False,
                   # Reconciliation owns expired placeholders. This also makes a
                   # reservation recoverable if the REST process dies after
                   # charging usage but before accepting the durable job.
                   'dispatch_at': now + 600}
            tx.set(ref, job)
            return job, token

        return apply(self.db.transaction())

    def accept(self, job_id, upload_token, audio):
        def apply(job, now):
            if not job or job['status'] != 'uploading' or job.get('upload_token') != upload_token:
                raise state.LeaseLost()
            job.update(audio=audio, duration_seconds=audio['duration_seconds'], status='queued', dispatch_at=now, next_attempt_at=now,
                       upload_token=None, upload_until=0)
            state.event(job, now, 'accepted')
            return job
        return self.change(job_id, apply)

    def abandon_upload(self, job_id, token):
        def apply(job, now):
            if job and job['status'] == 'uploading' and job.get('upload_token') == token:
                job['upload_until'] = 0
                job['dispatch_at'] = now
        self.change(job_id, apply)

    def extend_upload(self, job_id, token, seconds):
        """Keep a synchronous upload fenced while its expensive tail runs."""
        def apply(job, now):
            if not job or job.get('status') != 'uploading' or job.get('upload_token') != token:
                raise state.LeaseLost()
            job['upload_until'] = now + seconds
            job['dispatch_at'] = now + seconds
        self.change(job_id, apply)

    def commit_upload_usage(self, job_id, token):
        """Mark synchronous STT as consumed so stale cleanup keeps its charge."""
        def apply(job, now):
            if not job or job.get('status') != 'uploading' or job.get('upload_token') != token:
                raise state.LeaseLost()
            job['usage_committed'] = True
        self.change(job_id, apply)

    def discard_upload(self, job_id, token):
        """Delete an unaccepted upload placeholder owned by this request."""
        ref = self.collection.document(job_id)

        @firestore.transactional
        def apply(tx):
            snapshot = ref.get(transaction=tx)
            job = snapshot.to_dict() if snapshot.exists else None
            if job and job.get('status') == 'uploading' and job.get('upload_token') == token and not job.get('audio'):
                tx.delete(ref)
                return True
            return False

        return apply(self.db.transaction())

    def reject_upload(self, job_id, token):
        def apply(job, now):
            if job and job['status'] == 'uploading' and job.get('upload_token') == token:
                # This is a synchronous client verdict, not worker/outbox
                # failure. Keep it queryable without publishing it to the DLQ.
                job.update(status='failed', error_code='invalid_audio', retryable=False,
                           upload_until=0, dispatch_at=None)
                state.event(job, now, 'upload_rejected')
        self.change(job_id, apply)

    def claim(self, job_id, token):
        def apply(job, now):
            claimed = state.claim(job, now, token)
            if job and job['status'] == 'failed' and not job.get('dead_lettered'):
                job['dispatch_at'] = now
            return job if claimed else None
        return self.change(job_id, apply)

    def renew(self, job_id, token):
        self.change(job_id, lambda job, now: state.renew(job, token, now))

    def checkpoint(self, job_id, token, values, next_stage=None):
        def apply(job, now):
            state.require_lease(job, token, now)
            job['checkpoints'].update(values)
            if next_stage:
                job.update(stage=next_stage, stage_attempts=1)
            state.event(job, now, 'checkpoint')
            return job
        return self.change(job_id, apply)

    def fail(self, job_id, token, error, jitter=0):
        def apply(job, now):
            state.fail(job, token, now, error, jitter)
            if job['status'] == 'failed':
                job['dispatch_at'] = now
            return job
        return self.change(job_id, apply)

    def retry(self, job_id, developer_id, uid):
        def apply(job, now):
            if not job or job['owner_key'] != owner_key(developer_id, uid):
                raise KeyError(job_id)
            state.retry(job, now)
            job['dead_lettered'] = False
            return job
        return self.change(job_id, apply)

    def list_for_owner(self, developer_id, uid, limit=50, before=None):
        # Composite index is managed by ecs/api/terraform/audio_jobs_firestore.tf.
        query = self.collection.where(filter=FieldFilter('owner_key', '==', owner_key(developer_id, uid))).where(filter=FieldFilter('is_root', '==', True))
        query = query.order_by('created_at', direction=firestore.Query.DESCENDING).order_by('__name__', direction=firestore.Query.DESCENDING)
        if before:
            cursor = self.get(before)
            if not cursor or cursor['owner_key'] != owner_key(developer_id, uid):
                raise KeyError(before)
            query = query.start_after({'created_at': cursor['created_at'], '__name__': self.collection.document(before)})
        return [doc.to_dict() for doc in query.limit(limit).stream()]

    def active_for_owner(self, developer_id, uid):
        # Equality-only queries use Firestore index merging. Do not scan completed
        # history or restrict this to a recent page: old recordings can be retried.
        owner = owner_key(developer_id, uid)
        jobs = {}
        for status in ('queued', 'processing', 'retry_wait'):
            query = self.collection.where(filter=FieldFilter('owner_key', '==', owner)).where(
                filter=FieldFilter('is_root', '==', True)).where(filter=FieldFilter('status', '==', status))
            for doc in query.stream():
                jobs[doc.id] = doc.to_dict()
        return list(jobs.values())

    def followups(self, job_id):
        return [doc.to_dict() for doc in self.collection.where(filter=FieldFilter('parent_id', '==', job_id)).stream()]

    def followups_for_jobs(self, job_ids):
        grouped = {job_id: [] for job_id in job_ids}
        # Firestore supports at most 30 values per IN query.
        for start in range(0, len(job_ids), 30):
            query = self.collection.where(filter=FieldFilter('parent_id', 'in', job_ids[start:start + 30]))
            for doc in query.stream():
                child = doc.to_dict()
                grouped[child['parent_id']].append(child)
        return grouped

    def due(self, limit=100):
        return [doc.to_dict() for doc in self.collection.where(
            filter=FieldFilter('dispatch_at', '<=', self.clock())).order_by('dispatch_at').limit(limit).stream()]

    def dispatched(self, snapshot, dead_letter=False):
        def apply(job, now):
            if job and job.get('dispatch_at') == snapshot.get('dispatch_at') and job['status'] == snapshot['status']:
                job['dispatch_at'] = None if dead_letter else now + 300
                if dead_letter:
                    job['dead_lettered'] = True
        self.change(snapshot['id'], apply)

    def publish(self, job_id, token, conversation, child_stages=()):
        """Fence the result, conversation, and follow-up jobs in one transaction."""
        ref = self.collection.document(job_id)
        now = self.clock()

        @firestore.transactional
        def apply(tx):
            job = ref.get(transaction=tx).to_dict()
            state.require_lease(job, token, self.clock())
            user = self.db.collection('developer_data').document(job['developer_id']).collection('users').document(job['uid'])
            conv_ref = user.collection('conversations').document(job['conversation_id'])
            # A pre-existing result is never overwritten on replay, including user edits.
            existing = conv_ref.get(transaction=tx).to_dict()
            user_exists = user.get(transaction=tx).exists
            published_at = datetime.fromtimestamp(now, timezone.utc)
            if not user_exists:
                tx.set(user, {'id': job['uid'], 'created_at': published_at, 'updated_at': published_at})
            data = dict(conversation)
            compressed = zlib.compress(json.dumps(data.pop('transcript_segments', []), ensure_ascii=False).encode())
            data.update(transcript_segments=compressed, transcript_segments_compressed=True, updated_at=published_at)
            if existing is None and len(compressed) > 600000:
                data.update(transcript_segments=None, transcript_segments_chunked=True)
                for i, start in enumerate(range(0, len(compressed), 500000)):
                    tx.set(conv_ref.collection('transcript_chunks').document(f'chunk_{i:04d}'), {'data': compressed[start:start + 500000], 'index': i})
            if existing is None:
                tx.set(conv_ref, data)
            for stage in child_stages:
                child_id = str(uuid.uuid5(uuid.UUID(job_id), stage))
                child = {**job, 'id': child_id, 'parent_id': job_id, 'status': 'queued', 'stage': stage,
                         'created_at': now, 'updated_at': now, 'dispatch_at': now, 'next_attempt_at': now,
                         'attempts': 0, 'stage_attempts': 0, 'checkpoints': {}, 'history': [],
                         'lease_token': None, 'lease_until': 0, 'core_completed': True, 'is_root': False}
                for key in ('error_code', 'error', 'retryable', 'dead_lettered', 'manual_retry_at', 'heartbeat_at'):
                    child.pop(key, None)
                tx.set(self.collection.document(child_id), child)
            job.update(status='completed', stage='completed', core_completed=True, dispatch_at=None,
                       lease_token=None, lease_until=0, error_code=None, discarded=bool(conversation.get('discarded')))
            state.event(job, now, 'completed')
            tx.set(ref, job)
        apply(self.db.transaction())

    def complete(self, job_id, token):
        def apply(job, now):
            state.require_lease(job, token, now)
            job.update(status='completed', dispatch_at=None, lease_token=None, lease_until=0, error_code=None)
            state.event(job, now, 'completed')
        self.change(job_id, apply)
