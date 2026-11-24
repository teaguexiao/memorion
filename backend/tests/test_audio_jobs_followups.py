"""Partial side effects survive worker retries without overwriting user edits."""
import importlib
import sys
import types
import uuid
from datetime import datetime, timezone

import pytest

from test_audio_jobs import store, accepted
from test_audio_jobs_pipeline import DiskArtifacts, CountingSoniox
from utils.audio_jobs.pipeline import Pipeline
from utils.audio_jobs import state
from models.conversation import Conversation, ConversationSource, ConversationStatus, Structured


def install_module(monkeypatch, module):
    """Replace both import caches so test order cannot select the real module."""
    monkeypatch.setitem(sys.modules, module.__name__, module)
    parent_name, attribute = module.__name__.rsplit('.', 1)
    parent = importlib.import_module(parent_name)
    monkeypatch.setattr(parent, attribute, module, raising=False)


def test_people_reuses_non_ascii_name_index(store, tmp_path, monkeypatch):
    job = accepted(store)
    current = store.claim(job['id'], 'token')
    artifacts = DiskArtifacts(tmp_path)
    ref = artifacts.put(job['id'], 'token', 'people', [' Straße '])
    current['checkpoints']['people'] = ref
    processing = types.ModuleType('utils.conversations.process_conversation')
    db = types.ModuleType('database.developer_data')
    db.get_people_name_index = lambda *_: {'straße': 'existing-person'}
    user = types.SimpleNamespace(collection=lambda *_: pytest.fail('Existing person must not be recreated'))
    db._get_user_ref = lambda *_: user
    install_module(monkeypatch, processing)
    install_module(monkeypatch, db)
    Pipeline(store, artifacts, CountingSoniox()).people(current, 'token', lambda _: None, None)


def test_pdp_followup_invalidates_cache_and_propagates_failure(store, tmp_path, monkeypatch):
    from unittest.mock import Mock
    now = datetime.now(timezone.utc)
    conv = Conversation(id=str(uuid.uuid4()), created_at=now, started_at=now, finished_at=now,
                        source=ConversationSource.audio_upload, status=ConversationStatus.completed,
                        structured=Structured(title='Synthetic', overview='Meeting'), transcript_segments=[])
    root = accepted(store)
    child = {**root, 'parent_id': root['id'], 'stage': 'pdp'}
    db = types.ModuleType('database.developer_data')
    db.get_conversation = lambda *_: conv.model_dump()
    db.get_user_timezone = lambda *_: 'UTC'
    processing = types.ModuleType('utils.conversations.process_conversation')
    pdp = types.ModuleType('routers.pdp')
    pdp.invalidate_pdp_cache = Mock()
    for module in (db, processing, pdp):
        install_module(monkeypatch, module)
    pipeline = Pipeline(store, DiskArtifacts(tmp_path), CountingSoniox())
    pipeline.followup(child, 'token', lambda _: None)
    pdp.invalidate_pdp_cache.assert_called_once_with('test-dev', 'user', now.strftime('%Y-%m-%d'))
    pdp.invalidate_pdp_cache.side_effect = ConnectionError('retry cache invalidation')
    with pytest.raises(ConnectionError):
        pipeline.followup(child, 'token', lambda _: None)


