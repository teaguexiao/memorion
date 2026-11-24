"""Run unchanged router function bodies through FastAPI with isolated storage/STT.

Extracting the entry function avoids importing production credentials and unrelated
LLM/native audio dependencies. The actual receive loop, failure handling, session
persistence and ASGI WebSocket behavior execute; database/network services are mocks.
"""

import ast
import asyncio
import json
import os
import struct
import sys
import threading
import time
import types
import uuid
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional
from unittest.mock import AsyncMock, Mock

import pytest
from fastapi import FastAPI, Query, WebSocket, WebSocketDisconnect
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketState

from utils.stt.stream_lifecycle import SonioxStreamError, finish_soniox_stream, receive_with_stt, report_stt_error
from utils.stt import stream_lifecycle
from utils.stt.timeline import conversation_segments, has_original_timestamps, stream_segment, transcribed_spans
from models.transcript_segment import coerce_speaker_id


class STTService(Enum):
    soniox = 'soniox'
    deepgram = 'deepgram'


@pytest.fixture
def router_client(monkeypatch):
    clients = []

    def create(route, error=None, fail_after_audio=False, startup_failure=False):
        db = Mock()
        finalized = threading.Event()
        def updated(**kwargs):
            if kwargs.get('status') in ('completed', 'failed'):
                finalized.set()
        db.update_listen_session.side_effect = updated
        db.update_talk_session.side_effect = updated
        db.get_listen_session.return_value = {'app_processed_conversation_id': 'synthetic-conversation'}
        db.get_talk_session.return_value = {'id': 'synthetic-session'}
        uploaded = Mock()
        sockets = []

        async def provider(**kwargs):
            if startup_failure:
                raise error
            socket = types.SimpleNamespace(
                _on_message_task=asyncio.get_running_loop().create_future(),
                _keepalive_task=asyncio.create_task(asyncio.Event().wait()),
                _stream_error=None, _latest_text=None,
            )

            def fail():
                socket._stream_error = error
                if not socket._on_message_task.done():
                    socket._on_message_task.set_result(None)

            async def send(value):
                if fail_after_audio:
                    fail()
                elif value == '' and not socket._on_message_task.done():
                    socket._stream_finished = True
                    socket._on_message_task.set_result(None)

            async def close():
                if not socket._on_message_task.done():
                    socket._on_message_task.cancel()

            socket.send, socket.close = send, close
            sockets.append(socket)
            if error is not None and not fail_after_audio:
                asyncio.get_running_loop().call_later(0.01, fail)
            return socket

        conversations = types.ModuleType('routers.developer_conversations')
        conversations.listen_session_lock_key = lambda *args: 'synthetic-lock'
        monkeypatch.setitem(sys.modules, 'routers.developer_conversations', conversations)
        namespace = {
            **globals(), 'dev_db': db, 'active_sessions': {}, '_opus_lock': threading.Lock(), 'time_module': time,
            'json': json, 'os': os, 'struct': struct, 'uuid': uuid, 'deepcopy': deepcopy,
            'datetime': datetime, 'timezone': timezone, 'timedelta': timedelta,
            'Any': Any, 'Dict': Dict, 'List': List, 'Optional': Optional,
            'Query': Query, 'WebSocket': WebSocket, 'WebSocketState': WebSocketState,
            'receive_with_stt': receive_with_stt, 'report_stt_error': report_stt_error,
            'finish_soniox_stream': finish_soniox_stream,
            'stream_segment': stream_segment, 'conversation_segments': conversation_segments,
            'has_original_timestamps': has_original_timestamps, 'coerce_speaker_id': coerce_speaker_id,
            'transcribed_spans': transcribed_spans,
            'KEY_AUTH_ERROR_FORBIDDEN': 'forbidden',
            'resolve_developer_id_for_external_user': lambda *args: ('synthetic-dev', None),
            'has_transcription_credits_developer': lambda *args: True,
            'get_stt_service_for_language': lambda language: (STTService.soniox, language, 'stt-rt-v5'),
            'process_audio_soniox': provider, 'record_usage_developer': Mock(),
            'upload_conversation_recording_from_bytes': uploaded,
            'vad_trim_silence_bytes': lambda audio, **kwargs: (audio, [[0, 1]]),
            'DUPLICATE_FRAME_ALERT_FACTOR': 1.5, 'CONVERSATION_CREATION_TIMEOUT': 60,
            'MAX_SESSION_DURATION_SECONDS': 18000, 'USAGE_WRITE_INTERVAL_SECONDS': 30,
            'clean_transcript': AsyncMock(return_value={'text': 'synthetic transcript', 'changes': []}),
        }
        source = Path(__file__).resolve().parents[1] / 'routers' / f'developer_{route}.py'
        tree = ast.parse(source.read_text())
        node = next(node for node in tree.body if isinstance(node, ast.AsyncFunctionDef) and node.name == 'websocket_stream')
        node.decorator_list = []
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), 'exec'), namespace)
        app = FastAPI()
        app.websocket(f'/v1/{route}/stream/{{session_id}}')(namespace['websocket_stream'])
        client = TestClient(app)
        client.finalized = finalized
        clients.append(client)
        return client, db, uploaded, sockets

    yield create
    for client in clients:
        client.close()


