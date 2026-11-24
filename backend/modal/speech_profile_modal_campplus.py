"""
Speaker identification service — CAM++ zh-cn edition (Plan A, 2026-07).

Drop-in replacement for speech_profile_modal.py (speechbrain ECAPA-voxceleb),
which is trained on English-only VoxCeleb and misfires on Chinese speech
(non-target cosine scores for unseen languages sit at 0.27-0.40, right on top
of the old 0.25 threshold — see backend/docs/speaker-recognition-model-research-2026-07-12.md).

Model: 3D-Speaker CAM++ trained on 200k Chinese speakers (Apache-2.0).
  - CN-Celeb EER 4.32% vs ~7.45% for ECAPA-TDNN (ModelScope model card)
  - 7.18M params / 28MB weights / RTF 0.013 — lightest cold start of the family
  - 192-dim embedding, cosine scoring, official threshold 0.31
Weights are baked into the image at build time from the HF mirror
(funasr/campplus) — do NOT pull from modelscope.cn at runtime (slow/unstable
from overseas containers).

Deployed as a SEPARATE Modal app ("speech_profile_campplus") so it can be
canaried against the incumbent via HOSTED_SPEECH_PROFILE_API_URL switch.
The HTTP contract (endpoint / endpoint_with_profile) is identical.
"""

import hmac
import json
import shutil
import tempfile
import math
import time
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
    # Open-set outcome for this speaker: 'user' | 'person' | 'unknown' | 'ambiguous'.
    # 'unknown' (nobody is close enough) and 'ambiguous' (two identities are too
    # close to separate) are both reported instead of being collapsed into a
    # silent is_user=False, so callers can tell "not the user" apart from
    # "we could not tell" and offer the segment for manual labelling.
    decision: Optional[str] = None
    scope: Optional[str] = None


# Heavy imports and model loading deferred to container startup
model = None
AudioSegment = None
_device = None

WEIGHTS_PATH = '/root/weights/campplus_cn_common.bin'


def _init():
    """Initialize CAM++ inside the Modal container."""
    global model, AudioSegment, _device
    if model is not None:
        return
    os.environ['PYTORCH_CUDA_ALLOC_CONF'] = 'expandable_segments:True'
    import torch
    from pydub import AudioSegment as _AudioSegment
    from campplus.dtdnn import CAMPPlus
    AudioSegment = _AudioSegment
    _device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    # Config from funasr/campplus config.yaml (zh-cn 200k-speaker checkpoint)
    model = CAMPPlus(feat_dim=80, embedding_size=192)
    state = torch.load(WEIGHTS_PATH, map_location='cpu')
    model.load_state_dict(state)
    model.to(_device).eval()
    print(f'CAM++ zh-cn loaded on {_device}')


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


def _extract_fbank(signal):
    """80-dim kaldi fbank + CMN, matching 3D-Speaker inference recipe."""
    import torch
    import torchaudio.compliance.kaldi as kaldi
    # signal: (1, samples) float32 in [-1, 1] at 16k
    feat = kaldi.fbank(signal, num_mel_bins=80, sample_frequency=16000, dither=0)
    feat = feat - feat.mean(dim=0, keepdim=True)  # cepstral mean normalization
    return feat.unsqueeze(0)  # (1, T, 80)


def _encode(signal):
    """Run CAM++ on a (1, samples) waveform tensor -> 192-dim embedding."""
    import torch
    feat = _extract_fbank(signal).to(_device)
    with torch.no_grad():
        emb = model(feat)
    return emb.squeeze(0)


def _l2_normalize(emb):
    """Project an embedding onto the unit sphere."""
    import torch
    return emb / torch.linalg.norm(emb).clamp_min(1e-12)


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
            return _encode(signal)

        # For long audio: compute embeddings in chunks and average
        embeddings = []
        for start in range(0, total_samples, chunk_samples):
            chunk = signal[:, start:start + chunk_samples]
            if chunk.shape[1] < fs:  # skip chunks shorter than 1s
                continue
            embeddings.append(_encode(chunk))
            del chunk
        torch.cuda.empty_cache()

        if not embeddings:
            return _encode(signal)

        # Normalize BEFORE averaging. Only direction carries speaker identity —
        # cosine scoring discards magnitude — but a plain mean does not, so a
        # chunk that happens to encode with a larger norm pulls the average
        # toward itself. Loud or noisy chunks tend to have exactly that, which
        # let the least representative chunk dominate a long recording.
        stacked = torch.stack([_l2_normalize(e) for e in embeddings])
        return _l2_normalize(stacked.mean(dim=0))


def _cosine_score(emb1, emb2) -> float:
    """Compute cosine similarity between two embeddings."""
    import torch
    score = torch.nn.functional.cosine_similarity(emb1.unsqueeze(0), emb2.unsqueeze(0))
    return float(score[0])


