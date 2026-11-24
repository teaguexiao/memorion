"""Exercise the real transport against a local WebSocket server, without cloud data."""

import asyncio
import copy
import json
import time
from http import HTTPStatus
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
import websockets

from utils.stt import soniox_stream
from utils.stt import stream_lifecycle
from utils.stt.stream_lifecycle import SonioxStreamError, finish_soniox_stream, receive_with_stt, report_stt_error


async def silent_receive():
    await asyncio.Event().wait()


@pytest.mark.asyncio
@pytest.mark.parametrize('callback_delay', [0, 0.02])
async def test_explicit_end_flushes_tentative_tokens_before_cleanup(connect_local, callback_delay):
    async def server(ws):
        await ws.recv()  # configuration
        assert await ws.recv() == b'short speech'
        await ws.send(json.dumps({'tokens': [
            {'text': 'Short speech.', 'is_final': False, 'start_ms': 0, 'end_ms': 800},
        ]}))
        assert await ws.recv() == ''  # end of audio, not a keepalive
        await ws.send(json.dumps({'tokens': [
            {'text': 'Short speech.', 'is_final': True, 'speaker': '1', 'start_ms': 0, 'end_ms': 800},
        ], 'finished': True}))

    async def callback(value):
        await asyncio.sleep(callback_delay)

    socket, segments, _ = await connect_local(server, callback=callback)
    await socket.send(b'short speech')
    await finish_soniox_stream(socket, timeout=1)
    assert socket._stream_finished and socket._stream_error is None
    assert segments[-1]['text'] == 'Short speech.'
    assert socket._on_message_task.done()
    await finish_soniox_stream(socket, timeout=1)  # completion is idempotent


@pytest.mark.asyncio
async def test_explicit_end_timeout_is_bounded_and_does_not_cancel_receiver(connect_local):
    async def server(ws):
        await ws.recv()
        assert await ws.recv() == ''
        await ws.wait_closed()

    socket, _, _ = await connect_local(server)
    with pytest.raises(SonioxStreamError) as caught:
        await asyncio.wait_for(finish_soniox_stream(socket, timeout=0.02), 0.5)
    assert caught.value.error_type == 'final_transcript_timeout'
    assert caught.value.retryable
    assert socket._stream_error is caught.value
    assert not socket._on_message_task.cancelled()


@pytest.mark.asyncio
async def test_explicit_end_preserves_provider_failure(connect_local):
    async def server(ws):
        await ws.recv()
        assert await ws.recv() == ''
        await ws.send(json.dumps({'error_code': 429, 'error_type': 'rate_limit', 'request_id': 'synthetic'}))

    socket, _, _ = await connect_local(server)
    with pytest.raises(SonioxStreamError) as caught:
        await finish_soniox_stream(socket, timeout=1)
    assert caught.value.error_code == 429
    assert caught.value.error_type == 'rate_limit'


@pytest.mark.asyncio
@pytest.mark.parametrize('end_frame', ['', b''])
async def test_end_of_audio_stops_keepalive_and_late_audio_before_finished(connect_local, end_frame):
    ended, release = asyncio.Event(), asyncio.Event()

    async def server(ws):
        await ws.recv()
        assert await ws.recv() == end_frame
        ended.set()
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(ws.recv(), 0.06)
        await release.wait()
        await ws.send(json.dumps({'tokens': [], 'finished': True}))

    socket, _, _ = await connect_local(server, keepalive_interval=0.02)
    await socket.send(end_frame)
    await asyncio.wait_for(ended.wait(), 1)
    await socket.send(b'late audio')
    await socket.send(json.dumps({'type': 'keepalive'}))
    await socket.send(end_frame)
    await asyncio.sleep(0.08)
    assert socket._end_of_audio_sent and not socket._completion_received
    assert socket._keepalive_task.done()
    release.set()
    await finish_soniox_stream(socket, timeout=1)
    assert socket._stream_finished and socket._stream_error is None


