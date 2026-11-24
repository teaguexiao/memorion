"""Run with FIRESTORE_EMULATOR_HOST=127.0.0.1:8787; never writes production data."""
import concurrent.futures
import json
import os
import subprocess
import sys
import uuid
import zlib

import boto3
import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore
from moto import mock_aws

from utils.audio_jobs import state
from utils.audio_jobs.store import JobStore
from utils.audio_jobs.worker import Worker


@pytest.fixture
def store():
    if not os.getenv('FIRESTORE_EMULATOR_HOST', '').startswith('127.0.0.1:'):
        pytest.skip('Local Firestore emulator required')
    now = [10000.0]
    db = firestore.Client(project='demo-memorion-audio-jobs', credentials=AnonymousCredentials())
    result = JobStore(db, clock=lambda: now[0], collection=f'audio_jobs_test_{uuid.uuid4().hex}')
    result.now = now
    yield result
    for doc in result.collection.stream():
        doc.reference.delete()


def accepted(store, owner='user'):
    job_id = str(uuid.uuid4())
    job, token = store.reserve(job_id, {'developer_id': 'test-dev', 'uid': owner, 'started_at': '2026-09-19T00:00:00+00:00',
                                     'source': 'audio_upload', 'duration_seconds': 600, 'language': 'auto',
                                     'auto_process': True, 'use_vad': True})
    return store.accept(job_id, token, {'path': 'test.wav', 'generation': 1, 'sha256': 'test', 'duration_seconds': 600})


def test_unaccepted_upload_placeholder_can_be_discarded(store):
    job_id = str(uuid.uuid4())
    _, token = store.reserve(job_id, {
        'developer_id': 'test-dev',
        'uid': 'user',
        'started_at': '2026-09-19T00:00:00+00:00',
        'source': 'audio_upload',
        'duration_seconds': 0,
        'language': 'auto',
        'auto_process': True,
        'use_vad': True,
    })

    assert store.discard_upload(job_id, token) is True
    assert store.get(job_id) is None
    assert store.discard_upload(job_id, token) is False


def test_expired_upload_placeholder_releases_usage_then_is_discarded(store, queue):
    job_id = str(uuid.uuid4())
    _, token = store.reserve(job_id, {
        'developer_id': 'test-dev', 'uid': 'user',
        'started_at': '2026-09-19T00:00:00+00:00', 'source': 'audio_upload',
        'duration_seconds': 0, 'language': 'auto', 'auto_process': True, 'use_vad': True,
    })

    class CleanupProcessor:
        def __init__(self):
            self.released = []

        def release_stale_upload_usage(self, job):
            self.released.append((job['id'], job['upload_token']))

    processor = CleanupProcessor()
    queue.processor = processor
    store.now[0] += 601
    queue.dispatch()

    assert processor.released == [(job_id, token)]
    assert store.get(job_id) is None


def test_committed_sync_upload_cleanup_keeps_usage(store, queue):
    job_id = str(uuid.uuid4())
    _, token = store.reserve(job_id, {
        'developer_id': 'test-dev', 'uid': 'user',
        'started_at': '2026-09-19T00:00:00+00:00', 'source': 'audio_upload',
        'duration_seconds': 0, 'language': 'auto', 'auto_process': True, 'use_vad': True,
    })
    store.commit_upload_usage(job_id, token)

    class CleanupProcessor:
        def __init__(self):
            self.refunds = 0

        def release_stale_upload_usage(self, job):
            if not job.get('usage_committed'):
                self.refunds += 1

    processor = CleanupProcessor()
    queue.processor = processor
    store.now[0] += 601
    queue.dispatch()

    assert processor.refunds == 0
    assert store.get(job_id) is None


def test_sync_billing_placeholder_is_hidden_from_owner_jobs(store):
    job_id = str(uuid.uuid4())
    _, token = store.reserve(job_id, {
        'developer_id': 'test-dev', 'uid': 'user',
        'started_at': '2026-09-19T00:00:00+00:00', 'source': 'audio_upload',
        'duration_seconds': 0, 'language': 'auto', 'auto_process': True, 'use_vad': True,
        'is_root': False,
    })

    assert store.list_for_owner('test-dev', 'user') == []
    assert store.discard_upload(job_id, token) is True


@pytest.fixture
def queue(store):
    with mock_aws():
        sqs = boto3.client('sqs', region_name='us-east-1')
        url = sqs.create_queue(QueueName='audio')['QueueUrl']
        dlq = sqs.create_queue(QueueName='audio-failed')['QueueUrl']
        yield Worker(store, sqs, url, dlq, lambda job, token: store.complete(job['id'], token), clock=store.clock)


