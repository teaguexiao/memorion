"""Observe an upstream STT receiver while waiting for client audio."""

import asyncio

FINAL_CALLBACK_TIMEOUT_SECONDS = 30


class SonioxStreamError(Exception):
    def __init__(self, error_code=503, error_type='connection_closed', request_id=None):
        self.error_code = error_code
        self.error_type = error_type
        self.request_id = request_id
        self.retryable = error_code in (408, 413, 429) or error_code >= 500
        self.close_code = 1013 if self.retryable else 1011
        # Provider descriptions may contain credentials or transcript content.
        # Only stable error metadata goes to application logs and clients.
        super().__init__(f'Soniox error: {error_code} {error_type} (request_id={request_id})')

    def to_event(self):
        return {
            'type': 'error',
            'message': 'Transcription service unavailable.',
            'error_code': self.error_code,
            'error_type': self.error_type,
            'request_id': self.request_id,
            'retryable': self.retryable,
        }


def _receiver_error(stt_socket, monitor):
    error = getattr(stt_socket, '_stream_error', None)
    finished = getattr(stt_socket, '_stream_finished', False)
    if monitor is not None and monitor.done():
        if monitor.cancelled():
            if not finished:
                error = error or SonioxStreamError()
        else:
            try:
                monitor.result()
            except Exception as exception:
                if not finished:
                    error = error or (
                        exception if isinstance(exception, SonioxStreamError) else SonioxStreamError()
                    )
        if error is None and not finished:
            error = SonioxStreamError()
        stt_socket._stream_error = error
    return error


async def receive_with_stt(websocket, stt_socket, *, cancel_event=None, cancel_task=None, timeout=None):
    """Race input with STT termination without cancelling the receiver.

    Completed audio is returned even on simultaneous termination so callers can
    persist it before checking _stream_error/_stream_finished and forwarding.
    Successful upstream completion without audio returns a stt.finished event.
    A caller-owned cancel_task can be reused across frames. Callback delivery is
    bounded by the remaining receive timeout, or 30 seconds without a deadline.
    """
    deadline = asyncio.get_running_loop().time() + timeout if timeout is not None else None
    receive = asyncio.create_task(websocket.receive())
    cancel = cancel_task
    if cancel is None and cancel_event is not None:
        cancel = asyncio.create_task(cancel_event.wait())
    monitor = getattr(stt_socket, '_on_message_task', None)
    tasks = {receive}
    if cancel is not None:
        tasks.add(cancel)
    if monitor is not None:
        tasks.add(monitor)
    result = None
    try:
        done, _ = await asyncio.wait(tasks, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        if not done:
            raise asyncio.TimeoutError
        if cancel not in done:
            result = receive.result() if receive in done else {'type': 'stt.finished'}
    finally:
        owned = [receive]
        if cancel is not None and cancel_task is None:
            owned.append(cancel)
        for task in owned:
            if not task.done():
                task.cancel()
        await asyncio.gather(*owned, return_exceptions=True)

    # Cleanup above yields to the receiver. Observe terminal state afterwards,
    # before exposing end/keepalive controls to callers.
    error = _receiver_error(stt_socket, monitor)
    if result is None:
        return None
    if result.get('bytes') is not None:
        return result  # Persist the received frame before forwarding/failing.
    if (error is None and getattr(stt_socket, '_completion_received', False)
            and not getattr(stt_socket, '_stream_finished', False) and monitor is not None):
        # The provider is done sending, but final transcript callbacks can still
        # be awaiting client/database I/O. Preserve them through end/disconnect.
        try:
            remaining = (max(0, deadline - asyncio.get_running_loop().time())
                         if deadline is not None else FINAL_CALLBACK_TIMEOUT_SECONDS)
            await asyncio.wait_for(asyncio.shield(monitor), timeout=remaining)
        except asyncio.TimeoutError as exception:
            error = SonioxStreamError(503, 'final_transcript_timeout')
            stt_socket._stream_error = error
            raise error from exception
        except asyncio.CancelledError:
            if not monitor.cancelled():
                raise  # Cancellation of this receive must not cancel upstream.
        except Exception:
            pass  # Retrieve/classify the receiver result below.
        error = _receiver_error(stt_socket, monitor)
    if result.get('type') == 'websocket.disconnect':
        return result  # Persist any recorded error without sending to a gone client.
    if error is not None:
        raise error
    if getattr(stt_socket, '_stream_finished', False):
        return {'type': 'stt.finished'}
    return result


async def finish_soniox_stream(stt_socket, *, timeout=FINAL_CALLBACK_TIMEOUT_SECONDS):
    """Flush tentative tokens on explicit client end, before session cleanup.

    Empty audio is Soniox's end-of-audio signal. A quiet wall-clock interval or
    keepalive alone does not finalize short utterances. Wait for both the
    provider's finished response and delivery of its final transcript callbacks.
    """
    monitor = getattr(stt_socket, '_on_message_task', None)
    error = _receiver_error(stt_socket, monitor)
    if error is not None:
        raise error
    if getattr(stt_socket, '_stream_finished', False):
        return
    if monitor is None:
        error = SonioxStreamError()
        stt_socket._stream_error = error
        raise error

    async def finish():
        await stt_socket.send('')
        await asyncio.shield(monitor)

    try:
        await asyncio.wait_for(finish(), timeout=timeout)
    except asyncio.TimeoutError as exception:
        error = _receiver_error(stt_socket, monitor) or SonioxStreamError(503, 'final_transcript_timeout')
        stt_socket._stream_error = error
        raise error from exception
    except Exception as exception:
        error = _receiver_error(stt_socket, monitor) or (
            exception if isinstance(exception, SonioxStreamError) else SonioxStreamError()
        )
        stt_socket._stream_error = error
        raise error from exception
    error = _receiver_error(stt_socket, monitor)
    if error is not None:
        raise error
    if not getattr(stt_socket, '_stream_finished', False):
        raise SonioxStreamError()


async def report_stt_error(websocket, error):
    """Release the client connection before slow session persistence/cleanup."""
    try:
        await websocket.send_json(error.to_event())
    except Exception:
        pass  # The client may have disconnected while the error was arriving.
    try:
        await websocket.close(code=error.close_code, reason='Transcription service unavailable')
    except Exception:
        pass