@pytest.mark.parametrize('stage', ['memories', 'people'])
def test_partial_followup_reuses_extraction_and_preserves_existing_user_edit(store, tmp_path, monkeypatch, stage):
    owner = 'followup-' + uuid.uuid4().hex
    root = accepted(store, owner=owner)
    store.claim(root['id'], 'publish')
    now = datetime.now(timezone.utc)
    conv = Conversation(id=root['id'], created_at=now, started_at=now, finished_at=now,
                        source=ConversationSource.audio_upload, status=ConversationStatus.completed,
                        structured=Structured(title='Synthetic', overview='Synthetic meeting'), transcript_segments=[])
    store.publish(root['id'], 'publish', conv.dict(), [stage])
    child = store.followups(root['id'])[0]
    user = store.db.collection('developer_data').document('test-dev').collection('users').document(owner)
    calls = []
    processing = types.ModuleType('utils.conversations.process_conversation')
    if stage == 'memories':
        def extract(*args, **kwargs):
            calls.append('extract')
            return [types.SimpleNamespace(dict=lambda content=content: {'content': content, 'category': 'interesting'})
                    for content in ['First fact', 'Second fact']]
        processing.new_memories_extractor = extract
        processing._dedupe_against_stored_facts = lambda *_: (_[-1], [])
    else:
        def extract(*args, **kwargs):
            calls.append('extract')
            return ['Alex', 'Jamie']
        processing.extract_people_from_conversation = extract
    db = types.ModuleType('database.developer_data')
    db.get_user_language = lambda *_: 'en'
    db._get_user_ref = lambda *_: user
    db.PERSON_SOURCE_MENTION = 'mention'
    db.get_people_name_index = lambda *_: {d.to_dict()['name'].lower() for d in user.collection('people').stream()}
    install_module(monkeypatch, processing)
    install_module(monkeypatch, db)
    pipeline = Pipeline(store, DiskArtifacts(tmp_path), CountingSoniox())
    renew = store.renew
    renew_calls = []
    def interrupted(job_id, token):
        renew_calls.append(token)
        if len(renew_calls) == 2:
            raise ConnectionError('Worker interrupted after the first side effect')
        renew(job_id, token)
    monkeypatch.setattr(store, 'renew', interrupted)
    current = store.claim(child['id'], 'first')
    def save(values):
        current.update(store.checkpoint(child['id'], current['lease_token'], values))
    try:
        with pytest.raises(ConnectionError):
            getattr(pipeline, stage)(current, 'first', save, conv)
        items = list(user.collection(stage).stream())
        assert len(items) == 1
        items[0].reference.update({'user_note': 'Preserve my edit'})
        store.fail(child['id'], 'first', state.JobFailure('processing_unavailable'))
        store.now[0] += 601
        current = store.claim(child['id'], 'second')
        monkeypatch.setattr(store, 'renew', renew)
        getattr(pipeline, stage)(current, 'second', save, conv)
        assert calls == ['extract']
        assert len(list(user.collection(stage).stream())) == 2
        assert items[0].reference.get().to_dict()['user_note'] == 'Preserve my edit'
    finally:
        for collection in user.collections():
            for doc in collection.stream(): doc.reference.delete()


def test_webhook_response_checkpoint_loss_replays_same_event_id(store, tmp_path, monkeypatch):
    from utils.audio_jobs.webhooks import deliver
    owner = 'webhook-' + uuid.uuid4().hex
    root = accepted(store, owner=owner)
    store.claim(root['id'], 'publish')
    now = datetime.now(timezone.utc)
    conv = Conversation(id=root['id'], created_at=now, started_at=now, finished_at=now,
                        source=ConversationSource.audio_upload, status=ConversationStatus.completed,
                        structured=Structured(title='Synthetic', overview='Synthetic meeting'), transcript_segments=[])
    store.publish(root['id'], 'publish', conv.dict(), ['webhooks'])
    child = store.followups(root['id'])[0]
    db = types.ModuleType('database.developer_eir_webhooks')
    db.get_active_webhooks_for_event = lambda *_: [{'id': 'synthetic-hook'}]
    db.get_webhook_with_secret = lambda *_: {'status': 'active', 'url': 'https://synthetic.invalid', 'secret': 'test'}
    events = types.ModuleType('utils.developer_eir_events')
    events.create_event_payload = lambda *_: {'id': uuid.uuid4().hex}
    events.should_deliver_event = lambda *_: True
    received = []
    def send(url, secret, payload):
        received.append(payload['id'])
        return True, 200, ''
    events.deliver_webhook = send
    install_module(monkeypatch, db)
    monkeypatch.setitem(sys.modules, events.__name__, events)
    current = store.claim(child['id'], 'first')
    def save(values):
        if current['lease_token'] == 'first' and any(k.startswith('delivered_') for k in values):
            raise ConnectionError('Lost checkpoint after destination accepted event')
        current.update(store.checkpoint(child['id'], current['lease_token'], values))
    artifacts = DiskArtifacts(tmp_path)
    try:
        with pytest.raises(ConnectionError):
            deliver(current, store, artifacts, 'first', save, conv)
        store.fail(child['id'], 'first', state.JobFailure('processing_unavailable'))
        store.now[0] += 601
        current = store.claim(child['id'], 'second')
        deliver(current, store, artifacts, 'second', save, conv)
        assert len(received) == 2 and received[0] == received[1]
        assert any(k.startswith('delivered_') for k in current['checkpoints'])
    finally:
        store.db.collection('developer_data').document('test-dev').collection('users').document(owner).collection('conversations').document(root['id']).delete()
