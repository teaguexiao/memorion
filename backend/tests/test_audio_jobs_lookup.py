"""Receipt recovery uses metadata only; all writes target the local emulator."""
from datetime import datetime, timedelta, timezone

import pytest

from test_audio_jobs import store, accepted
from test_audio_jobs_api import client
from utils.audio_jobs import state


START = datetime(2026, 9, 19, tzinfo=timezone.utc)
KEY = 'soundcore:reinstalled-device:1789776000.ogg'


def lookup(client, *, key=KEY, started_at=START.isoformat(), authorization='owner'):
    return client.post('/v1/audio-jobs/lookup', headers={'Authorization': authorization},
                       json={'recordings': [{'recording_key': key, 'started_at': started_at}]})


@pytest.mark.parametrize('status', ['queued', 'processing', 'retry_wait', 'failed', 'completed'])
@pytest.mark.parametrize('same_device', [False, True])
def test_recovers_accepted_job_without_audio_transfer(store, client, status, same_device):
    job = accepted(store)
    job.update(status=status, discarded=True, retryable=True)
    if same_device:
        store.collection.document(job['id']).delete()
        job['id'] = job['conversation_id'] = state.identity('test-dev', 'user', START.isoformat(), KEY)
    store.collection.document(job['id']).set(job)
    before = store.get(job['id'])
    response = lookup(client, started_at='2026-09-19T08:00:00+08:00')
    assert response.status_code == 200
    item = response.json()['items'][0]
    assert item['can_upload'] is False
    assert item['conversation_id'] == job['id']
    assert item['processing'] is (status != 'completed')
    assert item['job']['status'] == status
    assert item['job']['discarded'] is True
    assert item['duration_seconds'] == 600
    assert not ({'audio', 'checkpoints', 'uid', 'developer_id'} & item['job'].keys())
    assert store.get(job['id']) == before


@pytest.fixture
def legacy(store):
    collection = store.db.collection('developer_data').document('test-dev').collection('users').document('user').collection('conversations')
    refs = []
    def create(**overrides):
        ref = collection.document()
        ref.set({'source': 'audio_upload', 'started_at': START, 'finished_at': START + timedelta(minutes=38),
                 'status': 'completed', 'discarded': True, 'deleted': False, **overrides})
        refs.append(ref)
        return ref.id
    yield create
    for ref in refs:
        ref.delete()


@pytest.mark.parametrize('deleted', [False, True])
def test_legacy_discarded_and_deleted_recordings_are_not_reimported(store, client, legacy, deleted):
    conversation_id = legacy(deleted=deleted)
    response = lookup(client)
    item = response.json()['items'][0]
    assert item['conversation_id'] == conversation_id
    assert item['can_upload'] is False
    assert item['processing'] is False
    assert item['duration_seconds'] == 38 * 60


def test_lookup_requires_auth_and_cannot_recover_another_accounts_receipt(store, client, legacy):
    accepted(store)
    legacy()
    assert lookup(client, authorization='invalid').status_code == 401
    for authorization in ['other', 'other-tenant']:
        item = lookup(client, authorization=authorization).json()['items'][0]
        assert item['can_upload'] is True
        assert 'conversation_id' not in item
        assert 'job' not in item


def test_unknown_file_can_upload_but_active_placeholder_cannot(store, client):
    assert lookup(client).json()['items'][0]['can_upload'] is True
    job_id = state.identity('test-dev', 'user', START.isoformat(), KEY)
    job, _ = store.reserve(job_id, {'developer_id': 'test-dev', 'uid': 'user', 'started_at': START.isoformat()})
    before = store.get(job_id)
    item = lookup(client).json()['items'][0]
    assert item['can_upload'] is False
    assert item['reason'] == 'upload_in_progress'
    assert 'conversation_id' not in item
    assert store.get(job_id) == before
    store.now[0] += 601
    assert lookup(client).json()['items'][0]['can_upload'] is True


def test_lookup_fails_closed_for_conflicting_identity_or_ambiguous_legacy_records(store, client, legacy):
    job = accepted(store)
    key_id = state.identity('test-dev', 'user', START.isoformat(), KEY)
    store.collection.document(key_id).set({**job, 'owner_key': 'another-owner'})
    assert lookup(client).json()['items'][0]['reason'] == 'identity_conflict'
    store.collection.document(key_id).delete()
    accepted(store)
    item = lookup(client).json()['items'][0]
    assert item['can_upload'] is False
    assert item['reason'] == 'ambiguous'
    for ref in store.collection.stream():
        ref.reference.delete()
    legacy()
    legacy()
    item = lookup(client).json()['items'][0]
    assert item['can_upload'] is False
    assert item['reason'] == 'ambiguous'


def test_lookup_batch_is_bounded_and_requires_unique_keys_and_timezone(client):
    item = {'recording_key': KEY, 'started_at': START.isoformat()}
    for recordings in [[], [item, item], [dict(item, recording_key=str(i)) for i in range(21)],
                       [dict(item, started_at='2026-09-19T00:00:00')]]:
        assert client.post('/v1/audio-jobs/lookup', headers={'Authorization': 'owner'},
                           json={'recordings': recordings}).status_code == 422
    recordings = [dict(item, recording_key=str(i), started_at=(START + timedelta(seconds=i)).isoformat()) for i in range(20)]
    response = client.post('/v1/audio-jobs/lookup', headers={'Authorization': 'owner'}, json={'recordings': recordings})
    assert response.status_code == 200
    assert [item['recording_key'] for item in response.json()['items']] == [str(i) for i in range(20)]
    assert all(item['can_upload'] for item in response.json()['items'])
