"""
Developer API - Speech Profile & Speaker Identification endpoints

Provides:
1. Speech Profile Management - Upload, retrieve, and delete user voice profiles
2. Speaker Identification - Identify speakers in audio segments using voice profiles

All data is tenant-isolated under:
gs://your-speech-profiles-bucket/developers/{developer_id}/users/{external_user_id}/
"""

import io
import json
import os
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile
from pydantic import BaseModel, Field
from pydub import AudioSegment

import database.developer_data as dev_db
import database.developer_speech_profile as speech_db
from dependencies import get_developer_id_from_api_key

router = APIRouter()

# Modal endpoint URL


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************

class SpeechProfileResponse(BaseModel):
    has_profile: bool
    profile_url: Optional[str] = None
    created_at: Optional[str] = None
    duration_seconds: Optional[float] = None
    samples_count: int = 0
    speech_samples_duration: float = 0.0


class SpeechProfileCreateResponse(BaseModel):
    status: str
    profile_url: str
    duration_seconds: float


class SampleResponse(BaseModel):
    sample_id: str
    sample_url: str
    created_at: Optional[str] = None
    duration_seconds: Optional[float] = None


class SampleCreateResponse(BaseModel):
    status: str
    sample_id: str
    sample_url: str
    duration_seconds: float


class TranscriptSegment(BaseModel):
    start: float = Field(..., description="Start time in seconds")
    end: float = Field(..., description="End time in seconds")
    text: str = Field(default="", description="Transcript text (optional)")


class SpeakerIdentificationResult(BaseModel):
    is_user: bool
    confidence: float = 0.0
    person_id: Optional[str] = None
    # Open-set outcome: 'user' | 'person' | 'unknown' | 'ambiguous'. Distinguishes
    # "this is not the user" from "nobody enrolled is close enough" and "two
    # identities are too close to separate", which a bare is_user=False hides.
    decision: Optional[str] = None


class SpeakerIdentificationResponse(BaseModel):
    results: List[SpeakerIdentificationResult]


# ******************************************************
# ****************** HELPER FUNCTIONS ******************
# ******************************************************

def validate_audio_file(file_bytes: bytes, filename: str) -> AudioSegment:
    """
    Validate and convert audio file to 16kHz mono WAV.

    Args:
        file_bytes: Raw file bytes
        filename: Original filename for format detection

    Returns:
        AudioSegment normalized to 16kHz mono

    Raises:
        HTTPException if validation fails
    """
    try:
        # Detect format from filename
        ext = filename.lower().split('.')[-1] if '.' in filename else 'wav'
        format_map = {
            'wav': 'wav',
            'mp3': 'mp3',
            'm4a': 'm4a',
            'ogg': 'ogg',
            'flac': 'flac',
            'webm': 'webm',
        }
        audio_format = format_map.get(ext, 'wav')

        # Load audio
        audio = AudioSegment.from_file(io.BytesIO(file_bytes), format=audio_format)

        # Normalize to 16kHz mono
        audio = audio.set_channels(1)
        audio = audio.set_frame_rate(16000)
        audio = audio.set_sample_width(2)  # 16-bit

        return audio

    except Exception as e:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid audio file: {str(e)}. Supported formats: WAV, MP3, M4A, OGG, FLAC"
        )


def audio_to_wav_bytes(audio: AudioSegment) -> bytes:
    """Convert AudioSegment to WAV bytes."""
    buffer = io.BytesIO()
    audio.export(buffer, format='wav')
    buffer.seek(0)
    return buffer.read()


# ******************************************************
# ****************** SPEECH PROFILE ENDPOINTS **********
# ******************************************************

