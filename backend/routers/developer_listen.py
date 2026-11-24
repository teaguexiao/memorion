"""
Developer API - Listen endpoints (Real-time Audio Streaming)

Provides real-time speech-to-text functionality:
- WebSocket-based real-time audio streaming
- Session management for listening sessions
- Support for Deepgram and Soniox STT services
"""

import asyncio
import json
import os
import struct
import threading
import time
import uuid
from copy import deepcopy
from datetime import datetime, timezone, timedelta
from typing import List, Optional, Dict, Any

import opuslib

# Global lock for opuslib ctypes calls — libopus is not thread-safe and
# concurrent decoder creation/usage across async tasks can corrupt the C heap.
_opus_lock = threading.Lock()
from fastapi import APIRouter, HTTPException, Query, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field
from starlette.websockets import WebSocketState

import database.developer_data as dev_db
from database import redis_db
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
    # send_initial_file_path,  # Removed: speech profile pre-send adds ~160s latency
)
from utils.stt.stream_lifecycle import SonioxStreamError, finish_soniox_stream, receive_with_stt, report_stt_error
from pydub import AudioSegment as PydubAudioSegment
from utils.stt.vad import vad_trim_silence_bytes
from utils.stt.timeline import conversation_segments, has_original_timestamps, stream_segment, transcribed_spans
from utils.other.storage import upload_conversation_recording_from_bytes
from utils.llm.conversation_processing import (
    extract_people_from_conversation,
    get_transcript_structure,
    map_speakers_to_names,
    merge_discard_verdict,
    should_discard_conversation,
    summary_marks_media,
)
from utils.other.storage import get_signed_url_from_path, get_profile_audio_if_exists
from utils.stt.speech_profile import identify_developer_speakers, _speaker_key
from models.transcript_segment import coerce_speaker_id
from utils.analytics import record_usage_developer
from utils.subscription import ensure_entitlement_for_use, has_transcription_credits_developer

router = APIRouter()

# Conversation splitting: when no new segments arrive for this many seconds,
# finalize the current batch into a conversation and start fresh.
# This mirrors the behavior of transcribe.py's conversation_creation_timeout.
CONVERSATION_CREATION_TIMEOUT = 120  # seconds

# Maximum transcript characters to send to LLM to avoid input-too-large errors
MAX_LLM_TRANSCRIPT_CHARS = 100000

# 「收到的音频秒数 / 会话墙钟秒数」超过这个值就报客户端重复发帧（见 WS finally 里的探测器）。
#
# 为什么是 1.5 而不是 1.0：客户端不是严格实时喂的（缓冲 + 一次 flush 多帧、断线重传），
# 所以健康会话也会略微越过 1.0。2026-08-17 实测健康会话的实时倍率是 0.87 / 0.90 / 1.40，
# 而故障会话是 6.1 ~ 14.8 —— 缝很宽，1.5 两边都留了余量。⚠️ 别为了「更灵敏」往 1.0 压：
# 这条日志的价值在于它响的时候一定是真的。
DUPLICATE_FRAME_ALERT_FACTOR = 1.5
USAGE_WRITE_INTERVAL_SECONDS = 30


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class TranscriptSegment(BaseModel):
    text: str
    start: float
    end: float
    speaker: Optional[str] = None
    is_user: bool = False
    original_start: Optional[float] = None
    original_end: Optional[float] = None
    timestamp_axis: Optional[str] = None


class ListenSessionResponse(BaseModel):
    id: str
    status: str  # active, completed, failed
    language: str
    stt_service: str
    transcript_segments: List[TranscriptSegment]
    duration_seconds: float
    created_at: datetime
    updated_at: datetime


class CreateSessionRequest(BaseModel):
    language: str = Field(default="zh", description="Language code (e.g., 'en', 'zh', 'multi')")
    sample_rate: int = Field(default=16000, description="Audio sample rate in Hz (8000 or 16000)")
    codec: str = Field(default="pcm16", description="Audio codec: 'pcm16', 'opus', or 'opus_fs320'")
    custom_stt: Optional[str] = Field(default=None, description="Set to 'enabled' for on-device STT mode (backend skips cloud STT)")


class CreateSessionResponse(BaseModel):
    session_id: str
    websocket_url: str
    stt_service: str
    language: str


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************


# Active WebSocket sessions keyed by (developer_id, external_user_id).
# Used to enforce single-session-per-user: when a new session starts, any
# existing session for the same user is terminated to prevent orphaned
# connections from accumulating billing.
active_sessions: Dict[str, asyncio.Event] = {}

# Maximum allowed session duration (seconds). Sessions exceeding this are
# force-closed to prevent unbounded billing from zombie connections.
MAX_SESSION_DURATION_SECONDS = 4 * 3600  # 4 hours


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


