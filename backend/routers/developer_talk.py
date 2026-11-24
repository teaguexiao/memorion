"""
Developer API - Talk endpoints (Real-time Audio Streaming with LLM Cleaning)

Provides real-time speech-to-text with intelligent LLM-based transcript cleaning:
- WebSocket-based real-time audio streaming
- Session management for talk sessions
- Post-stream LLM cleaning (filler removal, punctuation, self-correction detection)
"""

import asyncio
import json
import os
import struct
import time as time_module
import uuid
from datetime import datetime, timezone
from typing import List, Optional, Dict, Any

import threading

import opuslib
from fastapi import APIRouter, HTTPException, Query, WebSocket, WebSocketDisconnect

# Global lock for opuslib ctypes calls — libopus is not thread-safe
_opus_lock = threading.Lock()
from pydantic import BaseModel, Field
from starlette.websockets import WebSocketState

import database.developer_data as dev_db
from database.developers import (
    KEY_AUTH_ERROR_FORBIDDEN,
    resolve_developer_id_for_external_user,
)
from dependencies import require_developer_for_external_user
from utils.stt.streaming import (
    STTService,
    get_stt_service_for_language,
    process_audio_dg,
    process_audio_soniox,
)
from utils.stt.stream_lifecycle import SonioxStreamError, finish_soniox_stream, receive_with_stt, report_stt_error
from utils.llm.transcript_cleaner import clean_transcript

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class TranscriptSegment(BaseModel):
    text: str
    start: float
    end: float
    speaker: Optional[str] = None
    is_user: bool = False


class TalkSessionResponse(BaseModel):
    id: str
    status: str  # active, completed, failed
    language: str
    stt_service: str
    cleaning_level: str
    output_format: str
    transcript_segments: List[TranscriptSegment]
    cleaned_text: Optional[str] = None
    cleaning_changes: List[Dict[str, Any]] = []
    duration_seconds: float
    created_at: datetime
    updated_at: datetime


class CreateTalkSessionRequest(BaseModel):
    language: str = Field(default="zh", description="Language code (e.g., 'en', 'zh', 'multi')")
    sample_rate: int = Field(default=16000, description="Audio sample rate in Hz (8000 or 16000)")
    codec: str = Field(default="pcm16", description="Audio codec: 'pcm16', 'opus', or 'opus_fs320'")
    cleaning_level: str = Field(default="standard", description="Cleaning level: 'light', 'standard', or 'aggressive'")
    output_format: str = Field(default="paragraph", description="Output format: 'paragraph', 'bullets', or 'raw'")


class CreateTalkSessionResponse(BaseModel):
    session_id: str
    websocket_url: str
    stt_service: str
    language: str
    cleaning_level: str
    output_format: str


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************


active_sessions: Dict[str, Dict[str, Any]] = {}


