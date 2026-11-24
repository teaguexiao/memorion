import copy
import concurrent.futures
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest import mock

import pytest
from google.api_core.exceptions import AlreadyExists, ServiceUnavailable

from test_audio_jobs import store, accepted
from utils.audio_jobs.pipeline import Pipeline
from utils.audio_jobs import state
from models.conversation import Conversation, ConversationSource, ConversationStatus, Structured


@pytest.fixture(autouse=True)
def deployed_monthly_counter(monkeypatch):
    # Most tests exercise the authoritative path; the explicit incomplete-month
    # tests below override this durable marker guard.
    monkeypatch.setattr('database.user_usage.subscription_counter_covers_month', lambda *_: True)


def test_batch_transcription_usage_is_recorded_once():
    from database import user_usage

    class FakeDocument:
        def __init__(self):
            self.exists = False
            self.data = {}

        def get(self, transaction=None):
            return SimpleNamespace(exists=self.exists, to_dict=lambda: self.data)

    class FakeCollection:
        def __init__(self, document):
            self._document = document

        def document(self, document_id):
            return self._document

    class FakeUser:
        def __init__(self, event, hour, month):
            self._collections = {
                'usage_events': FakeCollection(event),
                'hourly_usage': FakeCollection(hour),
                'monthly_usage': FakeCollection(month),
            }

        def collection(self, name):
            return self._collections[name]

    class FakeTransaction:
        def __init__(self, event):
            self.event = event
            self.writes = []

        def set(self, reference, values, **kwargs):
            self.writes.append((reference, values, kwargs))
            if reference is self.event:
                self.event.exists = True
                self.event.data = values

    event = FakeDocument()
    hour = FakeDocument()
    month = FakeDocument()
    marker_started_at = datetime(2026, 9, 21, tzinfo=timezone.utc)
    transaction = FakeTransaction(event)
    occurred_at = datetime(2026, 10, 1, 0, 0, tzinfo=timezone.utc)

    with mock.patch.object(user_usage, '_get_user_ref', return_value=FakeUser(event, hour, month)), \
            mock.patch.object(
                user_usage,
                'ensure_subscription_usage_counter_started_at',
                return_value=marker_started_at,
            ), \
            mock.patch.object(user_usage.db, 'transaction', return_value=transaction), \
            mock.patch.object(user_usage.firestore, 'transactional', side_effect=lambda function: function):
        first = user_usage.record_transcription_usage_once(
            'user', 'audio-upload:conversation', 600,
            developer_id='developer', occurred_at=occurred_at,
        )
        second = user_usage.record_transcription_usage_once(
            'user', 'audio-upload:conversation', 600,
            developer_id='developer', occurred_at=occurred_at,
        )

    assert first is True
    assert second is False
    assert len(transaction.writes) == 3
    assert transaction.writes[0][1]['transcription_seconds'].value == 600


def test_subscription_counter_marker_is_memoized_per_process_client():
    from database import user_usage

    marker = mock.Mock()
    marker.create.side_effect = AlreadyExists('already created')
    marker.get.return_value = SimpleNamespace(
        exists=True,
        to_dict=lambda: {'started_at': datetime(2026, 9, 21, tzinfo=timezone.utc)},
    )
    isolated_db = object()
    with mock.patch.object(user_usage, 'db', isolated_db), \
            mock.patch.object(user_usage, '_usage_counter_state_ref', return_value=marker):
        user_usage._usage_counter_started_at_cache.pop(isolated_db, None)
        first = user_usage.ensure_subscription_usage_counter_started_at()
        second = user_usage.ensure_subscription_usage_counter_started_at()

    assert first == second == datetime(2026, 9, 21, tzinfo=timezone.utc)
    marker.create.assert_called_once()
    marker.get.assert_called_once()