@pytest.mark.asyncio
async def test_missing_receiver_does_not_send_end_of_audio():
    socket = SimpleNamespace(send=AsyncMock(), _stream_error=None)
    with pytest.raises(SonioxStreamError):
        await finish_soniox_stream(socket, timeout=0.02)
    socket.send.assert_not_awaited()


@pytest.fixture(autouse=True)
def key(monkeypatch):
    monkeypatch.setenv('SONIOX_API_KEY', 'synthetic-private-key')


@pytest_asyncio.fixture
async def connect_local(monkeypatch):
    real_connect = websockets.connect
    servers, sockets, connects = [], [], []

    async def start(handler, **options):
        server = await websockets.serve(
            handler, '127.0.0.1', 0, ping_interval=None,
            process_request=options.pop('process_request', None),
        )
        servers.append(server)
        uri = f'ws://127.0.0.1:{server.sockets[0].getsockname()[1]}'

        async def connect(remote_uri, **kwargs):
            connects.append((remote_uri, kwargs))
            return await real_connect(uri, proxy=None, **kwargs)

        monkeypatch.setattr(soniox_stream.websockets, 'connect', connect)
        segments = []
        callback = options.pop('callback', None)

        async def stream_transcript(value):
            segments.extend(copy.deepcopy(value))
            if callback is not None:
                await callback(value)

        socket = await soniox_stream.process_audio_soniox(
            stream_transcript,
            options.pop('sample_rate', 16000), options.pop('language', 'en'), 'synthetic-user', **options,
        )
        sockets.append(socket)
        return socket, segments, connects

    yield start
    for socket in sockets:
        await socket.close()
        await asyncio.gather(socket._on_message_task, socket._keepalive_task, return_exceptions=True)
    for server in servers:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
@pytest.mark.parametrize('sample_rate,language,audio_format,delay', [(16000, 'en', 's16le', 4000), (8000, 'zh', 'mulaw', 3000)])
async def test_header_auth_and_configuration_preserved(connect_local, capsys, sample_rate, language, audio_format, delay):
    received = {}

    async def server(ws):
        received['auth'] = ws.request.headers['Authorization']
        received['protocol'] = ws.request.headers.get('Sec-WebSocket-Protocol')
        received['config'] = json.loads(await ws.recv())
        await ws.send(json.dumps({'tokens': [], 'finished': True}))

    socket, _, connects = await connect_local(
        server, sample_rate=sample_rate, language=language, language_hints=['en', 'zh'],
        language_hints_strict=True, enable_endpoint_detection=True, max_endpoint_delay_ms=500,
        enable_speaker_diarization=False,
    )
    await asyncio.wait_for(socket._on_message_task, 1)
    assert received['auth'] == 'Bearer synthetic-private-key'
    assert received['protocol'] is None
    assert 'api_key' not in received['config']
    assert received['config'] == {
        'model': 'stt-rt-v5', 'audio_format': audio_format, 'sample_rate': sample_rate, 'num_channels': 1,
        'enable_speaker_diarization': False, 'language_hints': ['en', 'zh'],
        'language_hints_strict': True, 'enable_endpoint_detection': True, 'max_endpoint_delay_ms': 500,
        'max_non_final_tokens_duration_ms': delay,
    }
    assert connects[0][0] == 'wss://stt-rt.soniox.com/transcribe-websocket'
    assert socket._stream_error is None
    assert socket._stream_finished
    assert socket._keepalive_task.done()
    assert 'synthetic-private-key' not in capsys.readouterr().out


@pytest.mark.asyncio
@pytest.mark.parametrize('code,kind,retryable', [
    (400, 'handshake_rejected', False), (401, 'unauthenticated', False), (403, 'permission_denied', False),
    (429, 'handshake_rejected', True), (503, 'handshake_rejected', True),
])
async def test_rejected_http_upgrade_preserves_status_and_retry_policy(connect_local, capsys, code, kind, retryable):
    async def reject(connection, request):
        return connection.respond(HTTPStatus(code), 'synthetic-private-key rejected')

    with pytest.raises(SonioxStreamError) as caught:
        await connect_local(lambda ws: None, process_request=reject)
    error = caught.value
    assert (error.error_code, error.error_type, error.retryable) == (code, kind, retryable)
    assert error.close_code == (1013 if retryable else 1011)
    assert 'synthetic-private-key' not in str(error)
    assert 'synthetic-private-key' not in capsys.readouterr().out


