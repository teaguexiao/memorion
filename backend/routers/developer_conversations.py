"""
Developer API - Conversations endpoints

All data is tenant-isolated under developer_data/{developer_id}/users/{external_user_id}/conversations
"""

import asyncio
import threading
import uuid
from datetime import datetime, timezone, timedelta
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field, field_validator

import database.developer_data as dev_db
import database.redis_db as redis_db
from dependencies import get_developer_id_from_api_key
from models.conversation import Conversation, ConversationStatus, ConversationSource, Structured
from models.transcript_segment import coerce_speaker_id
from utils.conversations.process_conversation import process_conversation_developer
from utils.llm.conversation_processing import (
    get_transcript_structure,
    merge_discard_verdict,
    should_discard_conversation,
    summary_marks_media,
)
from utils.other.storage import get_signed_url_from_path
from utils.speech_sample_collector import collect_speech_samples_developer
from utils.stt.speech_profile import identify_developer_speakers, _speaker_key
from utils.stt.recording_alignment import conversation_audio_alignment, kept_intervals_hint, session_id_from_audio_path
from utils.stt.timeline import conversation_segments, has_original_timestamps, restore_original_timestamps

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class TranscriptSegment(BaseModel):
    text: str = Field(..., description="Segment text")
    speaker_id: int = Field(default=0, description="Speaker identifier")
    start: float = Field(default=0.0, description="Start time in seconds")
    end: float = Field(default=0.0, description="End time in seconds")
    is_user: bool = Field(default=False, description="Whether this is the user speaking")
    person_id: Optional[str] = Field(None, description="Person identifier")
    original_start: Optional[float] = Field(None, description="Start on the original session audio axis")
    original_end: Optional[float] = Field(None, description="End on the original session audio axis")
    timestamp_axis: Optional[str] = Field(None, description="Time axis: display, stream, or audio")

    @field_validator('speaker_id', mode='before')
    @classmethod
    def _coerce_speaker_id(cls, v):
        # Accept legacy string labels like 'SPEAKER_01' / 'speaker_1'
        return coerce_speaker_id(v) if v is not None else 0

    @field_validator('text')
    @classmethod
    def _strip_text(cls, v):
        return v.strip() if isinstance(v, str) else v


class ActionItem(BaseModel):
    description: str = Field(..., description="Action item description")
    completed: bool = Field(default=False, description="Whether completed")
    # 这个 model 同时是 action-items 接口的 response_model，缺字段会被 FastAPI
    # 静默滤掉——所以每次给待办加字段，这里都必须同步声明，否则客户端永远读不到。
    confirmed: bool = Field(default=True, description="User accepted this as a to-do")
    due_date: Optional[datetime] = Field(default=None, description="Deadline, only when a specific date is known")
    due_hint: str = Field(default='', description="Timing as spoken, e.g. 'this week'")


class StructuredData(BaseModel):
    title: str = ""
    overview: str = ""
    emoji: str = ""
    category: str = "other"
    action_items: List[ActionItem] = []


class ConversationCreate(BaseModel):
    external_user_id: str = Field(..., description="External user identifier")
    started_at: Optional[datetime] = Field(None, description="When the conversation started")
    finished_at: Optional[datetime] = Field(None, description="When the conversation ended")
    language: Optional[str] = Field(None, description="Language code")
    source: str = Field(default="api", description="Source of the conversation")
    metadata: Dict[str, Any] = Field(default={}, description="Additional metadata")


class ConversationProcess(BaseModel):
    """Request model for processing a conversation with segments."""
    external_user_id: str = Field(..., description="External user identifier")
    segments: List[TranscriptSegment] = Field(..., description="Transcript segments to process")
    started_at: Optional[datetime] = Field(None, description="When the conversation started")
    finished_at: Optional[datetime] = Field(None, description="When the conversation ended")
    language: Optional[str] = Field(default="zh", description="Language code for processing")
    source: str = Field(default="app", description="Source of the conversation")
    metadata: Dict[str, Any] = Field(default={}, description="Additional metadata")
    session_id: Optional[str] = Field(None, description="Listen session ID to link audio recording")


class ConversationUpdate(BaseModel):
    title: Optional[str] = Field(None, description="Conversation title")
    overview: Optional[str] = Field(None, description="Conversation overview/summary")
    status: Optional[str] = Field(None, description="Status (in_progress, completed, failed)")
    metadata: Optional[Dict[str, Any]] = Field(None, description="Metadata to merge")


class ConversationFinish(BaseModel):
    title: Optional[str] = Field(None, description="Conversation title")
    overview: Optional[str] = Field(None, description="Conversation overview/summary")
    category: Optional[str] = Field(None, description="Conversation category")
    action_items: Optional[List[ActionItem]] = Field(None, description="Action items")
    emotion: Optional[str] = Field(None, description="Emotion label: happy, angry, sad, surprised, or calm")


class SegmentAdd(BaseModel):
    text: str = Field(..., description="Segment text")
    speaker_id: int = Field(default=0, description="Speaker identifier")
    start: float = Field(default=0.0, description="Start time in seconds")
    end: float = Field(default=0.0, description="End time in seconds")
    is_user: bool = Field(default=False, description="Whether this is the user speaking")
    person_id: Optional[str] = Field(None, description="Person identifier")

    @field_validator('speaker_id', mode='before')
    @classmethod
    def _coerce_speaker_id(cls, v):
        # Accept legacy string labels like 'SPEAKER_01' / 'speaker_1'
        return coerce_speaker_id(v) if v is not None else 0

    @field_validator('text')
    @classmethod
    def _strip_text(cls, v):
        return v.strip() if isinstance(v, str) else v


class SegmentResponse(BaseModel):
    id: str
    text: str
    speaker_id: int
    start: float
    end: float
    is_user: bool
    person_id: Optional[str]
    original_start: Optional[float] = None
    original_end: Optional[float] = None
    timestamp_axis: Optional[str] = None
    # Why voiceprint matching left this speaker unlabelled: 'unknown' (nobody
    # enrolled was close enough) or 'ambiguous' (two enrolled identities could
    # not be separated). Absent once a label is written. MUST stay declared —
    # see the note on ConversationResponse.discarded: a response model silently
    # drops undeclared fields, so the app would never see the gray zone.
    speaker_status: Optional[str] = None
    speaker_assignment_source: Optional[str] = None