def test_subscription_counter_marker_outage_fails_open_without_caching():
    from database import user_usage

    marker = mock.Mock()
    marker.create.side_effect = ServiceUnavailable('temporarily unavailable')
    isolated_db = object()
    with mock.patch.object(user_usage, 'db', isolated_db), \
            mock.patch.object(user_usage, '_usage_counter_state_ref', return_value=marker):
        user_usage._usage_counter_started_at_cache.pop(isolated_db, None)
        assert user_usage.ensure_subscription_usage_counter_started_at() is None
        assert user_usage.ensure_subscription_usage_counter_started_at() is None

    assert marker.create.call_count == 2
    assert isolated_db not in user_usage._usage_counter_started_at_cache


def test_batch_transcription_reservation_rejects_monthly_overshoot():
    from database import user_usage

    event = mock.Mock()
    event.get.return_value = SimpleNamespace(exists=False)
    hour = mock.Mock()
    hourly = mock.Mock()
    hourly.document.return_value = hour
    month = mock.Mock()
    month.get.return_value = SimpleNamespace(
        exists=True,
        to_dict=lambda: {'transcription_seconds': 17_500},
    )
    monthly = mock.Mock()
    monthly.document.return_value = month
    events = mock.Mock()
    events.document.return_value = event
    user = mock.Mock()
    user.collection.side_effect = lambda name: {
        'usage_events': events,
        'hourly_usage': hourly,
        'monthly_usage': monthly,
    }[name]
    transaction = mock.Mock()
    marker = mock.Mock()
    marker.get.return_value = SimpleNamespace(
        exists=True,
        to_dict=lambda: {'started_at': datetime(2026, 9, 21, tzinfo=timezone.utc)},
    )

    with mock.patch.object(user_usage, '_get_user_ref', return_value=user), \
            mock.patch.object(user_usage, '_usage_counter_state_ref', return_value=marker), \
            mock.patch.object(user_usage.db, 'transaction', return_value=transaction), \
            mock.patch.object(user_usage.firestore, 'transactional', side_effect=lambda function: function):
        allowed = user_usage.reserve_transcription_usage_once(
            'user', 'audio-upload:new-conversation', 600,
            limit_seconds=18_000, developer_id='developer',
            occurred_at=datetime(2026, 10, 1, 0, 0, tzinfo=timezone.utc),
        )

    assert allowed is False
    transaction.set.assert_not_called()