@pytest.mark.asyncio
async def test_successful_finish_suppresses_late_audio_and_keepalive_sends(connect_local):
    async def server(ws):
        await ws.recv()
        await ws.send(json.dumps({'tokens': [], 'finished': True}))
        await ws.close()

    socket, _, _ = await connect_local(server)
    await asyncio.wait_for(socket._on_message_task, 1)
    assert socket._stream_finished and socket._stream_error is None
    await socket.send(json.dumps({'type': 'keepalive'}))
    await socket.send(b'late synthetic audio')
    assert socket._stream_error is None


@pytest.mark.asyncio
@pytest.mark.parametrize('tokens', [[], [
    {'text': 'Final speech.', 'is_final': True, 'speaker': '1', 'start_ms': 100, 'end_ms': 800},
]])
async def test_finished_response_remains_successful_after_abrupt_transport_close(connect_local, tokens):
    async def server(ws):
        await ws.recv()
        await ws.send(json.dumps({'tokens': tokens, 'finished': True}))
        ws.transport.abort()

    socket, segments, _ = await connect_local(server)
    client = SimpleNamespace(receive=silent_receive)
    assert await asyncio.wait_for(receive_with_stt(client, socket), 1) == {'type': 'stt.finished'}
    assert socket._stream_finished and socket._stream_error is None
    if tokens:
        assert segments[-1]['text'] == 'Final speech.'
        assert socket._latest_text == 'Final speech.'


@pytest.mark.asyncio
async def test_finished_receipt_suppresses_sends_and_preserves_pending_final_callback(connect_local):
    callback_started, release = asyncio.Event(), asyncio.Event()

    async def callback(value):
        callback_started.set()
        await release.wait()

    async def server(ws):
        await ws.recv()
        await ws.send(json.dumps({'tokens': [
            {'text': 'Final speech.', 'is_final': True, 'speaker': '1', 'start_ms': 100, 'end_ms': 800},
        ], 'finished': True}))
        ws.transport.abort()

    socket, segments, _ = await connect_local(server, callback=callback)
    await asyncio.wait_for(callback_started.wait(), 1)
    try:
        assert socket._completion_received and not socket._stream_finished
        await socket.send(json.dumps({'type': 'keepalive'}))
        await socket.send(b'late audio')
        assert socket._stream_error is None
        client = SimpleNamespace(receive=AsyncMock(return_value={'type': 'websocket.receive', 'text': '{"type":"end"}'}))
        waiting = asyncio.create_task(receive_with_stt(client, socket))
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert not waiting.done() and not socket._on_message_task.done()
    finally:
        release.set()
    assert await asyncio.wait_for(waiting, 1) == {'type': 'stt.finished'}
    assert socket._stream_finished and socket._stream_error is None
    assert segments[-1]['text'] == 'Final speech.'


@pytest.mark.asyncio
async def test_transcript_updates_keep_ids_speakers_timestamps_and_word_spaces(connect_local):
    def token(text, start, end, speaker='1', final=True):
        return {'text': text, 'start_ms': start, 'end_ms': end, 'speaker': speaker, 'is_final': final}

    async def server(ws):
        await ws.recv()
        for tokens in [
            [token('Hello', 1000, 1400), token(' draft', 1400, 1800, final=False)],
            [token(' world.', 1400, 2000), token('<end>', 0, 0)],
            [token('你好', 2200, 2500, '2'), token('世界。', 2500, 3000, '2')],
        ]:
            await ws.send(json.dumps({'tokens': tokens}))
        await ws.send(json.dumps({'tokens': [], 'finished': True}))

    socket, segments, _ = await connect_local(server)
    await asyncio.wait_for(socket._on_message_task, 1)
    first = [segment for segment in segments if segment['speaker'] == 'SPEAKER_01']
    second = [segment for segment in segments if segment['speaker'] == 'SPEAKER_02']
    assert len({segment['id'] for segment in first}) == 1
    assert first[-1]['text'] == 'Hello world.'
    assert (first[-1]['start'], first[-1]['end']) == (1, 2)
    assert second[-1]['text'] == '你好世界。'
    assert (second[-1]['start'], second[-1]['end']) == (2.2, 3)
    assert socket._latest_text == 'Hello world.你好世界。'


