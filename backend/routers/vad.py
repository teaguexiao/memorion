"""
VAD (Voice Activity Detection) Router

Provides HTTP endpoints for detecting speech segments in audio files.
Uses Silero VAD model (shared with utils/stt/vad.py).
"""

import os
import uuid
from typing import List

from fastapi import APIRouter, UploadFile, File, HTTPException
from pydantic import BaseModel

# Import from shared VAD module (model is loaded once at module level)
from utils.stt.vad import get_speech_segments

router = APIRouter()


class VadSegment(BaseModel):
    start: float
    end: float
    duration: float


class VadResponse(BaseModel):
    segments: List[VadSegment]
    has_speech: bool
    total_speech_duration: float


@router.post("/v1/vad", tags=['vad'], response_model=List[VadSegment])
async def detect_voice_activity(file: UploadFile = File(...)) -> List[VadSegment]:
    """
    Detect voice activity segments in an audio file.

    Returns a list of segments where speech was detected.
    Each segment contains start time, end time, and duration in seconds.

    Supported formats: WAV (16kHz recommended)
    """
    temp_dir = '_temp/vad'
    os.makedirs(temp_dir, exist_ok=True)

    upload_id = str(uuid.uuid4())
    file_path = f"{temp_dir}/{upload_id}_{file.filename}"

    try:
        # Save uploaded file
        with open(file_path, 'wb') as f:
            content = await file.read()
            f.write(content)

        # Run Silero VAD (uses shared model from utils/stt/vad.py)
        segments = get_speech_segments(file_path)

        # Build response
        result = [
            VadSegment(start=s['start'], end=s['end'], duration=s['duration'])
            for s in segments
        ]

        return result

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"VAD processing failed: {str(e)}")
    finally:
        # Cleanup temp file
        if os.path.exists(file_path):
            try:
                os.remove(file_path)
            except Exception:
                pass


@router.post("/v1/vad/check", tags=['vad'], response_model=VadResponse)
async def check_voice_activity(file: UploadFile = File(...)) -> VadResponse:
    """
    Check if audio file contains speech and return detailed analysis.

    Returns segments, whether speech was found, and total speech duration.
    """
    segments = await detect_voice_activity(file)

    total_duration = sum(s.duration for s in segments)

    return VadResponse(
        segments=segments,
        has_speech=len(segments) > 0,
        total_speech_duration=total_duration,
    )