class ConversationResponse(BaseModel):
    id: str
    created_at: datetime
    started_at: Optional[datetime]
    finished_at: Optional[datetime]
    language: Optional[str]
    source: str
    status: str
    transcript_segments: List[dict]
    structured: dict
    metadata: Dict[str, Any]
    updated_at: datetime
    audio_url: Optional[str] = None  # Deprecated: Use audio_path with /audio-url endpoint
    audio_path: Optional[str] = None  # GCS path for audio recording
    photos: List[dict] = []  # Photos captured during conversation
    # Whether the conversation was judged not meaningful / media playback.
    # MUST stay declared: a response model silently DROPS undeclared fields, so
    # omitting this made every conversation look `discarded=false` to clients
    # even when Firestore said otherwise — the app then rendered discarded
    # media captures on the home timeline, with no subtitle (the process path
    # skips first_person_observation for discarded convos).
    discarded: bool = False


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/conversations", response_model=List[ConversationResponse], tags=["developer-api-conversations"])
def list_conversations(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=100, ge=1, le=500, description="Maximum conversations to return"),
    offset: int = Query(default=0, ge=0, description="Number of conversations to skip"),
    statuses: Optional[str] = Query(None, description="Comma-separated statuses to filter"),
    start_date: Optional[datetime] = Query(None, description="Filter by start date"),
    end_date: Optional[datetime] = Query(None, description="Filter by end date"),
    categories: Optional[str] = Query(None, description="Comma-separated categories to filter"),
    include_discarded: bool = Query(default=False, description="Include discarded conversations"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List conversations for a user.

    Supports pagination and filtering by status, date range, and category.
    Discarded conversations are excluded by default.

    Sync `def` on purpose — see the note on `process_conversation`. The body is one
    blocking Firestore query, so `async def` put it on the event loop for nothing.
    """
    status_list = [s.strip() for s in statuses.split(",")] if statuses else None
    category_list = [c.strip() for c in categories.split(",")] if categories else None

    conversations = dev_db.get_conversations(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit,
        offset=offset,
        statuses=status_list,
        start_date=start_date,
        end_date=end_date,
        categories=category_list,
        include_discarded=include_discarded,
    )

    return conversations


class ConversationSearchRequest(BaseModel):
    """Request model for searching conversations."""
    external_user_id: Optional[str] = Field(None, description="External user identifier (can also be passed as query param)")
    query: str = Field(..., description="Search query text", min_length=1)
    page: int = Field(default=1, ge=1, description="Page number (1-indexed)")
    per_page: int = Field(default=10, ge=1, le=100, description="Results per page")
    include_discarded: bool = Field(default=True, description="Include discarded conversations")
    start_date: Optional[datetime] = Field(None, description="Filter by start date (ISO 8601)")
    end_date: Optional[datetime] = Field(None, description="Filter by end date (ISO 8601)")


class ConversationSearchResponse(BaseModel):
    """Response model for conversation search results."""
    items: List[dict] = Field(..., description="Matching conversations")
    total_pages: int = Field(..., description="Total number of pages")
    current_page: int = Field(..., description="Current page number")
    per_page: int = Field(..., description="Results per page")


@router.post("/v1/conversations/search", response_model=ConversationSearchResponse, tags=["developer-api-conversations"])
def search_conversations(
    search_request: ConversationSearchRequest,
    external_user_id: Optional[str] = Query(None, description="External user identifier (query param)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Search conversations by meaning.

    Ranking is semantic (the same Pinecone index the chat agent searches), so the
    query only has to describe what to look for — it need not reuse the words
    used in the conversation. Falls back to literal substring matching over
    title+overview when the semantic path has nothing to work with (no vectors
    for this user yet, or an embedding outage).

    Supports pagination and filtering by date range and discarded status.

    Note: external_user_id can be passed either in request body or as query parameter.

    Sync `def` on purpose — see the note on `process_conversation`. The one call
    below looks cheap but isn't: `search_conversations` embeds the query (Vertex AI
    round trip) and then queries Pinecone, so `async def` parked two network waits
    on the event loop. Static "is this handler heavy" scans miss this one because
    the weight lives a call-chain level down.
    """
    # Get external_user_id from body or query param
    user_id = search_request.external_user_id or external_user_id
    if not user_id:
        raise HTTPException(status_code=400, detail="external_user_id is required (in body or query param)")

    results = dev_db.search_conversations(
        developer_id=developer_id,
        external_user_id=user_id,
        query=search_request.query,
        page=search_request.page,
        per_page=search_request.per_page,
        include_discarded=search_request.include_discarded,
        start_date=search_request.start_date,
        end_date=search_request.end_date,
    )

    return results


@router.post("/v1/conversations", response_model=ConversationResponse, status_code=201, tags=["developer-api-conversations"])
async def create_conversation(
    conversation_data: ConversationCreate,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Create a new conversation for a user.

    The conversation starts in 'in_progress' status.
    Use the /finish endpoint to complete it.
    """
    conversation = dev_db.create_conversation(
        developer_id=developer_id,
        external_user_id=conversation_data.external_user_id,
        started_at=conversation_data.started_at,
        finished_at=conversation_data.finished_at,
        language=conversation_data.language,
        source=conversation_data.source,
        metadata=conversation_data.metadata,
    )

    return conversation


def listen_session_lock_key(developer_id: str, external_user_id: str, session_id: str) -> str:
    """The one lock that serializes ALL conversation creation for a listen session.

    Shared with `developer_listen._flush_conversation` and the WebSocket `finally`
    fallback. Before this was shared, the Redis lock only guarded POST /process
    against another POST /process, so the WS silence-flush could create a second
    conversation for the same recording in the seconds POST /process spends inside
    the LLM call, before it writes its dedup marker (observed 2026-08-08: session
    f0e5e8a0 produced conversations 43929118 and 3244256e five seconds apart).
    """
    return f"process_conversation:{developer_id}:{external_user_id}:{session_id}"


def _lookup_processed_conversation(
    developer_id: str,
    external_user_id: str,
    session_id: Optional[str],
) -> Optional[dict]:
    """Return the conversation already produced for this listen session, if any.

    Reads the two Firestore dedup markers written by the App POST /process path
    (`app_processed_conversation_id`) and the WebSocket auto-process paths
    (`auto_processed_conversation_id`). Returns None when the session has not
    been processed yet.
    """
    if not session_id:
        return None
    listen_session = dev_db.get_listen_session(
        developer_id=developer_id,
        external_user_id=external_user_id,
        session_id=session_id,
    )
    if not listen_session:
        return None
    existing_conv_id = (
        listen_session.get('auto_processed_conversation_id')
        or listen_session.get('app_processed_conversation_id')
    )
    if not existing_conv_id:
        return None
    return dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=existing_conv_id,
    )


@router.post("/v1/conversations/process", response_model=ConversationResponse, status_code=201, tags=["developer-api-conversations"])
async def process_conversation(
    process_data: ConversationProcess,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Create and process a conversation with transcript segments.

    This endpoint:
    1. Creates a new conversation
    2. Adds all provided transcript segments
    3. Uses LLM to generate title, overview, category, and action items
    4. Returns the completed conversation

    This is a convenience endpoint that combines create + add segments + finish.

    Concurrency / idempotency:
    Two concurrent POST /process for the SAME session_id used to both pass the
    Firestore dedup check (the marker is only written AFTER the multi-second LLM
    call) and each create a conversation + run the LLM — producing two records
    for one recording (CloudWatch 2026-07-24). We now serialize per session with
    a Redis distributed lock: the loser waits for the winner's marker instead of
    processing again. See redis_db.acquire_lock (fail-open on Redis outage).

    Event loop:
    Every blocking call below is dispatched with `run_in_threadpool`. This handler
    has to stay `async def` (the loser polls with `asyncio.sleep`), but its body is
    otherwise fully synchronous — Firestore reads plus a multi-second LLM pipeline —
    and uvicorn serves this app as a single worker (`Dockerfile`), i.e. one event
    loop per task and only two tasks. Running the pipeline inline therefore froze
    every other request landing on the same task for its whole duration, and this
    endpoint's p50 is 10.3s / max 36.3s (api_logs_daily, 2026-08-08..12). That is
    what made the app's pull-to-refresh feel unresponsive: a `GET /v1/conversations`
    that normally takes 90ms was measured at 1.2s, and 33.4s at worst, purely from
    queueing behind work like this. The poll loop keeps the loop free between
    iterations, so a waiting loser no longer blocks anyone either.
    """
    # Debug: Log session_id
    print(f"[PROCESS] session_id={process_data.session_id}, external_user_id={process_data.external_user_id}, segments={len(process_data.segments)}")

    # No session_id → nothing to dedup/serialize against; process directly.
    if not process_data.session_id:
        return await run_in_threadpool(_do_process_conversation, process_data, developer_id)

    lock_key = listen_session_lock_key(
        developer_id, process_data.external_user_id, process_data.session_id
    )

    # Lock TTL must exceed the worst-case create+LLM+finish time so the lock does
    # not expire mid-processing and let a second request in. If the holder
    # crashes, the TTL still lets a waiter take over afterwards.
    LOCK_TTL_SECONDS = 180
    # Wait budget for losers. MUST be >= LOCK_TTL so a legitimately-slow (but
    # healthy) winner is never abandoned mid-processing — otherwise a loser could
    # give up while the winner still holds the lock and double-process. We wait a
    # little longer than the TTL so that if the holder crashed, its lock expires
    # and we acquire it ourselves within the budget.
    WAIT_POLL_INTERVAL = 0.5
    MAX_WAIT_ITERATIONS = int((LOCK_TTL_SECONDS + 15) / WAIT_POLL_INTERVAL)

    # Optimistic pre-check: if already processed, skip the lock entirely.
    existing = await run_in_threadpool(
        _lookup_processed_conversation,
        developer_id, process_data.external_user_id, process_data.session_id,
    )
    if existing:
        print(f"[PROCESS] Session {process_data.session_id} already processed, returning existing (pre-lock)")
        return existing

    # Acquire-or-wait loop. Invariant: we ONLY call _do_process_conversation while
    # actually holding the lock. A loser either (a) sees the winner's dedup marker
    # and returns the existing conversation, or (b) acquires the lock itself after
    # the winner finishes/releases (or its TTL expires on crash), then processes.
    for _ in range(MAX_WAIT_ITERATIONS):
        if redis_db.acquire_lock(lock_key, ttl_seconds=LOCK_TTL_SECONDS):
            try:
                # Double-check under the lock: the winner may have finished and
                # released between our last poll and this acquire.
                existing = await run_in_threadpool(
                    _lookup_processed_conversation,
                    developer_id, process_data.external_user_id, process_data.session_id,
                )
                if existing:
                    print(f"[PROCESS] Session {process_data.session_id} already processed, returning existing (post-lock)")
                    return existing
                return await run_in_threadpool(_do_process_conversation, process_data, developer_id)
            finally:
                redis_db.release_lock(lock_key)

        # Lock held by a concurrent request — wait for its result before retrying.
        existing = await run_in_threadpool(
            _lookup_processed_conversation,
            developer_id, process_data.external_user_id, process_data.session_id,
        )
        if existing:
            print(f"[PROCESS] Session {process_data.session_id} processed by concurrent request, returning existing")
            return existing
        await asyncio.sleep(WAIT_POLL_INTERVAL)

    # Exhausted the wait budget (> lock TTL) without acquiring or seeing a result.
    # This should be unreachable in practice; surface it rather than silently
    # double-processing.
    print(f"[PROCESS] ERROR: could not acquire lock or find result for session {process_data.session_id} within budget")
    raise HTTPException(status_code=503, detail="Conversation is still being processed, please retry")


def _do_process_conversation(
    process_data: "ConversationProcess",
    developer_id: str,
):
    """Actual create+segments+LLM+finish pipeline for a conversation.

    Extracted from the endpoint so the endpoint can wrap it in a per-session
    Redis lock. Contains the original Firestore dedup check as an in-lock
    double-check (safe/no-op when the caller already checked).
    """
    # Dedup check: if this session was already processed (by backend auto-process
    # OR by a previous app POST /process call), return the existing conversation.
    listen_session = None
    if process_data.session_id:
        listen_session = dev_db.get_listen_session(
            developer_id=developer_id,
            external_user_id=process_data.external_user_id,
            session_id=process_data.session_id,
        )
        if listen_session:
            existing_conv_id = (
                listen_session.get('auto_processed_conversation_id')
                or listen_session.get('app_processed_conversation_id')
            )
            if existing_conv_id:
                print(f"[PROCESS] Session {process_data.session_id} already processed as conversation {existing_conv_id}, returning existing")
                existing_conv = dev_db.get_conversation(
                    developer_id=developer_id,
                    external_user_id=process_data.external_user_id,
                    conversation_id=existing_conv_id,
                )
                if existing_conv:
                    return existing_conv

    if not process_data.segments:
        raise HTTPException(status_code=400, detail="At least one segment is required")

    # Recover coordinates dropped by older clients from the server transcript.
    # New clients round-trip original_start/end. Rebase only a private copy.
    segment_data = restore_original_timestamps(
        [s.model_dump() for s in process_data.segments], listen_session or {},
    )
    if has_original_timestamps(segment_data):
        for s in segment_data:
            s['start'], s['end'] = s['original_start'], s['original_end']
    segment_data = conversation_segments(segment_data)
    process_data = process_data.model_copy(deep=True)
    process_data.segments = [TranscriptSegment(**s) for s in segment_data]

    # Build transcript text from segments — use real person names when the
    # client tagged a segment with person_id, so the LLM-generated summary
    # references "Alice" instead of "Speaker 1".
    person_ids = list({seg.person_id for seg in process_data.segments if seg.person_id})
    person_name_by_id: Dict[str, str] = {}
    if person_ids:
        try:
            people_docs = dev_db.get_people_by_ids(
                developer_id=developer_id,
                external_user_id=process_data.external_user_id,
                person_ids=person_ids,
            )
            person_name_by_id = {p['id']: p.get('name') for p in people_docs if p.get('name')}
        except Exception as e:
            print(f"[PROCESS] Failed to resolve person names: {e}")

    # 🚨 The wearer's own segments MUST keep the literal "User" label — the
    # summarizer and the media-detection branch of `should_discard_conversation`
    # both match on that exact string. See the long comment in
    # `developer_listen.py` `_auto_process_conversation` for why substituting the
    # display name here inverts the point of view.
    transcript_parts = []
    for seg in process_data.segments:
        if seg.is_user:
            speaker_label = "User"
        elif seg.person_id and seg.person_id in person_name_by_id:
            speaker_label = person_name_by_id[seg.person_id]
        else:
            speaker_label = f"Speaker {seg.speaker_id}"
        transcript_parts.append(f"{speaker_label}: {seg.text}")
    transcript_text = "\n".join(transcript_parts)

    # Truncate transcript to avoid LLM input-too-large errors
    max_llm_chars = 100000
    if len(transcript_text) > max_llm_chars:
        print(f"[process_conversation] Truncating transcript from {len(transcript_text)} to {max_llm_chars} chars")
        transcript_text = transcript_text[-max_llm_chars:]

    # Use LLM to process the transcript
    language_code = process_data.language or "zh"

    # Determine the real conversation start/end times.
    #
    # Segments are normalized above so the earliest segment starts at ~0:00 and
    # the latest end (`speech_span`) equals the true conversation length in
    # seconds. Historically started_at/finished_at were both set to the
    # processing instant, so they collapsed to the same minute (e.g. "10:31 to
    # 10:31") and the duration computed from them was a few seconds — even for
    # an 78-minute conversation. Derive both from the transcript span instead.
    speech_span = max((seg.end for seg in process_data.segments), default=0.0)

    started_at = process_data.started_at
    if started_at is None and process_data.session_id:
        # The listen session is created when recording starts, so its created_at
        # is the most accurate available start time.
        session = dev_db.get_listen_session(
            developer_id=developer_id,
            external_user_id=process_data.external_user_id,
            session_id=process_data.session_id,
        )
        if session and session.get('created_at'):
            timeline = session.get('transcript_timeline') or {}
            if has_original_timestamps(segment_data) and timeline.get('audio_started_at'):
                origin = min(s['original_start'] for s in segment_data)
                started_at = timeline['audio_started_at'] + timedelta(seconds=origin)
            else:
                started_at = session['created_at']
    if started_at is None:
        # Last resort: work backwards from now using the transcript span so the
        # start/finish gap still reflects the real conversation length.
        #
        # Deriving an anchor from `now` is only defensible because this is the
        # live path — the app posts here as soon as recording stops, so the error
        # is the processing latency (seconds). The batch paths must not copy it:
        # there, recording and upload can be a day apart, which is why
        # `audio_upload.py` 400s on a missing `started_at` rather than defaulting.
        started_at = datetime.now(timezone.utc) - timedelta(seconds=speech_span)

    finished_at = process_data.finished_at
    if finished_at is None:
        finished_at = started_at + timedelta(seconds=speech_span)

    if has_original_timestamps(segment_data):
        process_data.metadata['transcript_timeline'] = {
            'version': 2, 'axis': 'display', 'session_id': process_data.session_id,
            'origin_seconds': min(s['original_start'] for s in segment_data),
        }
    elif process_data.session_id:
        # Preserve legacy text/display times without inventing coordinates or
        # permanently rejecting creation. Audio consumers refuse this axis.
        process_data.metadata['transcript_timeline'] = {
            'version': 2, 'axis': 'display', 'session_id': process_data.session_id,
            'integrity': 'unverified',
        }

    user_language = dev_db.get_user_language(developer_id, process_data.external_user_id)
    output_language = user_language if user_language else None
    vocabulary_terms = dev_db.get_vocabulary_terms(developer_id, process_data.external_user_id)

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
        print(f"Error processing transcript with LLM: {e}")
        # Fallback to basic structure if LLM fails (localized title)
        from utils.locales import get_fallback_conversation_title
        structured = type('Structured', (), {
            'title': get_fallback_conversation_title(output_language or language_code),
            # Never present raw transcript text as if it were an LLM summary.
            'overview': '',
            'emoji': '💬',
            'category': 'other',
            'action_items': [],
        })()

    # The action-item gate deliberately does NOT run here — `is_user` is still
    # uniformly False before speech-profile matching. It runs afterwards, in
    # `_apply_action_item_gate`. See that function for what running it here cost.

    # Create conversation with processed data
    conversation = dev_db.create_conversation(
        developer_id=developer_id,
        external_user_id=process_data.external_user_id,
        started_at=started_at,
        finished_at=finished_at,
        language=language_code,
        source=process_data.source,
        metadata=process_data.metadata,
    )

    # Bulk-write all segments with compression to avoid Firestore 1MB limit
    segment_dicts = []
    for seg in process_data.segments:
        segment_dicts.append({
            "id": str(uuid.uuid4()),
            "text": seg.text,
            "speaker_id": seg.speaker_id,
            "start": seg.start,
            "end": seg.end,
            "is_user": seg.is_user,
            "person_id": seg.person_id,
            **{k: getattr(seg, k) for k in ('original_start', 'original_end', 'timestamp_axis')
               if getattr(seg, k) is not None},
        })
    dev_db.set_conversation_transcript_segments(
        developer_id=developer_id,
        external_user_id=process_data.external_user_id,
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

    # Decide whether the conversation is meaningful enough to keep. This path
    # previously only checked `speech_span < 10`, which let ambient/near-silent
    # captures through (e.g. a single stray word spread over >10s). Run the same
    # full discard check the WebSocket auto-process and batch pipelines use:
    # short-duration, low language density, too-few-meaningful-words, repetition
    # and media (no user speech) detection.
    should_discard = False
    try:
        should_discard = should_discard_conversation(
            transcript=transcript_text,
            photos=None,
            started_at=started_at,
            finished_at=finished_at,
            transcript_segments=process_data.segments,
            # 同 `developer_listen`：这里也跑在声纹之前，所以「没有 User 标签」在这条
            # 路径上同样是结构性的、零信息量的。判据是此刻是否已有归属信息 —— App 在
            # 录音过程中手动标注过说话人时才有。详见 developer_listen 那处的实测数据。
            speaker_attribution_available=any(
                getattr(s, 'is_user', False) for s in (process_data.segments or [])
            ),
        )
    except Exception as e:
        # Never block conversation creation on a discard-check failure; fall
        # back to the original cheap duration guard.
        print(f"[PROCESS] should_discard_conversation failed ({e}), falling back to speech_span check")
        should_discard = speech_span < 10
    summary_discarded = summary_marks_media(structured)
    if summary_discarded and not should_discard:
        print(f"[PROCESS] Conversation {conversation['id']} summary classified capture as media")
    should_discard = merge_discard_verdict(should_discard, structured)
    if should_discard:
        print(f"[PROCESS] Conversation {conversation['id']} judged not meaningful (speech_span={speech_span:.1f}s), marking as discarded")

    # Localized fallback title in case `structured` is missing it.
    from utils.locales import get_fallback_conversation_title
    fallback_title = get_fallback_conversation_title(output_language or language_code)

    # first_person_observation + highlights come from the same summary call now
    # (fields on Structured), no extra LLM call. Skipped for discarded convos.
    conv_title = getattr(structured, 'title', fallback_title)
    conv_overview = getattr(structured, 'overview', '')

    # Finish the conversation with structured data
    conversation = dev_db.finish_conversation(
        developer_id=developer_id,
        external_user_id=process_data.external_user_id,
        conversation_id=conversation['id'],
        title=conv_title,
        overview=conv_overview,
        category=getattr(structured, 'category', 'other'),
        action_items=action_items,
        emoji=getattr(structured, 'emoji', '🧠'),
        discarded=should_discard,
        emotion=getattr(structured, 'emotion', 'calm'),
        finished_at=finished_at,
        first_person_observation=None if should_discard else (getattr(structured, 'first_person_observation', None) or None),
        highlights=None if should_discard else getattr(structured, 'highlights', None),
    )

    # If session_id provided, link audio from listen session to conversation
    if process_data.session_id:
        print(f"[PROCESS] Looking up listen session: {process_data.session_id}")
        listen_session = dev_db.get_listen_session(
            developer_id=developer_id,
            external_user_id=process_data.external_user_id,
            session_id=process_data.session_id,
        )

        audio_path = None
        if listen_session:
            audio_path = listen_session.get('audio_path')

        # If audio_path not yet set (race condition - audio still being saved),
        # construct the expected path based on the predictable naming convention
        if not audio_path and listen_session:
            # Audio path format: dev_{developer_id}_{external_user_id}/{session_id}.wav
            expected_audio_path = f"dev_{developer_id}_{process_data.external_user_id}/{process_data.session_id}.wav"
            print(f"[PROCESS] audio_path not set yet, checking expected path: {expected_audio_path}")
            # Verify the audio file actually exists before using expected path
            if get_signed_url_from_path(expected_audio_path):
                audio_path = expected_audio_path
                print(f"[PROCESS] Audio file exists at expected path")
            else:
                print(f"[PROCESS] WARNING: Audio file does not exist at expected path, skipping audio link")

        print(f"[PROCESS] Listen session found: {listen_session is not None}, audio_path: {audio_path}")

        if audio_path:
            dev_db.update_conversation_audio_path_dev(
                developer_id=developer_id,
                external_user_id=process_data.external_user_id,
                conversation_id=conversation['id'],
                audio_path=audio_path,
            )
            print(f"[PROCESS] Linked audio_path to conversation {conversation['id']}")
            # Refresh conversation data
            conversation = dev_db.get_conversation(
                developer_id=developer_id,
                external_user_id=process_data.external_user_id,
                conversation_id=conversation['id'],
            )
        # Mark session so WS finally block knows not to auto-process
        try:
            dev_db.update_listen_session(
                developer_id=developer_id,
                external_user_id=process_data.external_user_id,
                session_id=process_data.session_id,
                app_processed_conversation_id=conversation['id'],
            )
            print(f"[PROCESS] Marked session {process_data.session_id} as app-processed with conversation {conversation['id']}")
        except Exception as e:
            print(f"[PROCESS] Failed to mark session as app-processed: {e}")
    else:
        print(f"[PROCESS] No session_id provided, skipping audio link")

    # Store vector embedding in Pinecone for RAG chat retrieval
    def _save_vector_background():
        try:
            from utils.conversations.process_conversation import save_vector_from_dict
            save_vector_from_dict(
                uid=process_data.external_user_id,
                conversation_id=conversation['id'],
                structured=structured,
                event_time=started_at,
                segments=segment_dicts,
                developer_id=developer_id,
            )
        except Exception as e:
            print(f"[VECTOR] Error saving vector: {e}")

    threading.Thread(target=_save_vector_background).start()

    # Long-term memory extraction is NOT started here any more. It runs at the end
    # of `_identify_speakers_then_emit_eir`, because the extraction prompt needs the
    # `is_user` flags that speaker identification writes — starting it here raced
    # the voiceprint thread and always lost. Same rationale as
    # `developer_listen._extract_memories_after_voiceprint`.

    # Emit webhook events for completed conversation
    _emit_conversation_completed_event(
        developer_id=developer_id,
        external_user_id=process_data.external_user_id,
        conversation=conversation,
        session_id=process_data.session_id,
    )

    # Flag the day for chapter recomputation. This path does not go through
    # `process_conversation_developer`, so it needs its own call — the same reason
    # the real-time chain once missed memory extraction entirely.
    mark_timeline_day_dirty(developer_id, process_data.external_user_id, started_at)

    return conversation


def _identify_speakers_then_emit_eir(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
    session_id: Optional[str],
):
    """Background task: voice-profile speaker ID, then EIR emotion detection.

    These run on the same thread (not in parallel) because EIR must read the
    is_user flags that speaker identification writes — otherwise EIR analyzes
    everyone's speech instead of just the user's. Speaker ID can call the
    hosted model (up to 120s), so this must stay off the request path.
    """
    try:
        if session_id:
            segments_for_match = conversation.get("transcript_segments", []) or []
            # Speakers the client already tagged (person_id present) are manual
            # assignments — the voice-profile vote must not overwrite them.
            protected_keys = {
                _speaker_key(seg) for seg in segments_for_match if seg.get("person_id")
            }
            _, sp_updated = identify_developer_speakers(
                developer_id=developer_id,
                external_user_id=external_user_id,
                session_id=session_id,
                segments=segments_for_match,
                protected_speaker_keys=protected_keys,
            )
            if sp_updated:
                dev_db.set_conversation_transcript_segments(
                    developer_id=developer_id,
                    external_user_id=external_user_id,
                    conversation_id=conversation['id'],
                    segments=segments_for_match,
                )
                print(f"[SPEECH_PROFILE] Updated segments for conversation {conversation['id']}")
                # Reuse the freshly-updated segments for EIR (avoids a re-read).
                conversation = {**conversation, "transcript_segments": segments_for_match}
                _revisit_user_dependent_verdicts(
                    developer_id, external_user_id, conversation, segments_for_match
                )
    except Exception as e:
        print(f"[SPEECH_PROFILE] Error in speech profile matching: {e}")

    # Unconditional with respect to the *outcome* of matching — "matching resolved
    # nobody" is the very case this gate exists for (no `is_user` ⇒ the to-dos
    # cannot be attributed to anyone) — but NOT with respect to whether matching
    # ran at all. Everything above is wrapped in `if session_id:`, and two callers
    # reach this function without one (`developer_listen._auto_process_conversation`
    # and the `/finish` endpoint, both via `_emit_conversation_completed_event`).
    # On those paths no voiceprint is ever consulted here, so `is_user` is still
    # whatever the summary saw: uniformly False. Judging attribution on that is the
    # 88% defect — see `_apply_action_item_gate` for what it cost on 2026-08-19.
    # The listen path runs its own gate after its own voiceprint thread; `/finish`
    # takes the caller's items at their word.
    # Idempotent, so the call inside `_revisit_user_dependent_verdicts` can stay for
    # the other paths that reach it.
    _apply_action_item_gate(
        developer_id, external_user_id, conversation,
        conversation.get('transcript_segments') or [],
        voiceprint_ran=bool(session_id),
    )

    # After the gate, so nothing is spent on a conversation whose to-dos were just
    # revoked. Only wired here, not inside `_revisit_user_dependent_verdicts` —
    # that one is also reached from the gate's other call site, and running an LLM
    # call twice for the same conversation would just cost twice.
    _apply_action_item_dedupe(developer_id, external_user_id, conversation)

    _emit_eir_emotion_event(developer_id, external_user_id, conversation)

    # Long-term memory extraction, last: it needs the `is_user` flags written
    # above, and it is the slowest step here so nothing else should wait on it.
    # Runs even when matching failed — worst case the transcript has no `is_user`,
    # which is exactly what the old racing version always got.
    if not conversation.get('discarded'):
        try:
            from utils.conversations.process_conversation import extract_memories_from_segments

            extract_memories_from_segments(
                developer_id=developer_id,
                external_user_id=external_user_id,
                conversation_id=conversation['id'],
                segments=conversation.get('transcript_segments') or [],
            )
        except Exception as e:
            print(f"[MEMORY] Extraction after voiceprint failed for {conversation.get('id')}: {e}")


def _set_action_items_in_place(conversation: dict, items: list) -> None:
    """Write `items` onto the caller's `conversation` dict, creating `structured`.

    Not `conversation.setdefault('structured', {})['action_items'] = items`: when the
    key exists and holds `None`, `setdefault` hands back that `None` and the
    subscript assignment raises TypeError. The gate reads the same field as
    `(conversation.get('structured') or {})` two lines up precisely because None is
    possible — and inside the gate that TypeError is swallowed by the best-effort
    `except`, leaving Firestore correct but the in-memory copy stale, which is the
    one thing this write-back exists to prevent.
    """
    structured = conversation.get('structured')
    if not isinstance(structured, dict):
        structured = {}
        conversation['structured'] = structured
    structured['action_items'] = items


def _apply_action_item_gate(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
    segments: list,
    *,
    voiceprint_ran: bool,
):
    """Revoke action items that cannot be attributed to the wearer.

    Runs after speech-profile matching, which is the only thing that ever sets
    `is_user` — see `user_participated_enough_for_action_items` for the three
    states and for why this gate flip-flopped once. Short version: it keeps to-dos
    only when a voiceprint actually named the wearer AND the wearer's share of
    spoken words clears the floor. Without `is_user` there is no way to tell whose
    commitment a sentence is, and "things *you* promised" with the wrong owner is
    worse than nothing — verified by hand on the 20 items that shipped on
    2026-08-15 (a parent's instruction to a child, the other party's promise in a
    pitch, and two items invented outright, all phrased as the user's own).

    Why it must not live on the request path: `is_user` is uniformly False there,
    so every conversation would look unattributable and every to-do would be
    deleted — that is the 88% loss this file's history records.

    ⚠️ `voiceprint_ran` is keyword-only and has **no default**, so every call site
    has to state whether a voiceprint was actually consulted. That is the whole
    point: "no `is_user`" only means "unattributable" once matching has run. Before
    that it means "not known yet", and the two are indistinguishable from inside
    this function — the segments look identical. Defaulting it to True is how the
    88% defect comes back, and it came back once exactly this way: `developer_listen`
    and the `/finish` endpoint both call `_emit_conversation_completed_event`
    *without* a session_id, that helper spawns `_identify_speakers_then_emit_eir`,
    and there the matching is wrapped in `if session_id:` while this gate ran
    unconditionally underneath it. On 2026-08-19 that revoked 2 real to-dos on
    conversation 829f0366 at 08:59:35 ("no is_user segment"); the listen path's own
    voiceprint thread found the wearer had spoken 88/175 segments (52% of words) 56
    seconds later and restored the conversation. Nothing in the logs contradicted
    itself except those two lines, one minute apart.

    ⚠️ **Revocation is now reversible, and this function is what reverses it.**
    `clear_action_items` archives to `structured.action_items_revoked` instead of
    deleting, and the "wearer spoke enough" branch below calls
    `restore_revoked_action_items` rather than returning early — that is what makes
    the 08-19 sequence recoverable. Reverting either half re-arms a permanent loss.

    Best-effort: a conversation must never fail because this couldn't run.
    """
    items = (conversation.get('structured') or {}).get('action_items') or []
    if not voiceprint_ran:
        if items:
            print(
                f"[action-items] Gate skipped on {conversation.get('id')}: speaker "
                f"identification never ran on this path, so `is_user` carries no "
                f"information yet — leaving {len(items)} item(s) for the path that does"
            )
        return
    try:
        from utils.llm.conversation_processing import (
            _ACTION_ITEM_MIN_USER_RATIO,
            user_participated_enough_for_action_items,
        )

        if user_participated_enough_for_action_items(segments):
            # A *later* voiceprint pass can overturn an earlier revocation, so this
            # branch cannot just return. A conversation gets gated once per
            # voiceprint thread (the listen path and the app-process path each run
            # one), and on 2026-08-19 the first pass revoked 2 items on 175
            # uniformly-False segments while the second, 56 seconds later, found the
            # wearer had spoken 52% of the words.
            #
            # ⚠️ This must be asked of Firestore, not of `conversation` — and the
            # `if not items` early return that used to sit at the top of this
            # function made it unreachable, because revoking empties the array.
            # The second caller's in-memory copy is no help either: it was usually
            # read *before* the first pass revoked, so it still shows the items as
            # present while Firestore has none.
            restored = dev_db.restore_revoked_action_items(
                developer_id=developer_id,
                external_user_id=external_user_id,
                conversation_id=conversation['id'],
            )
            if restored:
                # Write back, symmetrically with the revoke branch below. Without
                # this `_apply_action_item_dedupe` — which runs right after the gate
                # and reads this dict — sees the stale empty list and bails on
                # `len < 2`. The revoking pass skipped dedupe for that same reason,
                # so these items would go through dedupe *never*, not merely late.
                _set_action_items_in_place(conversation, restored)
                print(
                    f"[action-items] Restored {len(restored)} revoked action item(s) on "
                    f"{conversation['id']}: a later voiceprint pass cleared the floor"
                )
            return

        if not items:
            return

        # Distinguish the two reasons in the log — they call for different fixes.
        # "unattributable" points at voiceprint recall; "below the floor" means the
        # wearer really was just sitting in, which is the gate working as intended.
        tagged = any(
            (s.get('is_user') if isinstance(s, dict) else getattr(s, 'is_user', False))
            for s in segments
        )
        reason = (
            f"wearer spoke below {_ACTION_ITEM_MIN_USER_RATIO:.0%} of words"
            if tagged else
            "no is_user segment — ownership unattributable (voiceprint unresolved)"
        )

        removed = dev_db.clear_action_items(
            developer_id=developer_id,
            external_user_id=external_user_id,
            conversation_id=conversation['id'],
        )
        if removed:
            _set_action_items_in_place(conversation, [])
            print(
                f"[action-items] Revoked {removed} action item(s) on "
                f"{conversation['id']}: {reason}"
            )
    except Exception as e:
        print(f"[action-items] Gate failed on {conversation.get('id')}: {e}")


def _apply_action_item_dedupe(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
):
    """合并「你答应过的事」里重复的条目。

    跑在 `_apply_action_item_gate` **之后**，不是之前：被门禁清空的对话没有待办可判，
    早跑就是白花一次 LLM 调用。

    只判**这条对话内部**的重复，不跟历史待办比——实测（2026-08-17，某账号 384 条待办
    里 41 条冗余）13/18 组的重复就在同一条对话内，而跨对话比对贡献的 5/18 收益换来的
    是几乎全部的误杀。判据和放弃跨对话的完整实测见
    `utils.llm.deduplication` 的模块 docstring。

    Best-effort：一条对话绝不能因为判重失败而处理失败。
    """
    items = (conversation.get('structured') or {}).get('action_items') or []
    if len(items) < 2:
        return
    try:
        from utils.llm.deduplication import resolve_action_item_duplicates

        descriptions = [
            (it.get('description') if isinstance(it, dict) else str(it)) or '' for it in items
        ]
        drop_indexes = resolve_action_item_duplicates(descriptions)
        if not drop_indexes:
            return

        removed = dev_db.remove_action_items(
            developer_id=developer_id,
            external_user_id=external_user_id,
            conversation_id=conversation['id'],
            item_indexes=drop_indexes,
        )
        if removed:
            drop = set(drop_indexes)
            conversation.setdefault('structured', {})['action_items'] = [
                it for i, it in enumerate(items) if i not in drop
            ]
            print(
                f"[action-items] Merged {removed} duplicate item(s) on {conversation['id']}"
            )
    except Exception as e:
        print(f"[action-items] Dedupe failed on {conversation.get('id')}: {e}")


def _revisit_user_dependent_verdicts(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
    segments: list,
):
    """Re-run the `is_user`-dependent verdicts now that voiceprints are known.

    Ordering problem this fixes: `should_discard_conversation` and the action-item
    gate both read `is_user`, but they run on the request path — BEFORE speaker
    identification writes it. They therefore always saw `is_user=False` on every
    segment, i.e. "the user never spoke". Consequences observed in production:
      * a real conversation was discarded as media playback (old Rule 3), and
      * discarded conversations skip `first_person_observation`, so the app showed
        a title with no subtitle.

    Rather than move the whole discard/summary step behind a 120s model call, we
    revisit just the verdict once the real flags land. Only ever *undiscards*: a
    conversation kept by the LLM is never taken away here, and the discard rules
    that don't involve `is_user` (duration, density, repetition) already had their
    say on the request path.

    The action-item gate is applied here too — see `_apply_action_item_gate`. That
    one runs on every conversation, not just discarded ones, so it comes first.

    `voiceprint_ran=True` holds for every caller by construction: all four reach
    this function only after `identify_developer_speakers` returned, which is what
    the whole "revisit" framing means. Check that before adding a fifth.
    """
    _apply_action_item_gate(
        developer_id, external_user_id, conversation, segments, voiceprint_ran=True,
    )

    if not conversation.get('discarded'):
        return
    if not any(seg.get('is_user') for seg in segments):
        return  # still no user speech — the original verdict stands

    from utils.llm.conversation_processing import _compute_user_participation

    part = _compute_user_participation(segments)
    if not part or part['user_ratio'] <= 0.05:
        return

    print(
        f"[SPEECH_PROFILE] Conversation {conversation['id']} was discarded before voiceprints "
        f"were known; user actually spoke {part['user_segments']}/{part['total_segments']} segments "
        f"({part['user_ratio'] * 100:.0f}% of words) — restoring."
    )

    # A discarded conversation never got first_person_observation/highlights
    # written.  It may also carry the summarizer's own `[Media Recording]`
    # sentinel (or an empty fallback summary after a parse failure).  Restoring
    # only the flag would expose that broken card, so replace the full visible
    # summary when necessary.
    observation, highlights = None, None
    summary_updates = {}
    regenerated = None
    structured_existing = conversation.get('structured') or {}
    existing_title = (structured_existing.get('title') or '').strip()
    existing_overview = (structured_existing.get('overview') or '').strip()
    try:
        needs_full_summary = (
            summary_marks_media(structured_existing)
            or not existing_title
            or not existing_overview
        )
        if needs_full_summary or not (structured_existing.get('first_person_observation') or '').strip():
            # "User" is the literal label the summarizer prompt matches on — not
            # the display name. See `developer_listen.py` for the full rationale.
            transcript = "\n".join(
                f"{'User' if seg.get('is_user') else 'Speaker ' + str(seg.get('speaker_id', 0))}: "
                f"{seg.get('text', '')}"
                for seg in segments
            )
            language = dev_db.get_user_language(developer_id, external_user_id) or 'zh'
            regenerated = get_transcript_structure(
                transcript=transcript,
                started_at=conversation.get('started_at') or conversation.get('created_at'),
                language_code=language,
                tz=dev_db.get_user_time_zone(developer_id, external_user_id) or 'UTC',
                output_language=language,
                vocabulary_terms=dev_db.get_vocabulary_terms(developer_id, external_user_id),
            )
            observation = getattr(regenerated, 'first_person_observation', None) or None
            highlights = getattr(regenerated, 'highlights', None) or None
            if needs_full_summary:
                new_title = (getattr(regenerated, 'title', '') or '').strip()
                new_overview = (getattr(regenerated, 'overview', '') or '').strip()
                if summary_marks_media(regenerated) or not new_title or not new_overview:
                    print(
                        f"[SPEECH_PROFILE] Refusing to expose {conversation['id']}: "
                        "regenerated summary is still media/empty"
                    )
                    return
                summary_updates = {
                    'title': new_title,
                    'overview': new_overview,
                    'emoji': getattr(regenerated, 'emoji', '') or '',
                    'category': getattr(regenerated, 'category', '') or 'other',
                    'emotion': getattr(regenerated, 'emotion', '') or 'calm',
                }
    except Exception as e:
        print(f"[SPEECH_PROFILE] Could not regenerate summary for {conversation['id']}: {e}")
        if not existing_title or not existing_overview or summary_marks_media(structured_existing):
            return

    try:
        dev_db.update_conversation_discarded(
            developer_id=developer_id,
            external_user_id=external_user_id,
            conversation_id=conversation['id'],
            discarded=False,
            first_person_observation=observation,
            highlights=highlights,
            **summary_updates,
        )
        # Mutating the caller's dict is load-bearing, not bookkeeping:
        # `developer_listen._extract_memories_after_voiceprint` reads `discarded`
        # off this very dict afterwards to decide whether to extract. Rebuild it
        # as a copy and every conversation rescued here silently loses its
        # memories again.
        conversation['discarded'] = False
        if summary_updates:
            stored_structured = dict(structured_existing)
            stored_structured.update(summary_updates)
            stored_structured['first_person_observation'] = observation or ''
            stored_structured['highlights'] = highlights or []
            conversation['structured'] = stored_structured

            # The first vector was written from the media/fallback summary before
            # voiceprints completed. Replace it with exactly the fields now stored
            # in Firestore; do not embed regenerated action items/events that were
            # intentionally not written by this recovery path.
            from utils.conversations.process_conversation import save_vector_from_dict

            save_vector_from_dict(
                uid=external_user_id,
                conversation_id=conversation['id'],
                structured=stored_structured,
                event_time=conversation.get('started_at') or conversation.get('created_at'),
                segments=segments,
                developer_id=developer_id,
            )
    except Exception as e:
        print(f"[SPEECH_PROFILE] Failed to restore conversation {conversation['id']}: {e}")


def mark_timeline_day_dirty(developer_id: str, external_user_id: str, started_at, *, immediate: bool = False) -> None:
    """Flag a conversation's local day for chapter recomputation.

    Shared by this router's `/process` and `/finish` paths and by
    `developer_listen`'s auto-process. Each of those finishes a conversation
    without going through `process_conversation_developer`, so each needs its own
    call — the real-time chain going a whole release cycle with no memory
    extraction is what that omission looks like in production.

    Imported lazily and never allowed to raise: the chapter cache sits on top of
    conversations and must not be able to fail one.
    """
    try:
        from utils.timeline.store import mark_conversation_day_dirty

        if immediate:
            mark_conversation_day_dirty(developer_id, external_user_id, started_at, immediate=True)
        else:
            mark_conversation_day_dirty(developer_id, external_user_id, started_at)
    except Exception as e:
        print(f"[TIMELINE] Failed to mark day dirty: {e}")


def _emit_conversation_completed_event(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
    session_id: Optional[str] = None,
):
    """Emit webhook events when conversation is completed.

    This emits:
    - conversation.completed event
    - eir.emotion_detected event (via background thread, after speaker ID)
    """
    try:
        from utils.developer_eir_events import emit_developer_event
        from models.developer_eir_webhook import DeveloperEventType

        # Calculate duration
        duration_seconds = 0.0
        started_at = conversation.get("started_at")
        finished_at = conversation.get("finished_at")
        if started_at and finished_at:
            if hasattr(started_at, 'timestamp') and hasattr(finished_at, 'timestamp'):
                duration_seconds = (finished_at - started_at).total_seconds()

        structured = conversation.get("structured", {})

        # Emit conversation.completed event
        emit_developer_event(
            developer_id=developer_id,
            external_user_id=external_user_id,
            event_type=DeveloperEventType.conversation_completed,
            data={
                "conversation_id": conversation.get("id"),
                "title": structured.get("title", ""),
                "overview": structured.get("overview", ""),
                "duration_seconds": duration_seconds,
                "category": structured.get("category"),
                "action_items_count": len(structured.get("action_items", [])),
            }
        )
        print(f"[PROCESS] Emitted conversation.completed event for {conversation.get('id')}")

        # Speaker identification + EIR emotion detection in background.
        # Both run on one thread so EIR sees the is_user flags speaker ID writes.
        import threading
        threading.Thread(
            target=_identify_speakers_then_emit_eir,
            args=(developer_id, external_user_id, conversation, session_id),
            daemon=True,
        ).start()

    except Exception as e:
        print(f"[PROCESS] Error emitting webhook event: {e}")


def _emit_eir_emotion_event(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
):
    """Detect emotion from conversation and emit EIR webhook event.

    This runs in a background thread to avoid blocking the response.
    """
    try:
        from utils.developer_eir_events import emit_developer_event
        from models.developer_eir_webhook import DeveloperEventType
        from utils.llm.emotion_detection_simple import detect_emotion_from_transcript

        conversation_id = conversation.get("id")
        print(f"[EIR] Running emotion detection for conversation {conversation_id}")

        # Extract transcript segments
        segments = conversation.get("transcript_segments", [])
        if not segments:
            print(f"[EIR] No transcript segments for conversation {conversation_id}")
            return

        # Build transcript text from segments
        user_texts = []
        all_texts = []
        seg_starts = []
        seg_ends = []
        for seg in segments:
            text = seg.get("text", "")
            if text:
                all_texts.append(text)
                if seg.get("start") is not None:
                    seg_starts.append(seg.get("start"))
                if seg.get("end") is not None:
                    seg_ends.append(seg.get("end"))
                if seg.get("is_user", False):
                    user_texts.append(text)

        # Use user segments if available, otherwise use all segments
        used_user_segments = bool(user_texts)
        transcript = "\n".join(user_texts) if user_texts else "\n".join(all_texts)

        if len(transcript.strip()) < 30:
            print(f"[EIR] Transcript too short ({len(transcript)} chars) for conversation {conversation_id}")
            return

        # Detect emotion from transcript
        eir_result = detect_emotion_from_transcript(transcript)

        if eir_result is None:
            print(f"[EIR] No emotion detected for conversation {conversation_id}")
            return

        # Log the evidence behind the verdict so it stays inspectable even if the
        # conversation document is later deleted. We log only the model's
        # emotion_summary (its rationale), never the raw transcript text, to
        # avoid persisting user conversation content in CloudWatch.
        time_range = ""
        if seg_starts and seg_ends:
            time_range = f", time={min(seg_starts):.1f}-{max(seg_ends):.1f}s"
        print(f"[EIR] Detected emotion: {eir_result.primary_emotion.value} "
              f"(confidence: {eir_result.confidence:.2f}) for conversation {conversation_id}")
        print(f"[EIR] Verdict basis for {conversation_id}: "
              f"segments={len(segments)} (user_only={used_user_segments}) "
              f"chars={len(transcript)}{time_range} | summary={eir_result.emotion_summary!r}")

        # Persist EIR result onto the conversation document so /v1/discover/latest-emotion
        # and the mobile Avatar card can read the latest mood directly.
        try:
            import database.developer_data as _dev_db
            _dev_db.update_conversation_eir_dev(
                developer_id=developer_id,
                external_user_id=external_user_id,
                conversation_id=conversation_id,
                eir_emotion=eir_result.primary_emotion.value,
                eir_confidence=eir_result.confidence,
            )
        except Exception as e:
            print(f"[EIR] Failed to persist EIR result for {conversation_id}: {e}")

        # Emit the event
        emit_developer_event(
            developer_id=developer_id,
            external_user_id=external_user_id,
            event_type=DeveloperEventType.eir_emotion_detected,
            data={
                "conversation_id": conversation_id,
                "eir_primary_emotion": eir_result.primary_emotion.value,
                "eir_confidence": eir_result.confidence,
                "eir_should_notify": eir_result.should_notify,
                "eir_emotion_summary": eir_result.emotion_summary,
            }
        )
        print(f"[EIR] Emitted eir.emotion_detected event for conversation {conversation_id}")

    except Exception as e:
        print(f"[EIR] Error in emotion detection: {e}")
        import traceback
        traceback.print_exc()


@router.get("/v1/conversations/{conversation_id}", response_model=ConversationResponse, tags=["developer-api-conversations"])
async def get_conversation(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get a single conversation by ID.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return conversation


@router.get("/v1/conversations/{conversation_id}/audio-url", tags=["developer-api-conversations"])
def get_conversation_audio_url(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Generate a short-lived signed URL for downloading conversation audio.
    The URL is valid for 15 minutes.

    Returns:
        {"audio_url": "https://..."} if audio exists
        {"audio_url": null} if no audio available

    Sync `def` on purpose — see the note on `process_conversation`. `get_conversation`
    decompresses the transcript and the signing call talks to GCS; neither is awaited.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    # Get audio_path from conversation
    audio_path = conversation.get('audio_path')
    if not audio_path:
        # Generate path from external_user_id and conversation_id for backward compatibility
        audio_path = f'{external_user_id}/{conversation_id}.wav'

    signed_url = get_signed_url_from_path(audio_path, minutes=15)
    return {'audio_url': signed_url if signed_url else None}


@router.get("/v1/conversations/{conversation_id}/audio-alignment", tags=["developer-api-conversations"])
def get_conversation_audio_alignment(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Where each transcript segment sits in the conversation's audio file, so a client
    can seek to a sentence. Seek with these, never with the segment times shown in
    the transcript: a live recording's audio is the whole session with silence
    removed, so the two axes differ (see ``utils/stt/recording_alignment.py``).

    Returns:
        {"aligned": true, "segments": [{"id": ..., "start": s, "end": s}, ...]} on the
        audio file's axis. ``start == end`` means VAD removed that segment's audio.
        {"aligned": false, "reason": ..., "segments": []} when the transcript has no
        timestamp provenance (older recordings) — it cannot be aligned without guessing.

    Sync `def` on purpose — see the note on `process_conversation`.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return conversation_audio_alignment(developer_id, external_user_id, conversation)


@router.patch("/v1/conversations/{conversation_id}", response_model=ConversationResponse, tags=["developer-api-conversations"])
async def update_conversation(
    conversation_id: str,
    update_data: ConversationUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update a conversation.

    Only provided fields will be updated. Metadata is merged with existing.
    """
    conversation = dev_db.update_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        title=update_data.title,
        overview=update_data.overview,
        status=update_data.status,
        metadata=update_data.metadata,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return conversation


@router.delete("/v1/conversations/{conversation_id}", status_code=204, tags=["developer-api-conversations"])
async def delete_conversation(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a conversation.
    """
    # Read before deleting: `started_at` is the only thing that says which day's
    # chapters have to be rebuilt, and after the delete it is gone. A missed mark
    # here leaves the deleted conversation visible inside a cached chapter.
    existing = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        include_photos=False,
    )

    success = dev_db.delete_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Conversation not found")

    if existing:
        mark_timeline_day_dirty(developer_id, external_user_id, existing.get('started_at'))

    return


@router.post(
    "/v1/conversations/{conversation_id}/segments",
    response_model=SegmentResponse,
    status_code=201,
    tags=["developer-api-conversations"],
)
async def add_transcript_segment(
    conversation_id: str,
    segment_data: SegmentAdd,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Add a transcript segment to a conversation.

    Use this to stream transcript segments as they are generated.
    """
    segment = dev_db.add_transcript_segment(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        text=segment_data.text,
        speaker_id=segment_data.speaker_id,
        start=segment_data.start,
        end=segment_data.end,
        is_user=segment_data.is_user,
        person_id=segment_data.person_id,
    )

    if not segment:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return segment


@router.post(
    "/v1/conversations/{conversation_id}/finish",
    response_model=ConversationResponse,
    tags=["developer-api-conversations"],
)
async def finish_conversation(
    conversation_id: str,
    finish_data: ConversationFinish,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Mark a conversation as finished.

    Sets the status to 'completed' and updates the structured data
    (title, overview, category, action items).
    """
    action_items = None
    if finish_data.action_items:
        action_items = [
            {
                "description": item.description,
                "completed": item.completed,
                "confirmed": item.confirmed,
                "due_date": item.due_date,
                "due_hint": item.due_hint,
            }
            for item in finish_data.action_items
        ]

    conversation = dev_db.finish_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        title=finish_data.title,
        overview=finish_data.overview,
        category=finish_data.category,
        action_items=action_items,
        emotion=finish_data.emotion,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    # Emit webhook event
    _emit_conversation_completed_event(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation=conversation,
    )

    # A caller-supplied title/overview is exactly what the chapter rollup quotes,
    # so the day's chapters no longer describe their contents.
    mark_timeline_day_dirty(developer_id, external_user_id, conversation.get('started_at'))

    return conversation


@router.post(
    "/v1/conversations/{conversation_id}/reprocess",
    response_model=ConversationResponse,
    tags=["developer-api-conversations"],
)
async def reprocess_conversation(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    language_code: Optional[str] = Query(None, description="Language code for processing"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Reprocess a conversation to regenerate the LLM summary.

    Use this to:
    - Generate a summary for a conversation that was created without auto_process
    - Regenerate the summary if the original processing failed
    - Force reprocessing of a discarded conversation
    """
    # Get the conversation from developer data path
    conversation_data = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation_data:
        raise HTTPException(status_code=404, detail="Conversation not found")

    # Convert to Conversation model
    # Handle missing fields with defaults
    if 'structured' not in conversation_data or not conversation_data['structured']:
        conversation_data['structured'] = {'title': '', 'overview': ''}
    if 'transcript_segments' not in conversation_data:
        conversation_data['transcript_segments'] = []

    # Normalize source field to valid enum value
    source_str = conversation_data.get('source', 'audio_upload')
    try:
        source_enum = ConversationSource(source_str)
    except ValueError:
        source_enum = ConversationSource.audio_upload
    conversation_data['source'] = source_enum

    try:
        conversation = Conversation(**conversation_data)
    except Exception as e:
        print(f"Error creating Conversation object: {e}")
        # Create a minimal Conversation object
        conversation = Conversation(
            id=conversation_data.get('id', conversation_id),
            created_at=conversation_data.get('created_at', datetime.now(timezone.utc)),
            started_at=conversation_data.get('started_at'),
            finished_at=conversation_data.get('finished_at'),
            source=source_enum,
            language=conversation_data.get('language', language_code or 'en'),
            structured=Structured(title='', overview=''),
            transcript_segments=conversation_data.get('transcript_segments', []),
            status=ConversationStatus.processing,
        )

    # Use language from request or fall back to conversation language
    lang = language_code or conversation.language or 'en'

    # Update status to processing
    dev_db.update_conversation_status_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        status="processing",
    )

    # Process the conversation with LLM (force_process=True skips discard check
    # and uses the reprocess prompt for regeneration)
    processed_conversation = process_conversation_developer(
        developer_id=developer_id,
        external_user_id=external_user_id,
        language_code=lang,
        conversation=conversation,
        force_process=True,
    )

    # Return the updated conversation
    return dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )


# ******************************************************
# **************** ACTION ITEMS ************************
# ******************************************************


class ActionItemCreate(BaseModel):
    description: str = Field(..., description="Action item description")
    completed: bool = Field(default=False, description="Whether completed")
    due_date: Optional[datetime] = Field(None, description="Deadline, only when a specific date is known")
    due_hint: str = Field(default='', description="Timing as spoken, e.g. 'this week'")


class ActionItemUpdate(BaseModel):
    description: Optional[str] = Field(None, description="New description")
    completed: Optional[bool] = Field(None, description="New completed status")
    confirmed: Optional[bool] = Field(None, description="User accepted this as a to-do")
    due_date: Optional[datetime] = Field(None, description="New deadline")
    due_hint: Optional[str] = Field(None, description="New spoken timing hint")


class ActionItemBatchUpdate(BaseModel):
    idx: int = Field(..., description="Index of action item")
    description: Optional[str] = Field(None, description="New description")
    completed: Optional[bool] = Field(None, description="New completed status")
    confirmed: Optional[bool] = Field(None, description="User accepted this as a to-do")
    due_date: Optional[datetime] = Field(None, description="New deadline")
    due_hint: Optional[str] = Field(None, description="New spoken timing hint")


class ActionItemBatchRequest(BaseModel):
    updates: List[ActionItemBatchUpdate] = Field(..., description="List of updates")


@router.get(
    "/v1/conversations/{conversation_id}/action-items",
    response_model=List[ActionItem],
    tags=["developer-api-action-items"],
)
async def get_action_items(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get all action items for a conversation.
    """
    action_items = dev_db.get_action_items(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if action_items is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return action_items


@router.post(
    "/v1/conversations/{conversation_id}/action-items",
    response_model=ActionItem,
    status_code=201,
    tags=["developer-api-action-items"],
)
async def add_action_item(
    conversation_id: str,
    item_data: ActionItemCreate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Add a new action item to a conversation.
    """
    action_item = dev_db.add_action_item(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        description=item_data.description,
        completed=item_data.completed,
        due_date=item_data.due_date,
        due_hint=item_data.due_hint,
    )

    if not action_item:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return action_item


@router.patch(
    "/v1/conversations/{conversation_id}/action-items",
    response_model=List[ActionItem],
    tags=["developer-api-action-items"],
)
async def batch_update_action_items(
    conversation_id: str,
    batch_data: ActionItemBatchRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Batch update action items.

    Allows updating multiple action items in a single request.
    """
    updates = []
    for u in batch_data.updates:
        entry = {"idx": u.idx}
        if u.description is not None:
            entry["description"] = u.description
        if u.completed is not None:
            entry["completed"] = u.completed
        if u.confirmed is not None:
            entry["confirmed"] = u.confirmed
        if u.due_date is not None:
            entry["due_date"] = u.due_date
        if u.due_hint is not None:
            entry["due_hint"] = u.due_hint
        updates.append(entry)

    action_items = dev_db.batch_update_action_items(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        updates=updates,
    )

    if action_items is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return action_items


@router.patch(
    "/v1/conversations/{conversation_id}/action-items/{item_idx}",
    response_model=ActionItem,
    tags=["developer-api-action-items"],
)
async def update_action_item(
    conversation_id: str,
    item_idx: int,
    item_data: ActionItemUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update a single action item.
    """
    action_item = dev_db.update_action_item(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        item_idx=item_idx,
        description=item_data.description,
        completed=item_data.completed,
        confirmed=item_data.confirmed,
        due_date=item_data.due_date,
        due_hint=item_data.due_hint,
    )

    if not action_item:
        raise HTTPException(status_code=404, detail="Action item not found")

    return action_item


@router.delete(
    "/v1/conversations/{conversation_id}/action-items/{item_idx}",
    status_code=204,
    tags=["developer-api-action-items"],
)
async def delete_action_item(
    conversation_id: str,
    item_idx: int,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete an action item.
    """
    success = dev_db.delete_action_item(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        item_idx=item_idx,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Action item not found")

    return


# ******************************************************
# ************** ADDITIONAL CONVERSATION OPS ***********
# ******************************************************


@router.post("/v1/conversations/{conversation_id}/report", tags=["developer-api-conversations"])
async def report_conversation(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """Report a conversation for review."""
    conv = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )
    if not conv:
        raise HTTPException(status_code=404, detail="Conversation not found")

    dev_db.report_conversation(developer_id, external_user_id, conversation_id)
    return {"status": "reported"}


@router.patch("/v1/conversations/{conversation_id}/pin", tags=["developer-api-conversations"])
async def toggle_pin_conversation(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """Toggle the pinned status of a conversation."""
    new_pinned = dev_db.toggle_conversation_pin(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if new_pinned is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return {"pinned": new_pinned}


class TitleUpdate(BaseModel):
    title: str = Field(..., description="New conversation title")


@router.patch("/v1/conversations/{conversation_id}/title", tags=["developer-api-conversations"])
async def update_conversation_title(
    conversation_id: str,
    title: str = Query(..., description="New title"),
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update the title of a conversation.
    """
    success = dev_db.update_conversation_title_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        title=title,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return {"status": "Ok"}


class SetEventsStateRequest(BaseModel):
    events_idx: List[int] = Field(..., description="List of event indices to update")
    values: List[bool] = Field(..., description="List of created values (True/False)")


@router.patch("/v1/conversations/{conversation_id}/events", response_model=dict, tags=["developer-api-conversations"])
async def set_conversation_events_state(
    conversation_id: str,
    data: SetEventsStateRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update the 'created' state of events in a conversation.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    structured = conversation.get("structured", {})
    events = structured.get("events", [])

    for i, event_idx in enumerate(data.events_idx):
        if event_idx >= len(events):
            continue
        events[event_idx]["created"] = data.values[i]

    success = dev_db.update_conversation_events_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        events=events,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Failed to update events")

    return {"status": "Ok"}


class BulkAssignSegmentsRequest(BaseModel):
    segment_ids: List[str] = Field(..., description="List of segment IDs to assign")
    assign_type: str = Field(..., description="Type of assignment: 'is_user' or 'person_id'")
    value: Optional[str] = Field(None, description="Value to assign (person_id or 'true'/'false' for is_user)")
    source: str = Field(
        default='manual',
        description=(
            "Origin of this assignment: 'manual' when a person confirmed it, "
            "'auto' when a model produced it. Only manual assignments are allowed "
            "to enrol audio into the speaker's voiceprint — feeding a matcher's own "
            "guesses back into the profile it matched against drifts the profile "
            "toward whatever it got wrong."
        ),
    )


@router.patch(
    "/v1/conversations/{conversation_id}/segments/assign-bulk",
    response_model=ConversationResponse,
    tags=["developer-api-conversations"],
)
async def assign_segments_bulk(
    conversation_id: str,
    data: BulkAssignSegmentsRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Bulk assign speaker information to multiple transcript segments.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    value = data.value
    if value == 'null':
        value = None

    segments = conversation.get("transcript_segments", [])
    segment_map = {seg.get("id"): seg for seg in segments if seg.get("id")}

    for segment_id in data.segment_ids:
        if segment_id in segment_map:
            segment = segment_map[segment_id]
            if data.assign_type == 'is_user':
                segment["is_user"] = bool(value) if value is not None else False
                segment["person_id"] = None
            elif data.assign_type == 'person_id':
                segment["is_user"] = False
                segment["person_id"] = value
            else:
                raise HTTPException(status_code=400, detail="Invalid assign type")
            segment['speaker_assignment_source'] = data.source
            segment.pop('speaker_status', None)

    success = dev_db.update_conversation_segments_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        segments=segments,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Failed to update segments")

    mark_timeline_day_dirty(developer_id, external_user_id, conversation.get('started_at'), immediate=True)

    # Auto-collect speech samples from assigned segments in background.
    # `source` marks this as a human tag: only those may enrol into a voiceprint.
    threading.Thread(
        target=collect_speech_samples_developer,
        args=(developer_id, external_user_id, conversation, data.segment_ids, data.assign_type, value),
        kwargs={'source': data.source},
        daemon=True,
    ).start()

    return dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )


class UnresolvedSpeaker(BaseModel):
    speaker_id: int = Field(..., description="Diarization speaker index")
    segments: int = Field(..., description="How many segments this speaker holds")
    reason: str = Field(
        ...,
        description=(
            "'unknown' — nobody enrolled was close enough; ask who this was. "
            "'ambiguous' — two enrolled identities could not be separated; ask "
            "which of them it was."
        ),
    )


class IdentifySpeakersResponse(BaseModel):
    updated_segments: int = Field(..., description="Number of segments whose speaker changed")
    matched: bool = Field(..., description="Whether the voiceprint match produced any change")
    detail: Optional[str] = Field(None, description="Why nothing was matched, when applicable")
    # The question half of the confirmation loop. The answer half already exists
    # (PATCH assign-speaker), and an answer there enrols the audio as a voiceprint
    # sample, so every prompt the user resolves makes the next match better.
    unresolved: List[UnresolvedSpeaker] = Field(
        default_factory=list,
        description="Speakers voiceprint matching could not label, worth asking about",
    )


def _unresolved_speakers(segments: List[dict]) -> List[UnresolvedSpeaker]:
    """Group ``speaker_status`` marks into one entry per speaker.

    Segments carry the mark because segments are what get persisted, but the user
    is asked about a speaker, not about each of their sentences.
    """
    by_speaker: Dict[int, Dict[str, Any]] = {}
    for seg in segments:
        reason = seg.get("speaker_status")
        if not reason or seg.get("is_user") or seg.get("person_id"):
            continue
        try:
            sid = int(seg.get("speaker_id") or 0)
        except (TypeError, ValueError):
            continue
        entry = by_speaker.setdefault(sid, {"segments": 0, "reasons": {}})
        entry["segments"] += 1
        entry["reasons"][reason] = entry["reasons"].get(reason, 0) + 1
    out = []
    for sid, entry in sorted(by_speaker.items()):
        reason = max(entry["reasons"].items(), key=lambda kv: kv[1])[0]
        out.append(
            UnresolvedSpeaker(speaker_id=sid, segments=entry["segments"], reason=reason)
        )
    return out


@router.post(
    "/v1/conversations/{conversation_id}/identify-speakers",
    response_model=IdentifySpeakersResponse,
    tags=["developer-api-conversations"],
)
async def identify_conversation_speakers(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """Re-run voiceprint speaker identification on a stored conversation.

    Replaces the client-side flow where the app downloaded the recording and
    POSTed it to ``/v1/speaker-identification``. That could not be made correct
    from the client: the stored wav is VAD-trimmed while the app holds
    original-axis timestamps, and the app sends no diarization labels, so every
    segment collapsed into one speaker. Running it here reuses the same code path
    as automatic identification, which owns the timestamp remapping, the
    per-speaker vote and the enrolled-people comparison.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )
    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    audio_path = conversation.get("audio_path")
    if not audio_path:
        return IdentifySpeakersResponse(
            updated_segments=0, matched=False, detail="No recording stored for this conversation"
        )

    segments = conversation.get("transcript_segments", []) or []
    if not segments:
        return IdentifySpeakersResponse(updated_segments=0, matched=False, detail="No transcript segments")

    before = [(s.get("is_user"), s.get("person_id")) for s in segments]
    # Manual tags win over any model verdict, exactly as on the automatic path.
    protected_keys = {
        _speaker_key(seg) for seg in segments
        if seg.get('speaker_assignment_source') == 'manual' or (
            seg.get('speaker_assignment_source') != 'auto' and (seg.get("person_id") or seg.get("is_user")))
    }

    # The session id is embedded in the audio path the WS writer built
    # ({uid}/{session_id}.wav); it is what locates this session's VAD intervals.
    session_id = session_id_from_audio_path(audio_path)

    try:
        _, updated = await asyncio.to_thread(
            identify_developer_speakers,
            developer_id=developer_id,
            external_user_id=external_user_id,
            session_id=session_id,
            segments=segments,
            protected_speaker_keys=protected_keys,
            audio_wait_attempts=1,
            audio_gcs_path=audio_path,
            audio_kept_intervals=kept_intervals_hint(conversation),
        )
    except Exception as e:
        print(f"[SPEECH_PROFILE] Manual identification failed for {conversation_id}: {e}")
        raise HTTPException(status_code=502, detail="Speaker identification failed")

    unresolved = _unresolved_speakers(segments)

    if not updated:
        return IdentifySpeakersResponse(
            updated_segments=0,
            matched=False,
            detail="No speaker could be matched confidently",
            unresolved=unresolved,
        )

    dev_db.set_conversation_transcript_segments(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        segments=segments,
    )
    changed = sum(
        1
        for old, seg in zip(before, segments)
        if old != (seg.get("is_user"), seg.get("person_id"))
    )
    _revisit_user_dependent_verdicts(developer_id, external_user_id, conversation, segments)
    # `updated` can be true while `changed` is zero: recording why a speaker stayed
    # unresolved is itself a change worth persisting, but it moved no label.
    return IdentifySpeakersResponse(
        updated_segments=changed, matched=changed > 0, unresolved=unresolved
    )


@router.get("/v1/conversations/{conversation_id}/recording", response_model=dict, tags=["developer-api-conversations"])
async def conversation_has_audio_recording(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Check if a conversation has an associated audio recording.
    """
    has_recording = dev_db.check_conversation_recording_exists_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if has_recording is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return {"has_recording": has_recording}


@router.get("/v1/conversations/{conversation_id}/photos", response_model=List[dict], tags=["developer-api-conversations"])
async def get_conversation_photos(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get photos associated with a conversation.
    """
    photos = dev_db.get_conversation_photos_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if photos is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return photos


@router.get(
    "/v1/conversations/{conversation_id}/transcripts",
    response_model=Dict[str, List[dict]],
    tags=["developer-api-conversations"],
)
async def get_conversation_transcripts_by_models(
    conversation_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get transcripts organized by STT model (e.g., deepgram, soniox).
    """
    transcripts = dev_db.get_conversation_transcripts_by_model_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if transcripts is None:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return transcripts


@router.patch(
    "/v1/conversations/{conversation_id}/segments/{segment_idx}/assign",
    response_model=ConversationResponse,
    tags=["developer-api-conversations"],
)
async def set_assignee_conversation_segment(
    conversation_id: str,
    segment_idx: int,
    assign_type: str = Query(..., description="Type: 'is_user' or 'person_id'"),
    value: Optional[str] = Query(None, description="Value to assign"),
    external_user_id: str = Query(..., description="External user identifier"),
    source: str = Query('manual', description="'manual' (human-confirmed) or 'auto' (model verdict)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Assign speaker information to a single transcript segment by index.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    if value == 'null':
        value = None

    segments = conversation.get("transcript_segments", [])

    if segment_idx < 0 or segment_idx >= len(segments):
        raise HTTPException(status_code=400, detail="Invalid segment index")

    if assign_type == 'is_user':
        segments[segment_idx]["is_user"] = bool(value) if value is not None else False
        segments[segment_idx]["person_id"] = None
    elif assign_type == 'person_id':
        segments[segment_idx]["is_user"] = False
        segments[segment_idx]["person_id"] = value
    else:
        raise HTTPException(status_code=400, detail="Invalid assign type")

    segments[segment_idx]['speaker_assignment_source'] = source
    segments[segment_idx].pop('speaker_status', None)

    success = dev_db.update_conversation_segments_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        segments=segments,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Failed to update segment")

    mark_timeline_day_dirty(developer_id, external_user_id, conversation.get('started_at'), immediate=True)

    # Auto-collect speech sample from the assigned segment in background
    seg_id = segments[segment_idx].get("id")
    if seg_id:
        threading.Thread(
            target=collect_speech_samples_developer,
            args=(developer_id, external_user_id, conversation, [seg_id], assign_type, value),
            kwargs={'source': source},
            daemon=True,
        ).start()

    return dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )


@router.patch(
    "/v1/conversations/{conversation_id}/assign-speaker/{speaker_id}",
    response_model=ConversationResponse,
    tags=["developer-api-conversations"],
)
async def assign_speaker_to_segments(
    conversation_id: str,
    speaker_id: int,
    assign_type: str = Query(..., description="Type: 'is_user' or 'person_id'"),
    value: Optional[str] = Query(None, description="Value to assign"),
    external_user_id: str = Query(..., description="External user identifier"),
    source: str = Query('manual', description="'manual' (human-confirmed) or 'auto' (model verdict)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Assign speaker information to all segments with a given speaker_id.
    """
    conversation = dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )

    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    if value == 'null':
        value = None

    segments = conversation.get("transcript_segments", [])

    if assign_type == 'is_user':
        for segment in segments:
            if segment.get("speaker_id") == speaker_id:
                segment["is_user"] = bool(value) if value is not None else False
                segment["person_id"] = None
    elif assign_type == 'person_id':
        for segment in segments:
            if segment.get("speaker_id") == speaker_id:
                segment["is_user"] = False
                segment["person_id"] = value
    else:
        raise HTTPException(status_code=400, detail="Invalid assign type")

    for segment in segments:
        if segment.get('speaker_id') == speaker_id:
            segment['speaker_assignment_source'] = source
            segment.pop('speaker_status', None)

    success = dev_db.update_conversation_segments_dev(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        segments=segments,
    )

    if not success:
        raise HTTPException(status_code=404, detail="Failed to update segments")

    mark_timeline_day_dirty(developer_id, external_user_id, conversation.get('started_at'), immediate=True)

    # Auto-collect speech samples from all segments with this speaker_id in background
    assigned_ids = [s.get("id") for s in segments if s.get("speaker_id") == speaker_id and s.get("id")]
    if assigned_ids:
        threading.Thread(
            target=collect_speech_samples_developer,
            args=(developer_id, external_user_id, conversation, assigned_ids, assign_type, value),
            kwargs={'source': source},
            daemon=True,
        ).start()

    return dev_db.get_conversation(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
    )