def messages(queue):
    return queue.sqs.receive_message(QueueUrl=queue.queue_url, MaxNumberOfMessages=10).get('Messages', [])


def test_terminal_root_failure_releases_reserved_usage(queue, store):
    class TerminalProcessor:
        def __init__(self):
            self.released = []

        def __call__(self, job, token):
            raise state.JobFailure('invalid_audio', retryable=False)

        def release_failed_usage(self, job):
            self.released.append(job['id'])

    processor = TerminalProcessor()
    queue.processor = processor
    job = accepted(store)
    queue.dispatch()
    queue.handle(messages(queue)[0])

    assert store.get(job['id'])['status'] == 'failed'
    assert processor.released == [job['id']]


def test_terminal_refund_outage_does_not_poison_sqs_delivery(queue, store):
    class RefundOutageProcessor:
        def __call__(self, job, token):
            raise state.JobFailure('invalid_audio', retryable=False)

        def release_failed_usage(self, job):
            raise RuntimeError('firestore unavailable')

    queue.processor = RefundOutageProcessor()
    job = accepted(store)
    queue.dispatch()
    queue.handle(messages(queue)[0])

    assert store.get(job['id'])['status'] == 'failed'
    assert messages(queue) == []
    assert [due['id'] for due in store.due()] == [job['id']]


def test_refund_outage_does_not_block_later_failed_outbox_jobs(queue, store):
    first = accepted(store, owner='first')
    second = accepted(store, owner='second')
    for job in (first, second):
        token = f"token-{job['id']}"
        store.claim(job['id'], token)
        store.fail(job['id'], token, state.JobFailure('invalid_audio', retryable=False))

    class SelectiveRefundOutage:
        def __call__(self, job, token):
            pass

        def release_failed_usage(self, job):
            if job['id'] == first['id']:
                raise RuntimeError('firestore unavailable')

    queue.processor = SelectiveRefundOutage()
    queue.dispatch()

    assert store.get(first['id']).get('dead_lettered') is not True
    assert first['id'] not in {job['id'] for job in store.due()}
    assert store.get(second['id'])['dead_lettered'] is True
    dlq_messages = queue.sqs.receive_message(QueueUrl=queue.dlq_url, MaxNumberOfMessages=10).get('Messages', [])
    assert [json.loads(message['Body'])['job_id'] for message in dlq_messages] == [second['id']]


def test_terminal_post_transcription_failure_keeps_usage(queue, store):
    class TerminalProcessor:
        def __init__(self):
            self.released = []

        def __call__(self, job, token):
            raise state.JobFailure('summary_invalid', retryable=False)

        def release_failed_usage(self, job):
            self.released.append(job['id'])

    processor = TerminalProcessor()
    queue.processor = processor
    job = accepted(store)
    store.collection.document(job['id']).update({'stage': 'summarize'})
    queue.dispatch()
    queue.handle(messages(queue)[0])

    assert store.get(job['id'])['status'] == 'failed'
    assert processor.released == []


def test_retryable_pre_transcription_failure_keeps_reservation(queue, store):
    class RetryableProcessor:
        def __init__(self):
            self.released = []

        def __call__(self, job, token):
            raise state.JobFailure('provider_unavailable', retryable=True)

        def release_failed_usage(self, job):
            self.released.append(job['id'])

    processor = RetryableProcessor()
    queue.processor = processor
    job = accepted(store)
    queue.dispatch()
    queue.handle(messages(queue)[0])

    assert store.get(job['id'])['status'] == 'retry_wait'
    assert processor.released == []


def test_exhausted_retryable_pre_transcription_failure_releases_reservation(queue, store):
    class ExhaustedProcessor:
        def __init__(self):
            self.released = []

        def __call__(self, job, token):
            raise state.JobFailure('provider_unavailable', retryable=True)

        def release_failed_usage(self, job):
            self.released.append(job['id'])

    processor = ExhaustedProcessor()
    queue.processor = processor
    job = accepted(store)
    store.collection.document(job['id']).update({'stage_attempts': state.MAX_ATTEMPTS - 1})
    queue.dispatch()
    queue.handle(messages(queue)[0])

    assert store.get(job['id'])['status'] == 'failed'
    assert store.get(job['id'])['retryable'] is True
    assert processor.released == [job['id']]