def test_concurrent_batch_reservations_serialize_in_firestore(store):
    from database import user_usage

    user_ref = store.db.collection('developer_data').document('quota-dev').collection('users').document('quota-user')
    occurred_at = datetime(2026, 10, 1, 0, 0, tzinfo=timezone.utc)

    def reserve(event_id):
        return user_usage.reserve_transcription_usage_once(
            'quota-user', event_id, 10_000,
            limit_seconds=18_000, developer_id='quota-dev', occurred_at=occurred_at,
            reservation_owner=event_id,
        )

    with mock.patch.object(user_usage, 'db', store.db):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(reserve, ('upload-a', 'upload-b')))
        assert sorted(results) == [False, True]
        assert user_usage.get_monthly_usage_stats(
            'quota-user', occurred_at, developer_id='quota-dev'
        )['transcription_seconds'] == 10_000
        reserved_event = 'upload-a' if results[0] else 'upload-b'
        assert user_usage.reserve_transcription_usage_once_result(
            'quota-user', reserved_event, 10_000,
            limit_seconds=18_000, developer_id='quota-dev', occurred_at=occurred_at,
        ) == 'duplicate'
        assert user_usage.release_transcription_usage_once(
            'quota-user', reserved_event, developer_id='quota-dev', reservation_owner=reserved_event,
        ) is True
        assert user_usage.release_transcription_usage_once(
            'quota-user', reserved_event, developer_id='quota-dev', reservation_owner=reserved_event,
        ) is False
        assert user_usage.get_monthly_usage_stats(
            'quota-user', occurred_at, developer_id='quota-dev'
        )['transcription_seconds'] == 0
        assert user_usage.reserve_transcription_usage_once(
            'quota-user', 'upload-with-missing-hour', 600,
            limit_seconds=18_000, developer_id='quota-dev', occurred_at=occurred_at,
            reservation_owner='missing-hour-owner',
        ) is True
        user_ref.collection('hourly_usage').document('2026-10-01-00').delete()
        assert user_usage.release_transcription_usage_once(
            'quota-user', 'upload-with-missing-hour', developer_id='quota-dev',
            reservation_owner='missing-hour-owner',
        ) is True
        assert user_usage.get_monthly_usage_stats(
            'quota-user', occurred_at, developer_id='quota-dev'
        )['transcription_seconds'] == 0
        assert user_usage.get_monthly_transcription_seconds(
            'quota-user', occurred_at, developer_id='quota-dev'
        ) == 0

    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_stale_batch_reservation_can_be_reclaimed_without_double_counting(store):
    from database import user_usage

    occurred_at = datetime(2026, 10, 1, 0, 0, tzinfo=timezone.utc)
    user_ref = store.db.collection('developer_data').document('stale-dev').collection('users').document('stale-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.reserve_transcription_usage_once_result(
            'stale-user', 'stale-upload', 600,
            limit_seconds=18_000, developer_id='stale-dev', occurred_at=occurred_at,
        ) == 'recorded'
        assert user_usage.reserve_transcription_usage_once_result(
            'stale-user', 'stale-upload', 600,
            limit_seconds=18_000, developer_id='stale-dev',
            occurred_at=occurred_at + user_usage.TRANSCRIPTION_RESERVATION_STALE_AFTER - timedelta(seconds=1),
        ) == 'duplicate'
        assert user_usage.reserve_transcription_usage_once_result(
            'stale-user', 'stale-upload', 600,
            limit_seconds=18_000, developer_id='stale-dev',
            occurred_at=occurred_at + user_usage.TRANSCRIPTION_RESERVATION_STALE_AFTER,
            reservation_owner='reclaimed-owner',
        ) == 'recorded'
        assert user_usage.get_monthly_transcription_seconds(
            'stale-user', occurred_at, developer_id='stale-dev'
        ) == 600
        assert user_usage.release_transcription_usage_once(
            'stale-user', 'stale-upload', developer_id='stale-dev', reservation_owner='reclaimed-owner',
        ) is True
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_stale_batch_reservation_keeps_charge_when_account_is_over_limit(store):
    from database import user_usage

    occurred_at = datetime(2026, 10, 1, 0, 0, tzinfo=timezone.utc)
    user_ref = store.db.collection('developer_data').document('stale-limit-dev').collection('users').document('stale-limit-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.reserve_transcription_usage_once(
            'stale-limit-user', 'stale-limit-upload', 600,
            limit_seconds=18_000, developer_id='stale-limit-dev', occurred_at=occurred_at,
            reservation_owner='live-owner',
        ) is True
        user_usage.update_hourly_usage(
            'stale-limit-user', occurred_at, {'transcription_seconds': 17_401},
            developer_id='stale-limit-dev',
        )
        assert user_usage.reserve_transcription_usage_once_result(
            'stale-limit-user', 'stale-limit-upload', 600,
            limit_seconds=18_000, developer_id='stale-limit-dev',
            occurred_at=occurred_at + user_usage.TRANSCRIPTION_RESERVATION_STALE_AFTER,
            reservation_owner='retry-owner',
        ) == 'recorded'
        assert user_usage.get_monthly_transcription_seconds(
            'stale-limit-user', occurred_at, developer_id='stale-limit-dev'
        ) == 18_001
        assert user_usage.release_transcription_usage_once(
            'stale-limit-user', 'stale-limit-upload', developer_id='stale-limit-dev',
            reservation_owner='retry-owner',
        ) is True
        assert user_usage.release_transcription_usage_once(
            'stale-limit-user', 'stale-limit-upload', developer_id='stale-limit-dev',
            reservation_owner='live-owner',
        ) is False
        assert user_usage.get_monthly_transcription_seconds(
            'stale-limit-user', occurred_at, developer_id='stale-limit-dev'
        ) == 17_401
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_stale_reservation_keeps_original_month_charge(store):
    from database import user_usage

    september = datetime(2026, 9, 20, tzinfo=timezone.utc)
    november = datetime(2026, 11, 1, tzinfo=timezone.utc)
    user_ref = store.db.collection('developer_data').document('move-dev').collection('users').document('move-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.record_transcription_usage_once(
            'move-user', 'move-upload', 600,
            developer_id='move-dev', occurred_at=september,
        ) is True
        assert user_usage.reserve_transcription_usage_once_result(
            'move-user', 'move-upload', 600,
            limit_seconds=18_000, developer_id='move-dev', occurred_at=november,
            reservation_owner='move-owner',
        ) == 'recorded'
        assert user_ref.collection('monthly_usage').document('2026-09').get().to_dict()['transcription_seconds'] == 600
        assert user_usage.get_monthly_transcription_seconds(
            'move-user', november, developer_id='move-dev'
        ) == 0
        assert user_usage.release_transcription_usage_once(
            'move-user', 'move-upload', developer_id='move-dev', reservation_owner='move-owner',
        ) is True

    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_completed_sync_repair_keeps_original_reservation_month(store):
    from database import user_usage
    from utils import subscription

    september = datetime(2026, 9, 30, 23, 59, tzinfo=timezone.utc)
    event_id = 'sync-cross-month-repair'
    user_ref = store.db.collection('developer_data').document('repair-dev').collection('users').document('repair-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.record_transcription_usage_once(
            'repair-user', event_id, 600,
            developer_id='repair-dev', occurred_at=september, reservation_owner='expired',
        ) is True
        assert user_usage.release_transcription_usage_once(
            'repair-user', event_id, developer_id='repair-dev', reservation_owner='expired',
        ) is True
        subscription.commit_transcription_credits_developer(
            'repair-dev', 'repair-user', event_id, 600, occurred_at=september,
        )
        assert user_ref.collection('monthly_usage').document('2026-09').get().to_dict()['transcription_seconds'] == 600
        assert not user_ref.collection('monthly_usage').document('2026-10').get().exists

    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_only_reservation_owner_can_refund_sync_usage(store):
    from database import user_usage

    occurred_at = datetime(2026, 10, 1, tzinfo=timezone.utc)
    user_ref = store.db.collection('developer_data').document('owner-dev').collection('users').document('owner-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.record_transcription_usage_once(
            'owner-user', 'sync-upload', 600,
            developer_id='owner-dev', occurred_at=occurred_at, reservation_owner='attempt-a',
        ) is True
        assert user_usage.release_transcription_usage_once(
            'owner-user', 'sync-upload', developer_id='owner-dev', reservation_owner='attempt-b',
        ) is False
        assert user_usage.release_transcription_usage_once(
            'owner-user', 'sync-upload', developer_id='owner-dev', reservation_owner='attempt-a',
        ) is True

    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_expired_upload_owner_cannot_refund_new_upload_lease(store):
    from database import user_usage

    occurred_at = datetime(2026, 10, 1, tzinfo=timezone.utc)
    metadata = {
        'developer_id': 'lease-dev',
        'uid': 'lease-user',
        'source': 'audio_upload',
        'started_at': occurred_at.isoformat(),
        'language': 'auto',
        'duration_seconds': 0,
        'auto_process': True,
        'use_vad': True,
    }
    _, first_token = store.reserve('lease-race-job', metadata)
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.record_transcription_usage_once(
            'lease-user',
            'audio-upload:lease-race-job',
            600,
            developer_id='lease-dev',
            occurred_at=occurred_at,
            reservation_owner='first-request',
        ) is True
        store.collection.document('lease-race-job').update({'upload_until': 0})
        _, second_token = store.reserve('lease-race-job', metadata)
        assert second_token != first_token
        assert user_usage.release_transcription_usage_once(
            'lease-user',
            'audio-upload:lease-race-job',
            developer_id='lease-dev',
            reservation_owner='first-request',
            upload_job_id='lease-race-job',
            upload_token=first_token,
            job_collection=store.collection.id,
        ) is False
        assert user_usage.get_monthly_transcription_seconds(
            'lease-user', occurred_at, developer_id='lease-dev'
        ) == 600

    user_ref = store.db.collection('developer_data').document('lease-dev').collection('users').document('lease-user')
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_committed_sync_usage_cannot_be_refunded_by_stale_cleanup(store):
    from database import user_usage

    occurred_at = datetime(2026, 10, 1, tzinfo=timezone.utc)
    upload_job_id = '00000000-0000-4000-8000-000000000321'
    usage_event_id = 'audio-upload:stable-recording-identity'
    _, token = store.reserve(upload_job_id, {
        'developer_id': 'sync-dev', 'uid': 'sync-user', 'source': 'audio_upload',
        'started_at': occurred_at.isoformat(), 'language': 'auto', 'duration_seconds': 0,
        'auto_process': True, 'use_vad': True, 'is_root': False,
        'usage_event_id': usage_event_id,
    })
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.record_transcription_usage_once(
            'sync-user', usage_event_id, 600,
            developer_id='sync-dev', occurred_at=occurred_at, reservation_owner=token,
        ) is True
        store.commit_upload_usage(upload_job_id, token)
        assert user_usage.release_transcription_usage_once(
            'sync-user', usage_event_id, developer_id='sync-dev', reservation_owner=token,
            upload_job_id=upload_job_id, upload_token=token, job_collection=store.collection.id,
        ) is False
        assert user_usage.get_monthly_transcription_seconds(
            'sync-user', occurred_at, developer_id='sync-dev'
        ) == 600

    store.discard_upload(upload_job_id, token)
    user_ref = store.db.collection('developer_data').document('sync-dev').collection('users').document('sync-user')
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_incomplete_month_records_usage_without_false_quota_rejection(store):
    from database import user_usage

    occurred_at = datetime(2026, 9, 20, 0, 0, tzinfo=timezone.utc)
    user_ref = store.db.collection('developer_data').document('baseline-dev').collection('users').document('baseline-user')
    with mock.patch.object(user_usage, 'db', store.db), \
            mock.patch.object(user_usage, 'subscription_counter_covers_month', return_value=False):
        user_usage.update_hourly_usage(
            'baseline-user', occurred_at, {'transcription_seconds': 17_900},
            developer_id='baseline-dev',
        )
        assert user_usage.get_monthly_transcription_seconds(
            'baseline-user', occurred_at, developer_id='baseline-dev'
        ) == 17_900
        assert user_usage.reserve_transcription_usage_once_result(
            'baseline-user', 'too-large', 200,
            limit_seconds=18_000, developer_id='baseline-dev', occurred_at=occurred_at,
        ) == 'recorded_unenforced'

    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_failed_job_refund_is_fenced_against_manual_retry(store):
    from database import user_usage

    occurred_at = datetime(2026, 10, 1, tzinfo=timezone.utc)
    job_id = '00000000-0000-4000-8000-000000000123'
    event_id = f'audio-upload:{job_id}'
    job_ref = store.collection.document(job_id)
    user_ref = store.db.collection('developer_data').document('fence-dev').collection('users').document('fence-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.reserve_transcription_usage_once(
            'fence-user', event_id, 600,
            limit_seconds=18_000, developer_id='fence-dev', occurred_at=occurred_at,
        ) is True
        job_ref.set({
            'id': job_id,
            'developer_id': 'fence-dev',
            'uid': 'fence-user',
            'status': 'failed',
            'stage': 'transcribe',
            'updated_at': occurred_at.timestamp() + 10,
        })
        assert user_usage.release_transcription_usage_once(
            'fence-user', event_id, developer_id='fence-dev', failed_job_id=job_id,
            job_collection=store.collection.id,
        ) is True

        assert user_usage.reserve_transcription_usage_once(
            'fence-user', event_id, 600,
            limit_seconds=18_000, developer_id='fence-dev', occurred_at=occurred_at + timedelta(seconds=20),
            reservation_owner='retry-owner',
        ) is True
        assert user_usage.release_transcription_usage_once(
            'fence-user', event_id, developer_id='fence-dev', failed_job_id=job_id,
            job_collection=store.collection.id,
        ) is False
        job_ref.update({'status': 'queued'})
        assert user_usage.release_transcription_usage_once(
            'fence-user', event_id, developer_id='fence-dev', failed_job_id=job_id,
            job_collection=store.collection.id,
        ) is False
        assert user_usage.release_transcription_usage_once(
            'fence-user', event_id, developer_id='fence-dev', reservation_owner='retry-owner',
        ) is True

    job_ref.delete()
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_manual_retry_guard_blocks_concurrent_failed_job_refund(store):
    from database import user_usage

    occurred_at = datetime.now(timezone.utc)
    guard_until = occurred_at + timedelta(minutes=2)
    job_id = '00000000-0000-4000-8000-000000000124'
    event_id = f'audio-upload:{job_id}'
    job_ref = store.collection.document(job_id)
    user_ref = store.db.collection('developer_data').document('guard-dev').collection('users').document('guard-user')
    with mock.patch.object(user_usage, 'db', store.db):
        assert user_usage.record_transcription_usage_once(
            'guard-user', event_id, 600,
            developer_id='guard-dev', occurred_at=occurred_at,
            reservation_owner='original-owner',
        ) is True
        job_ref.set({
            'id': job_id,
            'developer_id': 'guard-dev',
            'uid': 'guard-user',
            'status': 'failed',
            'stage': 'transcribe',
            'updated_at': occurred_at.timestamp() + 10,
        })
        assert user_usage.reserve_transcription_usage_once_result(
            'guard-user', event_id, 600,
            limit_seconds=18_000, developer_id='guard-dev', occurred_at=occurred_at + timedelta(seconds=20),
            reservation_owner='manual-retry', refund_guard_until=guard_until,
        ) == 'duplicate'
        assert user_usage.release_transcription_usage_once(
            'guard-user', event_id, developer_id='guard-dev', failed_job_id=job_id,
            job_collection=store.collection.id,
        ) is False
        assert user_usage.release_transcription_usage_once(
            'guard-user', event_id, developer_id='guard-dev', reservation_owner='original-owner',
        ) is True

    job_ref.delete()
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_pre_boundary_month_counter_stays_non_authoritative(store):
    from database import user_usage

    occurred_at = datetime(2026, 9, 20, 0, 0, tzinfo=timezone.utc)
    user_ref = store.db.collection('developer_data').document('pro-dev').collection('users').document('pro-user')
    with mock.patch.object(user_usage, 'db', store.db), \
            mock.patch.object(user_usage, 'subscription_counter_covers_month', return_value=False):
        user_usage.update_hourly_usage(
            'pro-user', occurred_at - timedelta(hours=1), {'transcription_seconds': 400},
            developer_id='pro-dev',
        )
        assert user_usage.record_transcription_usage_once(
            'pro-user', 'pro-upload', 200,
            developer_id='pro-dev', occurred_at=occurred_at,
        ) is True
        month = user_ref.collection('monthly_usage').document('2026-09').get().to_dict()
        assert month.get('counter_complete') is not True
        assert month['transcription_seconds'] == 600
        assert user_usage.get_monthly_transcription_seconds(
            'pro-user', occurred_at, developer_id='pro-dev'
        ) == 600

    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    user_ref.delete()