# Enrolment clip length at which a clip counts as fully informative. Speaker
# embeddings stop improving well before this (NIST SRE and the CAM++ card both
# plateau in the 10-20s range), so weighting strictly by duration would let one
# long clip outvote five good short ones for no accuracy gain.
WEIGHT_SATURATION_SECONDS = float(os.getenv('CAMPPLUS_WEIGHT_SATURATION', '10'))
# Minimum share of the profile centroid held by the onboarding recording. It is
# the only audio we know belongs to the user — they recorded it alone, on
# purpose. Everything else was harvested from real conversations, where a
# mislabelled tap files a bystander under the user's name. Keeping the anchor at
# half the weight means no quantity of bad samples can redefine the profile.
ANCHOR_WEIGHT_FLOOR = float(os.getenv('CAMPPLUS_ANCHOR_FLOOR', '0.5'))


def _clip_weight(seconds: float) -> float:
    """Weight for one enrolment clip, saturating at WEIGHT_SATURATION_SECONDS.

    Clips arrive with silence already stripped (the collector removes pauses
    before upload), so length here is a stand-in for how much speech the clip
    actually contributes.
    """
    if seconds <= 0:
        return 0.0
    return min(seconds, WEIGHT_SATURATION_SECONDS) / WEIGHT_SATURATION_SECONDS


def _anchor_weight(sample_weights: List[float]) -> float:
    """Weight for the anchor that holds it at ANCHOR_WEIGHT_FLOOR of the total.

    Solves ``a / (a + s) >= floor`` for the anchor weight ``a`` given the summed
    sample weight ``s``. At floor=0.5 this is simply ``a = s``.
    """
    floor = min(max(ANCHOR_WEIGHT_FLOOR, 0.0), 0.99)
    total_samples = sum(w for w in sample_weights if w > 0)
    return max(1.0, total_samples * floor / (1.0 - floor))


def _weighted_centroid(vectors, weights):
    """Unit-length weighted mean of embeddings.

    Averaging embeddings rather than concatenating their audio is what makes a
    voiceprint improve with each recording instead of being decided by whichever
    clip is longest. Concatenation also runs cepstral mean normalization across
    the splice, mixing the acoustics of unrelated recordings into one statistic.
    """
    import torch
    usable = [(v, w) for v, w in zip(vectors, weights) if w > 0]
    if not usable:
        return None
    acc = None
    for vec, weight in usable:
        term = _l2_normalize(vec) * weight
        acc = term if acc is None else acc + term
    return _l2_normalize(acc)


# Agreement a collected clip must show with the trusted reference to join the
# centroid. Set to the accept threshold: a clip that would not be recognized as
# this speaker cannot be evidence of how they sound.
CLIP_AGREEMENT_MIN = float(os.getenv('CAMPPLUS_CLIP_AGREEMENT_MIN', '0.31'))


# Profile-health warning thresholds, read off the measured distribution rather
# than chosen — run scripts/measure_profile_health.py to reproduce. Across every
# enrolled identity in production (4 with more than one recording, 2026-08-04):
#
#   drift      min 0.900  mean 0.931  max 1.000
#   coherence  min 0.688  mean 0.878  max 1.000
#
# Guessing these is a trap worth naming. Drift is bounded below by the
# construction: with the anchor pinned at ANCHOR_WEIGHT_FLOOR of the weight and no
# kept clip closer than CLIP_AGREEMENT_MIN, drift cannot fall below
# (a + s·g)/sqrt(a² + s² + 2·a·s·g) = 0.809 at floor=0.5, gate=0.31. An
# intuitive-looking 0.80 cutoff is therefore dead code — it reads as implemented
# and can never fire.
#
# So drift warns at 0.88: inside the reachable range, below everything observed,
# i.e. it fires only on enrolment worse than the current worst. It is a backstop
# for bad clips that clear the gate — not the primary signal, because the gate and
# the anchor floor already bound those.
CENTROID_DRIFT_WARN = float(os.getenv('CAMPPLUS_DRIFT_WARN', '0.88'))
# Coherence is the sensitive one. It asks whether the kept clips agree with each
# OTHER, not merely with the anchor, which is what a reference assembled from two
# similar-sounding people fails. The one profile known to be contaminated (30 of
# 40 clips dropped, 48 files flagged by screen_speech_samples.py) sits at 0.688,
# and a 0.60 cutoff would have missed it.
#
# The upper side is worth stating precisely, because production cannot supply it:
# exactly ONE identity has two clips long enough for coherence to be a real
# measurement, and it is the contaminated one. The other profiles hold a single
# clip each, where "coherence" is just that clip agreeing with itself. So the
# clean-side reference is the chopping experiment below — pieces of one speaker's
# own onboarding recording score 0.913 at 6s and 0.967 at 12s. 0.75 sits between
# that and 0.688 with room on both sides, but it rests on one positive and one
# negative example. Re-run scripts/measure_profile_health.py once more users have
# extended their profiles, and move it if the distribution says so.
COHERENCE_WARN = float(os.getenv('CAMPPLUS_COHERENCE_WARN', '0.75'))
# Coherence is confounded by clip length: chopping ONE speaker's onboarding
# recording (single speaker by construction) into pieces and measuring coherence
# gives 0.785 at 3s, 0.861 at 4s, 0.913 at 6s, 0.967 at 12s. Short clips carry
# less speaker information, so they disagree with each other for reasons that have
# nothing to do with whose voice it is. Below this length the metric would warn on
# perfectly good audio, so it is not applied. Production clips are long anyway
# (median 62.8s, only 3.8% under 6s), which is why this costs almost no coverage.
COHERENCE_MIN_CLIP_SECONDS = float(os.getenv('CAMPPLUS_COHERENCE_MIN_SECONDS', '6'))
# Share of submitted clips rejected as a different voice. Empirically the loudest
# signal of all — the contaminated profile drops 75% — and it needs no geometry to
# interpret. Only meaningful once there are a few clips to take a share of.
DROP_RATIO_WARN = float(os.getenv('CAMPPLUS_DROP_RATIO_WARN', '0.5'))
DROP_RATIO_MIN_CLIPS = 4


