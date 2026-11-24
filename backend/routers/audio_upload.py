import math
import os
import re
import shutil
import struct
import subprocess
import uuid
from datetime import datetime, timezone, timedelta
from typing import Callable, Optional

import threading

from fastapi import APIRouter, UploadFile, File, Depends, HTTPException, Query
from opuslib import Decoder
from pydantic import BaseModel

# Global lock for opuslib ctypes calls — libopus is not thread-safe
_opus_lock = threading.Lock()
from utils.audio_upload_media import MAX_AUDIO_DURATION_SECONDS, TRANSCRIPTION_CHUNK_SECONDS, convert_to_wav_16k, validate_audio_file

import database.developer_data as developer_data_db
from database.redis_db import acquire_lock, release_lock
from models.conversation import (
    Conversation,
    ConversationSource,
    ConversationStatus,
    Structured,
)
from models.transcript_segment import TranscriptSegment
from utils.conversations.process_conversation import process_conversation_developer
from utils.other import endpoints as auth
from utils.other.storage import (
    upload_conversation_recording,
    get_conversation_audio_path,
)
from utils.stt.pre_recorded import soniox_transcribe_file
from utils.stt.vad import vad_is_empty_streaming as vad_is_empty
from utils.subscription import (
    MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR,
    commit_transcription_credits_developer,
    ensure_entitlement_for_use,
    release_transcription_credits_developer,
    reserve_transcription_credits_developer_result,
)

router = APIRouter()


class UploadAudioResponse(BaseModel):
    conversation_id: str
    status: str
    transcript_segments: list
    duration_seconds: float
    language: Optional[str] = None
    job_id: Optional[str] = None
    processing_status: Optional[str] = None


def _require_recording_started_at(started_at: Optional[str]) -> datetime:
    """The recording's start instant, or a 400. Never a `now()` default.

    Split out from the endpoint so it can be unit-tested without a multipart
    upload, an Opus decode and a Soniox transcription in the way.
    """
    if not started_at or not started_at.strip():
        raise HTTPException(
            status_code=400,
            detail="started_at is required: it is the time anchor for every transcript segment in "
                   "this recording, and defaulting it to the upload time would silently place the "
                   "recording at the wrong point on the user's timeline.",
        )
    try:
        parsed = datetime.fromisoformat(started_at.strip().replace('Z', '+00:00'))
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail=f"started_at is not a valid ISO-8601 timestamp: {started_at!r}",
        )
    if parsed.tzinfo is None:
        # A naive timestamp raises TypeError the moment it meets an aware one
        # downstream. Clients send `toUtc().toIso8601String()`, so reading a naive
        # value as UTC matches what they mean rather than guessing a local zone.
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _upload_lock_key(developer_id: str, uid: str, started_at: datetime) -> str:
    """One in-flight upload per recording. Milliseconds, to match the anchor's precision."""
    return f'upload_audio:{developer_id}:{uid}:{int(started_at.timestamp() * 1000)}'


def _existing_upload_response(developer_id: str, uid: str, conversation_id: str) -> Optional[UploadAudioResponse]:
    """Re-answer an earlier upload of the same recording from what's already stored.

    ⚠️ Goes through `get_conversation` rather than reading the doc directly:
    long conversations store `transcript_segments` zlib-compressed (inline or in a
    `transcript_chunks/` subcollection), so a raw read hands back **bytes** and the
    client would receive a plausible-looking response with a garbage transcript.
    """
    conv = developer_data_db.get_conversation(developer_id, uid, conversation_id, include_photos=False)
    if not conv:
        return None
    started, finished = conv.get('started_at'), conv.get('finished_at')
    duration = (finished - started).total_seconds() if started and finished else 0.0
    return UploadAudioResponse(
        conversation_id=conversation_id,
        status=conv.get('status') or 'completed',
        transcript_segments=conv.get('transcript_segments') or [],
        duration_seconds=duration,
        language=conv.get('language'),
    )


def _job_upload_response(job):
    # Legacy Watch/Soundcore versions understand only processing/completed here.
    # This acknowledges durable upload, not successful transcription. The audio
    # remains in GCS even after failure; new clients use processing_status/jobs.
    return UploadAudioResponse(
        conversation_id=job['conversation_id'], job_id=job['id'],
        status='completed' if job['status'] == 'completed' else 'processing',
        processing_status=job['status'], transcript_segments=[],
        duration_seconds=job.get('audio', {}).get('duration_seconds', job.get('duration_seconds', 0)),
    )