@pytest.mark.asyncio
@pytest.mark.parametrize('code,kind,retryable', [
    (400, 'invalid_request', False), (401, 'unauthenticated', False), (402, 'organization_balance_exhausted', False),
    (403, 'permission_denied', False), (408, 'request_timeout', True), (413, 'max_duration_reached', True),
    (429, 'max_concurrent_connections_reached', True), (500, 'internal_error', True), (503, 'service_unavailable', True),
])
async def test_error_frames_wake_silent_client_and_close_tasks(connect_local, capsys, code, kind, retryable):
    async def server(ws):
        # Error arrives after the handshake, before any audio is sent.
        await ws.send(json.dumps({
            'error_code': code, 'error_type': kind, 'request_id': 'synthetic-request',
            'error_message': 'synthetic-private-key secret-provider-description',
        }))
        await ws.wait_closed()

    socket, _, _ = await connect_local(server)
    client = SimpleNamespace(receive=silent_receive)
    with pytest.raises(SonioxStreamError) as caught:
        await asyncio.wait_for(receive_with_stt(client, socket), 1)
    error = caught.value
    assert (error.error_code, error.error_type, error.request_id) == (code, kind, 'synthetic-request')
    assert error.retryable is retryable
    assert socket._on_message_task.done() and socket._keepalive_task.done()
    with pytest.raises(SonioxStreamError) as late_send:
        await socket.send(b'late synthetic audio')
    assert late_send.value is error
    client = SimpleNamespace(send_json=AsyncMock(), close=AsyncMock())
    await report_stt_error(client, error)
    assert client.send_json.call_args.args[0]['retryable'] is retryable
    assert client.close.call_args.kwargs['code'] == (1013 if retryable else 1011)
    assert 'synthetic-private-key' not in capsys.readouterr().out
    assert 'secret-provider-description' not in str(error)


@pytest.mark.asyncio
async def test_unexpected_normal_upstream_close_is_failure(connect_local):
    async def server(ws):
        await ws.recv()
        await ws.close(code=1000)

    socket, _, _ = await connect_local(server)
    client = SimpleNamespace(receive=silent_receive)
    with pytest.raises(SonioxStreamError, match='connection_closed'):
        await asyncio.wait_for(receive_with_stt(client, socket), 1)


@pytest.mark.asyncio
async def test_missing_key_and_invalid_intervals_do_not_connect(monkeypatch):
    connect = AsyncMock()
    monkeypatch.setattr(soniox_stream.websockets, 'connect', connect)
    for interval in (0, -1, 20, 30, float('nan')):
        with pytest.raises(ValueError, match='keepalive_interval'):
            await soniox_stream.process_audio_soniox(lambda value: None, 16000, 'en', 'user', keepalive_interval=interval)
    monkeypatch.delenv('SONIOX_API_KEY')
    with pytest.raises(SonioxStreamError, match='unauthenticated'):
        await soniox_stream.process_audio_soniox(lambda value: None, 16000, 'en', 'user')
    connect.assert_not_called()


