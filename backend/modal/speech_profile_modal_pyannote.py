"""
Enhanced speech profile modal using Pyannote.audio 3.x for improved accuracy.

Key improvements:
1. Pyannote's wespeaker-voxceleb-resnet34-LM model (better than ECAPA-TDNN)
2. Proper embedding extraction and comparison
3. Better Chinese/multilingual support
4. Industry-standard speaker verification pipeline
"""
import hmac
import json
import shutil
import tempfile
import os
from collections import defaultdict
from typing import List, Optional

from fastapi import Depends, File, Form, Header, HTTPException, UploadFile
from modal import App, fastapi_endpoint, Secret, Image, concurrent
from pydantic import BaseModel

from models.transcript_segment import TranscriptSegment


def require_speech_profile_service(x_speech_profile_token: str = Header(default="")):
    secret = os.getenv("SPEECH_PROFILE_SERVICE_TOKEN")
    if not secret:
        raise HTTPException(status_code=503, detail="Speech profile service is not configured")
    if not hmac.compare_digest(x_speech_profile_token.encode(), secret.encode()):
        raise HTTPException(status_code=401, detail="Invalid speech profile service credentials")


class ResponseItem(BaseModel):
    is_user: bool
    confidence: float = 0.0
    person_id: Optional[str] = None


# Heavy imports and model loading deferred to container startup
model = None
AudioSegment = None


def _init():
    """Initialize Pyannote model."""
    global model, AudioSegment
    if model is not None:
        return

    os.environ['PYTORCH_CUDA_ALLOC_CONF'] = 'expandable_segments:True'
    import torch
    from pydub import AudioSegment as _AudioSegment
    from pyannote.audio import Model, Inference

    AudioSegment = _AudioSegment
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

    # Use Pyannote's wespeaker-voxceleb-resnet34-LM
    # This model has better multilingual support and higher accuracy
    pretrained_model = Model.from_pretrained(
        "pyannote/wespeaker-voxceleb-resnet34-LM",
        use_auth_token=os.getenv('HUGGINGFACE_TOKEN')
    )

    model = Inference(pretrained_model, window="whole", device=device)
    print(f"Loaded Pyannote wespeaker model on {device}")


# Storage functions (same as original)
def _get_storage_client():
    """Get GCS storage client"""
    from google.cloud import storage
    from google.oauth2 import service_account
    if os.environ.get('SERVICE_ACCOUNT_JSON'):
        service_account_info = json.loads(os.environ["SERVICE_ACCOUNT_JSON"])
        credentials = service_account.Credentials.from_service_account_info(service_account_info)
        return storage.Client(credentials=credentials)
    return storage.Client()


def get_profile_audio_if_exists(uid: str, directory: str) -> str:
    """Download user's main speech profile"""
    client = _get_storage_client()
    bucket = client.bucket(os.getenv('BUCKET_SPEECH_PROFILES'))
    path = f'{uid}/speech_profile.wav'
    blob = bucket.blob(path)
    if blob.exists():
        file_path = os.path.join(directory, 'profile.wav')
        blob.download_to_filename(file_path)
        return file_path
    return None


def get_additional_profile_recordings(uid: str, directory: str) -> List[str]:
    """Download additional speech profile recordings"""
    client = _get_storage_client()
    bucket = client.bucket(os.getenv('BUCKET_SPEECH_PROFILES'))
    blobs = bucket.list_blobs(prefix=f'{uid}/additional_profile_recordings/')
    paths = []
    for index, blob in enumerate(blobs):
        file_path = os.path.join(directory, f'clip-{index}.wav')
        blob.download_to_filename(file_path)
        paths.append(file_path)
    return paths


def get_speech_profile_expanded(uid: str, directory: str):
    """Get combined speech profile (main + additional recordings)"""
    _init()
    main = get_profile_audio_if_exists(uid, directory)
    if not main:
        return None
    parts = get_additional_profile_recordings(uid, directory)
    aseg = AudioSegment.from_wav(main)
    for part in parts:
        aseg += AudioSegment.from_wav(part)
    path = os.path.join(directory, 'complete-profile.wav')
    aseg.export(path, format='wav')
    return path


MAX_CHUNK_SECONDS = 30