def create_listen_session(
    developer_id: str,
    external_user_id: str,
    language: str,
    stt_service: str,
) -> Dict[str, Any]:
    """Create a new listening session in the database."""
    return dev_db.create_listen_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        language=language,
        stt_service=stt_service,
    )


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.post("/v1/listen", response_model=CreateSessionResponse, tags=["developer-api-listen"])
async def create_session(
    request: CreateSessionRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    Create a new real-time listening session.

    Returns a session ID and WebSocket URL for streaming audio.
    Audio should be sent as binary frames to the WebSocket.

    Supported formats:
    - pcm16: 16-bit PCM audio (linear16)
    - opus: Opus encoded audio
    - opus_fs320: Opus with 320 frame size (used by OmiGlass device)

    Sample rates: 8000 Hz or 16000 Hz
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = await asyncio.to_thread(require_developer_for_external_user, api_key, external_user_id)

    # Validate sample rate
    if request.sample_rate not in [8000, 16000]:
        raise HTTPException(status_code=400, detail="Sample rate must be 8000 or 16000 Hz")

    # Validate codec
    if request.codec not in ["pcm16", "opus", "opus_fs320"]:
        raise HTTPException(status_code=400, detail="Codec must be 'pcm16', 'opus', or 'opus_fs320'")

    # The app-managed Founding Pro trial begins on first meaningful use. This is
    # deliberately independent of Apple billing: no transaction and no auto-renew.
    await asyncio.to_thread(ensure_entitlement_for_use, developer_id, external_user_id)

    # Check transcription credits before creating session to prevent
    # retry storms from clients whose usage limits are exceeded.
    # On-device STT (custom_stt) sessions don't consume transcription quota,
    # so they are allowed even when credits are exhausted.
    has_credits = request.custom_stt == "enabled" or await asyncio.to_thread(
        has_transcription_credits_developer,
        developer_id,
        external_user_id,
    )
    if not has_credits:
        raise HTTPException(status_code=429, detail="Usage limit exceeded. Please upgrade your plan.")

    # Sync user's language preference if the session language differs from stored preference
    stored_language = await asyncio.to_thread(dev_db.get_user_language, developer_id, external_user_id)
    if request.language and request.language != stored_language:
        await asyncio.to_thread(dev_db.set_user_language, developer_id, external_user_id, request.language)

    # Get STT service for language
    stt_service, stt_language, model = get_stt_service_for_language(request.language)

    # Create session in database
    session = await asyncio.to_thread(
        create_listen_session,
        developer_id,
        external_user_id,
        request.language,
        stt_service.value,
    )

    # Generate WebSocket URL
    base_url = os.getenv("API_BASE_URL", "https://api.memorion.me")
    # Convert https to wss for WebSocket
    ws_base = base_url.replace("https://", "wss://").replace("http://", "ws://")
    custom_stt_param = f"&custom_stt={request.custom_stt}" if request.custom_stt else ""
    ws_url = f"{ws_base}/v1/listen/stream/{session['id']}?external_user_id={external_user_id}&api_key={api_key}&language={request.language}&sample_rate={request.sample_rate}&codec={request.codec}{custom_stt_param}"

    return CreateSessionResponse(
        session_id=session["id"],
        websocket_url=ws_url,
        stt_service=stt_service.value,
        language=stt_language,
    )


@router.get("/v1/listen", tags=["developer-api-listen"])
async def list_sessions(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=50, ge=1, le=100, description="Maximum sessions to return"),
    offset: int = Query(default=0, ge=0, description="Number to skip"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    List listening sessions for a user.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    sessions = dev_db.get_listen_sessions(
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
            "stt_service": s.get("stt_service", "deepgram"),
            "duration_seconds": s.get("duration_seconds", 0.0),
            "created_at": s["created_at"].isoformat() if hasattr(s["created_at"], 'isoformat') else s["created_at"],
        }
        for s in sessions
    ]


@router.get("/v1/listen/{session_id}", response_model=ListenSessionResponse, tags=["developer-api-listen"])
async def get_session(
    session_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    Get the status and results of a listening session.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    session = dev_db.get_listen_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        session_id=session_id,
    )

    if not session:
        raise HTTPException(status_code=404, detail="Listening session not found")

    return ListenSessionResponse(
        id=session["id"],
        status=session["status"],
        language=session["language"],
        stt_service=session.get("stt_service", "deepgram"),
        transcript_segments=[TranscriptSegment(**s) for s in session.get("transcript_segments", [])],
        duration_seconds=session.get("duration_seconds", 0.0),
        created_at=session["created_at"],
        updated_at=session["updated_at"],
    )


def _auto_process_conversation(
    developer_id: str,
    external_user_id: str,
    session_id: str,
    segments: List[Dict[str, Any]],
    audio_path: Optional[str],
    language: str,
    started_at: datetime,
    duration: float,
    custom_stt_mode: bool = False,
    manual_speaker_ids: Optional[set] = None,
    session_started_at: Optional[datetime] = None,
):
    """
    Server-side auto-processing: create a conversation from accumulated segments.
    Called in the WebSocket finally block to ensure conversations are created
    even when the app doesn't explicitly call POST /v1/conversations/process.
    """
    # A cancelled asyncio.to_thread waiter does not stop the worker. Own this
    # snapshot before any LLM calls; session finalization must never change it.
    segments = conversation_segments(segments)
    timeline = {'version': 2, 'session_id': session_id}
    if session_started_at is not None and has_original_timestamps(segments):
        origin = min(s['original_start'] for s in segments)
        started_at = session_started_at + timedelta(seconds=origin)
        timeline.update(axis='display', origin_seconds=origin)

    # Build transcript text from segments — resolve person_id to real names so
    # the LLM-generated summary uses "Alice" rather than "Speaker 1" when the
    # client manually tagged segments mid-recording.
    person_ids = list({seg.get('person_id') for seg in segments if seg.get('person_id')})
    person_name_by_id: Dict[str, str] = {}
    if person_ids:
        try:
            people_docs = dev_db.get_people_by_ids(
                developer_id=developer_id,
                external_user_id=external_user_id,
                person_ids=person_ids,
            )
            person_name_by_id = {p['id']: p.get('name') for p in people_docs if p.get('name')}
        except Exception as e:
            print(f"[WS] Auto-process: Failed to resolve person names: {e}")

    # 🚨 The wearer's own segments MUST be labelled with the literal "User", not
    # their display name. The summarizer prompt hardcodes that string in three
    # places (`utils/llm/conversation_processing.py` :390 / :419 / :585), and one
    # of them is a *negative* test: ":419 — the \"User\" label never appears in the
    # transcript (only \"Speaker N\") — this strongly suggests the user was not
    # speaking, just listening to media". Substituting "Teague" makes that branch
    # read as true for every recording where the wearer spoke, so the summary gets
    # written from the wrong point of view and can be judged media playback.
    # Contrast memory extraction, which *does* get the name — its prompt
    # interpolates {user_name} and explicitly tells the model to ignore speaker
    # attribution (`utils/prompts.py:10`). The rule is: substitute the display
    # name only where the prompt has been told what the name is.
    transcript_parts = []
    for seg in segments:
        if seg.get('is_user'):
            speaker_label = "User"
        elif seg.get('person_id') and seg.get('person_id') in person_name_by_id:
            speaker_label = person_name_by_id[seg['person_id']]
        else:
            speaker_label = f"Speaker {coerce_speaker_id(seg.get('speaker_id', seg.get('speaker', 0)))}"
        transcript_parts.append(f"{speaker_label}: {seg.get('text', '')}")
    transcript_text = "\n".join(transcript_parts)

    if not transcript_text.strip():
        print(f"[WS] Auto-process: No transcript text, skipping")
        return

    # Filter out very short transcripts that are just noise (e.g. "嗯", "啊", stray punctuation)
    # These are typically produced when the client WebSocket disconnects quickly
    # and Soniox only picks up a fragment of ambient noise.
    MIN_TRANSCRIPT_CHARS = 30
    raw_text = ''.join(seg.get('text', '') for seg in segments).strip()
    if len(raw_text) < MIN_TRANSCRIPT_CHARS:
        print(f"[WS] Auto-process: Transcript too short ({len(raw_text)} chars < {MIN_TRANSCRIPT_CHARS}), skipping conversation creation")
        return

    # Skip conversations whose actual spoken duration is under 1 minute – they
    # rarely contain meaningful content and waste LLM processing credits.
    #
    # IMPORTANT: use the real speech span derived from segment timestamps, NOT
    # the wall-clock `duration`. The conversation is usually flushed after a
    # 120s silence timeout, so wall-clock time is dominated by silence and a
    # 2-second utterance would otherwise sail past a 60s wall-clock check.
    MIN_DURATION_SECONDS = 60
    # Only use segments that carry both endpoints, so a one-sided/bogus value
    # can't inflate the span.
    timed_segments = [seg for seg in segments if seg.get('start') is not None and seg.get('end') is not None]
    speech_span = (
        max(seg.get('end', 0.0) for seg in timed_segments) - min(seg.get('start', 0.0) for seg in timed_segments)
        if timed_segments else 0.0
    )
    if speech_span < MIN_DURATION_SECONDS:
        print(f"[WS] Auto-process: Speech span too short ({speech_span:.1f}s < {MIN_DURATION_SECONDS}s, wall-clock={duration:.1f}s), skipping conversation creation")
        return

    # LLM-based meaningfulness / media detection — mirrors the legacy
    # process_conversation pipeline that this auto-process path replaced.
    # Discards transcripts that are repetitive, contain no real user speech
    # (TV/podcast/music playback), or are otherwise judged meaningless.
    # Build attribute-style segment views since the helpers access
    # `.is_user`/`.text`/`.start`/`.end`. Carrying start/end is what lets the
    # duration-based rules (Rule 0 short-duration, Rule 0.5 language density)
    # actually fire on this real-time path — previously they got None and were
    # silently skipped.
    discard_segments = [
        type('Seg', (), {
            'is_user': bool(seg.get('is_user', False)),
            'text': seg.get('text', '') or '',
            'start': seg.get('start'),
            'end': seg.get('end'),
        })()
        for seg in segments
    ]
    # Reconstruct the conversation's wall-clock window so Rule 0 can compare it.
    # finished_at mirrors the batch pipeline: started_at + real speech span.
    discard_finished_at = started_at + timedelta(seconds=speech_span)
    #
    # ⚠️ A discard verdict must NOT `return` here. It used to, and that made this
    # path the only one where a discard is *unrecoverable*: `is_user` is produced
    # by voiceprint matching, which runs in a background thread AFTER the
    # conversation exists. Returning early means no conversation, so no voiceprint
    # pass, so `_revisit_user_dependent_verdicts` never gets a chance to undo a
    # "no user speech → media playback" misjudgement — the transcript is simply
    # never written. Measured on 2026-08-09: seven sessions were dropped this way
    # in one day, including 1178 segments / 14155 words and 583 segments / 7269
    # words of real conversation, at normal human speech density. A contaminated
    # person voiceprint was swallowing the owner's segments, so `is_user` was
    # False everywhere and the LLM saw "the User label never appears".
    #
    # Path 2 (`POST /v1/conversations/process`) has always done the right thing:
    # create the conversation, then pass the verdict to `finish_conversation`
    # (`discarded=should_discard`). Mirror that shape here — the app filters
    # discarded conversations out anyway, so a wrong verdict costs a hidden row
    # instead of the recording.
    should_discard = False
    try:
        should_discard = should_discard_conversation(
            transcript=transcript_text,
            photos=None,
            started_at=started_at,
            finished_at=discard_finished_at,
            transcript_segments=discard_segments,
            # 🚨 判据是「此刻**是否已经有**归属信息」，不是「这条路径将来会不会有」。
            # 这里跑在声纹线程之前，云端 STT 从不产出 is_user，所以除了用户在录音过程中
            # 手动标注过说话人（`speaker_assigned`，罕见）以外，`is_user` 必然全 False。
            # 默认值 True 会让 prompt 收到「用户未出现在任何分段 ⇒ 强媒体信号」——一个
            # 在这条路径上恒定触发、承载零信息量的"证据"。
            #
            # 2026-08-21 实测（8 天 112 条被丢弃的对话，79 条金标）：默认 True 时真实
            # 对话被误丢**约 80%**（4 次测量 77% / 79% / 81% / 83%，组内波动 4pp）；只改
            # 这一个参数就降到 24/70 = 34%，而媒体召回 9/9 一条不掉 —— 纯赚。这与 2026-08-15 修手表上传那次是同一个缺陷，当时
            # 只给离线路径传了 False，理由是「live 路径可由声纹翻案恢复」；但声纹覆盖率
            # 实测只有约 36%，多数误判等不到翻案。
            # ⚠️ `discard_segments` 是上面用 `type('Seg', (), {...})()` 造的**属性风格**
            # 对象，不是 dict —— 这里写 `s.get('is_user')` 会 AttributeError，而这整个
            # 调用在 try 里，异常会被吞成「判定失败，保留」⇒ 丢弃判定整体静默失效。
            speaker_attribution_available=any(
                getattr(s, 'is_user', False) for s in (discard_segments or [])
            ),
        )
    except Exception as e:
        # Never block conversation creation on a discard-check failure.
        print(f"[WS] Auto-process: should_discard_conversation failed ({e}), keeping conversation")
    if should_discard:
        print(
            f"[WS] Auto-process: Conversation judged not meaningful "
            f"({len(segments)} segments, speech_span={speech_span:.1f}s), marking as discarded"
        )

    # High-confidence speaker → real-name mapping (LLM, text-based).
    # Run on the FULL transcript (before truncation) since self-introductions
    # usually appear early and truncation keeps the tail. Only speakers with
    # direct textual evidence (self-intro / being addressed) are mapped; the
    # rest stay "Speaker N". Newly named speakers are created as People and
    # their person_id is written back to matching segments below, so the user
    # can see who said what in real time. Voice-profile voting runs later and
    # takes priority where it is confident (it overwrites person_id).
    speaker_to_person_id: Dict[int, str] = {}
    try:
        # Only attempt mapping when there is at least one unnamed non-user speaker.
        has_unnamed_speaker = any(
            not seg.get('is_user') and not seg.get('person_id') for seg in segments
        )
        if has_unnamed_speaker:
            speaker_to_name = map_speakers_to_names(transcript_text)
            if speaker_to_name:
                # 全集合名字索引，不是 get_people(limit=1000)：后者按 created_at 截断，
                # 超过 limit 后老名字会静默「消失」并被重新建一遍。
                name_index = dev_db.get_people_name_index(developer_id, external_user_id)
                for spk_id, name in speaker_to_name.items():
                    existing = name_index.get(name.lower())
                    pid = existing['id'] if existing else None
                    if existing:
                        # 这个名字之前可能只是「被提到过」（甚至已被归档）。现在他被认成了
                        # 真的说话人 —— 升级，别再建一条同名的。归档也要撤销：判据变了。
                        if existing.get('deleted') or existing.get('source') != dev_db.PERSON_SOURCE_SPEAKER_MAPPING:
                            dev_db.restore_person(
                                developer_id, external_user_id, pid,
                                source=dev_db.PERSON_SOURCE_SPEAKER_MAPPING,
                            )
                    else:
                        created = dev_db.create_person(
                            developer_id, external_user_id, name,
                            source=dev_db.PERSON_SOURCE_SPEAKER_MAPPING,
                        )
                        pid = created['id'] if created else None
                        if pid:
                            name_index[name.lower()] = {
                                'id': pid, 'deleted': False,
                                'source': dev_db.PERSON_SOURCE_SPEAKER_MAPPING,
                            }
                    if pid:
                        speaker_to_person_id[spk_id] = pid
                        person_name_by_id[pid] = name

                # Write the resolved names back onto segments (in memory) and
                # rebuild the transcript so the summary uses real names too.
                if speaker_to_person_id:
                    for seg in segments:
                        if seg.get('is_user') or seg.get('person_id'):
                            continue
                        # Coerce speaker id to int to match the LLM-returned keys
                        # (it may arrive as a string like "0" or "SPEAKER_0").
                        raw_spk = seg.get('speaker_id', seg.get('speaker', 0))
                        spk_id = coerce_speaker_id(raw_spk, default=None)
                        if spk_id is None:
                            continue
                        pid = speaker_to_person_id.get(spk_id)
                        if pid:
                            seg['person_id'] = pid
                    transcript_parts = []
                    for seg in segments:
                        if seg.get('is_user'):
                            # Literal "User" — same reason as the first build above.
                            label = "User"
                        elif seg.get('person_id') and seg.get('person_id') in person_name_by_id:
                            label = person_name_by_id[seg['person_id']]
                        else:
                            label = f"Speaker {coerce_speaker_id(seg.get('speaker_id', seg.get('speaker', 0)))}"
                        transcript_parts.append(f"{label}: {seg.get('text', '')}")
                    transcript_text = "\n".join(transcript_parts)
                    print(f"[WS] Auto-process: mapped {len(speaker_to_person_id)} speaker(s) to named People")
    except Exception as e:
        # Mapping is best-effort; never block conversation processing.
        print(f"[WS] Auto-process: speaker→name mapping failed ({e})")

    # Truncate transcript text to avoid LLM input-too-large errors (e.g. Gemini 400 INVALID_ARGUMENT)
    if len(transcript_text) > MAX_LLM_TRANSCRIPT_CHARS:
        print(f"[WS] Auto-process: Truncating transcript from {len(transcript_text)} to {MAX_LLM_TRANSCRIPT_CHARS} chars")
        transcript_text = transcript_text[-MAX_LLM_TRANSCRIPT_CHARS:]

    # Use LLM to process the transcript
    language_code = language or "zh"
    user_language = dev_db.get_user_language(developer_id, external_user_id)
    output_language = user_language if user_language else None
    vocabulary_terms = dev_db.get_vocabulary_terms(developer_id, external_user_id)
    try:
        structured = get_transcript_structure(
            transcript=transcript_text,
            started_at=started_at,
            language_code=language_code,
            tz="UTC",
            photos=None,
            output_language=output_language,
            vocabulary_terms=vocabulary_terms,
        )
    except Exception as e:
        print(f"[WS] Auto-process: LLM processing failed: {e}")
        from utils.locales import get_fallback_conversation_title
        structured = type('Structured', (), {
            'title': get_fallback_conversation_title(output_language or language_code),
            # Never present raw transcript text as if it were an LLM summary.
            'overview': '',
            'emoji': '\U0001f4ac',
            'category': 'other',
            'action_items': [],
            'emotion': 'calm',
        })()

    # The discard classifier and summarizer are independent calls.  Production
    # showed the classifier returning keep while the summary returned the exact
    # ``[Media Recording]`` sentinel; persisting only the first verdict exposed
    # a card that both the model and product semantics said should be hidden.
    summary_discarded = summary_marks_media(structured)
    if summary_discarded and not should_discard:
        print("[WS] Auto-process: Summary classified capture as media; marking as discarded")
    should_discard = merge_discard_verdict(should_discard, structured)

    # The action-item gate deliberately does NOT run here. It needs voiceprint
    # `is_user` flags, which don't exist yet on this path — running it here read
    # "the user never spoke" on every conversation and deleted 88% of all to-dos.
    # It now runs after speech-profile matching, in `_apply_action_item_gate`.

    # Derive the real end time from the transcript span rather than the
    # processing instant, so started_at/finished_at reflect the true
    # conversation length (e.g. an 78-minute conversation must not collapse to
    # a few seconds between start and finish).
    speech_span = max((seg.get('end', 0.0) for seg in segments), default=0.0)
    finished_at = started_at + timedelta(seconds=speech_span)

    # Create conversation
    conversation = dev_db.create_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        started_at=started_at,
        finished_at=finished_at,
        language=language_code,
        source="app",
        metadata={'transcript_timeline': timeline},
    )

    # Bulk-write segments with compression to avoid Firestore 1MB limit
    segment_dicts = []
    for seg in segments:
        segment_dicts.append({
            "id": str(uuid.uuid4()),
            "text": (seg.get('text') or '').strip(),
            # STT segments carry the label in 'speaker' (e.g. "SPEAKER_01");
            # always persist speaker_id as an int per the API contract.
            "speaker_id": coerce_speaker_id(seg.get('speaker_id', seg.get('speaker', 0))),
            "start": seg.get('start', 0.0),
            "end": seg.get('end', 0.0),
            "is_user": seg.get('is_user', False),
            "person_id": seg.get('person_id'),
            **{k: seg[k] for k in ('original_start', 'original_end', 'timestamp_axis') if k in seg},
        })
    dev_db.set_conversation_transcript_segments(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation['id'],
        segments=segment_dicts,
    )

    # Extract action items
    action_items = None
    if hasattr(structured, 'action_items') and structured.action_items:
        action_items = [
            {
                "description": item.description if hasattr(item, 'description') else str(item),
                "completed": False,
                "confirmed": False,
                "due_date": getattr(item, 'due_date', None),
                "due_hint": getattr(item, 'due_hint', '') or '',
            }
            for item in structured.action_items
        ]

    # Localized fallback title in case `structured` is missing it.
    from utils.locales import get_fallback_conversation_title
    fallback_title = get_fallback_conversation_title(output_language or language_code)

    # first_person_observation + highlights come from the same summary call now
    # (fields on Structured), no extra LLM call. getattr guards the LLM-failure
    # fallback object which lacks these attributes.
    conv_title = getattr(structured, 'title', fallback_title)
    conv_overview = getattr(structured, 'overview', '')

    # Finish the conversation. `discarded` carries the verdict computed above;
    # observation/highlights are withheld while discarded (same as path 2) so a
    # hidden conversation doesn't pay for subtitle text nobody sees — the
    # voiceprint revisit regenerates them if it restores the conversation.
    conversation = dev_db.finish_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation['id'],
        title=conv_title,
        overview=conv_overview,
        category=getattr(structured, 'category', 'other'),
        action_items=action_items,
        emoji=getattr(structured, 'emoji', '\U0001f9e0'),
        discarded=should_discard,
        emotion=getattr(structured, 'emotion', 'calm'),
        finished_at=finished_at,
        first_person_observation=None if should_discard else (getattr(structured, 'first_person_observation', None) or None),
        highlights=None if should_discard else getattr(structured, 'highlights', None),
    )

    # Link audio if available
    if audio_path:
        dev_db.update_conversation_audio_path_dev(
            developer_id=developer_id,
            external_user_id=external_user_id,
            conversation_id=conversation['id'],
            audio_path=audio_path,
        )
        print(f"[WS] Auto-process: Linked audio_path to conversation {conversation['id']}")

    # Mark session as auto-processed to prevent duplicate processing
    # when the app also calls POST /v1/conversations/process
    try:
        dev_db.update_listen_session(
            developer_id=developer_id,
            external_user_id=external_user_id,
            session_id=session_id,
            auto_processed_conversation_id=conversation['id'],
        )
    except Exception as e:
        print(f"[WS] Auto-process: Failed to mark session as auto-processed: {e}")

    # Emit webhook events
    from routers.developer_conversations import _emit_conversation_completed_event, mark_timeline_day_dirty
    _emit_conversation_completed_event(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation=conversation,
    )

    # Flag the day for chapter recomputation (see `utils/timeline/store`). This
    # path creates conversations without going through
    # `process_conversation_developer`, so it needs its own call.
    mark_timeline_day_dirty(developer_id, external_user_id, started_at)

    # Record usage stats for the subscription/usage UI.
    # On-device STT is free — skip usage recording so it doesn't count
    # toward the user's plan limits.
    if not custom_stt_mode:
        words_transcribed = sum(len(seg.get('text', '').split()) for seg in segments)
        insights_gained = 0
        if action_items:
            for item in action_items:
                desc = item.get('description', '')
                if len(desc.split()) > 5:
                    insights_gained += 1
        overview = getattr(structured, 'overview', '')
        if overview:
            sentences = overview.split('.')
            for sentence in sentences:
                if len(sentence.split()) > 5:
                    insights_gained += 1
        if words_transcribed > 0 or insights_gained > 0:
            record_usage_developer(
                developer_id,
                external_user_id,
                words_transcribed=words_transcribed,
                insights_gained=insights_gained,
                memories_created=1,
            )

    # Store vector embedding in Pinecone for RAG chat retrieval
    def _save_vector_background():
        try:
            from utils.conversations.process_conversation import save_vector_from_dict
            save_vector_from_dict(
                uid=external_user_id,
                conversation_id=conversation['id'],
                structured=structured,
                event_time=started_at,
                segments=segment_dicts,
                developer_id=developer_id,
            )
        except Exception as e:
            print(f"[VECTOR] Error saving vector: {e}")

    threading.Thread(target=_save_vector_background).start()

    # Long-term memory extraction now hangs off the END of the speech-profile
    # thread instead of racing it — see `_speech_profile_matching_background`.
    #
    # The old comment here claimed the extractor "reads segment text only, so it
    # doesn't need is_user". That was wrong: the transcript it builds comes from
    # `TranscriptSegment.segments_as_string(..., user_name=...)`, which labels a
    # line with the wearer's real name only where `is_user` is set. Cloud STT
    # never sets that flag, so running concurrently meant the extraction prompt
    # was always handed a transcript in which the wearer appears as an anonymous
    # "Speaker N" and is indistinguishable from everyone else in the room —
    # exactly the attribution the prompt needs in order to decide whose life a
    # fact is about.
    def _extract_memories_after_voiceprint(conv: dict):
        # Reads the discard verdict AFTER the revisit pass, so a conversation
        # rescued from a wrong "media playback" verdict now contributes memories
        # too. That gap was noted in the old comment and left open.
        if conv.get('discarded'):
            return
        try:
            from utils.conversations.process_conversation import extract_memories_from_segments

            extract_memories_from_segments(
                developer_id=developer_id,
                external_user_id=external_user_id,
                conversation_id=conv['id'],
                segments=segment_dicts,
            )
        except Exception as e:
            print(f"[MEMORY] Extraction after voiceprint failed for {conv.get('id')}: {e}")

    # 转录稿里**被提到**的名字（prompt 明确要求提取 "John said he would come" 这类）。
    # 这些人从没说过话，所以建出来的 Person 一律标 source='mention'，并且默认**不出现在
    # 人物名单里**（`GET /v1/people` 默认 include_mentions=False）。
    #
    # ⚠️ 别把它跟上面 map_speakers_to_names 那条混为一谈：那条要求直接的文本证据
    # （自我介绍 / 被称呼），产物是真说话人，还会把 person_id 回写到段落。这条没有任何
    # 声音证据 —— 某账号 833 个人里 802 个（96.3%）来自这里，其中还有 `债款`、`付条`
    # 这种转录错误被当成了人名。
    def _extract_people_background():
        try:
            transcript_for_people = "\n".join(
                f"Speaker {coerce_speaker_id(seg.get('speaker_id', 0))}: {seg.get('text', '')}" for seg in segments
            )
            extracted_names = extract_people_from_conversation(transcript_for_people)
            if not extracted_names:
                return

            # ⚠️ 去重必须看到**全部**人物，包括已归档的：只是被提到一次不足以把一个
            # 被归档的名字复活，否则每条对话都会把清理掉的 800 个人重新建回来。
            # 也不能用 get_people(limit=1000) —— 见 get_people_name_index 的注释。
            name_index = dev_db.get_people_name_index(developer_id, external_user_id)

            created_count = 0
            for name in extracted_names:
                if name.lower() in name_index:
                    continue
                dev_db.create_person(
                    developer_id, external_user_id, name,
                    source=dev_db.PERSON_SOURCE_MENTION,
                )
                name_index[name.lower()] = {
                    'id': None, 'deleted': False, 'source': dev_db.PERSON_SOURCE_MENTION,
                }
                created_count += 1

            if created_count > 0:
                print(f"[PEOPLE] Created {created_count} new people from conversation {conversation['id']}")
        except Exception as e:
            print(f"[PEOPLE] Error extracting people: {e}")

    threading.Thread(target=_extract_people_background).start()

    # Speech profile matching — identify speakers using voice embeddings.
    # Shared with the App-created conversation path (developer_conversations.py).
    def _speech_profile_matching_background():
        # Carries the post-voiceprint discard verdict for the two consumers below.
        #
        # ⚠️ `discarded` must be seeded from `should_discard`, NOT from the dict
        # `create_conversation` returned. That dict hardcodes `"discarded": False`
        # and the real verdict only ever reached Firestore (via
        # `finish_conversation`), never this copy — so the revisit call below,
        # whose first act is `if not conversation.get('discarded'): return`, could
        # never do anything on this path. It has been dead code here.
        revisited = {
            **conversation,
            'transcript_segments': segment_dicts,
            'discarded': should_discard,
        }
        try:
            # NOTE: deliberately NOT gated on `audio_path`. On the silence-timer
            # flush path it is always None (audio is uploaded when the session
            # ends, later), yet identify_developer_speakers locates the wav by
            # session_id anyway and now waits for it to appear. Gating here meant
            # this path never ran speaker identification at all — which is why
            # api-ws logged zero SPEECH_PROFILE lines for a whole day.
            # Speakers the user manually tagged mid-recording must survive the
            # voice-profile vote. Derive their _speaker_key form from segment_dicts
            # (which carry speaker_id but not the 'speaker' label).
            protected_keys = set()
            if manual_speaker_ids:
                for seg in segment_dicts:
                    sid = coerce_speaker_id(seg.get('speaker_id', 0), default=None)
                    if sid in manual_speaker_ids:
                        protected_keys.add(_speaker_key(seg))
            _, updated = identify_developer_speakers(
                developer_id=developer_id,
                external_user_id=external_user_id,
                session_id=session_id,
                segments=segment_dicts,
                protected_speaker_keys=protected_keys,
            )
            if updated:
                dev_db.set_conversation_transcript_segments(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    conversation_id=conversation['id'],
                    segments=segment_dicts,
                )
                print(f"[SPEECH_PROFILE] Updated segments for conversation {conversation['id']}")
                # The discard verdict above ran before these flags existed, so a
                # real conversation could have been filed as media playback. This
                # also applies the action-item gate, which needs the same flags.
                from routers.developer_conversations import _revisit_user_dependent_verdicts

                _revisit_user_dependent_verdicts(
                    developer_id,
                    external_user_id,
                    revisited,
                    segment_dicts,
                )
        except Exception as e:
            print(f"[SPEECH_PROFILE] Error in speech profile matching: {e}")
        finally:
            # Both of these run unconditionally, and for opposite reasons.
            #
            # The action-item gate, because "matching produced nothing" is exactly
            # the case it exists for: no `is_user` ⇒ nobody can be named as the
            # owner ⇒ the to-dos are unattributable. Reaching it only through the
            # `if updated:` branch above would skip precisely that case and leave
            # the unattributable items in place. It is idempotent (no-ops when
            # there are no action items), so the call inside
            # `_revisit_user_dependent_verdicts` staying put is harmless.
            #
            # Memory extraction, because voiceprint matching is best-effort and a
            # failed match must not additionally cost the user their memories.
            # Worst case it extracts from a transcript with no `is_user` — the
            # same input the old racing version always had.
            try:
                from routers.developer_conversations import _apply_action_item_gate

                # `voiceprint_ran=True` even in the `except` case: this is the
                # `finally` of the block that called `identify_developer_speakers`,
                # so matching was attempted, and "attempted but resolved nobody" is
                # the case the gate exists for. This is also the ONLY gate that gets
                # to judge a listen conversation — the one reached via
                # `_emit_conversation_completed_event` is deliberately inert here
                # (no session_id ⇒ no voiceprint). See `_apply_action_item_gate`.
                _apply_action_item_gate(
                    developer_id, external_user_id, revisited, segment_dicts,
                    voiceprint_ran=True,
                )
            except Exception as e:
                print(f"[action-items] Post-voiceprint gate failed: {e}")
            _extract_memories_after_voiceprint(revisited)

    threading.Thread(target=_speech_profile_matching_background).start()

    print(f"[WS] Auto-process: Conversation {conversation['id']} created and processed for session {session_id}")