def test_historical_batch_writer_filters_authoritative_months(store):
    from database import user_usage

    with mock.patch.object(user_usage, 'db', store.db):
        user_usage.batch_update_hourly_usage(
            'user',
            {
                datetime(2026, 9, 30, 23, tzinfo=timezone.utc): {'transcription_seconds': 30},
                datetime(2026, 10, 1, tzinfo=timezone.utc): {'transcription_seconds': 60},
            },
        )
    usage = store.db.collection('users').document('user').collection('hourly_usage')
    assert usage.document('2026-09-30-23').get().exists
    assert not usage.document('2026-10-01-00').get().exists
    for snapshot in usage.stream():
        snapshot.reference.delete()
    store.db.collection('users').document('user').delete()


def test_historical_batch_writer_fails_closed_without_valid_boundary(store):
    from database import user_usage

    with mock.patch.object(user_usage, 'db', store.db), \
            mock.patch.object(user_usage, 'subscription_enforcement_start_at_utc', return_value=None):
        with pytest.raises(ValueError, match='valid subscription enforcement start'):
            user_usage.batch_update_hourly_usage(
                'user',
                {datetime(2026, 9, 30, 23, tzinfo=timezone.utc): {'transcription_seconds': 30}},
            )

    usage = store.db.collection('users').document('user').collection('hourly_usage')
    assert list(usage.stream()) == []