def create_wav_bytes(pcm_data: bytes, sample_rate: int) -> bytes:
    """Create WAV file bytes from raw PCM data."""
    channels = 1
    sample_width = 2  # 16-bit PCM

    wav_header = struct.pack(
        '<4sI4s4sIHHIIHH4sI',
        b'RIFF',
        36 + len(pcm_data),
        b'WAVE',
        b'fmt ',
        16,  # Subchunk1Size
        1,   # AudioFormat (PCM)
        channels,
        sample_rate,
        sample_rate * channels * sample_width,  # ByteRate
        channels * sample_width,  # BlockAlign
        sample_width * 8,  # BitsPerSample
        b'data',
        len(pcm_data)
    )
    return wav_header + pcm_data


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.post("/v1/talk", response_model=CreateTalkSessionResponse, tags=["developer-api-talk"])
async def create_session(
    request: CreateTalkSessionRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    Create a new real-time talk session.

    Returns a session ID and WebSocket URL for streaming audio.
    Audio should be sent as binary frames to the WebSocket.
    After the stream ends, the transcript is cleaned using LLM processing.

    Supported formats:
    - pcm16: 16-bit PCM audio (linear16)
    - opus: Opus encoded audio
    - opus_fs320: Opus with 320 frame size (used by OmiGlass device)

    Sample rates: 8000 Hz or 16000 Hz

    Cleaning levels:
    - light: Remove fillers + add punctuation only
    - standard: Remove fillers, repetitions, self-corrections + add punctuation
    - aggressive: All of standard + light restructuring for readability
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    # Validate sample rate
    if request.sample_rate not in [8000, 16000]:
        raise HTTPException(status_code=400, detail="Sample rate must be 8000 or 16000 Hz")

    # Validate codec
    if request.codec not in ["pcm16", "opus", "opus_fs320"]:
        raise HTTPException(status_code=400, detail="Codec must be 'pcm16', 'opus', or 'opus_fs320'")

    # Validate cleaning_level
    if request.cleaning_level not in ["light", "standard", "aggressive"]:
        raise HTTPException(status_code=400, detail="cleaning_level must be 'light', 'standard', or 'aggressive'")

    # Validate output_format
    if request.output_format not in ["paragraph", "bullets", "raw"]:
        raise HTTPException(status_code=400, detail="output_format must be 'paragraph', 'bullets', or 'raw'")

    # Get STT service for language
    stt_service, stt_language, model = get_stt_service_for_language(request.language)

    # Create session in database
    session = dev_db.create_talk_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        language=request.language,
        stt_service=stt_service.value,
        cleaning_level=request.cleaning_level,
        output_format=request.output_format,
    )

    # Generate WebSocket URL
    base_url = os.getenv("API_BASE_URL", "https://api.memorion.me")
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://")
    ws_url = (
        f"{ws_base}/v1/talk/stream/{session['id']}"
        f"?external_user_id={external_user_id}"
        f"&api_key={api_key}"
        f"&language={request.language}"
        f"&sample_rate={request.sample_rate}"
        f"&codec={request.codec}"
        f"&cleaning_level={request.cleaning_level}"
        f"&output_format={request.output_format}"
    )

    return CreateTalkSessionResponse(
        session_id=session["id"],
        websocket_url=ws_url,
        stt_service=stt_service.value,
        language=stt_language,
        cleaning_level=request.cleaning_level,
        output_format=request.output_format,
    )