def connect(client, route, *, sample_rate=16000):
    return client.websocket_connect(
        f'/v1/{route}/stream/synthetic-session?external_user_id=synthetic-user&api_key=synthetic-app-key&codec=pcm16&sample_rate={sample_rate}'
    )


def stall_provider_finish(client, route, *, text=None):
    namespace = client.app.routes[-1].endpoint.__globals__
    original_provider = namespace['process_audio_soniox']

    async def provider(**kwargs):
        socket = await original_provider(**kwargs)
        socket._latest_text = text
        original_send = socket.send

        async def send(value):
            if value != '':
                await original_send(value)

        socket.send = send
        return socket

    async def bounded_finish(socket, *, timeout=30):
        assert timeout == (1.5 if route == 'talk' else 30)
        await finish_soniox_stream(socket, timeout=0.02)

    namespace['process_audio_soniox'] = provider
    namespace['finish_soniox_stream'] = bounded_finish
    return namespace


@pytest.mark.parametrize('route', ['listen', 'talk'])
@pytest.mark.parametrize('binary_end', [False, True])
def test_missing_provider_finish_fails_with_deadline_on_both_end_markers(router_client, route, binary_end):
    client, db, uploaded, sockets = router_client(route)
    stall_provider_finish(client, route)
    audio = b'\0\0' * 1600
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(audio)
        if binary_end:
            ws.send_bytes(b'')
        else:
            ws.send_json({'type': 'end'})
        assert ws.receive_json()['error_type'] == 'final_transcript_timeout'
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 1013
        assert client.finalized.wait(3)
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'failed'
    assert sockets[0]._on_message_task.done()
    if route == 'listen':
        assert uploaded.call_args.kwargs['audio_bytes'] == audio


@pytest.mark.parametrize('binary_end', [False, True])
@pytest.mark.parametrize('sample_rate', [8000, 16000])
def test_talk_finish_timeout_recovers_available_text_with_warning(router_client, binary_end, sample_rate):
    client, db, _, sockets = router_client('talk')
    namespace = stall_provider_finish(client, 'talk', text='Available short speech.')
    with connect(client, 'talk', sample_rate=sample_rate) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(b'\0\0' * 1600)
        if binary_end:
            ws.send_bytes(b'')
        else:
            ws.send_json({'type': 'end'})
        events = []
        try:
            while True:
                events.append(ws.receive_json())
        except WebSocketDisconnect as closed:
            assert closed.code == 1000
        assert not any(event['type'] == 'error' for event in events)
        assert events[-1]['finalization_warning'] == 'used_tentative_text'
        assert client.finalized.wait(3)
    namespace['clean_transcript'].assert_awaited_once()
    update = db.update_talk_session.call_args.kwargs
    assert update['status'] == 'completed' and update['error'] is None
    assert update['transcript_segments'][0]['text'] == 'Available short speech.'
    assert update['transcript_segments'][0]['end'] == 1600 / sample_rate
    assert sockets[0]._on_message_task.done()