def test_acceptance_survives_new_client_without_queue(store):
    job = accepted(store)
    restarted = JobStore(store.db, store.clock, store.collection.id)
    assert restarted.get(job['id'])['audio']['path'] == 'test.wav'
    assert restarted.due()[0]['id'] == job['id']


def test_concurrent_claim_has_one_owner(store):
    job = accepted(store)
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        claims = list(pool.map(lambda i: store.claim(job['id'], str(i)), range(8)))
    assert sum(c is not None for c in claims) == 1


def test_upload_reservation_and_expired_uploader_fencing(store):
    job = accepted(store)
    original, token = store.reserve(job['id'], {})
    assert original['id'] == job['id'] and token is None
    with pytest.raises(state.LeaseLost):
        store.accept(job['id'], 'wrong', {})


def test_expired_worker_cannot_checkpoint_or_publish(store):
    job = accepted(store)
    store.claim(job['id'], 'old')
    store.now[0] += 91
    assert store.claim(job['id'], 'new')
    with pytest.raises(state.LeaseLost):
        store.checkpoint(job['id'], 'old', {'transcript': 'stale'})
    with pytest.raises(state.LeaseLost):
        store.publish(job['id'], 'old', {'transcript_segments': []})
    assert store.get(job['id'])['lease_token'] == 'new'


def test_killed_process_is_recovered_from_firestore(store):
    job = accepted(store)
    script = '''
import os
from google.cloud import firestore
from google.auth.credentials import AnonymousCredentials
from utils.audio_jobs.store import JobStore
store=JobStore(firestore.Client(project='demo-memorion-audio-jobs',credentials=AnonymousCredentials()), clock=lambda:10000, collection=os.environ['TEST_COLLECTION'])
store.claim(os.environ['TEST_JOB'], 'killed')
store.checkpoint(os.environ['TEST_JOB'], 'killed', {'soniox_transcription_id':'remote-123'})
os._exit(137)
'''
    result = subprocess.run([sys.executable, '-c', script], env={**os.environ, 'TEST_COLLECTION': store.collection.id, 'TEST_JOB': job['id']})
    assert result.returncode == 137
    store.now[0] += 91
    recovered = store.claim(job['id'], 'replacement')
    assert recovered['checkpoints']['soniox_transcription_id'] == 'remote-123'
    assert recovered['attempts'] == 2


def test_repeated_process_death_becomes_visible_failure(store):
    job = accepted(store)
    for i in range(4):
        assert store.claim(job['id'], str(i))
        store.now[0] += 91
    assert store.claim(job['id'], 'fifth') is None
    failed = store.get(job['id'])
    assert failed['status'] == 'failed' and failed['error_code'] == 'worker_interrupted'
    assert failed in store.due()


@pytest.mark.parametrize('failure,expected', [(state.JobFailure('no_speech', retryable=False), 'failed'),
                                             (state.JobFailure('provider_rate_limit', retry_after=500), 'retry_wait')])
def test_failures_visible_and_retry_classified(store, failure, expected):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.fail(job['id'], 'token', failure)
    result = store.get(job['id'])
    assert result['status'] == expected and result['error_code'] == failure.code
    if expected == 'retry_wait':
        assert result['next_attempt_at'] == store.clock() + 500
        assert store.claim(job['id'], 'early') is None


def test_manual_retry_keeps_checkpoint_and_is_owner_scoped(store):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.checkpoint(job['id'], 'token', {'transcript': 'persisted'}, 'summarize')
    store.fail(job['id'], 'token', state.JobFailure('summary_unavailable'))
    with pytest.raises(KeyError):
        store.retry(job['id'], 'test-dev', 'another-user')
    retried = store.retry(job['id'], 'test-dev', 'user')
    assert retried['checkpoints']['transcript'] == 'persisted'
    assert retried['stage'] == 'summarize'
    with pytest.raises(state.JobConflict):
        store.retry(job['id'], 'test-dev', 'user')


def test_outbox_send_failure_is_recoverable(store, queue, monkeypatch):
    job = accepted(store)
    original = queue.sqs.send_message
    monkeypatch.setattr(queue.sqs, 'send_message', lambda **_: (_ for _ in ()).throw(ConnectionError()))
    with pytest.raises(ConnectionError):
        queue.dispatch()
    assert store.get(job['id'])['status'] == 'queued'
    monkeypatch.setattr(queue.sqs, 'send_message', original)
    queue.dispatch()
    assert len(messages(queue)) == 1


