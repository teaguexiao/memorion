"""Credential-free sharing integration tests: real router, auth and public projection."""
import copy
import sys
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from routers import conversation_shares as routes
from middleware.share_privacy import SharePrivacyMiddleware
from utils.sharing import store as storage
from utils.sharing.content import active, public_content

rate_limit = routes.limit


class Doc:
    def __init__(self, db, path):
        self.db, self.path = db, path

    def collection(self, name):
        return Collection(self.db, self.path + '/' + name)

    def get(self, transaction=None, field_paths=None):
        data = copy.deepcopy(self.db.rows.get(self.path))
        return types.SimpleNamespace(exists=data is not None, to_dict=lambda: data, reference=self)

    def delete(self):
        self.db.rows.pop(self.path, None)

    def update(self, data):
        self.db.rows[self.path].update(data)


class Collection:
    def __init__(self, db, path):
        self.db, self.path = db, path

    def document(self, name):
        return Doc(self.db, self.path + '/' + name)

    def where(self, *, filter):
        self.filter = filter
        return self

    def stream(self):
        return [Doc(self.db, path).get() for path, row in list(self.db.rows.items())
                if path.startswith(self.path + '/') and row.get(self.filter.field_path) == self.filter.value]


class DB:
    def __init__(self):
        self.rows = {}

    def collection(self, name):
        return Collection(self, name)

    def transaction(self):
        return self

    def set(self, ref, row):
        self.rows[ref.path] = copy.deepcopy(row)

    def update(self, ref, fields):
        ref.update(fields)


@pytest.fixture
def setup(monkeypatch):
    monkeypatch.setenv('CONVERSATION_SHARING_ENABLED', 'true')
    monkeypatch.setattr(storage.firestore, 'transactional', lambda fn: fn)
    db = DB()
    store = storage.ShareStore(db)
    now = datetime.now(timezone.utc)
    dev = routes.MEMORION_APP_DEVELOPER_ID
    db.rows[f'developer_data/{dev}'] = {'is_active': True}
    source = {'created_at': now, 'status': 'completed', 'structured': {'title': 'Original', 'overview': 'Long summary\n' * 200},
              'audio_url': 'SECRET-AUDIO', 'photos': [{'url': 'SECRET-PHOTO'}], 'metadata': {'secret': 'PRIVATE'},
              'transcript_segments': [{'speaker_id': 8, 'person_id': 'PRIVATE-PERSON', 'is_user': True,
                                       'text': '<script>alert(1)</script>', 'start': 0, 'end': 7}]}
    for uid in ('alice', 'bob'):
        db.rows[f'developer_data/{dev}/users/{uid}'] = {'created_at': now}
        db.rows[f'developer_data/{dev}/users/{uid}/conversations/conv'] = copy.deepcopy(source)
    monkeypatch.setattr(routes, 'limit', lambda *args: None)
    monkeypatch.setattr(routes, 'firebase_app', lambda: 'test-app')
    def verify(token, **kwargs):
        assert kwargs['check_revoked'] is True
        if token not in ('alice', 'bob'):
            raise ValueError()
        return {'uid': token}
    monkeypatch.setattr(routes.firebase_auth, 'verify_id_token', verify)
    monkeypatch.setattr(routes.firebase_auth, 'get_user', lambda *a, **kw: types.SimpleNamespace(disabled=False))
    developers = types.ModuleType('database.developers')
    developers.get_developer = lambda _: types.SimpleNamespace(is_active=True)
    monkeypatch.setitem(sys.modules, 'database.developers', developers)
    monkeypatch.setattr(routes, 'load_conversation', lambda rec: copy.deepcopy(db.rows.get(
        f'developer_data/{dev}/users/{rec["owner_uid"]}/conversations/{rec["conversation_id"]}')))
    app = FastAPI()
    app.include_router(routes.router)
    app.add_middleware(SharePrivacyMiddleware)
    app.dependency_overrides[routes.get_store] = lambda: store
    return TestClient(app), db, store, dev


def create(client, uid='alice', mode='seven_days', **extra):
    return client.post('/v1/shares', headers={'Authorization': f'Bearer {uid}'}, json={
        'conversation_id': 'conv', 'expiry_mode': mode, 'request_id': str(uuid4()), **extra})


def resolve(client, token):
    return client.post('/v1/share-resolve', headers={'X-Share-Token': token, 'Origin': 'https://memorion.me'})