def _screened_centroid(anchor, clips: List[dict], label: str):
    """Centroid of ``anchor`` plus the clips that agree with it.

    ``clips`` is ``[{'emb': tensor, 'seconds': float, 'name': str}, ...]``.

    A voiceprint should get better with each recording, but only if each new
    recording is really the same person. Production enrolment is full of clips
    that are not: a mis-mapped timestamp filed whoever was speaking at that
    offset under this name. Averaging those in moves the centroid toward a
    stranger, which is worse than having one short reference — it produces
    confident wrong matches instead of abstentions.

    So each clip is scored against the anchor it claims to extend and dropped if
    it disagrees. The anchor itself is never screened and never dropped; it is
    the ground truth this function is built around.

    The log line carries two health metrics alongside the counts. ``drift`` is
    cos(centroid, anchor): how far enrolment has moved the profile from the audio
    the user deliberately recorded. ``coh`` is the mean agreement of the kept
    clips with the finished centroid: how much they agree with each other, not
    just with the anchor. Both are observations only — neither alters the match.
    """
    kept, dropped = [], []
    for clip in clips:
        score = _cosine_score(anchor, clip['emb'])
        (kept if score >= CLIP_AGREEMENT_MIN else dropped).append((clip, score))

    weights = [_clip_weight(c['seconds']) for c, _ in kept]
    anchor_w = _anchor_weight(weights)
    centroid = _weighted_centroid(
        [anchor] + [c['emb'] for c, _ in kept], [anchor_w] + weights
    )
    if centroid is None:
        print(f'[CAM++] {label} centroid: anchor only (no usable clips)')
        return anchor

    drift = _cosine_score(centroid, anchor)
    coherence = (
        sum(_cosine_score(centroid, c['emb']) for c, _ in kept) / len(kept)
        if kept
        else 1.0
    )
    detail = ''
    if dropped:
        shown = ', '.join('%s=%.3f' % (c['name'], s) for c, s in dropped[:5])
        detail = f', {len(dropped)} dropped as a different voice ({shown})'
    print(
        f'[CAM++] {label} centroid: anchor(w={anchor_w:.2f}) + {len(kept)} clips, '
        f'drift={drift:.3f} coh={coherence:.3f}{detail}'
    )
    total = len(kept) + len(dropped)
    drop_ratio = len(dropped) / total if total else 0.0
    # Judge coherence only on clips long enough for it to mean anything.
    long_enough = [c for c, _s in kept if c['seconds'] >= COHERENCE_MIN_CLIP_SECONDS]
    reasons = []
    if drift < CENTROID_DRIFT_WARN:
        reasons.append(f'drift {drift:.3f}<{CENTROID_DRIFT_WARN}')
    if len(long_enough) >= 2 and coherence < COHERENCE_WARN:
        reasons.append(f'coherence {coherence:.3f}<{COHERENCE_WARN}')
    if total >= DROP_RATIO_MIN_CLIPS and drop_ratio >= DROP_RATIO_WARN:
        reasons.append(f'{len(dropped)}/{total} clips rejected')
    if reasons:
        # Greppable prefix: the point of the metrics is to find these without
        # reading every centroid line.
        print(
            f'[CAM++] PROFILE_HEALTH {label}: ' + '; '.join(reasons)
            + ' — enrolment may hold another voice; run '
            'scripts/screen_speech_samples.py for this identity'
        )
    return centroid