@pytest.mark.asyncio
@pytest.mark.parametrize('cancelled', [False, True])
async def test_failed_or_cancelled_initial_send_releases_connection(monkeypatch, cancelled):
    entered = asyncio.Event()

    async def send(value):
        entered.set()
        if cancelled:
            await asyncio.Event().wait()
        raise RuntimeError('synthetic send failure')

    socket = SimpleNamespace(send=send, close=AsyncMock())
    monkeypatch.setattr(soniox_stream.websockets, 'connect', AsyncMock(return_value=socket))
    task = asyncio.create_task(soniox_stream.process_audio_soniox(lambda value: None, 16000, 'en', 'user'))
    await entered.wait()
    if cancelled:
        task.cancel()
    with pytest.raises(asyncio.CancelledError if cancelled else SonioxStreamError):
        await task
    socket.close.assert_awaited_once()


class ClockSocket:
    def __init__(self, clock):
        self.clock, self.closed, self.messages = clock, False, []
        self.queue = asyncio.Queue()

    async def send(self, value):
        self.messages.append((self.clock.now, value))

    async def close(self):
        self.closed = True
        await self.queue.put(None)

    def __aiter__(self):
        return self

    async def __anext__(self):
        value = await self.queue.get()
        if value is None:
            raise StopAsyncIteration
        return value


class Clock:
    def __init__(self):
        self.now, self.waiters = 0, []

    async def sleep(self, delay):
        future = asyncio.get_running_loop().create_future()
        self.waiters.append((self.now + delay, future))
        await future

    async def advance(self, now):
        self.now = now
        for due, future in self.waiters:
            if due <= now and not future.done():
                future.set_result(None)
        for _ in range(3):
            await asyncio.sleep(0)


@pytest.mark.asyncio
@pytest.mark.parametrize('audio_at', [14.99, 15.01])
async def test_default_keepalive_deadline_around_timer_boundary(monkeypatch, audio_at):
    clock = Clock()
    socket = ClockSocket(clock)
    monkeypatch.setattr(soniox_stream.websockets, 'connect', AsyncMock(return_value=socket))
    monkeypatch.setattr(soniox_stream, 'time', SimpleNamespace(monotonic=lambda: clock.now, time=time.time))
    monkeypatch.setattr(soniox_stream, 'asyncio', SimpleNamespace(
        sleep=clock.sleep, create_task=asyncio.create_task, gather=asyncio.gather,
        iscoroutine=asyncio.iscoroutine, CancelledError=asyncio.CancelledError,
    ))
    await soniox_stream.process_audio_soniox(lambda value: None, 16000, 'en', 'user')
    await clock.advance(0)
    if audio_at > 15:
        await clock.advance(15)
    await clock.advance(audio_at)
    await socket.send(b'synthetic audio')  # Normal caller send updates the deadline automatically.
    await clock.advance(15 if audio_at < 15 else 30)
    await clock.advance(audio_at + 15 + 1e-6)
    heartbeats = [at for at, value in socket.messages if isinstance(value, str) and 'keepalive' in value and at > audio_at]
    assert heartbeats == pytest.approx([audio_at + 15], abs=1e-5)
    assert heartbeats[0] - audio_at < 20
    await socket.close()
    await asyncio.gather(socket._on_message_task, socket._keepalive_task, return_exceptions=True)


@pytest.mark.asyncio
async def test_receive_timeout_cancellation_and_superseding_preserve_upstream_task():
    upstream = asyncio.create_task(asyncio.Event().wait())
    socket = SimpleNamespace(_on_message_task=upstream)
    receives = []

    async def receive():
        try:
            await asyncio.Event().wait()
        finally:
            receives.append('cancelled')

    client = SimpleNamespace(receive=receive)
    with pytest.raises(asyncio.TimeoutError):
        await receive_with_stt(client, socket, timeout=0.01)
    assert receives == ['cancelled'] and not upstream.done()
    superseded = asyncio.Event()
    superseded.set()
    assert await receive_with_stt(client, socket, cancel_event=superseded) is None
    waiting = asyncio.create_task(receive_with_stt(client, socket))
    await asyncio.sleep(0)
    waiting.cancel()
    with pytest.raises(asyncio.CancelledError):
        await waiting
    assert not upstream.done()
    upstream.cancel()
    await asyncio.gather(upstream, return_exceptions=True)