def test_realtime_quota_state_reuses_single_monthly_document(store):
    from database import user_usage

    month_ref = (
        store.db.collection('developer_data')
        .document('quota-state-dev')
        .collection('users')
        .document('quota-state-user')
        .collection('monthly_usage')
        .document('2026-10')
    )
    month_ref.set({'counter_complete': True, 'transcription_seconds': 1234})
    with mock.patch.object(user_usage, 'db', store.db), \
            mock.patch.object(
                user_usage,
                'ensure_subscription_usage_counter_started_at',
                side_effect=AssertionError('complete monthly document must not read the global marker'),
            ):
        assert user_usage.get_monthly_transcription_quota_state(
            'quota-state-user',
            datetime(2026, 10, 15, tzinfo=timezone.utc),
            developer_id='quota-state-dev',
        ) == (True, 1234)
    month_ref.delete()


class DiskArtifacts:
    def __init__(self, root):
        self.root = root
        self.downloads = 0
    def download_audio(self, audio, path):
        self.downloads += 1
        open(path, 'wb').write(b'synthetic')
    def put(self, job_id, token, name, value):
        import json
        path = self.root / f'{job_id}-{token}-{name}.json'
        path.write_text(json.dumps(value, default=str))
        return {'path': str(path)}
    def get(self, ref):
        import json
        return json.loads(open(ref['path']).read())
    def ensure_playback(self, job):
        return 'audio.wav'