def _commit_sync_upload_usage(
    jobs,
    upload_job_id: str,
    upload_token: str,
    developer_id: str,
    uid: str,
    usage_event_id: str,
    duration_seconds: int,
    usage_occurred_at: datetime,
) -> None:
    """Fence stale cleanup and idempotently restore any racing refund."""
    from utils.audio_jobs.state import LeaseLost

    try:
        jobs.commit_upload_usage(upload_job_id, upload_token)
    except LeaseLost:
        # Cleanup already removed the placeholder; its refund may also have
        # committed. Provider work completed, so the event must be restored.
        pass
    # Always reassert the exactly-once event. If stale cleanup read the old job
    # immediately before commit_upload_usage, it can refund without conflicting
    # on that document; this idempotent write closes that narrow race too.
    commit_transcription_credits_developer(
        developer_id,
        uid,
        usage_event_id,
        duration_seconds,
        occurred_at=usage_occurred_at,
    )


def _convert_upload_audio(original_path, wav_path, *, max_duration=None):
    try:
        return convert_to_wav_16k(original_path, wav_path, max_duration=max_duration)
    except (subprocess.TimeoutExpired, OSError) as error:
        print(f'[upload-audio] media preparation unavailable type={type(error).__name__}')
        raise HTTPException(503, 'Audio preparation is temporarily unavailable. Keep the file and retry.') from error


def decode_opus_to_wav(opus_file_path: str, wav_file_path: str, sample_rate: int = 16000, channels: int = 1, frame_size: int = 160):
    """Decode Opus encoded audio file to WAV format."""
    with _opus_lock:
        decoder = Decoder(sample_rate, channels)
    with open(opus_file_path, 'rb') as f:
        pcm_data = []
        frame_count = 0
        while True:
            length_bytes = f.read(4)
            if not length_bytes:
                break
            if len(length_bytes) < 4:
                break

            frame_length = struct.unpack('<I', length_bytes)[0]
            opus_data = f.read(frame_length)
            if len(opus_data) < frame_length:
                break
            try:
                with _opus_lock:
                    pcm_frame = decoder.decode(opus_data, frame_size=frame_size)
                pcm_data.append(pcm_frame)
                frame_count += 1
            except Exception as e:
                print(f"Error decoding frame {frame_count}: {e}")
                break

        if pcm_data:
            import wave
            pcm_bytes = b''.join(pcm_data)
            with wave.open(wav_file_path, 'wb') as wav_file:
                wav_file.setnchannels(channels)
                wav_file.setsampwidth(2)  # 16-bit audio
                wav_file.setframerate(sample_rate)
                wav_file.writeframes(pcm_bytes)
            print(f"Decoded audio saved to {wav_file_path}")
            return True
        else:
            print("No PCM data was decoded.")
            return False


def _reject(uid: str, filename: str, size: int, reason: str) -> HTTPException:
    """记一笔再返回 400。

    ⚠️ **拒绝原因必须落日志。** 客户端把 400 当**永久**失败（`_isPermanentRejection`，
    正确 —— 重传一万次也是这个结果），文件因此被搬进 `rejected/` 再也不会重来，用户只看到
    「N 段无法转录」。而这里以前一行日志都不打：2026-08-14 那两段被拒的手表录音，事后只能
    从「那一版构建会产出缺 moov 的文件」去**推断**原因，无法证实。一条不可重来的路径必须
    留下痕迹。
    """
    print(f"[upload-audio] rejected uid={uid[:8]}…{uid[-4:]} file={filename} bytes={size}: {reason}")
    return HTTPException(status_code=400, detail=reason)