@router.get(
    "/v1/speech-profiles",
    response_model=SpeechProfileResponse,
    tags=["developer-api-speech-profile"]
)
def get_speech_profile(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Check if a user has a speech profile and get its details.

    Returns profile information including URL, creation time, and sample count.

    Sync `def` on purpose — see the note on
    `developer_conversations.process_conversation`. The profile lives in GCS, so
    every read here is a blocking blob listing; `async def` put it on the event
    loop with nothing to yield to. The three handlers below are the same case.
    """
    profile = speech_db.get_developer_speech_profile(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    # Get accumulated auto-collected speech sample duration from user doc
    user_doc = dev_db.get_user_doc(developer_id, external_user_id)
    auto_duration = user_doc.get('speech_samples_duration', 0.0) if user_doc else 0.0

    if not profile:
        return SpeechProfileResponse(has_profile=False, speech_samples_duration=auto_duration)

    return SpeechProfileResponse(
        has_profile=True,
        profile_url=profile.get('profile_url'),
        created_at=profile.get('created_at'),
        duration_seconds=profile.get('duration_seconds'),
        samples_count=profile.get('samples_count', 0),
        speech_samples_duration=auto_duration,
    )


@router.post(
    "/v1/speech-profiles",
    response_model=SpeechProfileCreateResponse,
    status_code=201,
    tags=["developer-api-speech-profile"]
)
async def create_speech_profile(
    external_user_id: str = Query(..., description="External user identifier"),
    audio_file: UploadFile = File(..., description="Audio file (WAV, MP3, etc.) - 16kHz recommended"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Create or update a user's speech profile.

    Upload an audio sample of the user speaking to create their voice profile.
    The audio will be normalized to 16kHz mono WAV format.

    Recommended:
    - Duration: 10-60 seconds of clear speech
    - Single speaker (the user)
    - Minimal background noise

    If a profile already exists, it will be replaced.
    """
    # Read and validate audio
    file_bytes = await audio_file.read()
    if len(file_bytes) == 0:
        raise HTTPException(status_code=400, detail="Empty audio file")

    # Validate minimum file size (roughly 1 second of audio)
    if len(file_bytes) < 32000:
        raise HTTPException(status_code=400, detail="Audio file too short. Minimum 1 second required.")

    audio = validate_audio_file(file_bytes, audio_file.filename or 'audio.wav')

    # Validate duration (min 1 second, max 5 minutes)
    if audio.duration_seconds < 1:
        raise HTTPException(status_code=400, detail="Audio too short. Minimum 1 second required.")
    if audio.duration_seconds > 300:
        raise HTTPException(status_code=400, detail="Audio too long. Maximum 5 minutes allowed.")

    # Convert to WAV bytes
    wav_bytes = audio_to_wav_bytes(audio)

    # Upload to GCS
    result = speech_db.upload_developer_speech_profile(
        developer_id=developer_id,
        external_user_id=external_user_id,
        audio_bytes=wav_bytes,
    )

    return SpeechProfileCreateResponse(
        status="success",
        profile_url=result['profile_url'],
        duration_seconds=result['duration_seconds'],
    )


@router.delete(
    "/v1/speech-profiles",
    status_code=204,
    tags=["developer-api-speech-profile"]
)
def delete_speech_profile(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a user's speech profile and all associated samples.

    This action is irreversible. All speaker identification will stop working
    for this user until a new profile is created.

    Sync `def` on purpose — see `get_speech_profile` above.
    """
    deleted = speech_db.delete_developer_speech_profile(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    if not deleted:
        raise HTTPException(status_code=404, detail="Speech profile not found")

    return


# ******************************************************
# ****************** SAMPLE ENDPOINTS ******************
# ******************************************************

@router.get(
    "/v1/speech-profiles/samples",
    response_model=List[SampleResponse],
    tags=["developer-api-speech-profile"]
)
def list_samples(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    List additional speech samples for a user.

    Additional samples improve speaker identification accuracy.

    Sync `def` on purpose — see `get_speech_profile` above.
    """
    # Check if profile exists first
    if not speech_db.developer_has_speech_profile(developer_id, external_user_id):
        raise HTTPException(
            status_code=404,
            detail="Speech profile not found. Create a profile first before adding samples."
        )

    samples = speech_db.list_developer_samples(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    return [
        SampleResponse(
            sample_id=s['sample_id'],
            sample_url=s['sample_url'],
            created_at=s.get('created_at'),
        )
        for s in samples
    ]


@router.post(
    "/v1/speech-profiles/samples",
    response_model=SampleCreateResponse,
    status_code=201,
    tags=["developer-api-speech-profile"]
)
async def upload_sample(
    external_user_id: str = Query(..., description="External user identifier"),
    audio_file: UploadFile = File(..., description="Audio file (WAV, MP3, etc.)"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Upload an additional speech sample to improve speaker identification.

    Requirements:
    - A speech profile must exist first
    - Audio will be normalized to 16kHz mono WAV

    Additional samples help improve identification accuracy, especially in
    different acoustic environments or with varying speech patterns.
    """
    # Check if profile exists
    if not speech_db.developer_has_speech_profile(developer_id, external_user_id):
        raise HTTPException(
            status_code=400,
            detail="Speech profile not found. Create a profile first before adding samples."
        )

    # Read and validate audio
    file_bytes = await audio_file.read()
    if len(file_bytes) == 0:
        raise HTTPException(status_code=400, detail="Empty audio file")

    audio = validate_audio_file(file_bytes, audio_file.filename or 'audio.wav')

    # Validate duration
    if audio.duration_seconds < 1:
        raise HTTPException(status_code=400, detail="Audio too short. Minimum 1 second required.")
    if audio.duration_seconds > 120:
        raise HTTPException(status_code=400, detail="Sample too long. Maximum 2 minutes allowed.")

    # Convert to WAV bytes
    wav_bytes = audio_to_wav_bytes(audio)

    # Upload to GCS. Stamped as an explicit upload rather than left blank: a
    # sample with no provenance is indistinguishable from the pre-provenance
    # legacy ones, and this one is deliberately NOT revokable by cancelling a
    # transcript tag — the caller supplied the audio directly, so no speaker mark
    # is what justified it.
    result = speech_db.upload_developer_sample(
        developer_id=developer_id,
        external_user_id=external_user_id,
        audio_bytes=wav_bytes,
        metadata=speech_db.sample_provenance(
            source='upload',
            assign_type='is_user',
            target_id='user',
            conversation_id='',
            segment_ids=[],
            duration_seconds=audio.duration_seconds,
        ),
    )

    return SampleCreateResponse(
        status="success",
        sample_id=result['sample_id'],
        sample_url=result['sample_url'],
        duration_seconds=result['duration_seconds'],
    )


@router.delete(
    "/v1/speech-profiles/samples/{sample_id}",
    status_code=204,
    tags=["developer-api-speech-profile"]
)
def delete_sample(
    sample_id: str,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Delete a specific speech sample.

    Sync `def` on purpose — see `get_speech_profile` above.
    """
    deleted = speech_db.delete_developer_sample(
        developer_id=developer_id,
        external_user_id=external_user_id,
        sample_id=sample_id,
    )

    if not deleted:
        raise HTTPException(status_code=404, detail="Sample not found")

    return


# ******************************************************
# ************** SPEAKER IDENTIFICATION ****************
# ******************************************************

@router.post(
    "/v1/speaker-identification",
    response_model=SpeakerIdentificationResponse,
    tags=["developer-api-speech-profile"]
)
async def identify_speaker(
    external_user_id: str = Query(..., description="External user identifier"),
    audio_file: UploadFile = File(..., description="Audio file to analyze"),
    segments: str = Form(..., description="JSON array of transcript segments [{start, end, text}, ...]"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Identify which segments in an audio file were spoken by the user.

    DEPRECATED — use ``POST /v1/conversations/{id}/identify-speakers`` for stored
    conversations. This endpoint takes audio and timestamps from the client, and
    that framing cannot be made accurate:

    * Its results are per-segment. A 2-second segment is far too little audio for
      a reliable embedding; the accurate unit is all of one speaker's audio in the
      conversation pooled together, which requires diarization labels this
      endpoint's schema has no field for.
    * Clients hold original-axis timestamps while the stored recording is
      VAD-trimmed, so slicing the audio by those timestamps reads the wrong
      speaker's voice — the same misalignment that was fixed server-side.

    Kept for API compatibility. It now also reports each segment's open-set
    ``decision``, so a caller can tell "not the user" from "could not tell".
    """
    # Check if user has a speech profile
    if not speech_db.developer_has_speech_profile(developer_id, external_user_id):
        raise HTTPException(
            status_code=400,
            detail="No speech profile found. Create a profile first to use speaker identification."
        )

    # Parse segments
    try:
        segments_data = json.loads(segments)
        if not isinstance(segments_data, list):
            raise ValueError("segments must be a JSON array")
        transcript_segments = [TranscriptSegment(**s) for s in segments_data]
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON in segments: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid segments format: {str(e)}")

    if len(transcript_segments) == 0:
        return SpeakerIdentificationResponse(results=[])

    # Read and validate audio
    file_bytes = await audio_file.read()
    if len(file_bytes) == 0:
        raise HTTPException(status_code=400, detail="Empty audio file")

    audio = validate_audio_file(file_bytes, audio_file.filename or 'audio.wav')

    # Convert to WAV bytes for Modal
    wav_bytes = audio_to_wav_bytes(audio)

    # Download the speech profile for processing
    profile_path = speech_db.download_developer_profile_for_identification(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    if not profile_path:
        raise HTTPException(status_code=500, detail="Failed to load speech profile")

    try:
        # Call Modal endpoint for GPU-accelerated processing
        results = await _call_modal_endpoint_with_profile(
            audio_bytes=wav_bytes,
            profile_path=profile_path,
            segments=transcript_segments,
        )
        return SpeakerIdentificationResponse(results=results)

    except Exception as e:
        print(f"Speaker identification via Modal error: {e}")
        # Fallback to local processing if Modal fails
        print("Falling back to local processing...")
        try:
            results = _process_speaker_identification_local(
                audio_bytes=wav_bytes,
                profile_path=profile_path,
                segments=transcript_segments,
            )
            return SpeakerIdentificationResponse(results=results)
        except Exception as local_e:
            print(f"Local processing also failed: {local_e}")
            return SpeakerIdentificationResponse(
                results=[
                    SpeakerIdentificationResult(is_user=False, confidence=0.0)
                    for _ in transcript_segments
                ]
            )
    finally:
        # Clean up temp file
        if profile_path and os.path.exists(profile_path):
            os.remove(profile_path)


def _process_speaker_identification_local(
    audio_bytes: bytes,
    profile_path: str,
    segments: List[TranscriptSegment],
) -> List[SpeakerIdentificationResult]:
    """
    Process speaker identification locally using SpeechBrain.

    This mirrors the logic in speech_profile_modal.py but runs locally.
    For production, consider calling the Modal endpoint instead.
    """
    import tempfile
    import torch
    from speechbrain.inference.speaker import SpeakerRecognition

    # Load model (cached after first load)
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    model = SpeakerRecognition.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir="pretrained_models/spkrec-ecapa-voxceleb",
        run_opts={"device": device},
    )

    results = []

    # Save audio to temp file
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
        f.write(audio_bytes)
        audio_path = f.name

    try:
        audio = AudioSegment.from_wav(audio_path)

        for segment in segments:
            # Extract segment audio
            start_ms = int(segment.start * 1000)
            end_ms = int(segment.end * 1000)

            if end_ms <= start_ms or start_ms >= len(audio):
                results.append(SpeakerIdentificationResult(is_user=False, confidence=0.0))
                continue

            segment_audio = audio[start_ms:end_ms]

            # Skip very short segments
            if segment_audio.duration_seconds < 0.5:
                results.append(SpeakerIdentificationResult(is_user=False, confidence=0.0))
                continue

            # Save segment to temp file
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as seg_f:
                segment_audio.export(seg_f.name, format='wav')
                segment_path = seg_f.name

            try:
                # Compare with profile
                score, prediction = model.verify_files(profile_path, segment_path)
                confidence = float(score[0]) if bool(prediction[0]) else 0.0

                results.append(SpeakerIdentificationResult(
                    is_user=bool(prediction[0]),
                    confidence=confidence,
                ))
            except Exception as e:
                print(f"Segment comparison error: {e}")
                results.append(SpeakerIdentificationResult(is_user=False, confidence=0.0))
            finally:
                os.remove(segment_path)

    finally:
        os.remove(audio_path)

    return results


async def _call_modal_endpoint_with_profile(
    audio_bytes: bytes,
    profile_path: str,
    segments: List[TranscriptSegment],
) -> List[SpeakerIdentificationResult]:
    """
    Call the Modal endpoint with uploaded profile file.
    Used for Developer API where profiles are stored differently.
    """
    import httpx
    from utils.stt.speech_profile import speech_profile_service_headers

    # Read profile file
    with open(profile_path, 'rb') as f:
        profile_bytes = f.read()

    # Same hosted model the server-side path uses. Falling back to a different
    # model here (the old English-only ECAPA app) meant one user got two verdicts
    # from two models at two thresholds depending on which path ran.
    endpoint_url = (
        os.getenv('MODAL_SPEECH_PROFILE_WITH_UPLOAD_URL')
        or os.getenv('HOSTED_SPEECH_PROFILE_API_URL')
    )

    if not endpoint_url:
        raise RuntimeError('Hosted speech profile URL is missing')
    headers = speech_profile_service_headers()
    async with httpx.AsyncClient(timeout=120.0) as client:
        files = {
            'audio_file': ('audio.wav', audio_bytes, 'audio/wav'),
            'profile_file': ('profile.wav', profile_bytes, 'audio/wav'),
        }
        data = {
            'segments': json.dumps([s.dict() for s in segments]),
        }

        print(f"[Modal] Classifying {len(segments)} segments")
        response = await client.post(
            endpoint_url,
            files=files,
            data=data,
            headers=headers,
        )

        if response.status_code != 200:
            raise Exception(f"Modal endpoint error: {response.status_code}")

        results = response.json()
        print(f"[Modal] Got {len(results)} results")
        return [
            SpeakerIdentificationResult(
                is_user=r.get('is_user', False),
                confidence=r.get('confidence', 0.0) if r.get('is_user') else 0.0,
                person_id=r.get('person_id'),
                decision=r.get('decision'),
            )
            for r in results
        ]