# Consensus voiceprint (2026-11-04). Once an identity has enough clips, the anchor
# stops holding half the weight and every recording, anchor included, is weighted
# by how well it agrees with all the OTHER recordings. Why the anchor floor had to go:
# one user's onboarding recording (2026-03, a different device from the one they
# now wear) scored 0.28–0.55 against their own conversation clips; scored against
# that recording alone, 3 of 924 sentences in an 8-hour recording were theirs, while
# the anchor-pinned centroid found 71 and the consensus 127.
#
# Bad clips fade without anyone deleting them: a clip of another voice disagrees
# with the consensus of the rest, so its trust falls to zero, and the more genuine
# clips accumulate the firmer that consensus gets. Replayed on that user's 8 clips
# with 1–6 recordings of other people injected as if they were theirs, the injected
# clips together held at most 4% of the weight and at most 4 more sentences became
# the user's.
CONSENSUS_MIN_CLIPS = int(os.getenv('CAMPPLUS_CONSENSUS_MIN_CLIPS', '3'))
# The anchor's prior weight, in full-length clips: half the profile with 2 clips,
# a sixth with 10, and less with every recording after that.
ANCHOR_PRIOR_CLIPS = float(os.getenv('CAMPPLUS_ANCHOR_PRIOR_CLIPS', '2.0'))
# Leave-one-out agreement with the consensus maps linearly onto trust: none at or
# below LO, full at HI. Measured on that user: own clips agree with each other at
# median 0.58 (min 0.36) and with other people at median 0.23 (p90 0.35). LO=0.31
# still gave injected clips up to 11% of the weight; 0.40 held them to 4% at no
# cost to recall.
CONSENSUS_TRUST_LO = float(os.getenv('CAMPPLUS_CONSENSUS_TRUST_LO', '0.40'))
CONSENSUS_TRUST_HI = float(os.getenv('CAMPPLUS_CONSENSUS_TRUST_HI', '0.65'))
CONSENSUS_ROUNDS = 5
# A person reference this close to the user's own is taken to hold the user's voice
# and is not offered as a candidate. 🚨 Not the accept threshold, and not to be
# lowered back to it: dropping a real person is the dangerous direction, because
# their sentences can then only match the user. The consensus profile is built from
# clips recorded on the device the user wears, so it sits at 0.25–0.44 from other
# people recorded on that same device (the anchor-dominated profile sat at
# 0.12–0.34, far from everyone). At 0.31, 4 of 10 people were dropped, the user's
# son among them, and 32 sentences became the user's that otherwise go to
# unsure/someone else. One speaker's own clips agree at median 0.58 (2026-11-04).
CONTAMINATION_MIN = float(os.getenv('CAMPPLUS_CONTAMINATION_MIN', '0.50'))


def _consensus_centroid(anchor, clips: List[dict], label: str):
    """Centroid in which each recording's weight is earned by agreeing with the rest.

    Below CONSENSUS_MIN_CLIPS clips there is no consensus to speak of, so the
    anchor-pinned `_screened_centroid` applies. It is also the fallback when the
    consensus no longer resembles the anchor at all: if most clips agree with each
    other but not with the person who enrolled (one voice tagged as the user over
    and over), the majority is the contamination, and the anchor is all that is left.
    """
    if len(clips) < CONSENSUS_MIN_CLIPS:
        return _screened_centroid(anchor, clips, label)
    vectors = [_l2_normalize(anchor)] + [_l2_normalize(c['emb']) for c in clips]
    base = [ANCHOR_PRIOR_CLIPS] + [_clip_weight(c['seconds']) for c in clips]
    span = CONSENSUS_TRUST_HI - CONSENSUS_TRUST_LO
    trust = [1.0] * len(vectors)
    for _ in range(CONSENSUS_ROUNDS):
        weights = [b * t for b, t in zip(base, trust)]
        total = sum(v * w for v, w in zip(vectors, weights))
        trust = [min(1.0, max(0.0, (_cosine_score(total - v * w, v) - CONSENSUS_TRUST_LO) / span))
                 for v, w in zip(vectors, weights)]
    weights = [b * t for b, t in zip(base, trust)]
    centroid = _weighted_centroid(vectors, weights)
    if centroid is None or _cosine_score(centroid, anchor) < CLIP_AGREEMENT_MIN:
        print(f'[CAM++] PROFILE_HEALTH {label}: clips agree with each other but not with the '
              'anchor — falling back to the anchor-pinned centroid')
        return _screened_centroid(anchor, clips, label)
    total_weight = sum(weights)
    faded = [c['name'] for c, t in zip(clips, trust[1:]) if t == 0.0]
    print(f'[CAM++] {label} consensus: anchor share {weights[0] / total_weight:.2f}, '
          f'{len(clips) - len(faded)}/{len(clips)} clips carry weight'
          + (f', faded: {", ".join(faded[:5])}' if faded else ''))
    if len(clips) >= DROP_RATIO_MIN_CLIPS and len(faded) / len(clips) >= DROP_RATIO_WARN:
        print(f'[CAM++] PROFILE_HEALTH {label}: {len(faded)}/{len(clips)} clips disagree with the consensus')
    return centroid