def test_send_then_crash_duplicate_delivery_executes_once(store, queue, monkeypatch):
    job = accepted(store)
    original = store.dispatched
    monkeypatch.setattr(store, 'dispatched', lambda *_args, **_kw: (_ for _ in ()).throw(ConnectionError()))
    with pytest.raises(ConnectionError):
        queue.dispatch()
    monkeypatch.setattr(store, 'dispatched', original)
    queue.dispatch()
    calls = []
    def process(job, token):
        calls.append(job['id'])
        store.complete(job['id'], token)
    queue.processor = process
    for msg in messages(queue):
        queue.handle(msg)
    assert calls == [job['id']]


def test_queue_message_loss_is_repaired_from_job_record(store, queue):
    job = accepted(store)
    queue.dispatch()
    queue.sqs.purge_queue(QueueUrl=queue.queue_url)
    store.now[0] += 301
    queue.dispatch()
    queue.handle(messages(queue)[0])
    assert store.get(job['id'])['status'] == 'completed'


def test_failure_goes_to_dlq_but_remains_queryable(store, queue):
    job = accepted(store)
    queue.processor = lambda *_: (_ for _ in ()).throw(state.JobFailure('no_speech', retryable=False))
    queue.dispatch()
    queue.handle(messages(queue)[0])
    queue.dispatch()
    assert queue.sqs.receive_message(QueueUrl=queue.dlq_url)['Messages']
    result = store.list_for_owner('test-dev', 'user')
    assert result[0]['status'] == 'failed' and result[0]['dead_lettered']
    assert store.list_for_owner('test-dev', 'another') == []


def test_publish_and_followups_are_atomic_and_replay_preserves_edits(store):
    job = accepted(store)
    store.claim(job['id'], 'token')
    conversation = {'id': job['id'], 'status': 'completed', 'structured': {'title': 'initial'}, 'transcript_segments': [{'text': 'speech'}]}
    store.publish(job['id'], 'token', conversation, ['timeline', 'search'])
    ref = store.db.collection('developer_data').document('test-dev').collection('users').document('user').collection('conversations').document(job['id'])
    saved = ref.get().to_dict()
    assert json.loads(zlib.decompress(saved['transcript_segments'])) == [{'text': 'speech'}]
    manual_transcript = zlib.compress(json.dumps([
        {'id': 'manual', 'speaker_id': 1, 'is_user': False, 'person_id': 'human-confirmed',
         'speaker_assignment_source': 'manual', 'text': 'synthetic', 'start': 0, 'end': 8}
    ]).encode())
    ref.update({'structured.title': 'user edit', 'transcript_segments': manual_transcript,
                'transcript_segments_compressed': True})
    assert store.claim(job['id'], 'replay') is None
    with pytest.raises(state.LeaseLost):
        store.publish(job['id'], 'token', conversation, ['timeline'])
    assert ref.get().to_dict()['structured']['title'] == 'user edit'
    assert ref.get().to_dict()['transcript_segments'] == manual_transcript
    assert len(store.due()) == 2
    ref.delete()


def test_list_cursor_and_public_fields_do_not_leak_secrets(store):
    for _ in range(3):
        accepted(store)
        store.now[0] += 1
    first = store.list_for_owner('test-dev', 'user', limit=2)
    rest = store.list_for_owner('test-dev', 'user', before=first[-1]['id'])
    assert len(first) == 2 and len(rest) == 1
    assert not ({'audio', 'checkpoints', 'developer_id', 'uid', 'lease_token'} & state.public(first[0]).keys())


@pytest.mark.parametrize('existing_user', [False, True])
def test_publish_creates_user_and_preserves_existing_profile(store, existing_user):
    owner = uuid.uuid4().hex
    user = store.db.collection('developer_data').document('test-dev').collection('users').document(owner)
    profile = {'id': owner, 'name': 'Edited profile', 'created_at': 'original'}
    if existing_user:
        user.set(profile)
    job = accepted(store, owner=owner)
    store.claim(job['id'], 'token')
    store.publish(job['id'], 'token', {'id': job['id'], 'transcript_segments': []})
    conversation = user.collection('conversations').document(job['id'])
    try:
        assert user.get().exists
        assert conversation.get().to_dict()['updated_at'].timestamp() == store.clock()
        if existing_user:
            assert user.get().to_dict() == profile
        else:
            assert user.get().to_dict()['id'] == owner
    finally:
        conversation.delete()
        user.delete()