def test_talk_timeout_recovery_does_not_mask_late_provider_rejection(router_client):
    client, db, _, sockets = router_client('talk')
    namespace = stall_provider_finish(client, 'talk', text='Available short speech.')

    async def clean_and_reject(*args, **kwargs):
        sockets[0]._stream_error = SonioxStreamError(401, 'unauthenticated')
        return {'text': 'Available short speech.', 'changes': []}

    namespace['clean_transcript'] = clean_and_reject
    with connect(client, 'talk') as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(b'\0\0' * 1600)
        ws.send_json({'type': 'end'})
        events = []
        try:
            while True:
                events.append(ws.receive_json())
        except WebSocketDisconnect as closed:
            assert closed.code == 1011
        assert any(event.get('error_type') == 'unauthenticated' for event in events)
        assert not any(event['type'] == 'complete' for event in events)
        assert not any(event['type'] == 'cleaned' for event in events)
        assert client.finalized.wait(3)
    assert db.update_talk_session.call_args.kwargs['status'] == 'failed'


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_end_finalizes_short_utterance_before_persisting_session(router_client, route):
    client, db, _, sockets = router_client(route)
    namespace = client.app.routes[-1].endpoint.__globals__
    original_provider = namespace['process_audio_soniox']
    sleeps = []
    if route == 'talk':
        original_sleep = asyncio.sleep

        async def tracked_sleep(delay):
            sleeps.append(delay)
            await original_sleep(0)

        namespace['asyncio'] = types.SimpleNamespace(
            **{name: getattr(asyncio, name) for name in ('create_task', 'to_thread', 'CancelledError', 'TimeoutError')},
            sleep=tracked_sleep,
        )

    async def provider(**kwargs):
        socket = await original_provider(**kwargs)
        sent = []
        original_send = socket.send

        async def send(value):
            sent.append(value)
            if value == '':
                await kwargs['stream_transcript']([{
                    'id': 'short-final', 'text': 'Short final speech.',
                    'speaker': 'SPEAKER_01', 'start': 0, 'end': 0.8,
                }])
            await original_send(value)

        socket.send, socket.sent = send, sent
        return socket

    namespace['process_audio_soniox'] = provider
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(b'\0\0' * 1600)
        ws.send_json({'type': 'end'})
        events = []
        try:
            while True:
                events.append(ws.receive_json())
        except WebSocketDisconnect as closed:
            assert closed.code == 1000
        assert not any(event['type'] == 'error' for event in events)
        assert events[-1]['type'] == 'complete'
        assert client.finalized.wait(3)
    update = getattr(db, f'update_{route}_session')
    writes = [call.kwargs for call in update.call_args_list if call.kwargs.get('transcript_segments')]
    assert writes[-1]['transcript_segments'][-1]['text'] == 'Short final speech.'
    assert update.call_args.kwargs['status'] == 'completed'
    assert sockets[0].sent.count('') == 1
    assert sleeps == []  # Fully finalized Talk does not wait for text stability.


@pytest.mark.parametrize('route', ['listen', 'talk'])
@pytest.mark.parametrize('code,kind', [(401, 'unauthenticated'), (408, 'request_timeout'), (429, 'max_concurrent_connections_reached')])
def test_silent_client_gets_provider_error_close_and_failed_session(router_client, route, code, kind):
    client, db, _, sockets = router_client(route, SonioxStreamError(code, kind, 'synthetic-request'))
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        event = ws.receive_json()
        assert (event['type'], event['error_code'], event['error_type']) == ('error', code, kind)
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == (1011 if code == 401 else 1013)
        assert client.finalized.wait(3)
    update = getattr(db, f'update_{route}_session')
    assert update.call_args.kwargs['status'] == 'failed'
    assert kind in update.call_args.kwargs['error']
    assert all(socket._on_message_task.done() for socket in sockets)


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_startup_provider_failure_is_not_reported_ready_or_completed(router_client, route):
    client, db, _, _ = router_client(route, SonioxStreamError(401, 'unauthenticated'), startup_failure=True)
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'error'
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()
        assert client.finalized.wait(3)
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'failed'


