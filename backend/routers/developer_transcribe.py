"""
Developer API - Transcribe endpoints (Offline Audio Transcription)

Provides offline speech-to-text functionality:
- Audio file upload transcription
- Async task status tracking
"""

import asyncio
import math
import os
import shutil
import tempfile
import uuid
from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, HTTPException, Query, Request, UploadFile, File
from pydantic import BaseModel, Field
from pydub import AudioSegment

import database.developer_data as dev_db
from dependencies import require_developer_for_external_user
from utils.stt.pre_recorded import soniox_transcribe_file
from utils.stt.vad import vad_is_empty
from utils.logging.context import ensure_billing_context
from utils.subscription import (
    MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR,
    ensure_entitlement_for_use,
    release_transcription_credits_developer,
    reserve_transcription_credits_developer_result,
)

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


class TranscriptionTaskResponse(BaseModel):
    id: str
    status: str  # pending, processing, completed, failed, cancelled
    language: str
    transcript_segments: List[TranscriptSegment]
    duration_seconds: float
    error: Optional[str]
    created_at: datetime
    updated_at: datetime


class AudioUploadResponse(BaseModel):
    task_id: str
    status: str
    transcript_segments: List[TranscriptSegment]
    duration_seconds: float
    language: Optional[str] = None


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************


def validate_audio_file(file_path: str, min_duration: float = 1.0, max_duration: float = 7200.0) -> tuple:
    """
    Validate audio file format and duration.
    Returns (is_valid, error_message, duration_seconds)
    """
    try:
        aseg = AudioSegment.from_file(file_path)
        duration = aseg.duration_seconds

        if duration < min_duration:
            return False, f"Audio too short ({duration:.1f}s). Minimum is {min_duration}s", duration

        if duration > max_duration:
            return False, f"Audio too long ({duration:.1f}s). Maximum is {max_duration}s", duration

        return True, None, duration
    except Exception as e:
        return False, f"Invalid audio file: {str(e)}", 0.0