def _identify_speakers_then_revisit(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
    audio_gcs_path: str,
):
    """Background: voiceprint-match this upload's speakers, then re-open the
    verdicts that were decided while every segment still said ``is_user=False``.

    🚨 **Without this, an offline upload has no second chance.** The ordering
    problem is not unique to this path — `should_discard_conversation` and the
    action-item gate both read `is_user`, and both run before voiceprint matching
    anywhere. What made this path different is that `developer_listen` and
    `developer_conversations` each spawn exactly this pair afterwards (see
    `_identify_speakers_then_emit_eir`), so a wrong "the user never spoke" verdict
    gets re-opened, while `process_conversation_developer` spawns nothing. So on
    this path the verdict was **terminal**: 2026-08-15 discarded 11 of 13 watch
    uploads with empty titles, one of them a 39-minute family conversation, and
    discarding also skips memory extraction.

    ⚠️ **Deliberately not a call to `_identify_speakers_then_emit_eir`.** That one
    locates the audio by listen `session_id`, which an upload does not have — it is
    stored under the conversation id instead. It also emits the EIR event, which
    `process_conversation_developer` has already done by the time we get here.
    """
    try:
        from routers.developer_conversations import _revisit_user_dependent_verdicts
        from utils.stt.speech_profile import _speaker_key, identify_developer_speakers

        segments = conversation.get("transcript_segments") or []
        if not segments:
            return

        _, updated = identify_developer_speakers(
            developer_id=developer_id,
            external_user_id=external_user_id,
            # A label for the log lines, not a lookup key. The two places a session
            # id would otherwise be used are both covered by the arguments below:
            # where the audio lives (`audio_gcs_path`) and the VAD interval fallback
            # (`audio_kept_intervals`).
            session_id=f"upload:{conversation.get('id')}",
            segments=segments,
            audio_gcs_path=audio_gcs_path,
            # The wav in GCS is the full conversion — this path never VAD-trims it
            # (VAD is only consulted to reject silent uploads), so the transcript
            # timestamps are already on the audio's axis and need no remapping.
            # `[]` rather than `None` is what matters: `None` means "look it up on
            # the listen session", and there is no listen session.
            audio_kept_intervals=[],
            # Nothing to race with — the upload above has already finished, unlike
            # the live path where the wav lands only when the WebSocket closes.
            audio_wait_attempts=1,
            # Segments arrive straight from Soniox with no `person_id`, so this is
            # empty today. Kept so that a future client that tags speakers before
            # uploading doesn't have its manual assignments silently overwritten —
            # and built with `_speaker_key` rather than a local f-string, because a
            # key format that merely *looks* right protects nothing and says so
            # nowhere.
            protected_speaker_keys={
                _speaker_key(seg) for seg in segments if seg.get("person_id")
            },
        )
        if not updated:
            return

        developer_data_db.set_conversation_transcript_segments(
            developer_id=developer_id,
            external_user_id=external_user_id,
            conversation_id=conversation['id'],
            segments=segments,
        )
        _revisit_user_dependent_verdicts(
            developer_id, external_user_id, conversation, segments
        )
    except Exception as e:
        print(f"[SPEECH_PROFILE] upload speaker identification failed: {e}")


