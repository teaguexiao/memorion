"""Soniox real-time transport without database or other STT provider dependencies."""

import asyncio
import json
import os
import time
import uuid
from typing import List

import websockets

from utils.stt.stream_lifecycle import SonioxStreamError


def _is_websocket_closed(ws) -> bool:
    """Check if a websocket is closed, compatible with websockets 15.x+"""
    # In websockets 15.x, 'closed' attribute was removed
    # Use state attribute or close_code to check
    try:
        # Try using state (websockets 15.x)
        if hasattr(ws, 'state'):
            return ws.state.name == 'CLOSED'
        # Fallback to close_code
        if hasattr(ws, 'close_code'):
            return ws.close_code is not None
        # Legacy fallback
        return getattr(ws, 'closed', False)
    except Exception:
        return True  # Assume closed if we can't determine


async def process_audio_soniox(
    stream_transcript, sample_rate: int, language: str, uid: str, preseconds: int = 0, language_hints: List[str] = [],
    keepalive_interval: int = 15, language_hints_strict: bool = False,
    enable_endpoint_detection: bool = False, max_endpoint_delay_ms: int = None,
    enable_speaker_diarization: bool = True,
):
    """
    Process audio through Soniox Speech-to-Text WebSocket API with keep-alive functionality.

    This function implements WebSocket keep-alive as per Soniox documentation:
    https://soniox.com/docs/speech-to-text/core-concepts/connection-keepalive

    The keep-alive mechanism:
    - Sends {"type": "keepalive"} messages every 15 seconds (configurable) during silence
    - Maintains connection during VAD-detected silence periods
    - Ensures connection doesn't timeout (Soniox requires keepalive at least every 20 seconds)
    - Preserves session-level context (speaker labels, language tracking, etc.)

    Real-time latency optimization:
    - Uses max_non_final_tokens_duration_ms=3000 to optimize transcription latency for Chinese
    - Controls maximum duration non-final tokens can accumulate before finalization
    - Reference: https://soniox.com/docs/speech-to-text/core-concepts/real-time-latency

    Args:
        stream_transcript: Callback function to handle transcription results
        sample_rate: Audio sample rate (8000 or 16000 Hz)
        language: Language code for transcription
        uid: User ID for speaker identification (if enabled)
        preseconds: Number of seconds of pre-recorded audio to process
        language_hints: List of language hints for multi-language detection
        keepalive_interval: Interval in seconds for sending keepalive messages (default: 15)

    Returns:
        WebSocket connection object with keep-alive functionality
    """
    if not 0 < keepalive_interval < 20:
        raise ValueError('Soniox keepalive_interval must be greater than 0 and less than 20 seconds.')

    api_key = os.getenv('SONIOX_API_KEY')
    if not api_key:
        raise SonioxStreamError(401, 'unauthenticated')

    uri = 'wss://stt-rt.soniox.com/transcribe-websocket'

    # Speaker identification only works with English and 16kHz sample rate
    # New Soniox streaming is not supported speaker indentification
    has_speech_profile = (
        False  # create_user_speech_profile(uid) if uid and sample_rate == 16000 and language == 'en' else False
    )

    # Determine audio format based on sample rate
    audio_format = "s16le" if sample_rate == 16000 else "mulaw"

    # Optimize latency parameters based on language
    # For Chinese, use shorter duration to reduce latency
    max_non_final_duration = 3000 if language == 'zh' else 4000

    # Construct the initial request with all required and optional parameters
    # Soniox speaker diarization is available for all supported languages
    request = {
        'model': 'stt-rt-v5',
        'audio_format': audio_format,
        'sample_rate': sample_rate,
        'num_channels': 1,
        'enable_speaker_diarization': enable_speaker_diarization,
        'language_hints': language_hints if language_hints else [],
        'max_non_final_tokens_duration_ms': max_non_final_duration,  # Optimized for lower latency
    }

    if language_hints_strict:
        request['language_hints_strict'] = True
    if enable_endpoint_detection:
        request['enable_endpoint_detection'] = True
        if max_endpoint_delay_ms is not None:
            request['max_endpoint_delay_ms'] = max_endpoint_delay_ms

    # Add speaker identification if available
    if has_speech_profile:
        request['enable_speaker_identification'] = True
        request['cand_speaker_names'] = [uid]

    soniox_socket = None
    keepalive_task = None
    on_message_task = None
    try:
        # Connect to Soniox WebSocket

        print("Connecting to Soniox WebSocket...")
        soniox_socket = await websockets.connect(
            uri,
            additional_headers={'Authorization': f'Bearer {api_key}'},
            ping_timeout=None,
            ping_interval=None,
        )
        print("Connected to Soniox WebSocket.")

        soniox_socket._stream_error = None
        soniox_socket._stream_finished = False
        soniox_socket._completion_received = False
        soniox_socket._end_of_audio_sent = False
        last_activity_time = time.monotonic()
        original_send = soniox_socket.send

        async def send(message):
            nonlocal last_activity_time
            if soniox_socket._stream_error is not None:
                raise soniox_socket._stream_error
            if soniox_socket._completion_received or soniox_socket._end_of_audio_sent:
                return  # The provider has accepted the end of this stream.
            if message == '' or message == b'':
                # Stop all later audio/control sends while final results are pending.
                soniox_socket._end_of_audio_sent = True
            try:
                await original_send(message)
            except websockets.exceptions.ConnectionClosed as error:
                if soniox_socket._completion_received and soniox_socket._stream_error is None:
                    return
                raise soniox_socket._stream_error or SonioxStreamError() from error
            last_activity_time = time.monotonic()

        # Track actual sends, including audio forwarded by Listen and Talk.
        soniox_socket.send = send

        # Send the initial request
        await soniox_socket.send(json.dumps(request))
        print(f"Sent initial request: {request}")

        # Variable to track current speaker ID (for punctuation attribution)
        current_speaker_id = None

        # Keep-alive tracking variables
        keepalive_active = False

        # Keep-alive coroutine to maintain connection during silence
        # Follows Soniox documentation: send keepalive at least every 20 seconds during silence
        async def keepalive_handler():
            nonlocal keepalive_active
            keepalive_active = True
            print(f"Soniox keepalive handler started with {keepalive_interval}s interval")
            try:
                while (keepalive_active and not soniox_socket._completion_received
                       and not soniox_socket._end_of_audio_sent and not _is_websocket_closed(soniox_socket)):
                    # Recompute the remaining deadline after each wake. Sleeping
                    # another full interval after recent audio can leave almost
                    # 30 seconds of silence with the default 15-second interval.
                    remaining = keepalive_interval - (time.monotonic() - last_activity_time)
                    await asyncio.sleep(max(0, remaining))
                    if soniox_socket._end_of_audio_sent or soniox_socket._completion_received:
                        break
                    silence = time.monotonic() - last_activity_time
                    if silence >= keepalive_interval and not _is_websocket_closed(soniox_socket):
                        try:
                            keepalive_message = json.dumps({"type": "keepalive"})
                            await soniox_socket.send(keepalive_message)
                            print(f"Sent Soniox keepalive message after {silence:.1f}s of silence")
                        except websockets.exceptions.ConnectionClosed:
                            soniox_socket._stream_error = soniox_socket._stream_error or SonioxStreamError()
                            break
                        except Exception as e:
                            soniox_socket._stream_error = (
                                e if isinstance(e, SonioxStreamError) else SonioxStreamError()
                            )
                            await soniox_socket.close()
                            break
            except asyncio.CancelledError:
                print("Soniox keepalive handler cancelled")
            except Exception:
                soniox_socket._stream_error = SonioxStreamError()
                await soniox_socket.close()
            finally:
                keepalive_active = False
                print("Soniox keepalive handler stopped")

        # Start listening for messages from Soniox
        async def on_message():
            nonlocal current_speaker_id, keepalive_active

            # Persistent state across messages for accumulating same-speaker content
            persistent_segment_id = None
            persistent_segment_speaker = None
            persistent_segment_text = []
            persistent_segment_start = None
            persistent_segment_end = None
            last_log_time = 0
            last_logged_text = None

            async def send_current_segment(log=False):
                """Send the current accumulated segment to the client."""
                nonlocal persistent_segment_id, persistent_segment_speaker
                nonlocal persistent_segment_text, persistent_segment_start, persistent_segment_end

                if not persistent_segment_text or persistent_segment_speaker is None:
                    return
                if persistent_segment_start is None or persistent_segment_end is None:
                    return

                content = ''.join(persistent_segment_text)
                if not content.strip():
                    return

                # Filter out invalid Soniox placeholders (e.g. "No transcription")
                invalid_texts = ['no transcription', 'no transcript']
                if content.strip().lower() in invalid_texts:
                    print(f"Filtered invalid segment: '{content.strip()}'")
                    return

                start_time = persistent_segment_start / 1000.0
                end_time = persistent_segment_end / 1000.0

                if preseconds > 0 and start_time < preseconds:
                    return

                # Adjust timing if we have preseconds
                if preseconds > 0:
                    start_time -= preseconds
                    end_time -= preseconds

                # Determine if this is the user
                is_user = False
                if has_speech_profile and persistent_segment_speaker == uid:
                    is_user = True
                elif preseconds > 0 and persistent_segment_speaker == "1":
                    is_user = True

                segment = {
                    'id': persistent_segment_id,
                    'speaker': f"SPEAKER_0{persistent_segment_speaker}",
                    'start': start_time,
                    'end': end_time,
                    'text': content,
                    'is_user': is_user,
                    'person_id': None,
                }

                nonlocal last_log_time, last_logged_text
                now = time.time()
                text_tail = content[-60:] if len(content) > 60 else content
                if log:
                    print(f"Segment complete: id={persistent_segment_id[:8]}..., speaker={segment['speaker']}, len={len(content)}, text='...{text_tail}'")
                    last_log_time = now
                    last_logged_text = content
                elif now - last_log_time >= 3 and content != last_logged_text:
                    print(f"Streaming segment: id={persistent_segment_id[:8]}..., speaker={segment['speaker']}, len={len(content)}, text='...{text_tail}'")
                    last_log_time = now
                    last_logged_text = content
                result = stream_transcript([segment])
                if asyncio.iscoroutine(result):
                    await result

            def start_new_segment(speaker_id, token_text, token_start, token_end):
                """Start a new segment for a new speaker."""
                nonlocal persistent_segment_id, persistent_segment_speaker
                nonlocal persistent_segment_text, persistent_segment_start, persistent_segment_end

                persistent_segment_id = str(uuid.uuid4())
                persistent_segment_speaker = speaker_id
                persistent_segment_text = [token_text]
                persistent_segment_start = token_start
                persistent_segment_end = token_end
                print(f"Starting new segment {persistent_segment_id[:8]}... for speaker {speaker_id}")

            try:
                async for message in soniox_socket:
                    response = json.loads(message)

                    # Check for error responses
                    if 'error_code' in response:
                        raise SonioxStreamError(
                            response.get('error_code', 503),
                            response.get('error_type', 'provider_error'),
                            response.get('request_id'),
                        )

                    if response.get('finished'):
                        soniox_socket._completion_received = True

                    # Process response based on tokens field
                    if 'tokens' in response:
                        tokens = response.get('tokens', [])

                        if not tokens:
                            if response.get('finished'):
                                soniox_socket._stream_finished = True
                                break
                            continue

                        # Track accumulated text for Talk API instant use
                        # Final tokens accumulate permanently; non-final tokens are the latest window
                        final_parts = [t['text'] for t in tokens if t.get('is_final', False) and t['text'] not in ('<fin>', '<end>')]
                        non_final_parts = [t['text'] for t in tokens if not t.get('is_final', False) and t['text'] not in ('<fin>', '<end>')]
                        if final_parts:
                            soniox_socket._final_text += ''.join(final_parts)
                        soniox_socket._non_final_text = ''.join(non_final_parts)
                        soniox_socket._latest_text = soniox_socket._final_text + soniox_socket._non_final_text

                        for token in tokens:
                            token_text = token['text']
                            is_final = token.get('is_final', False)
                            token_speaker = token.get('speaker')

                            # Handle <fin> token from manual finalization
                            if token_text == '<fin>' and is_final:
                                print("Soniox <fin> token received, finalization complete")
                                await send_current_segment(log=True)
                                fin_event = getattr(soniox_socket, '_finalize_event', None)
                                if fin_event:
                                    fin_event.set()
                                continue

                            # Handle <end> token from endpoint detection
                            if token_text == '<end>' and is_final:
                                print("Soniox <end> token received, endpoint detected")
                                await send_current_segment(log=True)
                                continue

                            # Only process final tokens to avoid duplication
                            if not is_final:
                                continue

                            # Get speaker ID, default to "1" if not provided
                            if token_speaker is not None:
                                speaker_id = str(token_speaker)
                            else:
                                speaker_id = current_speaker_id if current_speaker_id is not None else "1"

                            # Get timing info
                            token_start = token.get('start_ms')
                            token_end = token.get('end_ms')

                            # Check if speaker changed
                            if persistent_segment_speaker is not None and persistent_segment_speaker != speaker_id:
                                # Speaker changed! Send the accumulated segment first
                                content = ''.join(persistent_segment_text)

                                # Check if content is only punctuation
                                punctuation_chars = '，。！？；：、""''（）《》【】…—,.!?;:\'"()[]{}...-'
                                is_only_punctuation = all(char in punctuation_chars or char.isspace() for char in content)

                                if content.strip() and not is_only_punctuation:
                                    print(f"SPEAKER CHANGE: Finishing segment for {persistent_segment_speaker}")
                                    await send_current_segment(log=True)

                                # Start new segment for new speaker
                                start_new_segment(speaker_id, token_text, token_start, token_end)
                            else:
                                # Same speaker or first token, accumulate
                                if persistent_segment_speaker is None:
                                    # First token ever
                                    start_new_segment(speaker_id, token_text, token_start, token_end)
                                else:
                                    # Same speaker, append to existing segment
                                    persistent_segment_text.append(token_text)
                                    persistent_segment_end = token_end

                            # Update global current_speaker_id
                            current_speaker_id = speaker_id

                        # Send updated segment after processing all tokens in this message
                        await send_current_segment()

                    else:
                        print(f"Unexpected Soniox response format: {response}")
                    if response.get('finished'):
                        # Deliver final tokens before declaring success, and
                        # stop reading once the provider confirms completion.
                        soniox_socket._stream_finished = True
                        break
            except websockets.exceptions.ConnectionClosed:
                if not soniox_socket._stream_finished:
                    soniox_socket._stream_error = soniox_socket._stream_error or SonioxStreamError()
            except Exception as e:
                soniox_socket._stream_error = (
                    e if isinstance(e, SonioxStreamError)
                    else soniox_socket._stream_error or SonioxStreamError()
                )
                print(soniox_socket._stream_error)
            finally:
                if not soniox_socket._stream_finished and soniox_socket._stream_error is None:
                    soniox_socket._stream_error = SonioxStreamError()
                # Stop keepalive handler when message processing ends
                keepalive_active = False
                if keepalive_task is not None:
                    keepalive_task.cancel()
                    await asyncio.gather(keepalive_task, return_exceptions=True)
                if not _is_websocket_closed(soniox_socket):
                    await soniox_socket.close()
                    print("Soniox WebSocket closed in on_message.")

        # Initialize tracking attributes for Talk API instant text
        soniox_socket._final_text = ''      # Accumulated final tokens text
        soniox_socket._non_final_text = ''  # Latest non-final tokens text
        soniox_socket._latest_text = None   # Combined: final + non-final

        # Start the coroutines
        on_message_task = asyncio.create_task(on_message())
        soniox_socket._on_message_task = on_message_task
        keepalive_task = asyncio.create_task(keepalive_handler())

        # Store the keepalive task reference on the socket for cleanup
        soniox_socket._keepalive_task = keepalive_task

        # Add method to update last audio sent time
        def update_last_audio_time():
            nonlocal last_activity_time
            last_activity_time = time.monotonic()

        soniox_socket._update_last_audio_time = update_last_audio_time

        # Return the Soniox WebSocket object
        return soniox_socket

    except (Exception, asyncio.CancelledError) as error:
        # Configuration sends can fail or be cancelled after opening the socket.
        # Release it even when no receiver/keepalive task was started yet.
        for task in (on_message_task, keepalive_task):
            if task is not None:
                task.cancel()
        await asyncio.gather(
            *(task for task in (on_message_task, keepalive_task) if task is not None),
            return_exceptions=True,
        )
        if soniox_socket is not None:
            await soniox_socket.close()
        if isinstance(error, asyncio.CancelledError):
            raise
        if isinstance(error, SonioxStreamError):
            raise
        if isinstance(error, websockets.exceptions.InvalidStatus):
            status = error.response.status_code
            kind = {401: 'unauthenticated', 403: 'permission_denied'}.get(status, 'handshake_rejected')
            raise SonioxStreamError(status, kind) from error
        raise SonioxStreamError(503, 'connection_failed') from error
