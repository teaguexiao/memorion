"""Daily journal jobs: outbox, leases and delivery (2026-10-28).

The record format and transitions are the audio jobs' (`utils.audio_jobs.state`), so the same
failures must be survivable: a lost or duplicated SQS message, a dead worker, a failure that
must not be retried. What is new here is the fence: a run that may have a successor must not
write the entry, because writing it twice also pushes the evening twice.

Run with FIRESTORE_EMULATOR_HOST=127.0.0.1:8787; never writes production data.
"""
import json
import os
import threading
import uuid

import boto3
import pytest
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore
from moto import mock_aws

from utils.audio_jobs import state
from utils.daily_journal_jobs import worker as journal_worker
from utils.daily_journal_jobs.store import JournalJobStore, job_id
from utils.daily_journal_jobs.worker import JournalWorker


@pytest.fixture
def store():
    if not os.getenv('FIRESTORE_EMULATOR_HOST', '').startswith('127.0.0.1:'):
        pytest.skip('Local Firestore emulator required')
    now = [10000.0]
    db = firestore.Client(project='demo-memorion-audio-jobs', credentials=AnonymousCredentials())
    result = JournalJobStore(db, clock=lambda: now[0], collection=f'journal_jobs_test_{uuid.uuid4().hex}')
    result.now = now
    yield result
    for doc in result.collection.stream():
        doc.reference.delete()


@pytest.fixture
def worker(store, tmp_path, monkeypatch):
    monkeypatch.setattr(journal_worker, 'HEALTH_FILE', tmp_path / 'health')
    with mock_aws():
        sqs = boto3.client('sqs', region_name='us-east-1')
        url = sqs.create_queue(QueueName='journal')['QueueUrl']
        dlq = sqs.create_queue(QueueName='journal-failed')['QueueUrl']
        yield JournalWorker(store, sqs, url, dlq, lambda job, fence: {'outcome': 'written'}, clock=store.clock)


def messages(worker, url=None):
    return worker.sqs.receive_message(QueueUrl=url or worker.queue_url, MaxNumberOfMessages=10).get('Messages', [])


def enqueue(store, catch_up=True):
    return store.enqueue('test-dev', 'user', '2026-10-25', catch_up=catch_up, include_image=True, force_regenerate=False)


def fails_with(error):
    def process(job, fence):
        raise error
    return process


def test_asking_again_for_a_waiting_or_running_pass_is_the_same_job(store):
    first = enqueue(store)
    assert first['status'] == 'queued'
    assert first['id'] == job_id('test-dev', 'user', '2026-10-25', 'catch_up')
    assert enqueue(store) == first
    assert store.claim(first['id'], 'token')
    assert enqueue(store)['status'] == 'processing'


def test_evening_catch_up_and_forced_passes_of_one_day_are_separate_jobs(store):
    evening = enqueue(store, catch_up=False)
    catch_up = enqueue(store, catch_up=True)
    forced = store.enqueue('test-dev', 'user', '2026-10-25', catch_up=False, include_image=True, force_regenerate=True)
    assert len({evening['id'], catch_up['id'], forced['id']}) == 3
    assert (evening['mode'], catch_up['mode'], forced['mode']) == ('evening', 'catch_up', 'force')


def insight_run(store, date_str='2026-10-28', dry_run=False):
    return store.enqueue_insight('test-dev', 'user', date_str, window_days=60, dry_run=dry_run, send_push=not dry_run)


def test_insight_runs_are_one_job_per_user_and_day(store):
    first = insight_run(store)
    assert (first['kind'], first['mode'], first['window_days'], first['send_push']) == ('insight', 'insight', 60, True)
    assert insight_run(store) == first
    assert store.claim(first['id'], 'token')
    assert insight_run(store)['status'] == 'processing'
    # A dry run, the next day and the same day's journal are separate records.
    others = {insight_run(store, dry_run=True)['id'], insight_run(store, '2026-10-29')['id'],
              store.enqueue('test-dev', 'user', '2026-10-28', catch_up=False, include_image=True,
                            force_regenerate=False)['id']}
    assert len(others) == 3 and first['id'] not in others
    assert store.get(job_id('test-dev', 'user', '2026-10-28', 'insight_dry_run'))['dry_run'] is True


def test_job_ids_are_tenant_scoped():
    assert job_id('dev', 'user', '2026-10-25', 'evening') != job_id('other', 'user', '2026-10-25', 'evening')
    assert job_id('dev', 'user', '2026-10-25', 'evening') != job_id('dev', 'user2', '2026-10-25', 'evening')