def test_single_source_full_summary_and_field_allowlist(setup):
    client, db, _, dev = setup
    response = create(client)
    assert response.status_code == 201, response.text
    token = response.json()['url'].split('#')[1]
    shared = resolve(client, token)
    assert shared.status_code == 200
    assert len(shared.json()['overview']) > 2000
    assert set(shared.json()) == {'title', 'overview', 'segments', 'duration_seconds', 'revision', 'expires_at', 'expiry_mode'}
    assert set(shared.json()['segments'][0]) == {'speaker', 'start', 'end', 'text'}
    assert 'SECRET' not in shared.text and 'PRIVATE' not in shared.text
    record = db.rows[f'conversation_shares/{response.json()["id"]}']
    assert token not in str(record) and 'overview' not in record and 'segments' not in record
    before_expiry = shared.json()['expires_at']
    db.rows[f'developer_data/{dev}/users/alice/conversations/conv']['structured'] = {'title': 'Edited', 'overview': 'New summary'}
    updated = resolve(client, token).json()
    assert updated['title'] == 'Edited' and updated['overview'] == 'New summary'
    assert updated['revision'] != shared.json()['revision'] and updated['expires_at'] == before_expiry


def test_owner_isolation_and_shared_keys_rejected(setup):
    client, *_ = setup
    row = create(client).json()
    assert client.post('/v1/shares', headers={'Authorization': 'memorion_dev_prod_embedded'}, json={
        'conversation_id': 'conv', 'expiry_mode': 'never', 'request_id': str(uuid4())}).status_code == 401
    assert create(client, 'expired-or-revoked-firebase-token').status_code == 401
    assert create(client, owner_uid='bob').status_code == 422
    assert client.delete('/v1/shares/' + row['id'], headers={'Authorization': 'Bearer bob'}).status_code == 404
    assert client.post('/v1/shares/' + row['id'] + '/rotate', headers={'Authorization': 'Bearer bob'},
                       json={'request_id': str(uuid4())}).status_code == 404
    assert client.get('/v1/shares?conversation_id=conv', headers={'Authorization': 'Bearer bob'}).json() == []


def test_expiry_rotation_revocation_and_duplicate_click(setup):
    client, db, *_ = setup
    row = create(client, mode='never').json()
    token = row['url'].split('#')[1]
    assert create(client).status_code == 409
    assert resolve(client, token).json()['expires_at'] is None
    rotated = client.post('/v1/shares/' + row['id'] + '/rotate', headers={'Authorization': 'Bearer alice'},
                          json={'request_id': str(uuid4())}).json()
    assert resolve(client, token).status_code == 404
    new_token = rotated['url'].split('#')[1]
    assert resolve(client, new_token).status_code == 200
    for _ in range(2):
        assert client.delete('/v1/shares/' + row['id'], headers={'Authorization': 'Bearer alice'}).status_code == 204
    assert resolve(client, new_token).status_code == 404
    seven = create(client).json()
    doc = db.rows['conversation_shares/' + seven['id']]
    assert doc['expires_at'] - doc['created_at'] == timedelta(days=7)
    doc['expires_at'] = datetime.now(timezone.utc)
    assert resolve(client, seven['url'].split('#')[1]).status_code == 404


@pytest.mark.parametrize('change', ['source_deleted', 'owner_deleted', 'recreated', 'disabled', 'blocked'])
def test_fail_closed_on_source_or_account_changes(setup, monkeypatch, change):
    client, db, _, dev = setup
    row = create(client).json()
    path = f'developer_data/{dev}/users/alice/conversations/conv'
    if change == 'source_deleted': del db.rows[path]
    if change == 'owner_deleted': del db.rows[f'developer_data/{dev}/users/alice']
    if change == 'recreated': db.rows[path]['created_at'] += timedelta(seconds=1)
    if change == 'disabled': monkeypatch.setattr(routes.firebase_auth, 'get_user', lambda *a, **kw: types.SimpleNamespace(disabled=True))
    if change == 'blocked': db.rows['conversation_shares/' + row['id']]['blocked_at'] = datetime.now(timezone.utc)
    assert resolve(client, row['url'].split('#')[1]).status_code == 404


def test_error_headers_cors_token_redaction_and_input_limits(setup):
    client, *_ = setup
    response = resolve(client, 'SECRET-INVALID-TOKEN')
    assert response.status_code == 404 and 'SECRET' not in response.text
    assert response.headers['cache-control'].startswith('private, no-store')
    assert response.headers['access-control-allow-origin'] == 'https://memorion.me'
    assert 'noindex' in response.headers['x-robots-tag']
    bad = client.options('/v1/share-resolve', headers={'Origin': 'https://attacker.test'})
    assert bad.status_code == 403 and 'access-control-allow-origin' not in bad.headers
    good = client.options('/v1/share-resolve', headers={'Origin': 'https://memorion.me', 'Access-Control-Request-Headers': 'x-share-token'})
    assert good.status_code == 204
    assert client.post('/v1/shares', content='x' * 4097).status_code == 413
    assert create(client, mode='one_day').status_code == 422