# Minimum segment duration (seconds) for reliable speaker verification
MIN_SEGMENT_DURATION = 1.0
# Threshold for positive speaker match (cosine similarity).
# 0.31 is the official operating point from the ModelScope model card
# (iic/speech_campplus_sv_zh-cn_16k-common). Tune against real recordings
# before full cutover — do NOT reuse the old ECAPA threshold (0.25).
SIMILARITY_THRESHOLD = float(os.getenv('CAMPPLUS_SIMILARITY_THRESHOLD', '0.31'))
# Minimum lead the top identity must hold over the runner-up to be trusted.
# Without it, a closed-set argmax will confidently hand a speaker to whichever
# enrolled identity scores a hair higher — and with several family members
# enrolled, near-ties are common (arXiv 2110.01200 on open-set SV: the top1/top2
# margin separates "this is them" from "these two are indistinguishable here"
# far better than the absolute score does). Ties become 'ambiguous', which the
# caller surfaces for manual labelling instead of guessing.
SCORE_MARGIN = float(os.getenv('CAMPPLUS_SCORE_MARGIN', '0.06'))
# Cap audio per speaker fed to the encoder; embeddings gain little past ~30s.
MAX_SPEAKER_AUDIO_SECONDS = 30
# Uploaded recordings are judged sentence by sentence (`local` scope). A sentence
# shorter than this carries too little voice for a verdict and gets none: on
# 2026-10-31 audio, 2s sentences already separated the user from their son with a
# median margin of 0.16 over the runner-up.
MIN_LOCAL_SEGMENT_SECONDS = float(os.getenv('CAMPPLUS_MIN_LOCAL_SEGMENT_SECONDS', '2.0'))
# Leave time for upload, cold start and serialization inside the 900s endpoint.
# Exhaustion returns partial evidence; unchecked audio has no new verdict.
LOCAL_CLASSIFICATION_BUDGET_SECONDS = 600


def _local_parts(start: float, end: float) -> list:
    """Split ONE sentence into consecutive parts of at most MAX_SPEAKER_AUDIO_SECONDS.

    🚨 Never pool audio across sentences. Until 2026-11-04 the local scope
    concatenated a diarization speaker's neighbouring sentences into 30s windows
    and required the window and both halves to agree. Whenever diarization merged
    two people under one label (a father and son trading lines over a card game),
    every window held both voices, scored close to both, and came back ambiguous:
    one 8-hour recording kept 14 of the user's sentences where per-sentence scoring
    found 129. A diarization label is a hint, not evidence about who spoke.

    A single long sentence can still hold two voices (diarization glued them into
    one turn), so its parts are scored separately and must all agree.
    """
    parts = max(1, math.ceil((end - start) / MAX_SPEAKER_AUDIO_SECONDS))
    return [(start + (end - start) * i / parts, start + (end - start) * (i + 1) / parts)
            for i in range(parts)]


def _combine_local_matches(outcomes: list) -> dict:
    """A sentence's label requires every one of its parts to agree."""
    if not outcomes or any(m.get('decision') is None for m in outcomes):
        return {'is_user': False, 'person_id': None, 'confidence': 0.0, 'scope': 'local', 'decision': None}
    identities = [(m.get('decision'), m.get('person_id')) for m in outcomes]
    first = outcomes[0]
    if (first.get('decision') in ('user', 'person') and
            all(identity == identities[0] for identity in identities)):
        return {**first, 'confidence': min(m['confidence'] for m in outcomes), 'scope': 'local'}
    return {'is_user': False, 'person_id': None, 'confidence': 0.0, 'scope': 'local',
            'decision': 'unknown' if all(m.get('decision') == 'unknown' for m in outcomes) else 'ambiguous'}


def _match_audio(audio, profile_embedding, people_embeddings: dict, label: str) -> dict:
    """Score one actual audio sample, cleaning its temporary file on every exit."""
    path = f'_temp/match_{os.urandom(8).hex()}.wav'
    try:
        audio.export(path, format='wav')
        embedding = _get_embedding(path)
        scores = {'user': _cosine_score(profile_embedding, embedding)}
        scores.update({pid: _cosine_score(reference, embedding) for pid, reference in people_embeddings.items()})
        decision, identity, confidence = _decide(scores)
        print(f'[CAM++] {label}: {audio.duration_seconds:.2f}s, '
              f'scores={ {k: round(v, 3) for k, v in scores.items()} } -> {decision}')
        return {'is_user': identity == 'user', 'confidence': confidence,
                'person_id': None if identity == 'user' else identity,
                'decision': ('user' if identity == 'user' else 'person') if decision == 'accept' else decision}
    finally:
        if os.path.exists(path):
            os.remove(path)