def test_job_runs_once_keeps_its_result_and_ignores_a_duplicate_delivery(store, worker):
    job = enqueue(store)
    calls = []
    worker.processor = lambda job, fence: calls.append(job['id']) or {'outcome': 'written', 'conversations': 3}
    worker.dispatch()
    [message] = messages(worker)
    worker.handle(message)
    record = store.get(job['id'])
    assert calls == [job['id']]
    assert record['status'] == 'completed'
    assert record['result'] == {'outcome': 'written', 'conversations': 3}
    assert record['dispatch_at'] is None
    worker.sqs.send_message(QueueUrl=worker.queue_url, MessageBody=json.dumps({'job_id': job['id']}))
    worker.handle(messages(worker)[0])
    assert calls == [job['id']]


def test_asking_again_after_completion_queues_a_new_run(store, worker):
    job = enqueue(store)
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'completed'
    again = enqueue(store)
    assert again['id'] == job['id']
    assert again['status'] == 'queued'
    assert again['runs'] == 2


def test_transient_failure_waits_then_runs_again(store, worker):
    job = enqueue(store)
    worker.processor = fails_with(TimeoutError('read timed out'))
    worker.dispatch()
    worker.handle(messages(worker)[0])
    record = store.get(job['id'])
    assert record['status'] == 'retry_wait'
    assert record['error_code'] == 'processing_unavailable'
    worker.processor = lambda job, fence: {'outcome': 'written'}
    worker.dispatch()
    assert messages(worker) == []
    store.now[0] = record['next_attempt_at'] + 1
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'completed'


def test_terminal_failure_goes_to_the_dlq_and_is_not_retried(store, worker):
    job = enqueue(store)
    calls = []

    def over_budget(job, fence):
        calls.append(job['id'])
        raise state.JobFailure('evidence_over_budget', retryable=False)

    worker.processor = over_budget
    worker.dispatch()
    worker.handle(messages(worker)[0])
    worker.dispatch()
    record = store.get(job['id'])
    assert record['status'] == 'failed'
    assert record['error_code'] == 'evidence_over_budget'
    assert record['dead_lettered']
    assert json.loads(messages(worker, worker.dlq_url)[0]['Body']) == {'job_id': job['id']}
    store.now[0] += 3600
    worker.dispatch()
    assert messages(worker) == []
    assert calls == [job['id']]


def test_lost_queue_message_is_resent_from_the_record(store, worker):
    job = enqueue(store)
    worker.dispatch()
    worker.sqs.purge_queue(QueueUrl=worker.queue_url)
    store.now[0] += 301
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'completed'


def test_send_then_crash_duplicate_delivery_executes_once(store, worker, monkeypatch):
    job = enqueue(store)
    original = store.dispatched
    monkeypatch.setattr(store, 'dispatched', lambda *_args, **_kw: (_ for _ in ()).throw(ConnectionError()))
    with pytest.raises(ConnectionError):
        worker.dispatch()
    monkeypatch.setattr(store, 'dispatched', original)
    worker.dispatch()
    calls = []
    worker.processor = lambda job, fence: calls.append(job['id']) or {'outcome': 'written'}
    for message in messages(worker):
        worker.handle(message)
    assert calls == [job['id']]


def test_dead_worker_lease_expires_into_another_attempt(store, worker):
    job = enqueue(store)
    assert store.claim(job['id'], 'dead-worker')
    worker.dispatch()
    assert messages(worker) == []
    store.now[0] += state.LEASE_SECONDS + 1
    worker.dispatch()
    worker.handle(messages(worker)[0])
    record = store.get(job['id'])
    assert record['status'] == 'completed'
    assert record['attempts'] == 2


def test_run_that_lost_its_lease_writes_nothing_and_keeps_the_message(store, worker, monkeypatch):
    job = enqueue(store)
    wrote, deleted = [], []
    monkeypatch.setattr(worker.sqs, 'delete_message', lambda **kwargs: deleted.append(kwargs))

    def process(job, fence):
        # Generation outlived the lease, and a redelivery took the job over meanwhile.
        store.now[0] += state.LEASE_SECONDS + 1
        assert store.claim(job['id'], 'successor')
        fence()
        wrote.append(job['id'])
        return {'outcome': 'written'}

    worker.processor = process
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert wrote == []
    assert deleted == []
    record = store.get(job['id'])
    assert record['status'] == 'processing' and record['lease_token'] == 'successor'