def test_cleanup_and_report(setup):
    client, db, store, dev = setup
    row = create(client).json()
    token = row['url'].split('#')[1]
    assert client.post('/v1/share-report', headers={'X-Share-Token': token}, json={'reason': 'privacy'}).status_code == 204
    assert db.rows['conversation_shares/' + row['id']]['reports.privacy'] is True
    store.delete_source(dev, 'alice', 'conv')
    assert resolve(client, token).status_code == 404
    row = create(client).json()
    store.delete_owner(dev, 'alice')
    assert resolve(client, row['url'].split('#')[1]).status_code == 404


def test_bad_expiry_never_becomes_permanent():
    now = datetime.now(timezone.utc)
    for row in ({}, {'expiry_mode': 'seven_days'}, {'expiry_mode': 'garbage'}, {'expiry_mode': 'never'}, {'expiry_mode': 'never', 'expires_at': now}):
        assert not active(row, now)
    assert active({'expiry_mode': 'never', 'expires_at': None}, now)


def test_revocation_during_content_load(setup, monkeypatch):
    client, _, store, dev = setup
    row = create(client).json()
    load = routes.load_conversation
    def racing_load(record):
        result = load(record)
        store.revoke(dev, 'alice', row['id'])
        return result
    monkeypatch.setattr(routes, 'load_conversation', racing_load)
    assert resolve(client, row['url'].split('#')[1]).status_code == 404


def test_cross_owner_create_and_disabled_feature(setup, monkeypatch):
    client, db, _, dev = setup
    db.rows[f'developer_data/{dev}/users/bob/conversations/bob-only'] = copy.deepcopy(
        db.rows[f'developer_data/{dev}/users/bob/conversations/conv'])
    assert create(client, conversation_id='bob-only').status_code == 404
    monkeypatch.delenv('CONVERSATION_SHARING_ENABLED')
    assert create(client).status_code == 503
    assert resolve(client, 'invalid').status_code == 503


def test_rate_limit_and_dependency_outage_fail_closed(setup, monkeypatch):
    client, *_ = setup
    row = create(client).json()
    redis = types.ModuleType('database.redis_db')
    def failed(*args):
        raise RuntimeError('DO-NOT-EXPOSE-SECRET')
    redis.r = types.SimpleNamespace(eval=failed)
    monkeypatch.setitem(sys.modules, 'database.redis_db', redis)
    monkeypatch.setattr(routes, 'limit', rate_limit)
    response = resolve(client, row['url'].split('#')[1])
    assert response.status_code == 503 and 'SECRET' not in response.text
    assert 'no-store' in response.headers['cache-control']
    redis.r.eval = lambda *args: 241
    assert resolve(client, row['url'].split('#')[1]).status_code == 429
    monkeypatch.setattr(routes, 'limit', lambda *args: None)
    monkeypatch.setattr(routes, 'load_conversation', failed)
    response = resolve(client, row['url'].split('#')[1])
    assert response.status_code == 503 and 'SECRET' not in response.text
    assert response.headers['access-control-allow-origin'] == 'https://memorion.me'


def test_proxy_limit_trusts_only_configured_peer_and_last_address(monkeypatch):
    from starlette.requests import Request
    keys = []
    monkeypatch.setattr(routes, 'limit', lambda key, *args: keys.append(key))
    monkeypatch.setenv('SHARE_TRUSTED_PROXY_CIDRS', '10.2.0.0/24')
    def check(peer, forwarded):
        routes.network_limit(Request({'type': 'http', 'client': (peer, 123),
            'headers': [(b'x-forwarded-for', forwarded.encode())]}))
    check('10.2.0.5', '1.1.1.1, 203.0.113.9')
    check('203.0.113.10', '1.1.1.1')
    assert keys == ['ip:203.0.113.9', 'ip:203.0.113.10']


def test_missing_firebase_configuration_is_service_failure(setup, monkeypatch):
    client, *_ = setup
    def unavailable():
        raise routes.HTTPException(503, 'Sharing is temporarily unavailable')
    monkeypatch.setattr(routes, 'firebase_app', unavailable)
    assert client.get('/v1/shares?conversation_id=conv', headers={'Authorization': 'Bearer alice'}).status_code == 503