@router.get("/v1/talk", tags=["developer-api-talk"])
async def list_sessions(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=50, ge=1, le=100, description="Maximum sessions to return"),
    offset: int = Query(default=0, ge=0, description="Number to skip"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    List talk sessions for a user.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    sessions = dev_db.get_talk_sessions(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit,
        offset=offset,
    )

    return [
        {
            "id": s["id"],
            "status": s["status"],
            "language": s["language"],
            "stt_service": s.get("stt_service", "soniox"),
            "cleaning_level": s.get("cleaning_level", "standard"),
            "output_format": s.get("output_format", "paragraph"),
            "duration_seconds": s.get("duration_seconds", 0.0),
            "has_cleaned_text": s.get("cleaned_text") is not None,
            "created_at": s["created_at"].isoformat() if hasattr(s["created_at"], 'isoformat') else s["created_at"],
        }
        for s in sessions
    ]


@router.get("/v1/talk/{session_id}", response_model=TalkSessionResponse, tags=["developer-api-talk"])
async def get_session(
    session_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    Get the status and results of a talk session.

    Once the session is completed, the response includes the LLM-cleaned transcript.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    session = dev_db.get_talk_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        session_id=session_id,
    )

    if not session:
        raise HTTPException(status_code=404, detail="Talk session not found")

    return TalkSessionResponse(
        id=session["id"],
        status=session["status"],
        language=session["language"],
        stt_service=session.get("stt_service", "soniox"),
        cleaning_level=session.get("cleaning_level", "standard"),
        output_format=session.get("output_format", "paragraph"),
        transcript_segments=[TranscriptSegment(**s) for s in session.get("transcript_segments", [])],
        cleaned_text=session.get("cleaned_text"),
        cleaning_changes=session.get("cleaning_changes", []),
        duration_seconds=session.get("duration_seconds", 0.0),
        created_at=session["created_at"],
        updated_at=session["updated_at"],
    )


@router.websocket("/v1/talk/stream/{session_id}")
async def websocket_stream(
    websocket: WebSocket,
    session_id: str,
    external_user_id: str = Query(...),
    api_key: str = Query(...),
    language: str = Query(default="zh"),
    sample_rate: int = Query(default=16000),
    codec: str = Query(default="pcm16"),
    cleaning_level: str = Query(default="standard"),
    output_format: str = Query(default="paragraph"),
):
    """
    WebSocket endpoint for real-time audio streaming with LLM cleaning.

    Send audio data as binary frames.
    Receive transcript updates as JSON messages.

    Message types (received from server):
    - {"type": "ready", ...} - Session ready, start sending audio
    - {"type": "partial", "text": "..."} - Interim/partial transcript (may change)
    - {"type": "sentence", "segments": [...]} - Final transcript segment
    - {"type": "cleaned", "text": "...", "changes": [...]} - LLM-cleaned final result
    - {"type": "complete", ...} - Session complete
    - {"type": "error", "message": "..."} - Error occurred

    Control messages (send to server):
    - {"type": "end"} - Signal end of recording. The server will continue accepting
      in-flight audio frames for up to 500ms after receiving this message, ensuring
      no trailing audio is lost. After draining, the server waits for STT to stabilize,
      then runs LLM cleaning and sends the result.
    - {"type": "keepalive"} - Keep connection alive
    """
    # Authenticate (enforces user-bound keys)
    developer_id, auth_error = resolve_developer_id_for_external_user(api_key, external_user_id)
    if auth_error == KEY_AUTH_ERROR_FORBIDDEN:
        await websocket.close(code=4003, reason="API key not authorized for this external_user_id")
        return
    if not developer_id:
        await websocket.close(code=4001, reason="Invalid API key")
        return

    # Verify session exists
    session = dev_db.get_talk_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        session_id=session_id,
    )

    if not session:
        await websocket.close(code=4004, reason="Session not found")
        return

    await websocket.accept()

    # Handle opus_fs320 codec
    frame_size = 160
    if codec == "opus_fs320":
        frame_size = 320
        codec = "opus"

    # Initialize Opus decoder if needed
    opus_decoder = None
    if codec == "opus":
        with _opus_lock:
            opus_decoder = opuslib.Decoder(sample_rate, 1)
        print(f"[Talk] Initialized Opus decoder: sample_rate={sample_rate}, frame_size={frame_size}")

    # Get STT service for language
    stt_service, stt_language, model = get_stt_service_for_language(language)

    # Track transcript segments
    all_segments: List[Dict[str, Any]] = []
    all_segments_index: Dict[str, int] = {}
    timestamp_offset: Optional[float] = None
    stt_socket = None
    stt_error = None
    finalization_warning = None
    tolerated_finalization_error = None
    start_time = datetime.utcnow()
    audio_buffer = bytearray()

    async def stream_transcript(segments: List[Dict[str, Any]]):
        """Callback to handle transcript segments from STT service."""
        nonlocal all_segments, timestamp_offset
        try:
            if websocket.client_state == WebSocketState.CONNECTED:
                # Determine timestamp offset from the first segment
                if timestamp_offset is None and segments:
                    first_start = segments[0].get('start', 0)
                    if first_start > 0:
                        timestamp_offset = first_start
                        print(f"[Talk] Timestamp offset set to {timestamp_offset:.2f}s")
                    else:
                        timestamp_offset = 0.0

                for seg in segments:
                    # Normalize timestamps
                    if timestamp_offset and timestamp_offset > 0:
                        seg['start'] = round(seg.get('start', 0) - timestamp_offset, 2)
                        seg['end'] = round(seg.get('end', 0) - timestamp_offset, 2)

                    seg_id = seg.get('id')

                    # Upsert by segment ID to deduplicate streaming updates
                    if seg_id and seg_id in all_segments_index:
                        all_segments[all_segments_index[seg_id]] = seg
                    else:
                        if seg_id:
                            all_segments_index[seg_id] = len(all_segments)
                        all_segments.append(seg)

                # Determine if these are partial or final segments
                # Soniox marks final segments; for others assume final
                is_final = any(seg.get('is_final', True) for seg in segments)

                if is_final:
                    await websocket.send_json({
                        "type": "sentence",
                        "segments": segments,
                    })
                else:
                    # Send combined partial text
                    partial_text = " ".join(seg.get('text', '') for seg in segments)
                    await websocket.send_json({
                        "type": "partial",
                        "text": partial_text,
                    })
        except Exception as e:
            print(f"[Talk] Error sending transcript: {e}")

    try:
        # Update session status to active
        dev_db.update_talk_session(
            developer_id=developer_id,
            external_user_id=external_user_id,
            session_id=session_id,
            status="active",
        )

        # Connect to STT service
        if stt_service == STTService.deepgram:
            stt_socket = await process_audio_dg(
                stream_transcript=stream_transcript,
                language=stt_language,
                sample_rate=sample_rate,
                channels=1,
                preseconds=0,
                model=model,
            )
        elif stt_service == STTService.soniox:
            stt_socket = await process_audio_soniox(
                stream_transcript=stream_transcript,
                sample_rate=sample_rate,
                language=stt_language,
                uid=external_user_id,
                preseconds=0,
                language_hints=[stt_language] if stt_language and stt_language != 'multi' else [],
                enable_endpoint_detection=True,
                max_endpoint_delay_ms=500,
                enable_speaker_diarization=False,
            )

        # Send ready message
        await websocket.send_json({
            "type": "ready",
            "session_id": session_id,
            "stt_service": stt_service.value,
            "language": stt_language,
            "cleaning_level": cleaning_level,
            "output_format": output_format,
        })

        # Main loop - receive audio and forward to STT
        end_received = False
        end_deadline = 0.0  # monotonic timestamp
        DRAIN_WINDOW_S = 0.5  # seconds to keep accepting audio after "end"

        while True:
            try:
                # After "end" received, use a short timeout to drain in-flight audio
                if end_received:
                    remaining = end_deadline - time_module.monotonic()
                    if remaining <= 0:
                        print(f"[Talk] Drain window expired, exiting receive loop")
                        break
                    try:
                        data = await receive_with_stt(websocket, stt_socket, timeout=remaining)
                    except asyncio.TimeoutError:
                        print(f"[Talk] Drain timeout, no more data")
                        break
                else:
                    data = await receive_with_stt(websocket, stt_socket)

                if data["type"] == "stt.finished":
                    break
                if data["type"] == "websocket.disconnect":
                    print(f"[Talk] Received websocket.disconnect")
                    break

                if "text" in data:
                    msg = json.loads(data["text"])
                    print("[Talk] Received a text message")
                    if msg.get("type") == "end":
                        t_end = time_module.monotonic()
                        print(f"[Talk] End message received, audio_buffer={len(audio_buffer)} bytes")
                        # Don't break immediately — keep draining in-flight audio
                        # for up to DRAIN_WINDOW_S so clients don't lose trailing frames.
                        end_received = True
                        end_deadline = t_end + DRAIN_WINDOW_S
                        continue
                    elif msg.get("type") == "keepalive":
                        if stt_service == STTService.soniox and stt_socket:
                            await stt_socket.send(json.dumps({"type": "keepalive"}))

                elif "bytes" in data:
                    audio_bytes = data["bytes"]
                    if audio_bytes == b'' and stt_service == STTService.soniox and stt_socket:
                        end_received = True  # legacy end-of-audio marker
                        break

                    # Decode Opus to PCM if needed
                    if opus_decoder is not None:
                        try:
                            with _opus_lock:
                                audio_bytes = opus_decoder.decode(bytes(audio_bytes), frame_size=frame_size)
                        except Exception as e:
                            print(f"[Talk] Opus decode error: {e}")
                            continue

                    audio_buffer.extend(audio_bytes)

                    if stt_socket:
                        if stt_service == STTService.deepgram:
                            stt_socket.send(audio_bytes)
                        elif stt_service == STTService.soniox:
                            if getattr(stt_socket, '_stream_error', None):
                                raise stt_socket._stream_error
                            if getattr(stt_socket, '_stream_finished', False):
                                break
                            await stt_socket.send(audio_bytes)

            except WebSocketDisconnect:
                break
            except SonioxStreamError:
                raise
            except Exception as e:
                print(f"[Talk] Error in WebSocket loop: {e}")
                break

        # After exiting the receive loop, wait for STT to finish processing
        if stt_service == STTService.soniox and stt_socket:
            if end_received:
                try:
                    await finish_soniox_stream(stt_socket, timeout=1.5)
                except SonioxStreamError as error:
                    if (error.error_type != 'final_transcript_timeout'
                            or getattr(stt_socket, '_stream_error', None) is not error
                            or not (getattr(stt_socket, '_latest_text', None) or '').strip()):
                        raise
                    # A missing completion acknowledgment must not discard
                    # available Talk text. Provider rejections never use this path.
                    tolerated_finalization_error = error
                    finalization_warning = 'used_tentative_text'
                    print('[Talk] Final response timed out; using available transcript')
            t_stt_wait = time_module.monotonic()
            if not end_received and not getattr(stt_socket, '_stream_finished', False):
                await asyncio.sleep(0.5)  # minimum wait for STT to process last audio
                if getattr(stt_socket, '_stream_error', None):
                    raise stt_socket._stream_error
                text_before = getattr(stt_socket, '_latest_text', None)
                # Poll for up to 1000ms more: stop if text stable for 200ms
                stable_count = 0
                for _ in range(10):
                    await asyncio.sleep(0.1)
                    if getattr(stt_socket, '_stream_error', None):
                        raise stt_socket._stream_error
                    text_now = getattr(stt_socket, '_latest_text', None)
                    if text_now and text_now != text_before:
                        text_before = text_now
                        stable_count = 0
                    else:
                        stable_count += 1
                        if stable_count >= 2:  # stable for 200ms
                            break

            latest_text = getattr(stt_socket, '_latest_text', None)
            wait_ms = (time_module.monotonic() - t_stt_wait) * 1000
            if latest_text:
                print(f"[Talk] Using text after {wait_ms:.0f}ms STT wait ({len(latest_text)} characters)")
                if not all_segments:
                    all_segments.append({
                        'text': latest_text,
                        'speaker': 'SPEAKER_01',
                        'start': 0,
                        'end': len(audio_buffer) / (sample_rate * 2),
                        'is_final': False,
                    })
                else:
                    all_segments[-1]['text'] = latest_text
            else:
                print(f"[Talk] No text available after {wait_ms:.0f}ms STT wait, segments: {len(all_segments)}")

    except SonioxStreamError as e:
        stt_error = e
        print(f"[Talk] {e}")
        await report_stt_error(websocket, e)
    except Exception as e:
        print(f"[Talk] WebSocket error: {e}")
        try:
            await websocket.send_json({
                "type": "error",
                "message": str(e),
            })
        except Exception:
            pass

    finally:
        receiver_error = getattr(stt_socket, '_stream_error', None)
        if receiver_error is not tolerated_finalization_error:
            stt_error = stt_error or receiver_error
        t_finally = time_module.monotonic()
        print(f"[Talk] Entering finally block, audio_buffer={len(audio_buffer)} bytes, segments={len(all_segments)}")

        # Calculate duration
        duration = (datetime.utcnow() - start_time).total_seconds()
        print(f"[Talk] Session duration: {duration:.1f}s")

        # Build transcript text from segments (already stable after finalize)
        cleaned_text = None
        cleaning_changes = []
        full_text = ""

        if all_segments:
            transcript_parts = []
            for seg in all_segments:
                transcript_parts.append(seg.get('text', ''))
            full_text = " ".join(transcript_parts).strip()

        # Fire-and-forget STT cleanup (don't block on it)
        async def _close_stt_bg():
            try:
                if stt_socket:
                    if stt_service == STTService.deepgram:
                        stt_socket.finish()
                    elif stt_service == STTService.soniox:
                        # Close socket first to unblock on_message's recv()
                        try:
                            await stt_socket.close()
                        except Exception:
                            pass
                        # Then cancel background tasks
                        for attr in ('_keepalive_task', '_on_message_task'):
                            task = getattr(stt_socket, attr, None)
                            if task and not task.done():
                                task.cancel()
                                try:
                                    await task
                                except (asyncio.CancelledError, Exception):
                                    pass
                print(f"[Talk] STT cleanup done")
            except Exception as e:
                print(f"[Talk] STT cleanup error: {e}")

        asyncio.create_task(_close_stt_bg())

        if full_text:
            print(f"[Talk] STT transcript length: {len(full_text)} characters")

            # LLM cleaning
            t_llm_start = time_module.monotonic()
            try:
                result = await clean_transcript(
                    text=full_text,
                    level=cleaning_level,
                    output_format=output_format,
                )
                cleaned_text = result.get("text", full_text)
                cleaning_changes = result.get("changes", [])
                print(f"[Talk] LLM cleaning took {(time_module.monotonic()-t_llm_start)*1000:.0f}ms")
                print(f"[Talk] Cleaned transcript length: {len(cleaned_text)} characters")
            except Exception as e:
                print(f"[Talk] LLM cleaning failed ({(time_module.monotonic()-t_llm_start)*1000:.0f}ms): {type(e).__name__}")
                cleaned_text = full_text
                cleaning_changes = [{"kind": "error", "detail": f"Cleaning failed: {str(e)}"}]

            # Send cleaned result to client if still connected
            receiver_error = getattr(stt_socket, '_stream_error', None)
            if (tolerated_finalization_error is not None and receiver_error is not None
                    and receiver_error is not tolerated_finalization_error and stt_error is None):
                stt_error = receiver_error
                await report_stt_error(websocket, stt_error)
            if websocket.client_state == WebSocketState.CONNECTED:
                try:
                    await websocket.send_json({
                        "type": "cleaned",
                        **({'finalization_warning': finalization_warning} if finalization_warning else {}),
                        "text": cleaned_text,
                        "changes": cleaning_changes,
                        "original_text": full_text,
                    })
                    print(f"[Talk] Sent cleaned result to client")
                except Exception as e:
                    print(f"[Talk] Error sending cleaned result: {e}")
            else:
                print(f"[Talk] WebSocket not connected, cannot send cleaned result")
        else:
            print(f"[Talk] No segments to clean")
            # Notify client that no speech was detected
            if websocket.client_state == WebSocketState.CONNECTED:
                try:
                    await websocket.send_json({
                        "type": "empty",
                        "message": "No speech detected. The audio may be too short or too quiet.",
                    })
                    print(f"[Talk] Sent empty notification to client")
                except Exception as e:
                    print(f"[Talk] Error sending empty notification: {e}")

        # Step 4: Send complete message and close client WebSocket
        receiver_error = getattr(stt_socket, '_stream_error', None)
        if (tolerated_finalization_error is not None and receiver_error is not None
                and receiver_error is not tolerated_finalization_error and stt_error is None):
            stt_error = receiver_error
            await report_stt_error(websocket, stt_error)

        if websocket.client_state == WebSocketState.CONNECTED:
            try:
                await websocket.send_json({
                    "type": "complete",
                    **({'finalization_warning': finalization_warning} if finalization_warning else {}),
                    "session_id": session_id,
                    "duration_seconds": duration,
                    "total_segments": len(all_segments),
                    "cleaned_text": cleaned_text,
                })
                print(f"[Talk] Sent complete message to client")
                await websocket.close()
            except Exception:
                pass

        # Update session with final results
        try:
            dev_db.update_talk_session(
                developer_id=developer_id,
                external_user_id=external_user_id,
                session_id=session_id,
                status="failed" if stt_error else "completed",
                error=str(stt_error) if stt_error else None,
                transcript_segments=all_segments,
                cleaned_text=cleaned_text,
                cleaning_changes=cleaning_changes,
                duration_seconds=duration,
            )
        except Exception as e:
            print(f"[Talk] Error updating talk session {session_id}: {e}")
            try:
                dev_db.update_talk_session(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    session_id=session_id,
                    status="failed" if stt_error else "completed",
                    error=str(stt_error) if stt_error else None,
                    duration_seconds=duration,
                )
            except Exception as e2:
                print(f"[Talk] Error updating talk session status {session_id}: {e2}")