def _transcribe_and_finish(
    *,
    developer_id: str,
    uid: str,
    conversation_id: str,
    wav_path: str,
    filename: str,
    upload_size: int,
    language: str,
    duration: float,
    recording_started_at: datetime,
    save_recording: bool,
    auto_process: bool,
    use_vad: bool,
    audio_gcs_path: Optional[str],
    usage_event_id: str,
    release_usage_on_failure: bool,
    reservation_owner: str,
    commit_usage: Optional[Callable[[], None]] = None,
) -> UploadAudioResponse:
    """VAD → Soniox → conversation → LLM → voiceprint. The expensive tail.

    Used only by synchronous callers. Deferred uploads use utils.audio_jobs,
    which checkpoints each stage in durable storage.

    `audio_gcs_path` is already set in the deferred case (the audio must be durable
    *before* the client is told it may delete its only copy), so the upload below is
    skipped rather than repeated.
    """
    # Apply VAD to check if audio contains speech.
    #
    # ⚠️ **This is the single most expensive step before Soniox, and it is globally
    # serialized.** Silero runs under `_vad_lock` with `torch.set_num_threads(1)`
    # (PyTorch inference on one model instance is not thread-safe), so concurrent
    # uploads queue behind each other here. Measured 2026-08-16: **38s for a
    # 27-minute recording** — over half the endpoint's 69s p50, before Soniox has
    # even been called. That measurement is why the deferred split lands above this
    # line rather than below it.
    if use_vad:
        is_empty = vad_is_empty(wav_path)
        if is_empty:
            if release_usage_on_failure:
                release_transcription_credits_developer(
                    developer_id, uid, usage_event_id, reservation_owner=reservation_owner
                )
            raise _reject(
                uid,
                filename,
                upload_size,
                "Audio contains no detectable speech. Please upload an audio file with clear speech.",
            )

    # Transcribe with Soniox (stt-async-v5). It takes the local path directly, so
    # unlike the FAL path this used to run there is no intermediate GCS upload.
    #
    # `raise_on_error=True` is load-bearing: the default swallows every failure
    # into `([], "en")`, which would arrive here indistinguishable from "the audio
    # genuinely had no speech" and get reported as the latter — telling the user to
    # re-record audio that was fine. The batch path in `sync.py` wants the opposite
    # (one bad file must not fail 479 others), hence the flag rather than a change
    # of default.
    transcript_segments: list[TranscriptSegment]
    try:
        transcript_segments, detected_language = soniox_transcribe_file(
            wav_path, language=language, raise_on_error=True
        )
    except Exception as e:
        if release_usage_on_failure:
            release_transcription_credits_developer(
                developer_id, uid, usage_event_id, reservation_owner=reservation_owner
            )
        print(f"Soniox transcription failed: {e}")
        raise HTTPException(status_code=502, detail=f"Transcription service failed: {e}")

    if not transcript_segments:
        # Reached only when Soniox succeeded and returned nothing, so this really is
        # about the audio. VAD above already rejects fully silent uploads; this
        # catches audio with sound but no intelligible speech.
        if release_usage_on_failure:
            release_transcription_credits_developer(
                developer_id, uid, usage_event_id, reservation_owner=reservation_owner
            )
        raise _reject(
            uid,
            filename,
            upload_size,
            "No speech could be transcribed from this audio. Please upload a recording with clear speech.",
        )

    # From here the cloud transcription has been consumed. A process death in
    # later conversation/LLM work must not make stale-upload reconciliation
    # refund real provider usage.
    if commit_usage:
        commit_usage()

    # Calculate finished_at based on duration
    recording_finished_at = recording_started_at + timedelta(seconds=duration)

    # Create conversation with in_progress status first (consistent with real-time mode)
    conversation = Conversation(
        id=conversation_id,
        created_at=datetime.now(timezone.utc),
        started_at=recording_started_at,
        finished_at=recording_finished_at,
        source=ConversationSource.audio_upload,
        language=detected_language if detected_language else language,
        structured=Structured(title="", overview=""),
        transcript_segments=transcript_segments,
        # ⚠️ Carried over from the early park in the deferred case. This assignment
        # is why `audio_path` survives: `upsert_conversation_full` below is a bare
        # `set()` with no merge, so a path that lives only in Firestore would be
        # clobbered back to None here.
        audio_path=audio_gcs_path,
        status=ConversationStatus.in_progress,  # Start with in_progress (consistent with real-time)
    )

    developer_data_db.upsert_conversation_full(developer_id, uid, conversation.dict())
    # Park the audio in GCS *before* processing rather than after. Two reasons,
    # neither of them tidiness:
    #
    #   * **Speaker attribution needs it.** `identify_developer_speakers` fetches
    #     the wav from GCS, and the thread spawned below is this path's only
    #     chance to set `is_user` at all — cloud STT never sets it and there is no
    #     live session for the user to tag a speaker in. No audio in GCS ⇒ no
    #     `is_user` ⇒ the discard verdict and the action-item gate both run blind.
    #   * **Processing can still fail** (LLM error, timeout) and `temp_dir` is
    #     wiped by the caller. Uploading first means a failed run leaves
    #     recoverable audio rather than nothing: 2026-08-15 spent 42 minutes
    #     transcribing a recording that afterwards had no copy left anywhere.
    #
    # ⚠️ `conversation.audio_path` must be set on the in-memory model too — see the
    # note on the `audio_path=` argument above.
    if save_recording and not audio_gcs_path:
        try:
            upload_conversation_recording(wav_path, uid, conversation_id)
            # Store GCS path in Firestore (not signed URL - that's generated on-demand)
            audio_gcs_path = get_conversation_audio_path(uid, conversation_id)
            conversation.audio_path = audio_gcs_path
            developer_data_db.update_conversation_audio_path_dev(
                developer_id, uid, conversation_id, audio_gcs_path
            )
        except Exception as e:
            print(f"Failed to save recording to GCS: {e}")
            audio_gcs_path = None

    if auto_process:
        # Update status to processing (consistent with real-time mode)
        conversation.status = ConversationStatus.processing
        developer_data_db.update_conversation_status_dev(developer_id, uid, conversation_id, "processing")

        # Full processing with LLM - use appropriate processor based on auth type
        conversation = process_conversation_developer(
            developer_id, uid, detected_language or language, conversation
        )
        # process_conversation* updates status to completed internally

        # Voiceprint matching off the request path, then re-open the verdicts it
        # invalidates. This is the second half of the fix described in
        # `_identify_speakers_then_revisit` — the discard rules can only be told
        # "speaker attribution is unavailable here" (see
        # `should_discard_conversation`) because *something* eventually supplies
        # it. Without this thread that flag would just be a permanent excuse.
        if audio_gcs_path:
            threading.Thread(
                target=_identify_speakers_then_revisit,
                args=(developer_id, uid, conversation.dict(), audio_gcs_path),
            ).start()
    else:
        # Skip LLM processing, directly mark as completed
        conversation.status = ConversationStatus.completed
        developer_data_db.update_conversation_status_dev(developer_id, uid, conversation_id, "completed")

    return UploadAudioResponse(
        conversation_id=conversation_id,
        status="completed" if auto_process else "created",
        transcript_segments=[s.dict() for s in transcript_segments],
        duration_seconds=duration,
        language=detected_language,
    )