def _segment_speaker_key(segment: TranscriptSegment) -> str:
    """Stable speaker key derived from speaker / speaker_id (whichever is set)."""
    if segment.speaker:
        return str(segment.speaker)
    if segment.speaker_id is not None:
        return f"SPEAKER_{int(segment.speaker_id):02d}"
    return "SPEAKER_00"


def _decide(scores: dict) -> tuple:
    """Open-set decision over ``{identity: cosine}``.

    Returns ``(decision, identity, confidence)`` where decision is one of
    ``accept`` / ``unknown`` / ``ambiguous``. A closed-set argmax is wrong here:
    the speaker in front of the mic is very often nobody we have enrolled (a
    colleague, a barista, a TV), so "who is closest" has to be able to answer
    "none of them" and "cannot tell these two apart".
    """
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    top_id, top_score = ranked[0]
    if top_score <= SIMILARITY_THRESHOLD:
        return 'unknown', None, top_score
    if len(ranked) > 1 and (top_score - ranked[1][1]) < SCORE_MARGIN:
        return 'ambiguous', None, top_score
    return 'accept', top_id, top_score


def _reference_embedding(anchor_path: str, clip_paths: List[str], label: str):
    """Embedding for one identity: anchor alone, or a screened centroid of clips.

    ``clip_paths`` are additional recordings of the SAME identity, each encoded
    separately. Encoding them separately (rather than concatenating the audio) is
    what allows a clip to be rejected on its own merits and what keeps one long
    clip from deciding the result.
    """
    anchor = _get_embedding(anchor_path)
    if not clip_paths:
        return anchor

    clips = []
    for path in clip_paths:
        try:
            audio = AudioSegment.from_wav(path)
            clips.append({
                'emb': _get_embedding(path),
                'seconds': audio.duration_seconds,
                'name': os.path.basename(path),
            })
        except Exception as e:
            print(f'[CAM++] Skipping unreadable clip {path}: {e}')
    if not clips:
        return anchor
    return _consensus_centroid(anchor, clips, label)


def _classify_local(audio, segments, by_speaker, profile_embedding, people_embeddings, matches, deadline):
    """Give every sentence of an uploaded recording its own verdict, in place.

    Sentences under MIN_LOCAL_SEGMENT_SECONDS, sentences left when the budget runs
    out, and sentences that fail to encode keep ``decision=None`` (no new verdict),
    so the caller never overwrites an earlier label with a non-answer.
    """
    items = sorted((item for rows in by_speaker.values() for item in rows), key=lambda item: item[1])
    for position, (idx, start, end) in enumerate(items):
        if end - start < MIN_LOCAL_SEGMENT_SECONDS:
            continue
        speaker = _segment_speaker_key(segments[idx])
        checks = []
        try:
            for part, (left, right) in enumerate(_local_parts(start, end)):
                if time.monotonic() >= deadline:
                    raise TimeoutError('Local budget exhausted')
                clip = audio[round(left * 1000):round(right * 1000)]
                checks.append(_match_audio(clip, profile_embedding, people_embeddings, f'{speaker}#{idx}.{part}'))
        except TimeoutError:
            print(f'[CAM++] Local budget exhausted after {position}/{len(items)} sentences; '
                  'the rest have no new verdict')
            return
        except Exception as e:
            print(f'[CAM++] Sentence {idx} ({speaker}) encode error: {e}')
            continue
        matches[idx] = _combine_local_matches(checks)


