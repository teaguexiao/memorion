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

# Import shared model from backend — no longer duplicated here.
# Requires image to mount models/ via add_local_dir (see image definition below).
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
    """Initialize heavy dependencies inside the Modal container."""
    global model, AudioSegment
    if model is not None:
        return
    os.environ['PYTORCH_CUDA_ALLOC_CONF'] = 'expandable_segments:True'
    import torch
    from pydub import AudioSegment as _AudioSegment
    from speechbrain.inference.speaker import SpeakerRecognition
    AudioSegment = _AudioSegment
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    model = SpeakerRecognition.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir="pretrained_models/spkrec-ecapa-voxceleb",
        run_opts={"device": device},
    )


# ============ Inlined storage functions ============
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
# ============ End inlined functions ============


MAX_CHUNK_SECONDS = 30


def _get_embedding(audio_path: str):
    """Compute speaker embedding for an audio file, chunking if too long."""
    import torch
    import torchaudio
    with torch.no_grad():
        signal, fs = torchaudio.load(audio_path)
        if fs != 16000:
            signal = torchaudio.functional.resample(signal, fs, 16000)
            fs = 16000
        if signal.shape[0] > 1:
            signal = signal.mean(dim=0, keepdim=True)

        total_samples = signal.shape[1]
        chunk_samples = MAX_CHUNK_SECONDS * fs

        if total_samples <= chunk_samples:
            embedding = model.encode_batch(signal.to(model.device))
            return embedding.squeeze()

        # For long audio: compute embeddings in chunks and average
        embeddings = []
        for start in range(0, total_samples, chunk_samples):
            chunk = signal[:, start:start + chunk_samples]
            if chunk.shape[1] < fs:  # skip chunks shorter than 1s
                continue
            emb = model.encode_batch(chunk.to(model.device))
            embeddings.append(emb.squeeze())
            del chunk
        torch.cuda.empty_cache()

        if not embeddings:
            embedding = model.encode_batch(signal.to(model.device))
            return embedding.squeeze()

        stacked = torch.stack(embeddings)
        return stacked.mean(dim=0)


def _cosine_score(emb1, emb2) -> float:
    """Compute cosine similarity between two embeddings."""
    import torch
    score = torch.nn.functional.cosine_similarity(emb1.unsqueeze(0), emb2.unsqueeze(0))
    return float(score[0])


# Minimum segment duration (seconds) for reliable speaker verification
MIN_SEGMENT_DURATION = 1.0
# Threshold for positive speaker match (cosine similarity)
SIMILARITY_THRESHOLD = 0.25
# Cap audio per speaker fed to the encoder. ECAPA-TDNN gains very little from
# more than ~30s of speech, and longer concatenations slow down GPU encode.
MAX_SPEAKER_AUDIO_SECONDS = 30


def _segment_speaker_key(segment: TranscriptSegment) -> str:
    """Stable speaker key derived from speaker / speaker_id (whichever is set)."""
    if segment.speaker:
        return str(segment.speaker)
    if segment.speaker_id is not None:
        return f"SPEAKER_{int(segment.speaker_id):02d}"
    return "SPEAKER_00"


def classify_segments(audio_file_path: str, profile_path: str, people: List[dict], segments: List[TranscriptSegment]):
    import torch
    _init()
    matches = [{'is_user': False, 'confidence': 0.0, 'person_id': None} for _ in segments]
    if not profile_path:
        return matches

    audio = AudioSegment.from_wav(audio_file_path)
    audio_duration = audio.duration_seconds
    print(f'Duration: {audio_duration:.2f}, segments: {len(segments)}')

    # Group segments by speaker so each speaker is encoded once.
    by_speaker: dict = defaultdict(list)
    for i, segment in enumerate(segments):
        seg_start = max(0.0, segment.start)
        seg_end = min(segment.end, audio_duration)
        if seg_end - seg_start < MIN_SEGMENT_DURATION:
            continue
        by_speaker[_segment_speaker_key(segment)].append((i, seg_start, seg_end))

    if not by_speaker:
        print('No usable segments for speaker classification')
        return matches

    # Profile / people embeddings — computed once.
    profile_embedding = _get_embedding(profile_path)
    people_embeddings = {}
    for person in people:
        try:
            people_embeddings[person['id']] = _get_embedding(person['path'])
        except Exception as e:
            print(f"Failed to encode person {person['id']}: {e}")

    file_name = os.path.basename(audio_file_path)

    for speaker, items in by_speaker.items():
        # Concat per-speaker audio, capped at MAX_SPEAKER_AUDIO_SECONDS.
        # We pick the longest segments first so short interjections don't
        # crowd out the speaker's stable speech.
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
            print(f'Speaker {speaker}: skipped (only {used_total:.2f}s usable)')
            continue

        temporal_file = f"_temp/{file_name}_{speaker}.wav"
        speaker_audio.export(temporal_file, format="wav")

        try:
            speaker_embedding = _get_embedding(temporal_file)
        except Exception as e:
            print(f"Speaker {speaker} encode error: {e}")
            try:
                os.remove(temporal_file)
            except OSError:
                pass
            continue

        try:
            os.remove(temporal_file)
        except OSError:
            pass

        scores = {'user': _cosine_score(profile_embedding, speaker_embedding)}
        for pid, pemb in people_embeddings.items():
            scores[pid] = _cosine_score(pemb, speaker_embedding)
        del speaker_embedding

        max_match = max(scores, key=scores.get)
        confidence = scores[max_match]
        print(f'Speaker {speaker}: {used_total:.2f}s used, scores={ {k: round(v, 3) for k, v in scores.items()} }')

        if confidence <= SIMILARITY_THRESHOLD:
            continue

        for idx, _s, _e in items:
            matches[idx] = {
                'is_user': max_match == 'user',
                'confidence': confidence,
                'person_id': None if max_match == 'user' else max_match,
            }

    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    return matches


app = App(name='speech_profile')
# Serverless on-demand: use pytorch base image with compatible dependencies
image = (
    Image.from_registry("pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime", add_python="3.11")
    .apt_install('ffmpeg', 'libsndfile1')
    .pip_install("fastapi[standard]")
    .pip_install("huggingface_hub<0.24")  # Compatible with speechbrain 1.0.0
    .pip_install("speechbrain==1.0.0")
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
    # Serverless on-demand: no keep_warm, container stays alive 5 min after last request
    scaledown_window=300,
    memory=(1024, 2048),
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
    memory=(1024, 2048),
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
    Speaker identification endpoint that accepts uploaded profile file.
    Used by Developer API where profiles are stored in a different location.

    :param audio_file: The conversation audio file
    :param profile_file: The user's speech profile audio file
    :param segments: JSON array of transcript segments
    :return: List of ResponseItem with is_user and person_id.
    """
    segments_data = json.loads(segments)
    default = [{'is_user': False}] * len(segments_data)

    # Save uploaded files
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
        print(f"Speaker identification error: {e}")
        return default
    finally:
        if os.path.exists(audio_path):
            os.remove(audio_path)
        if os.path.exists(profile_path):
            os.remove(profile_path)