async def process_audio_file(
    file_path: str,
    language: str,
    developer_id: str,
    external_user_id: str,
    task_id: str,
    has_speech: Optional[bool] = None,
) -> Dict[str, Any]:
    """Process audio file using Soniox Async API and return transcription results."""
    try:
        # Update task status to processing
        dev_db.update_transcription_task(
            developer_id=developer_id,
            external_user_id=external_user_id,
            task_id=task_id,
            status="processing",
        )

        # Get audio duration
        aseg = AudioSegment.from_file(file_path)
        duration = aseg.duration_seconds

        # Check if audio is empty (silence)
        if has_speech is False or (has_speech is None and vad_is_empty(file_path)):
            dev_db.update_transcription_task(
                developer_id=developer_id,
                external_user_id=external_user_id,
                task_id=task_id,
                status="completed",
                transcript_segments=[],
                duration_seconds=duration,
            )
            return {
                "task_id": task_id,
                "status": "completed",
                "transcript_segments": [],
                "duration_seconds": duration,
                "language": language,
            }

        # Transcribe using shared Soniox function
        transcript_segments, detected_language = soniox_transcribe_file(file_path, language)

        if not transcript_segments:
            raise Exception("Soniox transcription returned no segments")

        # Update task with results
        segments_dicts = [
            {"text": s.text, "start": s.start, "end": s.end,
             "speaker": s.speaker, "is_user": s.is_user}
            for s in transcript_segments
        ]
        dev_db.update_transcription_task(
            developer_id=developer_id,
            external_user_id=external_user_id,
            task_id=task_id,
            status="completed",
            transcript_segments=segments_dicts,
            duration_seconds=duration,
        )

        return {
            "task_id": task_id,
            "status": "completed",
            "transcript_segments": segments_dicts,
            "duration_seconds": duration,
            "language": detected_language,
        }

    except Exception as e:
        print(f"[soniox-async] Error: {e}")
        dev_db.update_transcription_task(
            developer_id=developer_id,
            external_user_id=external_user_id,
            task_id=task_id,
            status="failed",
            error=str(e),
        )
        return {
            "task_id": task_id,
            "status": "failed",
            "transcript_segments": [],
            "duration_seconds": 0.0,
            "error": str(e),
        }


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.post("/v1/transcribe/audio", response_model=AudioUploadResponse, tags=["developer-api-transcribe"])
async def upload_audio(
    request: Request,
    file: UploadFile = File(..., description="Audio file (WAV, MP3, M4A, OGG, FLAC)"),
    external_user_id: str = Query(..., description="External user identifier"),
    language: str = Query(default="auto", description="Language code (e.g., 'en', 'zh', 'auto' for detection)"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    Upload an audio file for offline transcription.

    Supported formats: WAV, MP3, M4A, OGG, FLAC
    Max file size: 100MB
    Duration: 1 second to 2 hours

    Returns transcription results synchronously.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)
    await asyncio.to_thread(ensure_entitlement_for_use, developer_id, external_user_id)

    # Validate file size (100MB max)
    max_size = 100 * 1024 * 1024
    file_content = await file.read()
    if len(file_content) > max_size:
        raise HTTPException(status_code=400, detail=f"File too large. Maximum is 100MB")

    # Save to temp file
    temp_dir = tempfile.mkdtemp()
    reservation = None
    usage_event_id = None
    reservation_owner = None
    transcription_completed = False
    try:
        # Get file extension
        ext = os.path.splitext(file.filename)[1] if file.filename else ".wav"
        temp_path = os.path.join(temp_dir, f"audio{ext}")

        with open(temp_path, "wb") as f:
            f.write(file_content)

        # Validate audio
        is_valid, error_msg, duration = validate_audio_file(temp_path)
        if not is_valid:
            raise HTTPException(status_code=400, detail=error_msg)
        # Create task
        task = await asyncio.to_thread(
            dev_db.create_transcription_task,
            developer_id,
            external_user_id,
            language,
        )

        # Silence is completed locally without spending or reserving cloud
        # transcription allowance. Pass the result through so VAD runs once.
        has_speech = not await asyncio.to_thread(vad_is_empty, temp_path)
        if has_speech:
            usage_event_id = f"developer-transcribe:{task['id']}"
            reservation_owner = uuid.uuid4().hex
            reservation = await asyncio.to_thread(
                reserve_transcription_credits_developer_result,
                developer_id,
                external_user_id,
                usage_event_id,
                math.ceil(duration),
                reservation_owner=reservation_owner,
            )
        if reservation is not None and not reservation.allowed:
            await asyncio.to_thread(
                dev_db.update_transcription_task,
                developer_id,
                external_user_id,
                task['id'],
                'failed',
                error='monthly_cloud_transcription_allowance_exceeded',
            )
            raise HTTPException(
                status_code=429,
                detail={
                    'code': reservation.error_code or MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR,
                    'message': 'Monthly cloud transcription allowance exceeded. Upgrade to Pro to continue.',
                },
            )

        # Process audio
        result = await process_audio_file(
            file_path=temp_path,
            language=language,
            developer_id=developer_id,
            external_user_id=external_user_id,
            task_id=task["id"],
            has_speech=has_speech,
        )

        if result["status"] == "failed":
            raise HTTPException(status_code=500, detail=result.get("error", "Transcription failed"))
        transcription_completed = True

        # Set billing context for API logging
        billing_context = ensure_billing_context(request)
        billing_context.set_stt_usage(result["duration_seconds"], is_realtime=False)
        billing_context.external_user_id = external_user_id

        return AudioUploadResponse(
            task_id=result["task_id"],
            status=result["status"],
            transcript_segments=[TranscriptSegment(**s) for s in result["transcript_segments"]],
            duration_seconds=result["duration_seconds"],
            language=result.get("language"),
        )

    finally:
        if (
            reservation is not None
            and reservation.newly_reserved
            and not transcription_completed
            and usage_event_id is not None
        ):
            await asyncio.to_thread(
                release_transcription_credits_developer,
                developer_id,
                external_user_id,
                usage_event_id,
                reservation_owner=reservation_owner,
            )
        # Cleanup temp files
        shutil.rmtree(temp_dir, ignore_errors=True)


@router.get("/v1/transcribe/{task_id}", response_model=TranscriptionTaskResponse, tags=["developer-api-transcribe"])
async def get_transcription_task(
    task_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    Get the status and results of a transcription task.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    task = dev_db.get_transcription_task(
        developer_id=developer_id,
        external_user_id=external_user_id,
        task_id=task_id,
    )

    if not task:
        raise HTTPException(status_code=404, detail="Transcription task not found")

    return TranscriptionTaskResponse(
        id=task["id"],
        status=task["status"],
        language=task["language"],
        transcript_segments=[TranscriptSegment(**s) for s in task.get("transcript_segments", [])],
        duration_seconds=task.get("duration_seconds", 0.0),
        error=task.get("error"),
        created_at=task["created_at"],
        updated_at=task["updated_at"],
    )


@router.get("/v1/transcribe", tags=["developer-api-transcribe"])
async def list_transcription_tasks(
    external_user_id: str = Query(..., description="External user identifier"),
    limit: int = Query(default=50, ge=1, le=100, description="Maximum tasks to return"),
    offset: int = Query(default=0, ge=0, description="Number to skip"),
    api_key: str = Query(..., alias="api_key", description="Developer API key"),
):
    """
    List transcription tasks for a user.
    """
    # Authenticate (enforces user-bound keys -> 403 on mismatch)
    developer_id = require_developer_for_external_user(api_key, external_user_id)

    tasks = dev_db.get_transcription_tasks(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=limit,
        offset=offset,
    )

    return [
        {
            "id": t["id"],
            "status": t["status"],
            "language": t["language"],
            "duration_seconds": t.get("duration_seconds", 0.0),
            "created_at": t["created_at"].isoformat() if hasattr(t["created_at"], 'isoformat') else t["created_at"],
        }
        for t in tasks
    ]