class CountingSoniox:
    def __init__(self):
        self.calls = 0
    def transcribe(self, path, language, cp, save):
        self.calls += 1
        save({'soniox_transcription_id': 'remote-task'})
        return {'segments': [], 'language': 'en'}


class TestPipeline(Pipeline):
    __test__ = False
    fail_stage = None
    def validate(self, job, path):
        if self.fail_stage == 'validate':
            raise state.JobFailure('no_speech', retryable=False)
    def attribute(self, job, transcript):
        if self.fail_stage == 'speakers':
            raise ConnectionError('synthetic')
    def summarize(self, job):
        if self.fail_stage == 'summarize':
            raise ConnectionError('synthetic')
        return Conversation(id=job['id'], source=ConversationSource.audio_upload,
                            created_at=datetime.now(timezone.utc), started_at=datetime.fromisoformat(job['started_at']),
                            finished_at=datetime.now(timezone.utc), status=ConversationStatus.completed, transcript_segments=[],
                            structured=Structured(title='Synthetic', overview='Test'))


@pytest.mark.parametrize('stage', ['speakers', 'summarize', 'publish'])
def test_resume_stage_does_not_repeat_completed_stt(store, tmp_path, stage):
    job = accepted(store)
    artifacts = DiskArtifacts(tmp_path)
    soniox = CountingSoniox()
    pipeline = TestPipeline(store, artifacts, soniox)
    pipeline.fail_stage = stage
    original = artifacts.ensure_playback
    if stage == 'publish':
        artifacts.ensure_playback = lambda _: (_ for _ in ()).throw(ConnectionError())
    current = store.claim(job['id'], 'first')
    with pytest.raises(ConnectionError):
        pipeline(current, 'first')
    store.fail(job['id'], 'first', state.JobFailure('synthetic'))
    assert store.get(job['id'])['stage'] == stage
    store.now[0] += 601
    pipeline.fail_stage = None
    artifacts.ensure_playback = original
    pipeline(store.claim(job['id'], 'second'), 'second')
    assert soniox.calls == 1
    assert artifacts.downloads == 1
    assert store.get(job['id'])['status'] == 'completed'
    assert {child['stage'] for child in store.followups(job['id'])} >= {'timeline', 'provider_cleanup', 'webhooks'}
    store.db.collection('developer_data').document('test-dev').collection('users').document('user').collection('conversations').document(job['id']).delete()