def test_fence_holds_the_lease_for_the_write(store, worker):
    job = enqueue(store)

    def process(job, fence):
        store.now[0] += state.LEASE_SECONDS - 10
        fence()
        store.now[0] += state.LEASE_SECONDS - 10
        # Past the lease taken at claim time, within the one the fence renewed.
        assert store.claim(job['id'], 'intruder') is None
        return {'outcome': 'written'}

    worker.processor = process
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'completed'


def long_day(store, renewed):
    """A job that runs past its first lease, so only heartbeat renewals let it finish."""
    def process(job, fence):
        store.now[0] += state.LEASE_SECONDS - 10
        renewed.clear()
        assert renewed.wait(5), 'no renewal while the job ran'
        store.now[0] += state.LEASE_SECONDS - 10
        return {'outcome': 'written'}
    return process


def test_heartbeat_keeps_a_long_job_leased(store, worker, monkeypatch):
    monkeypatch.setattr(journal_worker, 'HEARTBEAT_SECONDS', 0.02)
    renewed = threading.Event()
    original = store.renew
    monkeypatch.setattr(store, 'renew', lambda *args: (original(*args), renewed.set()))
    job = enqueue(store)
    worker.processor = long_day(store, renewed)
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'completed'
    assert messages(worker) == []


def test_one_failed_renewal_does_not_give_the_job_up(store, worker, monkeypatch):
    monkeypatch.setattr(journal_worker, 'HEARTBEAT_SECONDS', 0.02)
    renewed = threading.Event()
    original, calls = store.renew, []

    def flaky_renew(*args):
        calls.append(1)
        if len(calls) == 1:
            raise ConnectionError('Firestore unavailable')
        original(*args)
        renewed.set()

    monkeypatch.setattr(store, 'renew', flaky_renew)
    job = enqueue(store)
    worker.processor = long_day(store, renewed)
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'completed'


def test_stuck_job_exits_the_process(store, worker, monkeypatch):
    monkeypatch.setattr(journal_worker, 'HEARTBEAT_SECONDS', 0.02)
    exited = threading.Event()

    def fake_exit(code):
        assert code == 70
        exited.set()

    monkeypatch.setattr(journal_worker.os, '_exit', fake_exit)
    enqueue(store)

    def stuck(job, fence):
        store.now[0] += journal_worker.JOB_HARD_LIMIT_SECONDS + 1
        assert exited.wait(5)
        raise state.LeaseLost()

    worker.processor = stuck
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert exited.is_set()


def test_lost_lease_leaves_the_message_unacked(store, worker, monkeypatch):
    enqueue(store)
    deleted = []
    monkeypatch.setattr(worker.sqs, 'delete_message', lambda **kwargs: deleted.append(kwargs))
    worker.processor = fails_with(state.LeaseLost())
    worker.dispatch()
    worker.handle(messages(worker)[0])
    assert deleted == []


def test_failure_that_cannot_be_recorded_is_not_acked(store, worker, monkeypatch):
    job = enqueue(store)
    worker.dispatch()
    worker.processor = fails_with(ConnectionError('database unavailable'))
    original = store.fail
    monkeypatch.setattr(store, 'fail', lambda *_args, **_kw: (_ for _ in ()).throw(ConnectionError()))
    with pytest.raises(ConnectionError):
        worker.handle(messages(worker)[0])
    assert store.get(job['id'])['status'] == 'processing'
    store.now[0] += state.LEASE_SECONDS + 1
    monkeypatch.setattr(store, 'fail', original)
    assert store.claim(job['id'], 'new-worker')


def test_malformed_message_is_set_aside(store, worker):
    worker.sqs.send_message(QueueUrl=worker.queue_url, MessageBody='not json')
    worker.handle(messages(worker)[0])
    [aside] = messages(worker, worker.dlq_url)
    assert json.loads(aside['Body']) == {'error': 'invalid_message'}
    assert messages(worker) == []


def test_run_writes_up_to_concurrency_journals_at_once():
    # No queue or store needed: this only checks that the consumers run side by side.
    worker = JournalWorker(None, None, 'queue', 'dlq', None, concurrency=3)
    worker.dispatch = lambda: None
    together = threading.Barrier(3, timeout=5)
    met = []

    def consume():
        together.wait()
        met.append(threading.current_thread().name)
        worker.stop.set()

    worker.consume = consume
    worker.run()
    assert len(met) == 3
