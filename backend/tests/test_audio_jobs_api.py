import importlib
import sys
import types

import pytest
from fastapi import FastAPI, Header, HTTPException
from fastapi.testclient import TestClient
from google.cloud import firestore

from test_audio_jobs import store, accepted
from utils.audio_jobs import state
from utils.audio_jobs.state import JobConflict
from utils.subscription import UsageReservation


@pytest.fixture
def client(store, monkeypatch):
    # Replace only credential verification. Real FastAPI routing, serialization,
    # owner checks, transactions and Firestore queries still execute.
    def user(authorization: str = Header(None)):
        if authorization == 'owner':
            return ('test-dev', 'user')
        if authorization == 'other':
            return ('test-dev', 'other')
        if authorization == 'other-tenant':
            return ('other-dev', 'user')
        raise HTTPException(401)
    auth = types.ModuleType('utils.other.endpoints')
    auth.get_current_user_context = user
    monkeypatch.setitem(sys.modules, 'utils.other.endpoints', auth)
    import utils.other
    monkeypatch.setattr(utils.other, 'endpoints', auth, raising=False)
    sys.modules.pop('routers.audio_jobs', None)
    routes = importlib.import_module('routers.audio_jobs')
    monkeypatch.setattr(routes, 'JobStore', lambda: store)
    from database import user_usage
    monkeypatch.setattr(user_usage, 'db', store.db)
    app = FastAPI()
    app.include_router(routes.router)
    yield TestClient(app)
    user_ref = store.db.collection('developer_data').document('test-dev').collection('users').document('user')
    for collection_name in ('hourly_usage', 'monthly_usage', 'usage_events'):
        for snapshot in user_ref.collection(collection_name).stream():
            snapshot.reference.delete()
    sys.modules.pop('routers.audio_jobs', None)


def test_authentication_and_cross_tenant_isolation(store, client):
    job = accepted(store)
    path = f"/v1/audio-jobs/{job['id']}"
    assert client.get(path).status_code == 401
    for auth in ('other', 'other-tenant'):
        assert client.get(path, headers={'Authorization': auth}).status_code == 404
        assert client.post(path + '/retry', headers={'Authorization': auth}).status_code == 404
        assert client.get('/v1/audio-jobs', headers={'Authorization': auth}).json()['items'] == []
    assert client.get(path, headers={'Authorization': 'owner'}).json()['status'] == 'queued'


def test_active_jobs_include_old_retries_but_not_terminal_uploads_or_followups(store, client):
    old = accepted(store)
    store.collection.document(old['id']).update({'status': 'retry_wait', 'created_at': 1})
    running = accepted(store)
    store.claim(running['id'], 'lease')
    queued = accepted(store)
    template = store.get(queued['id'])
    batch = store.db.batch()
    for index in range(60):
        value = dict(template, id=f'finished-{index}', status='completed', created_at=20000 + index)
        batch.set(store.collection.document(value['id']), value)
    for status in ('uploading', 'failed', 'cancelled'):
        value = dict(template, id=status, status=status)
        batch.set(store.collection.document(status), value)
    child = dict(template, id='followup', is_root=False, parent_id=queued['id'])
    batch.set(store.collection.document(child['id']), child)
    batch.commit()
    accepted(store, owner='other')

    path = '/v1/audio-jobs/active'
    assert client.get(path).status_code == 401
    assert client.get(path, headers={'Authorization': 'other-tenant'}).json()['items'] == []
    result = client.get(path, headers={'Authorization': 'owner'})
    assert result.status_code == 200
    assert {job['id'] for job in result.json()['items']} == {old['id'], running['id'], queued['id']}
    store.collection.document(old['id']).update({'status': 'completed'})
    assert old['id'] not in {job['id'] for job in client.get(path, headers={'Authorization': 'owner'}).json()['items']}


def test_failed_task_can_be_retried_without_uploading_audio(store, client):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.checkpoint(job['id'], 'token', {'transcript': {'path': 'saved'}}, 'summarize')
    store.fail(job['id'], 'token', state.JobFailure('provider_unavailable'))
    path = f"/v1/audio-jobs/{job['id']}"
    response = client.post(path + '/retry', headers={'Authorization': 'owner'})
    assert response.status_code == 200
    assert response.json()['stage'] == 'summarize'
    assert store.get(job['id'])['audio']['path'] == 'test.wav'
    assert store.get(job['id'])['checkpoints']['transcript']['path'] == 'saved'
    assert client.post(path + '/retry', headers={'Authorization': 'owner'}).status_code == 409