@router.websocket("/v1/listen/stream/{session_id}")
async def websocket_stream(
    websocket: WebSocket,
    session_id: str,
    external_user_id: str = Query(...),
    api_key: str = Query(...),
    language: str = Query(default="zh"),
    sample_rate: int = Query(default=16000),
    codec: str = Query(default="pcm16"),
    custom_stt: Optional[str] = Query(default=None),
):
    """
    WebSocket endpoint for real-time audio streaming.

    Send audio data as binary frames.
    Receive transcript segments as JSON messages.

    Message format (received):
    {
        "type": "transcript",
        "segments": [
            {"text": "...", "start": 0.0, "end": 1.5, "speaker": "SPEAKER_0", "is_user": false}
        ]
    }

    Control messages:
    - Send {"type": "end"} to gracefully close the session
    """
    # Authenticate (enforces user-bound keys)
    developer_id, auth_error = resolve_developer_id_for_external_user(api_key, external_user_id)
    if auth_error == KEY_AUTH_ERROR_FORBIDDEN:
        print(f"[WS] Rejecting {session_id}: API key not authorized for external_user_id={external_user_id}")
        await websocket.close(code=4003, reason="API key not authorized for this external_user_id")
        return
    if not developer_id:
        print(f"[WS] Rejecting {session_id}: invalid API key")
        await websocket.close(code=4001, reason="Invalid API key")
        return

    # Verify session exists
    session = dev_db.get_listen_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        session_id=session_id,
    )

    if not session:
        print(f"[WS] Rejecting {session_id}: session not found (dev={developer_id}, user={external_user_id})")
        await websocket.close(code=4004, reason="Session not found")
        return

    # Check transcription credits before accepting.
    # On-device STT (custom_stt) sessions don't consume transcription quota.
    if custom_stt != "enabled" and not await asyncio.to_thread(
        has_transcription_credits_developer,
        developer_id,
        external_user_id,
    ):
        print(f"[WS] Rejecting {session_id}: usage limit exceeded for {external_user_id}")
        await websocket.close(code=4002, reason="Usage limit exceeded")
        return

    await websocket.accept()

    # Enforce single active session per user: signal any existing session to stop.
    # This prevents orphaned connections (from network drops) from accumulating billing.
    session_key = f"{developer_id}:{external_user_id}"
    old_cancel_event = active_sessions.get(session_key)
    if old_cancel_event is not None:
        old_cancel_event.set()
        print(f"[WS] Cancelled previous session for {session_key} (new session {session_id})")
    cancel_event = asyncio.Event()
    active_sessions[session_key] = cancel_event

    # Handle opus_fs320 codec - set frame_size for decoder
    frame_size = 160
    if codec == "opus_fs320":
        frame_size = 320
        codec = "opus"

    # Determine custom STT mode early — needed before Opus decoder init
    custom_stt_mode = (custom_stt == "enabled")

    # Initialize Opus decoder if needed (skip in custom_stt mode — server doesn't
    # need to decode audio for STT when the client provides transcriptions directly)
    opus_decoder = None
    if codec == "opus" and not custom_stt_mode:
        with _opus_lock:
            opus_decoder = opuslib.Decoder(sample_rate, 1)
        print(f"Initialized Opus decoder: sample_rate={sample_rate}, frame_size={frame_size}")

    # Get STT service for language
    stt_service, stt_language, model = get_stt_service_for_language(language)

    # Track transcript segments for the CURRENT conversation batch
    # When the silence timer fires, these are flushed into a conversation and reset.
    current_segments: List[Dict[str, Any]] = []
    # Track ALL segments across the entire session (for listen_session storage)
    all_segments: List[Dict[str, Any]] = []
    # Index dicts for fast upsert by segment ID (Soniox sends streaming updates
    # with the same ID — each update carries the full accumulated segment text).
    current_segments_index: Dict[str, int] = {}  # seg_id -> index in current_segments
    all_segments_index: Dict[str, int] = {}       # seg_id -> index in all_segments
    # Segment ids already written into a conversation by an earlier flush.
    #
    # This exists because the two facts above collide: segment ids live for the
    # whole STT session, but `current_segments_index` is cleared on every flush.
    # An update to a segment that a previous batch already consumed therefore
    # looks brand new — and since each Soniox update carries the *full accumulated*
    # text, it re-enters the next conversation carrying the entire session
    # transcript so far. Measured on production data: one day produced five
    # conversations each holding a single segment whose text was a strict prefix
    # superset of the last (74 → 179 → 617 → 684 → 2101 chars) and whose `end`
    # grew to 17012s, i.e. one sentence claiming 4.7 hours. 111 conversations
    # DB-wide carry such a segment, and the chapter layer cannot repair it: those
    # copies are prefixes of each other, so text similarity between them is
    # 0.068–0.585, far under any sane dedup threshold. It has to be stopped here.
    flushed_segment_ids: set = set()
    # Manual speaker tags applied by the user mid-recording (via `speaker_assigned`
    # WebSocket messages). Keyed by speaker_id -> {"person_id": str|None, "is_user": bool}.
    # Applied to existing segments immediately and re-applied to late-arriving
    # segments of the same speaker in stream_transcript, so the conversation
    # created on session end preserves the user's tags.
    manual_speaker_tags: Dict[int, Dict[str, Any]] = {}
    # Timestamp offset for real-time normalization: set from the first segment's
    # start time so all timestamps sent to the client begin at ~0:00.
    timestamp_offset: Optional[float] = None
    stt_socket = None
    stt_error = None
    receive_task = None
    start_time = datetime.utcnow()
    audio_buffer = bytearray()  # Collect audio data for saving to GCS

    def _transcript_timeline():
        return {
            'version': 2, 'axis': 'display',
            'original_coordinates_available': not custom_stt_mode,
            'display_offset_seconds': timestamp_offset or 0.0,
            'audio_started_at': start_time.replace(tzinfo=timezone.utc),
        }

    # Credit check state
    websocket_active = True
    credit_check_task: Optional[asyncio.Task] = None
    cancel_task: Optional[asyncio.Task] = None
    last_usage_record_time: float = time.time()

    async def _check_credits_periodically():
        """Record usage incrementally and check credits every 30s."""
        nonlocal websocket_active, last_usage_record_time
        session_start_monotonic = time.monotonic()
        while websocket_active:
            await asyncio.sleep(30)
            if not websocket_active:
                break

            # Enforce maximum session duration to prevent zombie connections
            elapsed = time.monotonic() - session_start_monotonic
            if elapsed > MAX_SESSION_DURATION_SECONDS:
                print(f"[WS] Session {session_id} exceeded max duration ({MAX_SESSION_DURATION_SECONDS}s), closing")
                websocket_active = False
                try:
                    await websocket.close(code=4008, reason="Maximum session duration exceeded")
                except Exception:
                    pass
                break

            # Skip billing for custom_stt mode (on-device STT is free)
            if custom_stt_mode:
                continue

            # Check credits BEFORE recording to avoid overshoot
            if not await asyncio.to_thread(
                has_transcription_credits_developer,
                developer_id,
                external_user_id,
            ):
                print(f"[WS] Usage limit exceeded for {external_user_id}, closing")
                websocket_active = False
                try:
                    await websocket.close(code=4002, reason="Usage limit exceeded")
                except Exception:
                    pass
                break

            # Record incremental transcription time since last record
            now = time.time()
            delta = int(now - last_usage_record_time)
            if delta >= USAGE_WRITE_INTERVAL_SECONDS:
                await asyncio.to_thread(
                    record_usage_developer,
                    developer_id,
                    external_user_id,
                    transcription_seconds=delta,
                )
                last_usage_record_time = now

    # Conversation splitting state
    conversation_creation_task: Optional[asyncio.Task] = None
    conversation_creation_lock = asyncio.Lock()
    current_conversation_start = start_time  # start time of the current batch

    async def _flush_conversation():
        """Flush current segments into a conversation (silence-timer path).

        Serialized against POST /v1/conversations/process via the SHARED Redis lock
        (`listen_session_lock_key`). Without it, this flush could create a second
        conversation for the same recording during the multi-second window POST
        /process spends inside the LLM call, before it writes its dedup marker —
        observed 2026-08-08 on session f0e5e8a0 (two conversations, 5s apart).

        Note this path is SUPPOSED to fire repeatedly: a long recording is split
        into one conversation per silence gap. So it must NOT bail out on
        `auto_processed_conversation_id` (its own marker from a previous flush) —
        only on `app_processed_conversation_id`, which means the app took over
        this session wholesale.
        """
        nonlocal current_segments, current_segments_index, current_conversation_start

        # Take the segments out of the shared buffer FIRST, so segments arriving
        # while we hold the lock accumulate into the next batch instead of being
        # dropped or double-counted.
        segments_to_process = deepcopy(current_segments)
        batch_started_at = current_conversation_start
        current_segments = []
        current_segments_index = {}
        current_conversation_start = datetime.utcnow()
        # Remember what this batch owns before handing it off: a later update to
        # one of these ids must be recognised as an already-written segment rather
        # than a new one (see `flushed_segment_ids`). Recorded even if the batch is
        # later returned unconsumed — `stream_transcript` looks the id up in
        # `current_segments_index` first, so a returned batch still upserts
        # correctly, while a *new* id can never be resurrected.
        flushed_segment_ids.update(
            seg['id'] for seg in segments_to_process if seg.get('id')
        )

        if not segments_to_process:
            return

        from routers.developer_conversations import listen_session_lock_key

        lock_key = listen_session_lock_key(developer_id, external_user_id, session_id)

        # Blocking on the lock would stall the WebSocket read loop, so the
        # acquire + process runs off the event loop thread. TTL mirrors the value
        # in POST /process (worst-case create+LLM+finish).
        def _locked_flush() -> bool:
            """Returns False when the batch was not consumed and must be returned."""
            if not redis_db.acquire_lock(lock_key, ttl_seconds=180):
                # POST /process holds the lock — it is mid-LLM on this session.
                print(f"[WS] Flush deferred: lock held for session {session_id}")
                return False
            try:
                # Re-check under the lock: the app may have finished processing
                # this session between our last read and the acquire.
                session_now = dev_db.get_listen_session(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    session_id=session_id,
                )
                if session_now and session_now.get('app_processed_conversation_id'):
                    # The app processed this whole session itself; its conversation
                    # covers these segments. Consume the batch so the finally block
                    # doesn't try to create a duplicate from them.
                    print(f"[WS] Flush skipped: session {session_id} already processed by the app")
                    return True
                print(f"[WS] Flushing {len(segments_to_process)} segments into conversation for session {session_id}")
                _auto_process_conversation(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    session_id=session_id,
                    segments=segments_to_process,
                    audio_path=None,  # audio linked at session end
                    language=language,
                    started_at=batch_started_at,
                    duration=(datetime.utcnow() - batch_started_at).total_seconds(),
                    custom_stt_mode=custom_stt_mode,
                    manual_speaker_ids=set(manual_speaker_tags.keys()),
                    session_started_at=start_time.replace(tzinfo=timezone.utc),
                )
                return True
            finally:
                redis_db.release_lock(lock_key)

        consumed = False
        try:
            consumed = await asyncio.to_thread(_locked_flush)
        except Exception as e:
            print(f"[WS] Error flushing conversation for session {session_id}: {e}")

        if not consumed:
            # Put the batch back at the FRONT of the buffer so nothing is lost:
            # the next silence flush (or the finally fallback) picks it up. Don't
            # rely on the client re-sending these segments.
            current_segments[:0] = segments_to_process
            current_conversation_start = batch_started_at
            # Rebuild the id→index map: prepending shifted every existing entry,
            # and stream_transcript upserts by that index (a stale map would
            # overwrite the wrong segment).
            current_segments_index = {
                seg['id']: i for i, seg in enumerate(current_segments) if seg.get('id')
            }

    async def _trigger_conversation_after_silence():
        """Wait for silence timeout then flush conversation."""
        try:
            await asyncio.sleep(CONVERSATION_CREATION_TIMEOUT)
            await _flush_conversation()
        except asyncio.CancelledError:
            pass

    async def _reset_conversation_timer():
        """Cancel existing timer and start a new one (called when new segments arrive)."""
        nonlocal conversation_creation_task
        async with conversation_creation_lock:
            if conversation_creation_task is not None:
                conversation_creation_task.cancel()
                try:
                    await conversation_creation_task
                except asyncio.CancelledError:
                    pass
            conversation_creation_task = asyncio.create_task(
                _trigger_conversation_after_silence()
            )

    def _apply_manual_tag_to_seg(seg: Dict[str, Any]):
        """Apply a user's manual speaker tag onto a single segment (in place).

        Late-arriving STT segments for an already-tagged speaker must inherit the
        tag, otherwise the conversation created on session end would show
        "Speaker N" for them. Only fills segments that haven't been tagged yet,
        so it never clobbers a more specific per-segment assignment."""
        if not manual_speaker_tags:
            return
        spk_id = coerce_speaker_id(seg.get('speaker_id', seg.get('speaker', 0)), default=None)
        if spk_id is None:
            return
        tag = manual_speaker_tags.get(spk_id)
        if not tag:
            return
        # Don't override an already-assigned segment.
        if seg.get('is_user') or seg.get('person_id'):
            return
        seg['is_user'] = tag.get('is_user', False)
        seg['person_id'] = tag.get('person_id')

    async def stream_transcript(segments: List[Dict[str, Any]]):
        """Callback to handle transcript segments from STT service."""
        nonlocal current_segments, all_segments, timestamp_offset
        try:
            if websocket.client_state == WebSocketState.CONNECTED:
                first_frame = timestamp_offset is None and bool(segments)
                # Display starts at zero; retain original coordinates for audio
                # slicing and persist the offset for older App POST clients.
                if timestamp_offset is None and segments:
                    first_start = segments[0].get('start', 0)
                    if first_start > 0:
                        timestamp_offset = first_start
                        print(f"[WS] Timestamp offset set to {timestamp_offset:.2f}s from first segment")
                    else:
                        timestamp_offset = 0.0

                # Normalize timestamps and upsert by ID to deduplicate streaming updates.
                # Soniox sends the same segment ID multiple times as text accumulates;
                # each update carries the full segment so we just replace in-place.
                display_segments = []
                for incoming in segments:
                    seg = stream_segment(incoming, timestamp_offset or 0.0)
                    seg['speaker_id'] = coerce_speaker_id(seg.get('speaker_id', seg.get('speaker', 0)))
                    if custom_stt_mode:
                        # On-device STT may restart its clock after a pause; it
                        # is not evidence of coordinates on the session WAV.
                        seg.pop('original_start', None)
                        seg.pop('original_end', None)

                    # Re-apply any manual speaker tag for this speaker so late
                    # segments inherit the user's mid-recording assignment.
                    _apply_manual_tag_to_seg(seg)
                    display_segments.append(deepcopy(seg))

                    seg_id = seg.get('id')

                    # current_segments (for the current conversation batch)
                    if seg_id and seg_id in current_segments_index:
                        current_segments[current_segments_index[seg_id]] = seg
                    elif seg_id and seg_id in flushed_segment_ids:
                        # An earlier flush already wrote this segment into its own
                        # conversation. Letting it into this batch would copy the
                        # whole accumulated session transcript forward, because the
                        # update carries the full text (see `flushed_segment_ids`).
                        # `all_segments` still takes it below, so the session-wide
                        # record and the end-of-session conversation keep the final,
                        # most complete version of the sentence.
                        pass
                    else:
                        if seg_id:
                            current_segments_index[seg_id] = len(current_segments)
                        current_segments.append(seg)

                    # all_segments (session-wide, stored in listen_session)
                    if seg_id and seg_id in all_segments_index:
                        all_segments[all_segments_index[seg_id]] = deepcopy(seg)
                    else:
                        if seg_id:
                            all_segments_index[seg_id] = len(all_segments)
                        all_segments.append(deepcopy(seg))

                # Reset conversation creation timer (new speech detected)
                await _reset_conversation_timer()

                # Send to client
                await websocket.send_json({
                    "type": "transcript",
                    "segments": display_segments,
                })
                if first_frame:
                    try:
                        await asyncio.to_thread(
                            dev_db.update_listen_session,
                            developer_id=developer_id, external_user_id=external_user_id,
                            session_id=session_id, transcript_timeline=_transcript_timeline(),
                        )
                    except Exception as e:
                        # Deliver the transcript even during a transient DB error.
                        # Finalization retries the complete provenance.
                        print(f"[WS] Initial timeline save deferred to finalization: {e}")
        except Exception as e:
            print(f"Error sending transcript: {e}")

    # On-device STT partial result tracking: Apple Speech sends multiple
    # updates for the same utterance (partial results). We assign a stable
    # segment ID so the client's updateSegments() replaces in-place instead
    # of appending duplicates. A new ID is generated only when the start
    # time jumps significantly, indicating a new utterance.
    _ondevice_current_seg_id: Optional[str] = None
    _ondevice_last_start: Optional[float] = None
    _ONDEVICE_NEW_SEG_THRESHOLD = 1.5  # seconds — start jump > this means new segment

    try:
        # Update session status to active
        dev_db.update_listen_session(
            developer_id=developer_id,
            external_user_id=external_user_id,
            session_id=session_id,
            status="active",
        )

        # Connect to STT service (skip in custom_stt mode — client provides transcriptions)
        speech_profile_path = None  # kept for finally cleanup block
        if not custom_stt_mode:
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
                )
        else:
            print(f"[WS] Custom STT mode enabled for session {session_id} — skipping cloud STT")

        # Send ready message
        await websocket.send_json({
            "type": "ready",
            "session_id": session_id,
            "stt_service": "custom_stt" if custom_stt_mode else stt_service.value,
            "language": stt_language,
        })

        # Note: For Soniox, process_audio_soniox() already starts an internal recv task
        # that calls our stream_transcript callback. No need for a separate receive task here
        # — starting one would cause "cannot call recv while another coroutine is already
        # running recv" errors due to two concurrent recv loops on the same WebSocket.

        # Start periodic credit check
        credit_check_task = asyncio.create_task(_check_credits_periodically())
        cancel_task = asyncio.create_task(cancel_event.wait())

        # Main loop - receive audio and forward to STT
        while websocket_active:
            try:
                data = await receive_with_stt(websocket, stt_socket, cancel_task=cancel_task)
                if data is None:
                    print(f"[WS] Session {session_id} superseded by newer connection, closing")
                    break
                if data["type"] == "stt.finished":
                    break

                # Log all non-bytes messages for debugging
                if "bytes" not in data:
                    print(f"[WS] Received non-bytes data: {data}")

                if data["type"] == "websocket.disconnect":
                    print(f"[WS] Received websocket.disconnect")
                    break

                if "text" in data:
                    # JSON control message
                    import json
                    msg = json.loads(data["text"])
                    print(f"[WS] Received text message: {msg}")
                    if msg.get("type") == "end":
                        if stt_service == STTService.soniox and stt_socket and not custom_stt_mode:
                            await finish_soniox_stream(stt_socket)
                        print(f"[WS] End message received, breaking loop")
                        break
                    elif msg.get("type") == "keepalive":
                        # Send keepalive to STT if needed
                        if stt_service == STTService.soniox and stt_socket:
                            await stt_socket.send(json.dumps({"type": "keepalive"}))
                    elif msg.get("type") == "speaker_assigned":
                        # User manually tagged a speaker mid-recording. Apply the
                        # tag to the in-memory segments now and remember it for
                        # this speaker so late-arriving segments inherit it. This
                        # is what makes the tag survive into the conversation that
                        # auto-process creates on session end.
                        raw_spk = msg.get("speaker_id")
                        spk_id = coerce_speaker_id(raw_spk, default=None)
                        raw_pid = msg.get("person_id")
                        # The app sends 'user' to mark the owner; otherwise a
                        # person_id (or empty/None when un-assigning).
                        is_user = raw_pid == "user"
                        person_id = None if (is_user or not raw_pid) else raw_pid
                        seg_ids = set(msg.get("segment_ids") or [])
                        if spk_id is not None:
                            manual_speaker_tags[spk_id] = {
                                "person_id": person_id,
                                "is_user": is_user,
                            }
                            # Apply to already-received segments. Prefer the
                            # explicit segment_ids from the client; fall back to
                            # matching on speaker_id when none were provided.
                            applied = 0
                            for seg in all_segments + current_segments:
                                match = (
                                    seg.get("id") in seg_ids if seg_ids
                                    else coerce_speaker_id(
                                        seg.get("speaker_id", seg.get("speaker", 0)), default=None
                                    ) == spk_id
                                )
                                if match:
                                    seg["is_user"] = is_user
                                    seg["person_id"] = person_id
                                    applied += 1
                            print(f"[WS] speaker_assigned: speaker={spk_id} person_id={person_id} is_user={is_user}, updated {applied} buffer entries")
                    elif msg.get("type") == "suggested_transcript" and custom_stt_mode:
                        # On-device STT: client sends transcript segments directly.
                        # The client assigns stable segment IDs:
                        #   - Confirmed segments get permanent IDs
                        #   - The pending (partial) segment keeps its ID until finalized
                        # If client doesn't provide IDs, fall back to server-side assignment.
                        client_segments = msg.get("segments", [])
                        stt_provider = msg.get("stt_provider", "on_device")
                        if client_segments:
                            normalized = []
                            for seg in client_segments:
                                seg_start = seg.get("start", 0.0)
                                seg_id = seg.get("id")

                                # Fall back to server-side ID assignment if client didn't provide one
                                if not seg_id:
                                    if (
                                        _ondevice_current_seg_id is None
                                        or _ondevice_last_start is None
                                        or abs(seg_start - _ondevice_last_start) > _ONDEVICE_NEW_SEG_THRESHOLD
                                    ):
                                        _ondevice_current_seg_id = f"ondevice_{uuid.uuid4().hex[:12]}"
                                    seg_id = _ondevice_current_seg_id
                                _ondevice_last_start = seg_start

                                normalized.append({
                                    "id": seg_id,
                                    "text": seg.get("text", ""),
                                    "start": seg_start,
                                    "end": seg.get("end", 0.0),
                                    "speaker": seg.get("speaker", "SPEAKER_0"),
                                    "speaker_id": coerce_speaker_id(seg.get("speaker_id", 0)),
                                    "is_user": seg.get("is_user", False),
                                })
                            print(f"[WS] Custom STT: received {len(normalized)} segments from {stt_provider}")
                            await stream_transcript(normalized)

                elif "bytes" in data:
                    # Audio data
                    audio_bytes = data["bytes"]
                    if audio_bytes == b'' and stt_service == STTService.soniox and stt_socket and not custom_stt_mode:
                        # Empty binary audio is also a legacy end-of-audio marker.
                        # Apply the same deadline rather than buffering later frames.
                        await finish_soniox_stream(stt_socket)
                        break

                    # Decode Opus to PCM if needed
                    if opus_decoder is not None:
                        try:
                            with _opus_lock:
                                audio_bytes = opus_decoder.decode(bytes(audio_bytes), frame_size=frame_size)
                        except Exception as e:
                            print(f"Opus decode error: {e}")
                            continue

                    # Collect PCM data for saving to GCS
                    audio_buffer.extend(audio_bytes)

                    # Forward to cloud STT (skip in custom_stt mode)
                    if stt_socket and not custom_stt_mode:
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
                print(f"Error in WebSocket loop: {e}")
                break

    except SonioxStreamError as e:
        stt_error = e
        print(f"[WS] {e}")
        await report_stt_error(websocket, e)
    except Exception as e:
        print(f"WebSocket error: {e}")
        await websocket.send_json({
            "type": "error",
            "message": str(e),
        })

    finally:
        stt_error = stt_error or getattr(stt_socket, '_stream_error', None)
        websocket_active = False
        print(f"[WS] Entering finally block, audio_buffer size: {len(audio_buffer)} bytes")

        # Remove ourselves from active_sessions only if we are still the current session
        if active_sessions.get(session_key) is cancel_event:
            del active_sessions[session_key]

        if cancel_task is not None:
            cancel_task.cancel()
            await asyncio.gather(cancel_task, return_exceptions=True)

        # Cancel the credit check task
        if credit_check_task is not None:
            credit_check_task.cancel()
            try:
                await credit_check_task
            except asyncio.CancelledError:
                pass

        # Cancel the conversation creation timer
        if conversation_creation_task is not None:
            conversation_creation_task.cancel()
            try:
                await conversation_creation_task
            except asyncio.CancelledError:
                pass

        # Cancel Soniox receive task
        if receive_task:
            receive_task.cancel()
            try:
                await receive_task
            except asyncio.CancelledError:
                pass

        # Close STT connection
        if stt_socket:
            try:
                if stt_service == STTService.deepgram:
                    stt_socket.finish()
                elif stt_service == STTService.soniox:
                    # Cancel the internal on_message task if present
                    if hasattr(stt_socket, '_on_message_task') and stt_socket._on_message_task:
                        stt_socket._on_message_task.cancel()
                        try:
                            await stt_socket._on_message_task
                        except asyncio.CancelledError:
                            pass
                    # Cancel the internal keepalive task if present
                    if hasattr(stt_socket, '_keepalive_task') and stt_socket._keepalive_task:
                        stt_socket._keepalive_task.cancel()
                        try:
                            await stt_socket._keepalive_task
                        except asyncio.CancelledError:
                            pass
                    await stt_socket.close()
            except Exception as e:
                print(f"Error closing STT socket: {e}")

        # Calculate duration
        duration = (datetime.utcnow() - start_time).total_seconds()
        print(f"[WS] Session duration: {duration}s")

        # 🚨 客户端重复发帧的探测器（2026-08-17）。
        #
        # 收到的音频秒数不可能显著超过会话的墙钟秒数 —— 超了只有一种解释：客户端把同一帧
        # 发了多遍。App 侧曾经因为 BLE 音频特征上挂了多个监听器，把同一帧发 6~14 遍
        # （见 app/lib/services/devices/live_subscription_registry.dart）。
        #
        # ⚠️ **这个探测器存在的理由是那次故障全链路零错误日志。** Opus 帧本身合法、解码不
        # 报错；音频被复印成 10ms 粒度的卡碟后 Soniox **合法地**返回 0 段并正常关闭；VAD
        # 也照跑。也就是说除了「时长对不上」以外没有任何一处会响。所以判据只能是这个比值，
        # 而它以前从没被算过 —— 两周的持续损耗就是这么无声地过去的。
        #
        # ⚠️ **必须在 VAD 裁剪之前算**（裁剪在下面 `vad_trim_silence_bytes`）。裁完再算
        # 得到的是另一个数、而且会放行：实测 22fc3b65 原始 608s / 墙钟 106s = 5.73×，
        # 而裁后只剩 117s ⇒ 1.10×。事后也补不回来 —— 见 `update_listen_session` 的
        # `audio_realtime_factor` 文档，三个「从音频本身判断」的判据都被对照组否掉了。
        realtime_factor = None
        if duration > 30 and len(audio_buffer) > 0:
            audio_seconds = len(audio_buffer) / float(sample_rate * 2)  # 16-bit mono
            realtime_factor = audio_seconds / duration
            if realtime_factor > DUPLICATE_FRAME_ALERT_FACTOR:
                print(
                    f"🚨 [WS] DUPLICATE AUDIO FRAMES suspected for session {session_id}: "
                    f"received {audio_seconds:.1f}s of audio in {duration:.1f}s wall clock "
                    f"({realtime_factor:.2f}x realtime, dev={developer_id}, user={external_user_id}). "
                    f"Client is very likely sending each BLE frame ~{round(realtime_factor)}x."
                )

        # Record remaining transcription time since last periodic record
        # Skip for custom_stt mode (on-device STT is free)
        if not custom_stt_mode:
            remaining_seconds = int(time.time() - last_usage_record_time)
            if remaining_seconds > 0:
                await asyncio.to_thread(
                    record_usage_developer,
                    developer_id,
                    external_user_id,
                    transcription_seconds=remaining_seconds,
                )

        # Save audio to GCS for speaker identification
        audio_path = None
        audio_kept_intervals = None
        transcript_saved = False
        if len(audio_buffer) > 0:
            try:
                # Trim silence using VAD before saving — the raw audio_buffer
                # contains the entire WS session including long silent periods.
                # Capture kept_intervals so we can remap STT segment timestamps
                # onto the trimmed audio's time axis (otherwise the saved wav
                # is shorter than the segment timestamps, which causes the
                # speech-profile module to skip every segment as "negative
                # effective duration" and burns Modal GPU time for nothing).
                trimmed_audio, kept_intervals = vad_trim_silence_bytes(
                    bytes(audio_buffer),
                    sample_rate=sample_rate,
                    return_kept_intervals=True,
                    # Silero misses real speech on some recordings, and what is cut
                    # here is gone for playback and voiceprint alike: never trim a
                    # span STT transcribed (session-wide, so earlier silence-split
                    # conversations are covered too).
                    keep_spans=transcribed_spans(all_segments),
                )

                # Keep transcript times intact. Only consumers slicing the WAV
                # map copies through these intervals, using original_start/end.
                audio_kept_intervals = kept_intervals
                # Publish alignment metadata before the blob becomes visible to
                # a waiting voiceprint worker (upload completion is its wake-up).
                try:
                    await asyncio.to_thread(
                        dev_db.update_listen_session,
                        developer_id=developer_id, external_user_id=external_user_id,
                        session_id=session_id, audio_kept_intervals=kept_intervals,
                        transcript_segments=deepcopy(all_segments),
                        transcript_timeline=_transcript_timeline(),
                    )
                    transcript_saved = True
                except Exception as e:
                    # Preserve the recording even during a DB outage. Raw audio
                    # needs no VAD map; final session writes retry its metadata.
                    print(f"[WS] Alignment save failed; retaining untrimmed audio: {e}")
                    trimmed_audio = bytes(audio_buffer)
                    audio_kept_intervals = []

                # Use external_user_id as uid for storage path
                # This allows the Flutter app to download the audio for speaker identification
                uid = f"dev_{developer_id}_{external_user_id}"
                upload_conversation_recording_from_bytes(
                    audio_bytes=trimmed_audio,
                    uid=uid,
                    conversation_id=session_id,
                    sample_rate=sample_rate,
                )
                audio_path = f"{uid}/{session_id}.wav"
                print(f"Audio saved to GCS: {audio_path}, size: {len(trimmed_audio)} bytes (original: {len(audio_buffer)} bytes)")
            except Exception as e:
                print(f"Failed to save audio to GCS: {e}")
                audio_path = None

        # Update session with final results
        try:
            dev_db.update_listen_session(
                developer_id=developer_id,
                external_user_id=external_user_id,
                session_id=session_id,
                status="failed" if stt_error else "completed",
                error=str(stt_error) if stt_error else None,
                transcript_segments=None if transcript_saved else all_segments,
                duration_seconds=duration,
                audio_path=audio_path,
                audio_kept_intervals=audio_kept_intervals,
                audio_realtime_factor=realtime_factor,
                transcript_timeline=_transcript_timeline(),
            )
        except Exception as e:
            print(f"Error updating listen session {session_id}: {e}")
            # Try to at least update the status without transcript data
            try:
                dev_db.update_listen_session(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    session_id=session_id,
                    status="failed" if stt_error else "completed",
                    error=str(stt_error) if stt_error else None,
                    duration_seconds=duration,
                    audio_path=audio_path,
                    audio_kept_intervals=audio_kept_intervals,
                    audio_realtime_factor=realtime_factor,
                    transcript_timeline=_transcript_timeline(),
                )
            except Exception as e2:
                print(f"Error updating listen session status {session_id}: {e2}")

        # Fallback path: process whatever segments the silence timer never flushed
        # (e.g. an unexpected disconnect while the app never called POST /process).
        #
        # It takes the same shared Redis lock as POST /process and the flush — the
        # read-check-create sequence is otherwise not atomic, which is how session
        # f0e5e8a0 ended up with two conversations on 2026-08-08.
        #
        # 🚨 **让路的判据是 `app_processed_conversation_id`，不是「有没有 marker」**
        # （2026-08-22 修）。这两个 marker 语义不同：前者表示 App 整体接管了本 session，
        # 后者只表示**某一批**已被静音切分归档。以前这里两个都查、且那个早退排在
        # `if not remaining_segments` **之前**，于是「切分过至少一次的长会话」在收尾时
        # 尾巴（最后一次切分之后说的话）被整段丢掉 —— 一条 BLE 连接一天切分几十次，
        # 每次会话收尾都丢一段，而且不报错。
        #
        # 客户端改成不再每 120s 自己拆会话之后（`capture_provider` 的
        # `_startSegmentTimeout` gate），长命 session 成了常态，这条路径每天都会走到。
        #
        # 允许在 `auto_processed_conversation_id` 存在时继续归档是安全的，理由是
        # **`remaining_segments` 与任何已切分批次必然不相交**：`_flush_conversation` 取批次
        # 时会同步清空 `current_segments`，而上面的 finally 已经 `await` 过
        # `conversation_creation_task` 的取消（见「Cancel the conversation creation timer」），
        # 所以走到这里时不存在还在飞的 flush。别把那个 await 删掉——它是这条推理的前提。
        from routers.developer_conversations import listen_session_lock_key

        remaining_segments = deepcopy(current_segments)
        final_lock_key = listen_session_lock_key(developer_id, external_user_id, session_id)

        # This block WAITS for either the lock or the other path's marker, instead of
        # giving up when the lock is busy: it is the ONLY place in the whole pipeline
        # that links the recording's audio to its conversation (the silence flush
        # passes audio_path=None, and POST /process never sees the audio at all).
        # A busy lock means the holder is still inside its multi-second LLM call and
        # has not written its marker yet — returning right then would leave the audio
        # orphaned, i.e. a recording with nothing to play back.
        FINALIZE_LOCK_WAIT_SECONDS = 60

        def _blocking_conversation_id():
            """让本路径让路的 conversation id；None 表示「该由我归档」。

            - `app_processed_conversation_id` ⇒ 无条件让路。App 提交的是它自己那份完整
              段落列表，我们再建一条就是重复内容。
            - `auto_processed_conversation_id` ⇒ **只在没有尾巴要归档时**让路。它只代表
              某一批已被切分走，而 `remaining_segments` 与那些批次不相交（理由见上面
              那段注释），所以有尾巴时必须继续，否则整段丢掉。

            两种让路都要把音频挂到返回的那条对话上 —— 本路径是全链路唯一挂音频的地方
            （切分路径传 `audio_path=None`，POST /process 压根看不到音频）。
            """
            session_doc = dev_db.get_listen_session(
                developer_id=developer_id,
                external_user_id=external_user_id,
                session_id=session_id,
            )
            if not session_doc:
                return None
            app_processed = session_doc.get('app_processed_conversation_id')
            if app_processed:
                return app_processed
            auto_processed = session_doc.get('auto_processed_conversation_id')
            if auto_processed and not remaining_segments:
                return auto_processed
            return None

        def _link_audio(conversation_id: str):
            if not audio_path:
                return
            try:
                dev_db.update_conversation_audio_path_dev(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    conversation_id=conversation_id,
                    audio_path=audio_path,
                )
                print(f"[WS] Linked audio to already-processed conversation {conversation_id}")
            except Exception as e:
                print(f"[WS] Failed to link audio to already-processed conversation: {e}")

        def _locked_finalize():
            # Poll rather than block, re-reading the marker each round: whichever
            # arrives first — the marker (someone finished; just hang the audio on
            # their conversation) or the lock (nobody else is creating; we may) —
            # ends the wait.
            acquired = False
            waited = 0.0
            while True:
                existing = _blocking_conversation_id()
                if existing:
                    _link_audio(existing)
                    print(f"[WS] Session {session_id} already processed as {existing}, skipping auto-process")
                    return
                acquired = redis_db.acquire_lock(final_lock_key, ttl_seconds=180)
                if acquired or waited >= FINALIZE_LOCK_WAIT_SECONDS:
                    break
                time.sleep(0.5)
                waited += 0.5

            try:
                if not acquired:
                    # Holder is still running and still has no marker after the whole
                    # wait. Creating a conversation now would duplicate it, and there
                    # is no id to link the audio to, so leave both to the holder.
                    print(
                        f"[WS] Finalize: lock still held after {waited:.0f}s for session {session_id}, "
                        f"skipping auto-process (audio may stay unlinked)"
                    )
                    return

                # Re-check under the lock: the marker may have landed between our last
                # read and the acquire.
                existing_conv_id = _blocking_conversation_id()
                if existing_conv_id:
                    _link_audio(existing_conv_id)
                    print(f"[WS] Session {session_id} already processed as {existing_conv_id}, skipping auto-process")
                    return

                if not remaining_segments:
                    return

                print(f"[WS] Processing remaining {len(remaining_segments)} segments for session {session_id}")
                _auto_process_conversation(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    session_id=session_id,
                    segments=remaining_segments,
                    audio_path=audio_path,
                    language=language,
                    started_at=current_conversation_start,
                    duration=(datetime.utcnow() - current_conversation_start).total_seconds(),
                    custom_stt_mode=custom_stt_mode,
                    manual_speaker_ids=set(manual_speaker_tags.keys()),
                    session_started_at=start_time.replace(tzinfo=timezone.utc),
                )
            finally:
                if acquired:
                    redis_db.release_lock(final_lock_key)

        try:
            await asyncio.to_thread(_locked_finalize)
        except Exception as e:
            print(f"[WS] Error in auto-processing conversation for session {session_id}: {e}")

        # Clean up temp speech profile file
        if speech_profile_path and os.path.exists(speech_profile_path):
            try:
                os.remove(speech_profile_path)
            except Exception:
                pass

        # Close WebSocket if still open
        if websocket.client_state == WebSocketState.CONNECTED:
            try:
                await websocket.send_json({
                    "type": "complete",
                    "session_id": session_id,
                    "duration_seconds": duration,
                    "total_segments": len(all_segments),
                    "audio_path": audio_path,
                })
                await websocket.close()
            except Exception:
                pass