def test_followup_does_not_inherit_parent_manual_retry_cooldown(store):
    job = accepted(store, owner=uuid.uuid4().hex)
    store.claim(job['id'], 'first')
    store.fail(job['id'], 'first', state.JobFailure('provider_unavailable'))
    store.retry(job['id'], 'test-dev', job['uid'])
    store.claim(job['id'], 'retry')
    store.publish(job['id'], 'retry', {'id': job['id'], 'transcript_segments': []}, ['timeline'])
    child = store.followups(job['id'])[0]
    assert not ({'retryable', 'error_code', 'manual_retry_at', 'dead_lettered'} & child.keys())
    store.claim(child['id'], 'child')
    store.fail(child['id'], 'child', state.JobFailure('timeline_unavailable'))
    assert store.retry(child['id'], 'test-dev', job['uid'])['status'] == 'queued'
    user = store.db.collection('developer_data').document('test-dev').collection('users').document(job['uid'])
    user.collection('conversations').document(job['id']).delete()
    user.delete()


def test_identity_is_tenant_scoped_and_recording_key_stable():
    a = state.identity('d', 'u', 'time', 'device:recording')
    assert a == state.identity('d', 'u', 'changed-clock', 'device:recording')
    assert a != state.identity('other', 'u', 'time', 'device:recording')


def test_completed_result_with_lost_ack_is_not_reprocessed(store, queue, monkeypatch):
    job = accepted(store)
    queue.dispatch()
    message = messages(queue)[0]
    calls = []
    def process(job, token):
        calls.append(job['id'])
        store.complete(job['id'], token)
    queue.processor = process
    original = queue.sqs.delete_message
    monkeypatch.setattr(queue.sqs, 'delete_message', lambda **_: (_ for _ in ()).throw(ConnectionError()))
    with pytest.raises(ConnectionError):
        queue.handle(message)
    monkeypatch.setattr(queue.sqs, 'delete_message', original)
    queue.handle(message)
    assert calls == [job['id']]
    assert store.get(job['id'])['status'] == 'completed'


def test_failure_to_save_checkpoint_does_not_ack_success(store, queue, monkeypatch):
    job = accepted(store)
    queue.dispatch()
    def process(*_):
        raise ConnectionError('database unavailable')
    queue.processor = process
    original = store.fail
    monkeypatch.setattr(store, 'fail', lambda *_args, **_kw: (_ for _ in ()).throw(ConnectionError()))
    with pytest.raises(ConnectionError):
        queue.handle(messages(queue)[0])
    assert store.get(job['id'])['status'] == 'processing'
    store.now[0] += 91
    monkeypatch.setattr(store, 'fail', original)
    assert store.claim(job['id'], 'new-worker')


def test_lease_heartbeat_blocks_early_recovery(store):
    job = accepted(store)
    store.claim(job['id'], 'first')
    store.now[0] += 80
    store.renew(job['id'], 'first')
    store.now[0] += 30
    assert store.claim(job['id'], 'second') is None
    store.now[0] += 61
    assert store.claim(job['id'], 'second')


def test_invalid_upload_is_visible_but_never_accepted_as_cloud_receipt(store):
    job = accepted(store)
    metadata = {key: job[key] for key in ('developer_id', 'uid', 'started_at', 'source', 'duration_seconds')}
    job_id = str(uuid.uuid4())
    _, token = store.reserve(job_id, metadata)
    store.reject_upload(job_id, token)
    failed = store.get(job_id)
    assert failed['status'] == 'failed' and 'audio' not in failed
    assert failed['dispatch_at'] is None
    store.now[0] += 601
    assert job_id not in {job['id'] for job in store.due()}
    assert not state.public(failed)['can_retry']
    _, new_token = store.reserve(job_id, metadata)
    assert new_token and new_token != token


def test_large_transcript_chunks_roundtrip(store):
    job = accepted(store)
    store.claim(job['id'], 'token')
    segments = [{'text': os.urandom(700000).hex()}]
    store.publish(job['id'], 'token', {'id': job['id'], 'transcript_segments': segments})
    ref = store.db.collection('developer_data').document('test-dev').collection('users').document('user').collection('conversations').document(job['id'])
    saved = ref.get().to_dict()
    assert saved['transcript_segments_chunked']
    chunks = sorted((doc.to_dict() for doc in ref.collection('transcript_chunks').stream()), key=lambda d: d['index'])
    assert json.loads(zlib.decompress(b''.join(part['data'] for part in chunks))) == segments
    for doc in ref.collection('transcript_chunks').stream():
        doc.reference.delete()
    ref.delete()