def test_retry_wait_race_keeps_reservation_for_automatic_worker_retry(store, client, monkeypatch):
    import routers.audio_jobs as routes

    job = accepted(store)
    store.claim(job['id'], 'token')
    store.fail(job['id'], 'token', state.JobFailure('provider_unavailable'))
    monkeypatch.setattr(
        routes,
        'reserve_transcription_credits_developer_result',
        lambda *args, **kwargs: UsageReservation(allowed=True, newly_reserved=True),
    )
    release_mock = lambda *args, **kwargs: pytest.fail('retry_wait reservation must remain charged')
    monkeypatch.setattr(routes, 'release_transcription_credits_developer', release_mock)
    def lose_retry_race(*args, **kwargs):
        raise JobConflict('race')
    monkeypatch.setattr(store, 'retry', lose_retry_race)

    response = client.post(f"/v1/audio-jobs/{job['id']}/retry", headers={'Authorization': 'owner'})

    assert response.status_code == 409
    assert store.get(job['id'])['status'] == 'retry_wait'


def test_legacy_failed_task_without_duration_is_not_misreported_as_missing(store, client):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.fail(job['id'], 'token', state.JobFailure('provider_unavailable'))
    store.collection.document(job['id']).update({'duration_seconds': firestore.DELETE_FIELD})

    response = client.post(f"/v1/audio-jobs/{job['id']}/retry", headers={'Authorization': 'owner'})

    assert response.status_code == 200
    assert response.json()['status'] == 'queued'


def test_failed_task_without_any_duration_requires_reupload(store, client):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.fail(job['id'], 'token', state.JobFailure('provider_unavailable'))
    audio = store.get(job['id'])['audio']
    audio.pop('duration_seconds', None)
    store.collection.document(job['id']).update({
        'duration_seconds': firestore.DELETE_FIELD,
        'audio': audio,
    })

    response = client.post(f"/v1/audio-jobs/{job['id']}/retry", headers={'Authorization': 'owner'})

    assert response.status_code == 409
    assert response.json()['detail'] == 'duration_unavailable_reupload_required'


def test_legacy_null_manual_retry_timestamp_is_retryable(store, client):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.fail(job['id'], 'token', state.JobFailure('provider_unavailable'))
    store.collection.document(job['id']).update({'manual_retry_at': None})

    response = client.post(f"/v1/audio-jobs/{job['id']}/retry", headers={'Authorization': 'owner'})

    assert response.status_code == 200
    assert response.json()['status'] == 'queued'


def test_permanent_failure_and_list_visibility(store, client):
    job = accepted(store)
    store.claim(job['id'], 'token')
    store.fail(job['id'], 'token', state.JobFailure('no_speech', retryable=False))
    value = client.get('/v1/audio-jobs', headers={'Authorization': 'owner'}).json()['items'][0]
    assert value['status'] == 'failed'
    assert value['error_code'] == 'no_speech'
    assert not value['can_retry']
    assert not ({'uid', 'developer_id', 'checkpoints', 'audio'} & value.keys())
    assert client.post(f"/v1/audio-jobs/{job['id']}/retry", headers={'Authorization': 'owner'}).status_code == 409


def test_list_batches_followups_across_query_limit_and_filters_owner(store, client, monkeypatch):
    jobs = [accepted(store) for _ in range(31)]
    for job in jobs:
        store.collection.document('child-' + job['id']).set({
            **job, 'id': 'child-' + job['id'], 'parent_id': job['id'], 'is_root': False,
        })
    store.collection.document('foreign-child').set({
        **jobs[0], 'id': 'foreign-child', 'parent_id': jobs[0]['id'], 'is_root': False,
        'owner_key': 'another-owner',
    })
    queries = []
    original = store.collection.where
    def where(*args, **kwargs):
        condition = kwargs.get('filter')
        if condition.field_path == 'parent_id':
            queries.append(condition)
        return original(*args, **kwargs)
    monkeypatch.setattr(store.collection, 'where', where)
    response = client.get('/v1/audio-jobs?limit=100', headers={'Authorization': 'owner'})
    assert response.status_code == 200
    items = response.json()['items']
    assert len(items) == 31
    assert len(queries) == 2
    for item in items:
        assert [child['id'] for child in item['followups']] == ['child-' + item['id']]
