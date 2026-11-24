"""Exercise worker publication through the actual conversation response contract.

Only select dependency-free definitions from the API/database modules, avoiding
their production credential and LLM initialization. Firestore publication,
read normalization, FastAPI response validation and serialization are real.
"""
import ast
import copy
import json
import zlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import BaseModel

from test_audio_jobs import accepted, store
from models.conversation import Conversation, ConversationSource, ConversationStatus, Structured


def load_definitions(path, names):
    namespace = dict(globals())
    tree = ast.parse(path.read_text())
    nodes = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names]
    assert {node.name for node in nodes} == set(names)
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace


BACKEND = Path(__file__).resolve().parents[1]
Response = load_definitions(BACKEND / 'routers/developer_conversations.py', ['ConversationResponse'])['ConversationResponse']
prepare = load_definitions(BACKEND / 'database/developer_data.py',
                           ['_normalize_transcript_segments', '_prepare_conversation_for_read'])['_prepare_conversation_for_read']


def conversation(job_id='synthetic'):
    return Conversation(id=job_id, created_at=datetime(2026, 9, 19, tzinfo=timezone.utc),
                        started_at=datetime(2026, 9, 18, tzinfo=timezone.utc),
                        finished_at=datetime(2026, 9, 18, 0, 1, tzinfo=timezone.utc),
                        source=ConversationSource.audio_upload, status=ConversationStatus.completed,
                        language='en', structured=Structured(title='Synthetic', overview='Test'),
                        transcript_segments=[]).model_dump()


def client_for(data):
    app = FastAPI()

    @app.get('/v1/conversations', response_model=List[Response])
    def listing():
        return [prepare(data)]

    @app.get('/v1/conversations/synthetic', response_model=Response)
    def detail():
        return prepare(data)

    return TestClient(app, raise_server_exceptions=False)


def test_worker_publication_is_readable_by_list_and_detail(store):
    job = accepted(store)
    store.claim(job['id'], 'worker')
    store.publish(job['id'], 'worker', conversation(job['id']), ['timeline'])
    ref = store.db.collection('developer_data').document('test-dev').collection('users').document('user').collection('conversations').document(job['id'])
    try:
        saved = ref.get().to_dict()
        assert saved.get('updated_at') == datetime.fromtimestamp(store.clock(), timezone.utc)
        client = client_for(saved)
        for path in ['/v1/conversations', '/v1/conversations/synthetic']:
            response = client.get(path)
            assert response.status_code == 200
            body = response.json()
            item = body[0] if isinstance(body, list) else body
            assert item['id'] == job['id']
            assert item['status'] == 'completed'
            assert item['discarded'] is False
    finally:
        ref.delete()


def test_publication_does_not_replace_existing_conversation_or_timestamp(store):
    job = accepted(store)
    store.claim(job['id'], 'worker')
    ref = store.db.collection('developer_data').document('test-dev').collection('users').document('user').collection('conversations').document(job['id'])
    existing = conversation(job['id'])
    existing['updated_at'] = datetime(2026, 9, 20, tzinfo=timezone.utc)
    existing['structured']['title'] = 'User edit'
    ref.set(existing)
    try:
        store.publish(job['id'], 'worker', conversation(job['id']), ['timeline'])
        assert ref.get().to_dict() == existing
    finally:
        ref.delete()


@pytest.mark.parametrize('timestamp', ['missing', None, datetime(2026, 9, 20, tzinfo=timezone.utc)])
def test_legacy_timestamp_fallback_is_stable_and_preserves_existing_value(timestamp):
    data = conversation()
    if timestamp != 'missing':
        data['updated_at'] = timestamp
    before = copy.deepcopy(data)
    expected = timestamp if isinstance(timestamp, datetime) else data['created_at']
    client = client_for(data)
    for path in ['/v1/conversations', '/v1/conversations/synthetic']:
        response = client.get(path)
        assert response.status_code == 200
        body = response.json()
        item = body[0] if isinstance(body, list) else body
        assert datetime.fromisoformat(item['updated_at'].replace('Z', '+00:00')) == expected
    assert data == before


def test_legacy_nonempty_transcript_uses_real_speaker_normalization():
    data = conversation()
    data['transcript_segments'] = [{'text': ' Synthetic speech ', 'speaker_id': 'SPEAKER_01',
                                  'start': 0.0, 'end': 1.0}]
    before = copy.deepcopy(data)
    response = client_for(data).get('/v1/conversations')
    assert response.status_code == 200
    segment = response.json()[0]['transcript_segments'][0]
    assert segment['speaker_id'] == 1
    assert segment['text'] == 'Synthetic speech'
    assert data == before