def test_no_speech_never_calls_transcription(store, tmp_path):
    job = accepted(store)
    soniox = CountingSoniox()
    pipeline = TestPipeline(store, DiskArtifacts(tmp_path), soniox)
    pipeline.fail_stage = 'validate'
    with pytest.raises(state.JobFailure, match='no_speech'):
        pipeline(store.claim(job['id'], 'one'), 'one')
    assert soniox.calls == 0


def test_provider_cleanup_tolerates_deleted_parent(store, tmp_path):
    from unittest.mock import Mock
    provider = Mock()
    Pipeline(store, DiskArtifacts(tmp_path), provider).followup(
        {'parent_id': 'deleted-parent', 'stage': 'provider_cleanup'}, 'token', lambda _: None)
    provider.cleanup.assert_not_called()


def test_each_transcription_chunk_has_a_bounded_retry_budget(store, tmp_path, monkeypatch):
    from utils import audio_upload_media as media
    from utils.audio_jobs.soniox import Soniox
    from test_long_audio import sparse_wav

    source = sparse_wav(tmp_path / 'source.wav', 8, rate=10)
    split = media.transcription_chunks
    monkeypatch.setattr(media, 'needs_transcription_chunks', lambda _: True)
    monkeypatch.setattr(media, 'transcription_chunks', lambda path: split(path, chunk_seconds=2))
    provider = Soniox()
    timed_out = set()

    def transcribe_one(path, language, checkpoint, save, *, chunk):
        index = int(chunk.core_start_seconds / 2)
        if index not in timed_out:
            timed_out.add(index)
            raise state.JobFailure('provider_timeout')
        return {'segments': [{'text': str(index), 'speaker': '1', 'start': index * 2,
                              'end': index * 2 + 1, 'is_user': False}], 'language': 'en'}

    monkeypatch.setattr(provider, '_transcribe_one', transcribe_one)
    job_id = accepted(store)['id']
    for attempt in range(5):
        job = store.claim(job_id, 'worker')
        assert job is not None
        store.checkpoint(job_id, 'worker', {}, 'transcribe') if attempt == 0 else None
        def save(values, next_stage=None):
            store.checkpoint(job_id, 'worker', values, next_stage)
        try:
            result = provider.transcribe(source, 'auto', job['checkpoints'], save)
        except state.JobFailure as error:
            store.fail(job_id, 'worker', error)
            job = store.get(job_id)
            assert job['status'] == 'retry_wait'
            store.now[0] = job['next_attempt_at']
        else:
            assert attempt == 4
            assert len(result['segments']) == 4
            break
    else:
        pytest.fail('long transcription did not resume all four parts')

    # A subsequent chunk that never finishes must still exhaust its budget;
    # re-reading completed parts cannot grant unlimited retries.
    cp = store.get(job_id)['checkpoints']
    cp['soniox_chunks']['3'].pop('completed')
    store.checkpoint(job_id, 'worker', cp)
    def stalled(path, language, checkpoint, save, *, chunk):
        if chunk.core_start_seconds == 6:
            raise state.JobFailure('provider_timeout')
        return transcribe_one(path, language, checkpoint, save, chunk=chunk)
    monkeypatch.setattr(provider, '_transcribe_one', stalled)
    while True:
        job = store.get(job_id)
        with pytest.raises(state.JobFailure) as error:
            provider.transcribe(source, 'auto', job['checkpoints'], save)
        store.fail(job_id, 'worker', error.value)
        job = store.get(job_id)
        if job['status'] == 'failed':
            assert job['stage_attempts'] == state.MAX_ATTEMPTS
            break
        store.now[0] = job['next_attempt_at']
        assert store.claim(job_id, 'worker') is not None