def _get_embedding(audio_path: str):
    """Compute speaker embedding using Pyannote."""
    import torch
    import torchaudio

    with torch.no_grad():
        signal, fs = torchaudio.load(audio_path)

        # Resample to 16kHz if needed
        if fs != 16000:
            signal = torchaudio.functional.resample(signal, fs, 16000)
            fs = 16000

        # Convert to mono if stereo
        if signal.shape[0] > 1:
            signal = signal.mean(dim=0, keepdim=True)

        total_samples = signal.shape[1]
        chunk_samples = MAX_CHUNK_SECONDS * fs

        # Pyannote expects file path, so we'll use the original file
        # For short audio, extract embedding directly
        if total_samples <= chunk_samples:
            embedding = model(audio_path)
            return embedding

        # For long audio: compute embeddings in chunks and average
        from pydub import AudioSegment as AS
        audio = AS.from_wav(audio_path)
        embeddings = []

        for start_sec in range(0, int(audio.duration_seconds), MAX_CHUNK_SECONDS):
            end_sec = min(start_sec + MAX_CHUNK_SECONDS, audio.duration_seconds)
            if end_sec - start_sec < 1.0:  # Skip chunks shorter than 1s
                continue

            # Extract chunk
            chunk_audio = audio[start_sec * 1000:end_sec * 1000]
            chunk_path = f"_temp/chunk_{os.urandom(4).hex()}.wav"
            chunk_audio.export(chunk_path, format='wav')

            try:
                emb = model(chunk_path)
                embeddings.append(emb)
            finally:
                if os.path.exists(chunk_path):
                    os.remove(chunk_path)

        torch.cuda.empty_cache()

        if not embeddings:
            embedding = model(audio_path)
            return embedding

        # Average embeddings
        stacked = torch.stack(embeddings)
        return stacked.mean(dim=0)


def _cosine_score(emb1, emb2) -> float:
    """Compute cosine similarity between two embeddings."""
    import torch
    # Ensure embeddings are 1D tensors
    if emb1.dim() > 1:
        emb1 = emb1.squeeze()
    if emb2.dim() > 1:
        emb2 = emb2.squeeze()

    score = torch.nn.functional.cosine_similarity(emb1.unsqueeze(0), emb2.unsqueeze(0))
    return float(score[0])


# Improved parameters for Pyannote model
MIN_SEGMENT_DURATION = 1.0
# Pyannote embeddings have different score distribution
# Recommended threshold: 0.5 for high precision, 0.3 for balanced
SIMILARITY_THRESHOLD = 0.45  # Balanced threshold
MAX_SPEAKER_AUDIO_SECONDS = 30


def _segment_speaker_key(segment: TranscriptSegment) -> str:
    """Stable speaker key derived from speaker / speaker_id (whichever is set)."""
    if segment.speaker:
        return str(segment.speaker)
    if segment.speaker_id is not None:
        return f"SPEAKER_{int(segment.speaker_id):02d}"
    return "SPEAKER_00"


def classify_segments(audio_file_path: str, profile_path: str, people: List[dict], segments: List[TranscriptSegment]):
    """Classify segments using Pyannote embeddings."""
    import torch
    _init()
    matches = [{'is_user': False, 'confidence': 0.0, 'person_id': None} for _ in segments]
    if not profile_path:
        return matches

    audio = AudioSegment.from_wav(audio_file_path)
    audio_duration = audio.duration_seconds
    print(f'[Pyannote] Duration: {audio_duration:.2f}s, segments: {len(segments)}')

    # Group segments by speaker
    by_speaker: dict = defaultdict(list)
    for i, segment in enumerate(segments):
        seg_start = max(0.0, segment.start)
        seg_end = min(segment.end, audio_duration)
        if seg_end - seg_start < MIN_SEGMENT_DURATION:
            continue
        by_speaker[_segment_speaker_key(segment)].append((i, seg_start, seg_end))

    if not by_speaker:
        print('[Pyannote] No usable segments for speaker classification')
        return matches

    # Compute profile embedding once
    print(f'[Pyannote] Computing profile embedding from {profile_path}')
    profile_embedding = _get_embedding(profile_path)

    # Compute people embeddings
    people_embeddings = {}
    for person in people:
        try:
            people_embeddings[person['id']] = _get_embedding(person['path'])
            print(f"[Pyannote] Loaded embedding for person {person['id']}")
        except Exception as e:
            print(f"[Pyannote] Failed to encode person {person['id']}: {e}")

    file_name = os.path.basename(audio_file_path)

    for speaker, items in by_speaker.items():
        # Concat per-speaker audio (take longest segments first)
        items_sorted = sorted(items, key=lambda x: (x[2] - x[1]), reverse=True)
        accum_ms = 0
        cap_ms = MAX_SPEAKER_AUDIO_SECONDS * 1000
        speaker_audio = AudioSegment.silent(duration=0, frame_rate=16000)
        used_total = 0.0

        for _, s, e in items_sorted:
            if accum_ms >= cap_ms:
                break
            slice_ms = int((e - s) * 1000)
            if slice_ms <= 0:
                continue
            take_ms = min(slice_ms, cap_ms - accum_ms)
            speaker_audio += audio[int(s * 1000):int(s * 1000) + take_ms]
            accum_ms += take_ms
            used_total += take_ms / 1000.0

        if accum_ms < int(MIN_SEGMENT_DURATION * 1000):
            print(f'[Pyannote] Speaker {speaker}: skipped (only {used_total:.2f}s usable)')
            continue

        temporal_file = f"_temp/{file_name}_{speaker}.wav"
        speaker_audio.export(temporal_file, format="wav")

        try:
            speaker_embedding = _get_embedding(temporal_file)
        except Exception as e:
            print(f"[Pyannote] Speaker {speaker} encode error: {e}")
            try:
                os.remove(temporal_file)
            except OSError:
                pass
            continue

        try:
            os.remove(temporal_file)
        except OSError:
            pass

        # Compute similarities
        scores = {'user': _cosine_score(profile_embedding, speaker_embedding)}
        for pid, pemb in people_embeddings.items():
            scores[pid] = _cosine_score(pemb, speaker_embedding)
        del speaker_embedding

        max_match = max(scores, key=scores.get)
        confidence = scores[max_match]
        scores_str = {k: f'{v:.3f}' for k, v in scores.items()}
        print(f'[Pyannote] Speaker {speaker}: {used_total:.2f}s, scores={scores_str}, threshold={SIMILARITY_THRESHOLD}')

        if confidence <= SIMILARITY_THRESHOLD:
            print(f'  -> REJECTED (confidence {confidence:.3f} < {SIMILARITY_THRESHOLD})')
            continue

        print(f'  -> MATCHED as "{max_match}" (confidence {confidence:.3f})')

        for idx, _s, _e in items:
            matches[idx] = {
                'is_user': max_match == 'user',
                'confidence': confidence,
                'person_id': None if max_match == 'user' else max_match,
            }

    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    return matches