def classify_segments(
    audio_file_path: str,
    profile_path: str,
    people: List[dict],
    segments: List[TranscriptSegment],
    profile_clip_paths: Optional[List[str]] = None,
    classification_scope: str = 'speaker',
):
    import torch
    deadline = time.monotonic() + LOCAL_CLASSIFICATION_BUDGET_SECONDS if classification_scope == 'local' else None
    _init()
    local = classification_scope == 'local'
    matches = [
        {'is_user': False, 'confidence': 0.0, 'person_id': None,
         'decision': None, **({'scope': 'local'} if local else {})}
        for _ in segments
    ]
    if not profile_path:
        return matches

    audio = AudioSegment.from_wav(audio_file_path)
    audio_duration = audio.duration_seconds
    print(f'[CAM++] Duration: {audio_duration:.2f}, segments: {len(segments)}')

    # Group segments by speaker so each speaker is encoded once.
    by_speaker: dict = defaultdict(list)
    for i, segment in enumerate(segments):
        seg_start = max(0.0, segment.start)
        seg_end = min(segment.end, audio_duration)
        if seg_end - seg_start < MIN_SEGMENT_DURATION:
            continue
        by_speaker[_segment_speaker_key(segment)].append((i, seg_start, seg_end))

    if not by_speaker:
        print('[CAM++] No usable segments for speaker classification')
        return matches

    # Profile / people embeddings — computed once.
    profile_embedding = _reference_embedding(
        profile_path, profile_clip_paths or [], 'user'
    )
    people_embeddings = {}
    for person in people:
        try:
            pemb = _reference_embedding(
                person['path'], person.get('clip_paths') or [], f"person {person['id']}"
            )
        except Exception as e:
            print(f"[CAM++] Failed to encode person {person['id']}: {e}")
            continue
        # A person reference that sounds like the USER is contaminated — the
        # user's own voice got filed under someone else's name (which the
        # pre-2026-08 collector did whenever segment timestamps were on the
        # untrimmed axis). Keeping it guarantees a wrong answer either way: it
        # steals the user's own segments, or it makes both identities ambiguous.
        # Both embeddings are already in hand here, so the check is free.
        contamination = _cosine_score(profile_embedding, pemb)
        if contamination >= CONTAMINATION_MIN:
            print(
                f"[CAM++] Dropping person {person['id']}: reference matches the "
                f"user's own profile (cos={contamination:.3f} >= {CONTAMINATION_MIN}) "
                f"— it is contaminated, not a distinct speaker"
            )
            continue
        people_embeddings[person['id']] = pemb

    if local:
        _classify_local(audio, segments, by_speaker, profile_embedding, people_embeddings, matches, deadline)
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
        return matches

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
            start_ms = round(s * 1000)
            slice_ms = round(e * 1000) - start_ms
            if slice_ms <= 0:
                continue
            take_ms = min(slice_ms, cap_ms - accum_ms)
            speaker_audio += audio[start_ms:start_ms + take_ms]
            accum_ms += take_ms
            used_total += take_ms / 1000.0

        if accum_ms < int(MIN_SEGMENT_DURATION * 1000):
            print(f'[CAM++] Speaker {speaker}: skipped (only {used_total:.2f}s usable)')
            continue
        try:
            match = _match_audio(speaker_audio, profile_embedding, people_embeddings, speaker)
        except Exception as e:
            print(f"[CAM++] Speaker {speaker} encode error: {e}")
            continue
        for idx, _s, _e in items:
            matches[idx] = dict(match)


    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    return matches


app = App(name='speech_profile_campplus')
# Weights baked at build time from the HF mirror (see module docstring).
image = (
    Image.from_registry("pytorch/pytorch:2.1.0-cuda11.8-cudnn8-runtime", add_python="3.11")
    .apt_install('ffmpeg', 'libsndfile1')
    .pip_install("fastapi[standard]")
    .pip_install("torchaudio")
    .pip_install("pydub")
    .pip_install("requests")
    .pip_install("google-cloud-storage")
    .pip_install("redis")
    .run_commands(
        "mkdir -p /root/weights && "
        "python -c \"import requests; r = requests.get('https://huggingface.co/funasr/campplus/resolve/main/campplus_cn_common.bin', timeout=300); r.raise_for_status(); open('/root/weights/campplus_cn_common.bin','wb').write(r.content)\""
    )
    .env({"PYTHONPATH": "/root"})
    .add_local_dir("models", remote_path="/root/models")
    .add_local_dir("modal/campplus", remote_path="/root/campplus")
)

os.makedirs('_temp', exist_ok=True)