def test_listen_preserves_received_audio_when_provider_fails(router_client):
    client, db, uploaded, _ = router_client('listen', SonioxStreamError(503, 'service_unavailable'), fail_after_audio=True)
    audio = b'\x00\x00' * 1600
    with connect(client, 'listen') as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(audio)
        assert ws.receive_json()['error_type'] == 'service_unavailable'
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()
        assert client.finalized.wait(3)
    uploaded.assert_called_once()
    assert uploaded.call_args.kwargs['audio_bytes'] == audio
    assert db.update_listen_session.call_args.kwargs['status'] == 'failed'
    assert db.update_listen_session.call_args.kwargs['audio_path']


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_simultaneous_provider_failure_preserves_consumed_audio(router_client, monkeypatch, capsys, route):
    client, db, uploaded, sockets = router_client(route)
    original_receive = WebSocket.receive

    async def receive_and_fail(websocket):
        data = await original_receive(websocket)
        if data.get('bytes') is not None:
            socket = sockets[0]
            socket._stream_error = SonioxStreamError(408, 'request_timeout')
            socket._on_message_task.set_result(None)
        return data

    monkeypatch.setattr(WebSocket, 'receive', receive_and_fail)
    audio = b'\x00\x00' * 1600
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(audio)
        assert ws.receive_json()['error_type'] == 'request_timeout'
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()
        assert client.finalized.wait(3)
    if route == 'listen':
        uploaded.assert_called_once()
        assert uploaded.call_args.kwargs['audio_bytes'] == audio
    else:
        # Talk keeps its audio in memory; it has no recording-upload path.
        assert f'audio_buffer={len(audio)} bytes' in capsys.readouterr().out
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'failed'


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_empty_audio_terminator_completes_successful_provider_stream(router_client, route):
    client, db, _, sockets = router_client(route)
    namespace = client.app.routes[-1].endpoint.__globals__
    original_provider = namespace['process_audio_soniox']

    async def provider(**kwargs):
        socket = await original_provider(**kwargs)
        original_send = socket.send

        async def send(value):
            if value == b'':
                socket._stream_finished = True
                socket._on_message_task.set_result(None)
            else:
                await original_send(value)

        socket.send = send
        return socket

    namespace['process_audio_soniox'] = provider
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_bytes(b'\x00\x00' * 1600)
        ws.send_bytes(b'')
        events = []
        try:
            while True:
                events.append(ws.receive_json())
        except WebSocketDisconnect:
            pass
        assert not any(event['type'] == 'error' for event in events)
        assert events[-1]['type'] == 'complete'
        assert client.finalized.wait(3)
    assert sockets[0]._stream_finished and sockets[0]._stream_error is None
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'completed'


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_recorded_failure_wins_end_control_before_receiver_cleanup(router_client, monkeypatch, route):
    client, db, _, sockets = router_client(route)
    original_receive = WebSocket.receive

    async def receive_and_record_failure(websocket):
        data = await original_receive(websocket)
        if 'text' in data:
            socket = sockets[0]
            socket._stream_error = SonioxStreamError(401, 'unauthenticated')
            assert not socket._on_message_task.done()
        return data

    monkeypatch.setattr(WebSocket, 'receive', receive_and_record_failure)
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_json({'type': 'end'})
        assert ws.receive_json()['error_type'] == 'unauthenticated'
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 1011
        assert client.finalized.wait(3)
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'failed'


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_failure_recorded_during_receive_cleanup_wins_end_control(router_client, monkeypatch, route):
    client, db, _, sockets = router_client(route)
    original_gather = asyncio.gather

    async def gather_and_fail(*tasks, **kwargs):
        result = await original_gather(*tasks, **kwargs)
        sockets[0]._stream_error = SonioxStreamError(401, 'unauthenticated')
        return result

    monkeypatch.setattr(stream_lifecycle, 'asyncio', types.SimpleNamespace(
        **{name: getattr(asyncio, name) for name in ('create_task', 'wait', 'FIRST_COMPLETED', 'TimeoutError', 'shield', 'CancelledError', 'get_running_loop', 'wait_for')},
        gather=gather_and_fail,
    ))
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_json({'type': 'end'})
        assert ws.receive_json()['error_type'] == 'unauthenticated'
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 1011
        assert client.finalized.wait(3)
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'failed'


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_client_disconnect_retains_already_recorded_provider_failure(router_client, monkeypatch, route):
    client, db, _, sockets = router_client(route)
    original_receive = WebSocket.receive

    async def receive_and_record_failure(websocket):
        data = await original_receive(websocket)
        if data['type'] == 'websocket.disconnect':
            sockets[0]._stream_error = SonioxStreamError(503, 'service_unavailable')
        return data

    monkeypatch.setattr(WebSocket, 'receive', receive_and_record_failure)
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.close()
        assert client.finalized.wait(3)
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'failed'


def test_talk_failure_during_provider_finalization_is_not_completed(router_client):
    client, db, _, sockets = router_client('talk')
    namespace = client.app.routes[-1].endpoint.__globals__
    original_provider = namespace['process_audio_soniox']

    async def provider(**kwargs):
        socket = await original_provider(**kwargs)
        original_send = socket.send

        async def send(value):
            if value == '':
                socket._stream_error = SonioxStreamError(503, 'service_unavailable')
            await original_send(value)

        socket.send = send
        return socket

    namespace['process_audio_soniox'] = provider
    with connect(client, 'talk') as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_json({'type': 'end'})
        assert ws.receive_json()['error_type'] == 'service_unavailable'
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()
        assert client.finalized.wait(3)
    assert db.update_talk_session.call_args.kwargs['status'] == 'failed'


@pytest.mark.parametrize('route', ['listen', 'talk'])
def test_normal_end_still_completes_session(router_client, route):
    client, db, _, _ = router_client(route)
    with connect(client, route) as ws:
        assert ws.receive_json()['type'] == 'ready'
        ws.send_json({'type': 'end'})
        events = []
        try:
            while True:
                events.append(ws.receive_json())
        except WebSocketDisconnect:
            pass
        assert not any(event['type'] == 'error' for event in events)
        assert events[-1]['type'] == 'complete'
        assert client.finalized.wait(3)
    assert getattr(db, f'update_{route}_session').call_args.kwargs['status'] == 'completed'