@pytest.mark.asyncio
async def test_non_soniox_and_client_disconnect_paths_remain_compatible():
    client = SimpleNamespace(receive=AsyncMock(return_value={'bytes': b'audio', 'type': 'websocket.receive'}))
    assert (await receive_with_stt(client, None))['bytes'] == b'audio'
    monitor = asyncio.create_task(asyncio.sleep(0))
    await monitor
    client.receive.return_value = {'type': 'websocket.disconnect'}
    assert (await receive_with_stt(client, SimpleNamespace(_on_message_task=monitor)))['type'] == 'websocket.disconnect'


@pytest.mark.asyncio
async def test_receiver_exception_is_a_provider_failure_and_is_retrieved():
    async def broken_receiver():
        raise OSError('synthetic receiver failure')
    monitor = asyncio.create_task(broken_receiver())
    client = SimpleNamespace(receive=silent_receive)
    with pytest.raises(SonioxStreamError, match='connection_closed'):
        await receive_with_stt(client, SimpleNamespace(_on_message_task=monitor, _stream_error=None))
    assert monitor.done()


@pytest.mark.asyncio
@pytest.mark.parametrize('finished', [False, True])
async def test_simultaneous_audio_and_termination_returns_audio_before_terminal_status(finished):
    monitor = asyncio.create_task(asyncio.sleep(0))
    await monitor
    error = None if finished else SonioxStreamError(408, 'request_timeout')
    socket = SimpleNamespace(_on_message_task=monitor, _stream_error=error, _stream_finished=finished)
    message = {'type': 'websocket.receive', 'bytes': b'synthetic audio'}
    client = SimpleNamespace(receive=AsyncMock(return_value=message))
    assert await receive_with_stt(client, socket) == message
    client.receive = silent_receive
    if finished:
        assert await receive_with_stt(client, socket) == {'type': 'stt.finished'}
    else:
        with pytest.raises(SonioxStreamError, match='request_timeout'):
            await receive_with_stt(client, socket)


@pytest.mark.asyncio
@pytest.mark.parametrize('use_receive_deadline', [False, True])
async def test_pending_final_callback_has_bounded_wait_without_cancelling_receiver(monkeypatch, use_receive_deadline):
    monkeypatch.setattr(stream_lifecycle, 'FINAL_CALLBACK_TIMEOUT_SECONDS', 0.02)
    monitor = asyncio.create_task(asyncio.Event().wait())
    socket = SimpleNamespace(_on_message_task=monitor, _stream_error=None, _completion_received=True, _stream_finished=False)
    client = SimpleNamespace(receive=AsyncMock(return_value={'type': 'websocket.receive', 'text': '{"type":"end"}'}))
    try:
        with pytest.raises(SonioxStreamError, match='final_transcript_timeout') as caught:
            await asyncio.wait_for(
                receive_with_stt(client, socket, timeout=0.02 if use_receive_deadline else None), 0.5,
            )
        assert socket._stream_error is caught.value
        assert caught.value.retryable and not monitor.done()
    finally:
        monitor.cancel()
        await asyncio.gather(monitor, return_exceptions=True)


@pytest.mark.asyncio
async def test_caller_owned_cancel_watcher_is_reused_across_frames():
    event = asyncio.Event()
    cancel = asyncio.create_task(event.wait())
    monitor = asyncio.create_task(asyncio.Event().wait())
    client = SimpleNamespace(receive=AsyncMock(return_value={'type': 'websocket.receive', 'bytes': b'audio'}))
    socket = SimpleNamespace(_on_message_task=monitor)
    try:
        for _ in range(3):
            assert (await receive_with_stt(client, socket, cancel_task=cancel))['bytes'] == b'audio'
            assert not cancel.done() and not monitor.done()
        event.set()
        assert await receive_with_stt(client, socket, cancel_task=cancel) is None
    finally:
        for task in (cancel, monitor):
            task.cancel()
        await asyncio.gather(cancel, monitor, return_exceptions=True)