@app.function(
    image=image,
    # Serverless on-demand: no keep_warm, container stays alive 5 min after last request
    scaledown_window=300,
    memory=(1024, 2048),
    cpu=4,
    gpu="T4",
    secrets=[Secret.from_name('envs'), Secret.from_name("gcp-credentials")],
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
    secrets=[Secret.from_name('envs')],
    timeout=900,
)
@concurrent(max_inputs=1)
@fastapi_endpoint(method='POST')
def endpoint_with_profile(
    audio_file: UploadFile = File(...),
    profile_file: UploadFile = File(...),
    segments: str = Form(...),
    people_files: List[UploadFile] = File(default=[]),
    people_ids: str = Form(default='[]'),
    profile_clip_files: List[UploadFile] = File(default=[]),
    people_clip_files: List[UploadFile] = File(default=[]),
    people_clip_owners: str = Form(default='[]'),
    classification_scope: str = Form(default='speaker'),
    _: None = Depends(require_speech_profile_service),
) -> List[ResponseItem]:
    """
    Speaker identification endpoint that accepts uploaded profile file.
    Used by Developer API where profiles are stored in a different location.

    :param audio_file: The conversation audio file
    :param profile_file: The user's onboarding recording — the trusted anchor.
    :param segments: JSON array of transcript segments
    :param people_files: Anchor audio for other enrolled people, in the same
        order as ``people_ids``. Optional — omit to verify against the user only.
    :param people_ids: JSON array of person IDs matching ``people_files``
        positionally. Sent as a separate field because multipart part names
        cannot carry the ID reliably across HTTP clients.
    :param profile_clip_files: Extra recordings of the USER, each kept separate so
        it can be screened against the anchor and weighted on its own. Sending
        them individually rather than pre-concatenated is what lets one bad clip
        be discarded instead of silently averaged in.
    :param people_clip_files: Extra recordings of the enrolled people, attributed
        by ``people_clip_owners``.
    :param people_clip_owners: JSON array of person IDs, positionally matching
        ``people_clip_files``.
    :param classification_scope: ``local`` judges every sentence on its own audio
        (uploaded recordings). Default ``speaker`` retains the legacy streaming contract.
    :return: List of ResponseItem with is_user, person_id and decision.
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

    def _spill(upload, kind: str) -> str:
        path = f'_temp/{kind}_{os.urandom(8).hex()}.wav'
        with open(path, 'wb') as fh:
            fh.write(upload.file.read())
        return path

    def _parse_ids(raw: str) -> list:
        try:
            return json.loads(raw) if raw else []
        except json.JSONDecodeError:
            return []

    profile_clip_paths = [_spill(u, 'uclip') for u in (profile_clip_files or [])]

    # Persist people reference audio, pairing each file with its ID by position.
    # A length mismatch means the caller built the request wrong; drop the people
    # entirely rather than risk labelling a speaker with someone else's ID.
    people = []
    ids = _parse_ids(people_ids)
    if people_files and len(ids) != len(people_files):
        print(
            f"[CAM++] people_ids/{len(ids)} does not match people_files/"
            f"{len(people_files)} — ignoring people references"
        )
    elif people_files:
        for pid, upload in zip(ids, people_files):
            people.append({
                'id': str(pid), 'path': _spill(upload, 'person'), 'clip_paths': [],
            })

    # Extra clips are attributed by owner ID. Same rule as above: if the pairing
    # is not exact, the clips are unattributable, and a clip filed under the wrong
    # person is precisely the corruption this phase exists to prevent.
    clip_owners = _parse_ids(people_clip_owners)
    people_clip_paths = []
    if people_clip_files:
        if len(clip_owners) != len(people_clip_files):
            print(
                f"[CAM++] people_clip_owners/{len(clip_owners)} does not match "
                f"people_clip_files/{len(people_clip_files)} — ignoring extra clips"
            )
        else:
            by_id = {p['id']: p for p in people}
            for pid, upload in zip(clip_owners, people_clip_files):
                owner = by_id.get(str(pid))
                if owner is None:
                    continue
                path = _spill(upload, 'pclip')
                people_clip_paths.append(path)
                owner['clip_paths'].append(path)

    try:
        transcript_segments = [TranscriptSegment(**segment) for segment in segments_data]
        result = classify_segments(
            audio_path, profile_path, people, transcript_segments,
            profile_clip_paths=profile_clip_paths,
            classification_scope=classification_scope,
        )
        return result
    except Exception as e:
        print(f"[CAM++] Speaker identification error: {e}")
        return default
    finally:
        for path in (
            [audio_path, profile_path]
            + [p['path'] for p in people]
            + profile_clip_paths
            + people_clip_paths
        ):
            if os.path.exists(path):
                os.remove(path)


@app.function(
    image=image,
    scaledown_window=300,
    memory=(1024, 2048),
    cpu=4,
    gpu="T4",
    secrets=[Secret.from_name('envs')],
)
@concurrent(max_inputs=1)
@fastapi_endpoint(method='POST')
def embed(
    files: List[UploadFile] = File(...),
    _: None = Depends(require_speech_profile_service),
) -> List[List[float]]:
    """Return the raw 192-dim embedding for each uploaded wav, in order.

    Exists for offline auditing and threshold calibration: scoring N enrolled
    recordings against each other needs N embeddings, not N^2 HTTP round-trips
    through the classification endpoint. Returns ``[]`` for a file that fails to
    encode, so a bad file does not shift the rest of the list out of alignment
    with its input.
    """
    _init()
    out: List[List[float]] = []
    for upload in files:
        path = f'_temp/embed_{os.urandom(8).hex()}.wav'
        try:
            with open(path, 'wb') as f:
                f.write(upload.file.read())
            emb = _get_embedding(path)
            out.append([float(x) for x in emb.tolist()])
        except Exception as e:
            print(f'[CAM++] embed failed for {upload.filename}: {e}')
            out.append([])
        finally:
            if os.path.exists(path):
                os.remove(path)
    return out