@router.post("/v1/conversations/upload-audio", tags=['conversations'])
def upload_audio_for_conversation(
    file: UploadFile = File(...),
    # ⚠️ **默认值只能是「不指定」那一类的值**（见 `_soniox_language_hints`）。这里曾经默认
    # `"multi"` —— 那是实时链路的 Soniox **模型名**，被当成语言 hint 发给离线 API 会让整次
    # 转录 400，于是**任何不显式传 language 的上传都必然失败**。现在两头都堵住了（默认值
    # 改对 + 下游认不出的值一律降级），留一头就还会被下一个调用方踩到。
    language: str = Query(default="auto", description="Language hint for transcription (ISO 639-1, or 'auto')"),
    started_at: Optional[str] = Query(default=None, description="Recording start timestamp (ISO format)"),
    # ⚠️ **This flag buys more than audio playback — it is the prerequisite for
    # `is_user`.** Speaker attribution downloads the recording from GCS, so with
    # `save_recording=false` nothing on this path can ever tell the wearer's voice
    # from anyone else's: the conversation gets no `is_user`, the summary is written
    # from a bystander's viewpoint, and the action-item gate clears every item.
    # Default stays `false` so third-party uploads don't silently start retaining
    # audio; the app passes `true` (see `watch_recording_service.dart`).
    save_recording: Optional[bool] = Query(
        default=False,
        description=(
            "Save original audio to cloud storage. Also enables voice-profile speaker "
            "identification, which needs to fetch the recording back."
        ),
    ),
    auto_process: bool = Query(default=True, description="Automatically process conversation after transcription"),
    use_vad: bool = Query(default=True, description="Use VAD to filter silence and validate audio has speech"),
    allow_short_recording: bool = Query(default=False, description="Accept nonempty short voice notes; speech validation still applies"),
    # ⚠️ **Opt-in, and it must stay opt-in.** `transcript_segments` / `language` in
    # the response are part of the public developer API; a caller that reads them
    # cannot be handed an empty list by default. The app's watch queue passes `true`
    # (`watch_recording_service.dart`), which is where the latency actually hurt:
    # uploads are serial and `syncNow` fires on every cold start and foreground, so
    # a queue of multi-minute uploads blocked the sync spinner for its whole length.
    #
    # 🚨 **Requires `save_recording=true`; otherwise it silently degrades to
    # synchronous.** Returning early tells the client it may delete its only copy,
    # so we must hold one that a re-run can start from. See utils.audio_jobs.
    defer_processing: bool = Query(
        default=False,
        description=(
            "Return as soon as the audio is validated and stored, then transcribe and "
            "summarize in the background. The response carries the conversation id but "
            "no transcript. Requires save_recording=true."
        ),
    ),
    recording_key: Optional[str] = Query(default=None, max_length=160),
    ctx: tuple = Depends(auth.get_current_user_context),
) -> UploadAudioResponse:
    """
    Upload an audio file for transcription and conversation creation.

    Supported formats:
    - WAV (any sample rate, will be converted to 16kHz)
    - Opus encoded binary files (.bin with length-prefixed frames)

    The audio will be:
    1. Validated for format and duration (5 seconds to 8 hours)
    2. Converted to 16kHz WAV if needed
    3. Processed with VAD to filter silence
    4. Transcribed using Soniox async (stt-async-v5)
    5. Converted to a conversation with transcript segments
    6. Optionally processed by LLM for summary generation

    With `defer_processing=true` the response is sent after step 2 and steps 3-6 run
    as durable tasks consumed by the independent audio worker. Recordings longer than
    2 hours require this mode and `save_recording=true`, so provider timeouts can
    resume from persisted chunk checkpoints instead of starting over.

    ⚠️ Sync `def` on purpose — see the note on
    `developer_conversations.process_conversation`. Steps 2-6 are all blocking
    (ffmpeg, Silero VAD, Soniox upload + poll, optional GCS upload, optional LLM),
    so `async def` ran a multi-minute pipeline on the event loop and stalled every
    other request on the same ECS task for its duration.

    Reading the upload stays legal here because it goes through `file.file` (the
    underlying spooled temp file) via `shutil.copyfileobj` — never
    `await file.read()`, which is what would force this back to `async def`.
    """
    developer_id, uid = ctx
    ensure_entitlement_for_use(developer_id, uid)

    # Validate the time anchor before anything expensive runs. `started_at` is the
    # sole anchor for every transcript segment in this conversation: segments store
    # only offsets (`start`/`end` relative to the recording), so the timeline layer
    # derives a segment's absolute time as `started_at + segment.start`.
    #
    # There is deliberately no `now()` fallback. Defaulting to the upload moment
    # silently relocates the whole recording to whenever the file happened to
    # arrive — for batch-synced audio that can be a day or more later. The failure
    # is invisible: the conversation looks fine on its own, and only the day's
    # timeline is wrong (recording lands on the wrong day, or glues itself to
    # unrelated recordings that really did happen at that hour).
    #
    # A 400 is the right answer because the caller always knows the recording time
    # (the app passes `_localAudioBuffer.startedAt`, set on the first captured
    # frame). Erroring is recoverable; a wrong anchor is not, because nothing
    # downstream can tell a defaulted timestamp from a real one.
    recording_started_at = _require_recording_started_at(started_at).astimezone(timezone.utc)

    durable = bool(defer_processing and save_recording)
    if defer_processing and not save_recording:
        print('[upload-audio] defer_processing requires save_recording; using synchronous processing')
    upload_token = None
    usage_reserved = False
    transcription_started = False
    from utils.audio_jobs.store import JobStore
    from utils.audio_jobs.state import identity, JobConflict, LeaseLost
    jobs = JobStore()
    job_id = identity(developer_id, uid, recording_started_at.isoformat(), recording_key)
    usage_event_id = f'audio-upload:{job_id}'
    # Synchronous requests retain their Redis concurrency contract. Their
    # Firestore document is only an invisible, process-death billing lease and
    # therefore has a unique id; deferred jobs keep the stable public id.
    upload_job_id = job_id if durable else str(uuid.uuid4())
    existing_job = jobs.get(job_id)
    if existing_job and existing_job.get('audio'):
        if durable:
            return _job_upload_response(existing_job)
        if existing_job['status'] == 'completed':
            existing_result = _existing_upload_response(developer_id, uid, existing_job['conversation_id'])
            if existing_result:
                return existing_result
        raise HTTPException(409, 'This recording already has a processing task. Check its status before retrying.')

    # Idempotency. `(uid, source, started_at)` identifies one recording exactly, so a
    # re-upload of a recording we already processed answers from storage instead of
    # transcribing it again.
    #
    # 🚨 **This is not an optimisation — without it a retry multiplies the recording.**
    # 2026-08-15: a 30-minute watch recording took longer than the (then 120s) request
    # cap, the client got a 504 and retried, and the abandoned request kept running to
    # completion and wrote its conversation anyway. Four attempts → four identical
    # conversations and four Soniox jobs off an account-level budget shared with the
    # live streaming path. The cap is fixed too (`main.py`'s `paths_timeout`), but a
    # cap alone only moves the threshold: any 504/timeout/network drop after the
    # transcription lands reproduces this, and the client is *right* to retry those.
    duplicate_id = developer_data_db.get_conversation_id_by_source_started_at(
        developer_id, uid, ConversationSource.audio_upload.value, recording_started_at
    )
    if duplicate_id:
        existing = _existing_upload_response(developer_id, uid, duplicate_id)
        if existing:
            print(
                f"[upload-audio] {uid}: started_at={recording_started_at.isoformat()} already "
                f"processed as {duplicate_id}, returning it without re-transcribing"
            )
            return existing

    # And the in-flight case, which the check above cannot see: the first attempt is
    # still transcribing, so no conversation exists yet. 409 rather than 200 because
    # nothing is stored yet and we must not let the client delete its only copy —
    # 409 is retryable on the client (`_isPermanentRejection` covers 400/413/415/422),
    # and by the next retry the holder will have finished and the check above answers.
    #
    # `acquire_lock` fails **open** on a Redis outage (returns True), so an outage
    # degrades to today's behaviour rather than 409-ing every upload forever.
    lock_key = _upload_lock_key(developer_id, uid, recording_started_at)
    if not durable and not acquire_lock(lock_key, ttl_seconds=15 * 60):
        print(f"[upload-audio] {uid}: started_at={recording_started_at.isoformat()} already in flight, 409")
        raise HTTPException(
            status_code=409,
            detail="This recording is already being transcribed. Keep the file and retry shortly.",
        )

    temp_dir = f'_temp/audio_upload/{uid}/{uuid.uuid4().hex}'
    os.makedirs(temp_dir, exist_ok=True)

    # Decided up front so a deferred response can name the conversation before the
    # document exists. Nothing is written under this id until transcription
    # succeeds — deliberately: a doc created here would sit on the user's home
    # timeline as an untitled empty card for the whole transcription window, and a
    # failed run would leave it there permanently.
    conversation_id = job_id if durable else str(uuid.uuid4())
    try:
        job, upload_token = jobs.reserve(upload_job_id, {
            'developer_id': developer_id, 'uid': uid, 'source': 'audio_upload',
            'started_at': recording_started_at.isoformat(), 'language': language,
            'duration_seconds': 0, 'auto_process': auto_process, 'use_vad': use_vad,
            'is_root': durable, 'usage_event_id': usage_event_id,
        })
    except JobConflict:
        if not durable:
            release_lock(lock_key)
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise HTTPException(409, 'Upload is already being received. Keep the file and retry.')
    except Exception:
        if not durable:
            release_lock(lock_key)
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise
    if upload_token is None:
        if not durable:
            release_lock(lock_key)
        shutil.rmtree(temp_dir, ignore_errors=True)
        return _job_upload_response(job)
    try:
        # Save uploaded file
        filename = file.filename or 'uploaded_audio'
        # Keep upload names as metadata; the input must never alias audio.wav.
        original_path = f'{temp_dir}/original'

        with open(original_path, 'wb') as f:
            shutil.copyfileobj(file.file, f)
        upload_size = os.path.getsize(original_path)
        print(f"[upload-audio] preparing media bytes={upload_size}", flush=True)

        # Determine file type and process accordingly
        wav_path = f'{temp_dir}/audio.wav'
        is_opus = filename.endswith('.bin') or filename.endswith('.opus')

        if is_opus:
            # Extract frame size from filename if present (e.g., audio_fs320_timestamp.bin)
            frame_size = 160  # Default frame size
            match = re.search(r'_fs(\d+)', filename)
            if match:
                try:
                    frame_size = int(match.group(1))
                except ValueError:
                    pass

            # Decode Opus to WAV
            if not decode_opus_to_wav(original_path, wav_path, frame_size=frame_size):
                raise _reject(uid, filename, upload_size, "Failed to decode Opus audio file")
        else:
            # Convert to standard WAV format
            if not _convert_upload_audio(
                original_path, wav_path,
                max_duration=MAX_AUDIO_DURATION_SECONDS if durable else TRANSCRIPTION_CHUNK_SECONDS,
            ):
                raise _reject(uid, filename, upload_size, "Failed to convert audio file to WAV format")

        # Validate audio
        # Long recordings must outlive the HTTP request and checkpoint each
        # provider chunk. Keep legacy synchronous callers at their existing cap.
        is_valid, error_msg, duration = validate_audio_file(
            wav_path, min_duration=0.1 if allow_short_recording else 5.0,
            max_duration=MAX_AUDIO_DURATION_SECONDS if durable else TRANSCRIPTION_CHUNK_SECONDS
        )
        if not is_valid:
            raise _reject(uid, filename, upload_size, error_msg)
        print(f"[upload-audio] media validated duration={duration:.2f}s bytes={upload_size}", flush=True)
        try:
            # Conversion/validation may consume most of the initial lease for a
            # large file. Renew before charging so a replacement request cannot
            # steal the fence between the usage transaction and accept/extend.
            jobs.extend_upload(upload_job_id, upload_token, 600)
        except LeaseLost:
            raise HTTPException(409, 'Upload ownership expired. Keep the file and retry.')
        # Tie billing ownership to the durable upload fence. The worker can
        # safely refund this reservation if this REST process disappears.
        reservation_owner = upload_token
        usage_occurred_at = datetime.now(timezone.utc)
        reservation = reserve_transcription_credits_developer_result(
            developer_id,
            uid,
            usage_event_id,
            math.ceil(duration),
            now=usage_occurred_at,
            reservation_owner=reservation_owner,
        )
        if not reservation.allowed:
            raise HTTPException(
                429,
                {
                    'code': reservation.error_code or MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR,
                    'message': 'Monthly cloud transcription allowance exceeded. Upgrade to Pro to continue.',
                },
            )
        # A duplicate may still belong to a concurrent request when Redis fails
        # open. Only a new reservation (including a transactionally reclaimed
        # stale one) may be released by this attempt.
        usage_reserved = reservation.newly_reserved

        # ── The synchronous/deferred boundary ────────────────────────────────────
        #
        # Everything above is cheap and its failures are *permanent* — the two the
        # watch has actually produced are an m4a with a missing/truncated `moov`
        # atom (ffmpeg: "Invalid data found when processing input") and a 557-byte
        # empty file from a denied mic permission. Both must stay a synchronous 400
        # even when processing is deferred: the client treats 400 as permanent
        # (`_isPermanentRejection`) and moves the file to `rejected/`, and that
        # verdict is the only way the user ever learns a recording can't be
        # transcribed. Measured cost of keeping them here: ffmpeg decodes a
        # 27-minute recording in ~1s (2026-08-16).
        #
        # Everything below is expensive and *retryable* — 38s of globally
        # serialized Silero VAD, a Soniox job that polls up to 300s, then the LLM.
        # That is what moves off the request.
        audio_gcs_path: Optional[str] = None
        if durable:
            from utils.audio_jobs.artifacts import Artifacts
            audio = Artifacts().put_audio(job_id, upload_token, wav_path)
            # One Firestore commit makes the audio receipt AND pending dispatch durable.
            job = jobs.accept(job_id, upload_token, {**audio, 'duration_seconds': duration})
            # Billing ownership moved to the durable worker with the same commit.
            # Response serialization must not refund a job that can already run.
            transcription_started = True
            return _job_upload_response(job)

        tail_kwargs = dict(
            developer_id=developer_id,
            wav_path=wav_path,
            filename=filename,
            upload_size=upload_size,
            language=language,
            duration=duration,
            recording_started_at=recording_started_at,
            save_recording=bool(save_recording),
            auto_process=auto_process,
            use_vad=use_vad,
            audio_gcs_path=audio_gcs_path,
            usage_event_id=usage_event_id,
            release_usage_on_failure=usage_reserved,
            reservation_owner=reservation_owner,
            commit_usage=lambda: _commit_sync_upload_usage(
                jobs,
                upload_job_id,
                upload_token,
                developer_id,
                uid,
                usage_event_id,
                math.ceil(duration),
                usage_occurred_at,
            ),
        )

        # The initial ten-minute lease protects validation. The synchronous
        # Soniox + LLM tail may legitimately run much longer for a two-hour file.
        try:
            jobs.extend_upload(upload_job_id, upload_token, 3 * 60 * 60)
        except LeaseLost:
            if usage_reserved:
                release_transcription_credits_developer(
                    developer_id,
                    uid,
                    usage_event_id,
                    reservation_owner=reservation_owner,
                )
                usage_reserved = False
            raise HTTPException(409, 'Upload ownership expired. Keep the file and retry.')
        transcription_started = True
        response = _transcribe_and_finish(uid=uid, conversation_id=conversation_id, **tail_kwargs)
        try:
            jobs.discard_upload(upload_job_id, upload_token)
        except Exception as cleanup_error:
            # The conversation and exactly-once charge are already durable.
            # Worker reconciliation can remove this committed placeholder.
            print(f"[upload-audio] completed placeholder cleanup deferred type={type(cleanup_error).__name__}")
        return response

    except HTTPException as error:
        if usage_reserved and not transcription_started:
            release_transcription_credits_developer(
                developer_id,
                uid,
                usage_event_id,
                reservation_owner=reservation_owner,
                upload_job_id=upload_job_id,
                upload_token=upload_token,
            )
        if durable and error.status_code in (400, 413, 415, 422):
            jobs.reject_upload(upload_job_id, upload_token)
        elif error.status_code == 429 or not durable:
            jobs.discard_upload(upload_job_id, upload_token)
        raise
    except Exception as e:
        if usage_reserved and not transcription_started:
            release_transcription_credits_developer(
                developer_id,
                uid,
                usage_event_id,
                reservation_owner=reservation_owner,
                upload_job_id=upload_job_id,
                upload_token=upload_token,
            )
        print(f"Error processing audio upload: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=f"Failed to process audio: {str(e)}")
    finally:
        try:
            if not durable:
                release_lock(lock_key)
        finally:
            try:
                # Expired placeholders are already due for worker cleanup. A
                # transient Firestore failure here must not replace a successful
                # upload response or retain the synchronous Redis lock.
                jobs.abandon_upload(upload_job_id, upload_token)
            except Exception as cleanup_error:
                print(f"[upload-audio] placeholder cleanup deferred type={type(cleanup_error).__name__}")
            finally:
                shutil.rmtree(temp_dir, ignore_errors=True)