app = App(name='speech_profile_pyannote')

# Updated image with Pyannote
image = (
    Image.from_registry("pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime", add_python="3.11")
    .apt_install('ffmpeg', 'libsndfile1')
    .pip_install("fastapi[standard]")
    .pip_install("pyannote.audio==3.1.1")  # Latest stable version
    .pip_install("torchaudio")
    .pip_install("pydub")
    .pip_install("requests")
    .pip_install("google-cloud-storage")
    .pip_install("redis")
    .env({"PYTHONPATH": "/root"})
    .add_local_dir("models", remote_path="/root/models")
)

os.makedirs('_temp', exist_ok=True)


@app.function(
    image=image,
    scaledown_window=300,
    memory=(2048, 4096),  # Increased memory for Pyannote
    cpu=4,
    gpu="T4",
    secrets=[Secret.from_name('huggingface-token'), Secret.from_name('envs'), Secret.from_name("gcp-credentials")],
)
@concurrent(max_inputs=1)
@fastapi_endpoint(method='POST')
def endpoint(
    uid: str,
    audio_file: UploadFile = File(...),
    segments: str = Form(...),
    _: None = Depends(require_speech_profile_service),
) -> List[ResponseItem]:
    """Match audio against a legacy stored profile for a trusted service caller."""
    if os.getenv("SPEECH_PROFILE_ENABLE_LEGACY_UID_LOOKUP") != "true":
        raise HTTPException(status_code=404, detail="Legacy profile lookup is disabled")
    if not uid or '/' in uid or '\\' in uid:
        raise HTTPException(status_code=400, detail="Invalid user identifier")
    segments_data = json.loads(segments)
    default = [{'is_user': False}] * len(segments_data)
    with tempfile.TemporaryDirectory(prefix='speech-profile-') as directory:
        profile_path = get_speech_profile_expanded(uid, directory)
        if not profile_path:
            return default
        audio_path = os.path.join(directory, 'audio.wav')
        with open(audio_path, 'wb') as target:
            shutil.copyfileobj(audio_file.file, target)
        try:
            transcript_segments = [TranscriptSegment(**segment) for segment in segments_data]
            return classify_segments(audio_path, profile_path, [], transcript_segments)
        except Exception as e:
            print(f"Speaker identification error: {type(e).__name__}")
            return default


@app.function(
    image=image,
    scaledown_window=300,
    memory=(2048, 4096),
    cpu=4,
    gpu="T4",
    secrets=[Secret.from_name('huggingface-token'), Secret.from_name('envs')],
)
@concurrent(max_inputs=1)
@fastapi_endpoint(method='POST')
def endpoint_with_profile(
    audio_file: UploadFile = File(...),
    profile_file: UploadFile = File(...),
    segments: str = Form(...),
    _: None = Depends(require_speech_profile_service),
) -> List[ResponseItem]:
    """
    Enhanced speaker identification with uploaded profile using Pyannote.
    """
    segments_data = json.loads(segments)
    default = [{'is_user': False}] * len(segments_data)

    audio_path = f'_temp/audio_{os.urandom(8).hex()}.wav'
    profile_path = f'_temp/profile_{os.urandom(8).hex()}.wav'

    with open(audio_path, 'wb') as f:
        f.write(audio_file.file.read())

    with open(profile_path, 'wb') as f:
        f.write(profile_file.file.read())

    try:
        transcript_segments = [TranscriptSegment(**segment) for segment in segments_data]
        result = classify_segments(audio_path, profile_path, [], transcript_segments)
        return result
    except Exception as e:
        print(f"[Pyannote] Speaker identification error: {e}")
        import traceback
        traceback.print_exc()
        return default
    finally:
        if os.path.exists(audio_path):
            os.remove(audio_path)
        if os.path.exists(profile_path):
            os.remove(profile_path)
