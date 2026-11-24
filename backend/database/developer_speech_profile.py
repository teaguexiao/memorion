"""
Developer Speech Profile Storage

GCS storage operations for developer-specific speech profiles.
Data is isolated by developer_id and external_user_id.

Storage structure:
gs://your-speech-profiles-bucket/
├── developers/
│   └── {developer_id}/
│       └── users/
│           └── {external_user_id}/
│               ├── speech_profile.wav
│               └── samples/
│                   ├── sample_001.wav
│                   └── sample_002.wav
└── {uid}/  # Existing App user data (unchanged)
    └── speech_profile.wav
"""

import base64
import datetime
import hashlib
import json
import math
import os
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, List, Optional, Tuple

from google.cloud import storage
from google.oauth2 import service_account
from pydub import AudioSegment

# Initialize storage client lazily to avoid import errors
_storage_client = None
speech_profiles_bucket = os.getenv('BUCKET_SPEECH_PROFILES')


def _get_storage_client():
    """Get or create the GCS storage client."""
    global _storage_client
    if _storage_client is None:
        if os.environ.get('SERVICE_ACCOUNT_JSON'):
            service_account_info = json.loads(os.environ["SERVICE_ACCOUNT_JSON"])
            credentials = service_account.Credentials.from_service_account_info(service_account_info)
            _storage_client = storage.Client(credentials=credentials)
        else:
            _storage_client = storage.Client()
    return _storage_client


def _get_developer_profile_path(developer_id: str, external_user_id: str) -> str:
    """Get GCS path for developer user's speech profile."""
    return f'developers/{developer_id}/users/{external_user_id}/speech_profile.wav'


def _get_developer_samples_prefix(developer_id: str, external_user_id: str) -> str:
    """Get GCS prefix for developer user's additional samples."""
    return f'developers/{developer_id}/users/{external_user_id}/samples/'


def _get_developer_people_prefix(developer_id: str, external_user_id: str) -> str:
    """Get GCS prefix holding one folder of samples per enrolled person."""
    return f'developers/{developer_id}/users/{external_user_id}/people_profiles/'


def _get_developer_revoked_prefix(developer_id: str, external_user_id: str) -> str:
    """Where samples go when the user takes back the tag that produced them.

    ⚠️ **This must stay a SIBLING of the two prefixes above, never a
    subdirectory of them.** Both readers list by prefix and derive identity from
    the path — ``download_developer_people_for_identification`` does
    ``rest.split('/', 1)[0]`` — so a sample parked at
    ``people_profiles/{pid}/revoked/x.wav`` is still read back as one of that
    person's samples, and the revocation silently does nothing. Note also that
    ``revoked_samples/`` is not a string prefix of ``samples/``, so the user's
    own profile listing skips it for the same reason.
    """
    return f'developers/{developer_id}/users/{external_user_id}/revoked_samples/'


def _get_signed_url(blob, minutes: int) -> str:
    """Generate a signed URL for blob access."""
    return blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=minutes),
        method="GET"
    )


# ******************************************************
# ************** SPEECH PROFILE CRUD *******************
# ******************************************************

def upload_developer_speech_profile(
    developer_id: str,
    external_user_id: str,
    audio_bytes: bytes
) -> Dict:
    """
    Upload a speech profile for a developer's user.

    Args:
        developer_id: Developer ID
        external_user_id: External user identifier
        audio_bytes: WAV audio data (16kHz, mono)

    Returns:
        Dict with profile_url, duration_seconds
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    path = _get_developer_profile_path(developer_id, external_user_id)
    blob = bucket.blob(path)

    # Upload the audio
    blob.upload_from_string(audio_bytes, content_type='audio/wav')

    # Calculate duration using pydub
    import io
    audio = AudioSegment.from_file(io.BytesIO(audio_bytes), format='wav')
    duration_seconds = audio.duration_seconds

    # Generate signed URL for response
    signed_url = _get_signed_url(blob, 60)

    return {
        'profile_url': signed_url,
        'duration_seconds': duration_seconds,
        'gcs_path': path,
    }


def get_developer_speech_profile(
    developer_id: str,
    external_user_id: str
) -> Optional[Dict]:
    """
    Get speech profile info for a developer's user.

    Args:
        developer_id: Developer ID
        external_user_id: External user identifier

    Returns:
        Dict with has_profile, profile_url, created_at, duration_seconds, samples_count
        or None if no profile exists
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    path = _get_developer_profile_path(developer_id, external_user_id)
    blob = bucket.blob(path)

    if not blob.exists():
        return None

    # Reload to get metadata
    blob.reload()

    # Get samples count
    samples_prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    samples = list(bucket.list_blobs(prefix=samples_prefix))
    samples_count = len(samples)

    return {
        'has_profile': True,
        'profile_url': _get_signed_url(blob, 60),
        'created_at': blob.time_created.isoformat() if blob.time_created else None,
        'duration_seconds': None,  # Would need to download to calculate
        'samples_count': samples_count,
    }


def developer_has_speech_profile(
    developer_id: str,
    external_user_id: str
) -> bool:
    """Check if a developer's user has a speech profile."""
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    path = _get_developer_profile_path(developer_id, external_user_id)
    blob = bucket.blob(path)
    return blob.exists()


def delete_developer_speech_profile(
    developer_id: str,
    external_user_id: str
) -> bool:
    """
    Delete speech profile and all samples for a developer's user.

    Returns:
        True if profile was deleted, False if it didn't exist
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)

    # Delete main profile
    profile_path = _get_developer_profile_path(developer_id, external_user_id)
    profile_blob = bucket.blob(profile_path)
    profile_existed = profile_blob.exists()

    if profile_existed:
        profile_blob.delete()

    # Delete all samples
    samples_prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    blobs = bucket.list_blobs(prefix=samples_prefix)
    for blob in blobs:
        blob.delete()

    return profile_existed


# ******************************************************
# ************** SAMPLE MANAGEMENT *********************
# ******************************************************

def upload_developer_sample(
    developer_id: str,
    external_user_id: str,
    audio_bytes: bytes,
    metadata: Optional[Dict[str, str]] = None,
) -> Dict:
    """
    Upload an additional speech sample for a developer's user.

    Args:
        developer_id: Developer ID
        external_user_id: External user identifier
        audio_bytes: WAV audio data (16kHz, mono)
        metadata: Provenance for this sample — build it with
            ``sample_provenance``. Omitting it makes the sample unrevokable; see
            that function for why the mapping cannot be reconstructed later.

    Returns:
        Dict with sample_id, sample_url, duration_seconds
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    sample_id = str(uuid.uuid4())[:8]
    prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    path = f'{prefix}sample_{sample_id}.wav'
    blob = bucket.blob(path)
    if metadata:
        blob.metadata = metadata

    # Upload the audio
    blob.upload_from_string(audio_bytes, content_type='audio/wav')

    # Calculate duration
    import io
    audio = AudioSegment.from_file(io.BytesIO(audio_bytes), format='wav')
    duration_seconds = audio.duration_seconds

    return {
        'sample_id': sample_id,
        'sample_url': _get_signed_url(blob, 60),
        'duration_seconds': duration_seconds,
    }


def find_duplicate_sample(
    developer_id: str,
    external_user_id: str,
    audio_bytes: bytes,
    person_id: Optional[str] = None,
) -> Optional[str]:
    """Name of an already-stored sample byte-identical to ``audio_bytes``, if any.

    Collection is triggered per assignment call, and the same assignment can arrive
    more than once — a retried request, a double tap, three threads started for one
    conversation. Nothing downstream notices: each upload gets a fresh
    ``{uuid[:8]}.wav``, so N copies of one recording become N "separate" enrolment
    clips. They then count N times toward the reference budget and N times toward
    the centroid weight, which is the one thing averaging embeddings is supposed to
    prevent — a single recording deciding the voiceprint.

    Found in production: person ``ee723de2`` held three blobs with an identical
    md5, all uploaded within the same second, alongside a fourth genuine recording.

    Compared on GCS's own md5 rather than by re-downloading: the hash is already in
    the listing, so this costs one prefix listing and no bytes.
    """
    digest = base64.b64encode(hashlib.md5(audio_bytes).digest()).decode()
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    if person_id:
        prefix = f'{_get_developer_people_prefix(developer_id, external_user_id)}{person_id}/'
    else:
        prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    for blob in bucket.list_blobs(prefix=prefix):
        if blob.name.endswith('.wav') and blob.md5_hash == digest:
            return blob.name
    return None


def download_developer_anchor(
    developer_id: str,
    external_user_id: str,
    temp_dir: str = '_temp',
) -> Optional[str]:
    """Download just the onboarding recording. Caller must delete the path.

    Separate from ``download_developer_profile_parts`` because the screening caller
    wants ONLY the anchor: pulling the collected clips too would fetch up to
    ``MAX_PROFILE_CLIPS`` blobs it will not look at, and — worse — would judge new
    audio against a reference that already contains unscreened samples.
    """
    os.makedirs(temp_dir, exist_ok=True)
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    blob = bucket.blob(_get_developer_profile_path(developer_id, external_user_id))
    if not blob.exists():
        return None
    path = f'{temp_dir}/anchor_{developer_id}_{external_user_id}_{uuid.uuid4().hex[:8]}.wav'
    try:
        blob.download_to_filename(path)
    except Exception as e:
        print(f'[SPEECH_PROFILE] Could not download anchor for {external_user_id}: {e}')
        try:
            os.remove(path)
        except OSError:
            pass
        return None
    return path


def list_developer_samples(
    developer_id: str,
    external_user_id: str
) -> List[Dict]:
    """
    List all additional speech samples for a developer's user.

    Returns:
        List of dicts with sample_id, sample_url, created_at
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    blobs = bucket.list_blobs(prefix=prefix)

    samples = []
    for blob in blobs:
        # Extract sample_id from filename (sample_xxxxxxxx.wav)
        filename = blob.name.split('/')[-1]
        if filename.startswith('sample_') and filename.endswith('.wav'):
            sample_id = filename[7:-4]  # Remove 'sample_' prefix and '.wav' suffix
            samples.append({
                'sample_id': sample_id,
                'sample_url': _get_signed_url(blob, 60),
                'created_at': blob.time_created.isoformat() if blob.time_created else None,
            })

    return samples


def delete_developer_sample(
    developer_id: str,
    external_user_id: str,
    sample_id: str
) -> bool:
    """
    Delete a specific speech sample.

    Returns:
        True if sample was deleted, False if it didn't exist
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    path = f'{prefix}sample_{sample_id}.wav'
    blob = bucket.blob(path)

    if blob.exists():
        blob.delete()
        return True
    return False


# ******************************************************
# ******* SAMPLE PROVENANCE & REVOCATION ***************
# ******************************************************

# Longest ``segment_ids`` value we will write. GCS caps custom metadata at 8 KiB
# of keys+values per object, and one upload can merge up to
# MAX_SAMPLE_DURATION/MIN_CLIP_DURATION clips, so the list is bounded in practice
# (~60 uuids, ~2.2 KB) — this only exists so lowering the clip floor cannot start
# failing uploads with a 400 from GCS.
MAX_SEGMENT_IDS_BYTES = 6000


def sample_provenance(
    *,
    source: str,
    assign_type: str,
    target_id: str,
    conversation_id: str,
    segment_ids: List[str],
    duration_seconds: float,
    net_speech_seconds: Optional[float] = None,
    anchor_cos: Optional[float] = None,
) -> Dict[str, str]:
    """Build the custom blob metadata that makes a sample revokable.

    A collected sample is otherwise anonymous: the object name is a bare
    ``{uuid[:8]}.wav``, one upload merges several transcript segments into a
    single wav, and neither the segment (which persists only ``is_user`` /
    ``person_id`` / ``speaker_status``) nor the blob records where the audio came
    from. So when the user later takes the tag back — the retraction of exactly
    the confirmation that enrolled this audio — there is nothing to match on.

    That mapping is **not recoverable after the fact**: the segments have already
    been overwritten with the new (or empty) owner by the time the retraction
    reaches us. It has to be written at collection time or not at all, which is
    why samples uploaded before this existed can never be revoked automatically.

    Values are all strings because GCS custom metadata is a string→string map.
    """
    joined = ','.join(s for s in segment_ids if s)
    complete = True
    if len(joined.encode()) > MAX_SEGMENT_IDS_BYTES:
        kept = []
        used = 0
        for sid in (s for s in segment_ids if s):
            cost = len(sid.encode()) + 1
            if used + cost > MAX_SEGMENT_IDS_BYTES:
                break
            kept.append(sid)
            used += cost
        joined = ','.join(kept)
        complete = False
        print(
            f'[SPEECH_PROFILE] Provenance for {conversation_id} lists '
            f'{len(kept)}/{len(segment_ids)} segments (metadata size cap) — '
            f'revocation may miss this sample'
        )
    md = {
        'source': source,
        'assign_type': assign_type,
        'target_id': target_id or '',
        'conversation_id': conversation_id or '',
        'segment_ids': joined,
        'segment_ids_complete': '1' if complete else '0',
        'duration_seconds': f'{duration_seconds:.2f}',
        'collected_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if net_speech_seconds is not None:
        md['net_speech_seconds'] = f'{net_speech_seconds:.2f}'
    if anchor_cos is not None:
        # Recorded at collection time because that is the only moment it is cheap:
        # afterwards, answering "was this ever screened, and how well did it score?"
        # for one sample costs downloading two wavs and two GPU encodes. Auditing a
        # whole corpus without it (39 samples, one account) is a 40-file embed run.
        # Absent on samples collected before screening existed, which is itself the
        # signal that they were never checked.
        md['anchor_cos'] = f'{anchor_cos:.4f}'
    return md


def revoke_samples_from_segments(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    segment_ids: List[str],
    keep_target: Optional[Tuple[str, str]] = None,
    reason: str = 'unassigned',
    chapter_operation_id: Optional[str] = None,
    revoked_samples: Optional[List[Dict]] = None,
    strict: bool = False,
) -> List[Dict]:
    """Quarantine every sample that was enrolled from ``segment_ids``.

    Called when a manual speaker tag is withdrawn or changed. The tag was the
    only reason the audio was enrolled, so withdrawing it should withdraw the
    audio — otherwise "I marked this wrong" leaves the wrong voiceprint in place
    and the same mis-identification comes back on the next conversation.

    **Moved, not deleted.** A cancel can itself be a mis-tap, and this audio is
    unrecoverable once gone (the source recording is trimmed and eventually aged
    out). The blob keeps its original provenance plus ``revoked_at`` /
    ``revoked_reason`` / ``original_path``, so restoring one is a copy back.

    ``keep_target`` is the identity being confirmed right now, as
    ``(assign_type, target_id)``. Samples already filed under it are left alone:
    re-confirming the same person must not throw away their enrolment. Pass None
    when clearing the speaker entirely.

    Samples with no provenance (uploaded before ``sample_provenance`` existed) are
    skipped, on purpose — attributing them is guesswork, and deleting audio the
    user tagged correctly is worse than leaving a stale sample the anchor
    screening in ``download_developer_people_for_identification`` can still
    reject.

    Returns one dict per revoked sample, with the ``assign_type`` / ``target_id``
    / ``duration_seconds`` the caller needs to correct the tracked totals.
    If supplied, ``revoked_samples`` receives each successful removal before
    proceeding. Strict chapter callers can account for that progress even if a
    later copy, delete, or listing fails and the operation must be retried.
    ``strict`` also applies this behavior across operations, when chapter learning
    must retract contradictory samples enrolled from another entry point first.
    """
    wanted = {s for s in (segment_ids or []) if s}
    if not conversation_id or not wanted:
        return []

    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    quarantine = _get_developer_revoked_prefix(developer_id, external_user_id)
    revoked = revoked_samples if revoked_samples is not None else []

    for prefix in (
        _get_developer_people_prefix(developer_id, external_user_id),
        _get_developer_samples_prefix(developer_id, external_user_id),
    ):
        for blob in bucket.list_blobs(prefix=prefix):
            if not blob.name.endswith('.wav'):
                continue
            md = blob.metadata or {}
            if chapter_operation_id and md.get('chapter_operation_id') != chapter_operation_id:
                continue
            if md.get('conversation_id') != conversation_id:
                continue
            recorded = {s for s in (md.get('segment_ids') or '').split(',') if s}
            if not recorded & wanted:
                continue
            assign_type = md.get('assign_type') or 'unknown'
            target_id = md.get('target_id') or 'unknown'
            if keep_target is not None and (assign_type, target_id) == keep_target:
                continue

            filename = blob.name.split('/')[-1]
            dest = f'{quarantine}{assign_type}/{target_id}/{conversation_id}/{filename}'
            try:
                new_blob = bucket.copy_blob(blob, bucket, dest)
                new_md = dict(md)
                new_md.update({
                    'revoked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    'revoked_reason': reason,
                    'original_path': blob.name,
                })
                new_blob.metadata = new_md
                new_blob.patch()
                # Delete only after the copy is safely in place, so a failure
                # here leaves a duplicate (harmless, the original is gone from
                # the read path) rather than losing the audio.
                blob.delete()
            except Exception as e:
                print(f'[SPEECH_PROFILE] Could not revoke {blob.name}: {e}')
                if chapter_operation_id or strict:
                    raise
                continue

            try:
                duration = float(md.get('duration_seconds') or 0.0)
            except ValueError:
                duration = 0.0
            revoked.append({
                'sample_id': filename[:-4],
                'assign_type': assign_type,
                'target_id': target_id,
                'duration_seconds': duration,
                'original_path': blob.name,
                'quarantined_to': dest,
            })

    if revoked:
        print(
            f'[SPEECH_PROFILE] Revoked {len(revoked)} sample(s) for '
            f'{external_user_id} ({reason}): '
            + ', '.join(f"{r['assign_type']}:{r['target_id']}" for r in revoked)
        )
    return revoked


# ******************************************************
# ************** SPEAKER IDENTIFICATION ****************
# ******************************************************

def download_developer_profile_for_identification(
    developer_id: str,
    external_user_id: str,
    temp_dir: str = '_temp'
) -> Optional[str]:
    """
    Download speech profile for speaker identification.
    Combines the onboarding recording with a bounded amount of extra samples.

    The onboarding recording always leads and is never dropped: the user made it
    alone and on purpose, so it is the only audio we know belongs to them. Extra
    samples were collected from taps of "this is me" in real conversations, which
    is far less reliable — a mis-mapped timestamp files a bystander's voice under
    the user (production data has samples scoring cos<0.1 against the same user's
    onboarding recording, i.e. plainly a different person).

    Two bounds keep a bad sample from taking the profile over:

    * The onboarding audio must stay a MAJORITY of the reference, so no amount of
      collected audio can outvote it. Concatenating 57 unscreened samples onto a
      47s anchor is how this profile stopped matching its own owner.
    * Newest samples first — a stale voice matters less than the current one.

    Prefer ``download_developer_profile_parts``: it keeps the anchor and each
    sample separate so the model can screen and weight them individually, rather
    than gluing them into one waveform where a bad sample is indistinguishable
    from a good one. This function remains for callers that need a single file.

    Args:
        developer_id: Developer ID
        external_user_id: External user identifier
        temp_dir: Directory for temporary files

    Returns:
        Path to combined audio file, or None if no profile exists
    """
    # ⚠️ This caller MUST pass share_of_anchor. It glues the parts into one
    # waveform, so the model sees a single reference and its ANCHOR_WEIGHT_FLOOR
    # never applies — total seconds is the only thing left holding the anchor's
    # majority. Dropping this argument would not fail any import or raise: it would
    # quietly let collected audio outweigh the onboarding recording, which is the
    # exact failure ("this profile stopped matching its own owner") documented
    # above.
    anchor_path, clip_paths = download_developer_profile_parts(
        developer_id, external_user_id, temp_dir,
        share_of_anchor=MAX_SAMPLE_SHARE_OF_PROFILE,
    )
    if not anchor_path:
        return None

    # Every downloaded part must be deleted on EVERY exit, including the ones that
    # raise. A corrupt anchor makes `from_wav` throw before the loop below is
    # reached, which used to leak the anchor plus all N clips into temp_dir — on a
    # long-lived container that is unbounded disk growth for the one user whose
    # profile is broken, i.e. it repeats on every conversation they record.
    def _discard(path):
        try:
            os.remove(path)
        except OSError:
            pass

    try:
        combined = AudioSegment.from_wav(anchor_path)
        for path in clip_paths:
            try:
                combined += AudioSegment.from_wav(path)
            except Exception as e:
                print(f'[SPEECH_PROFILE] Skipping unreadable sample {path}: {e}')

        combined_path = f'{temp_dir}/{developer_id}_{external_user_id}_complete.wav'
        combined.export(combined_path, format='wav')
        return combined_path
    except Exception as e:
        print(
            f'[SPEECH_PROFILE] Could not assemble profile for {external_user_id}: {e}'
        )
        return None
    finally:
        _discard(anchor_path)
        for path in clip_paths:
            _discard(path)


def download_developer_profile_parts(
    developer_id: str,
    external_user_id: str,
    temp_dir: str = '_temp',
    share_of_anchor: Optional[float] = None,
) -> Tuple[Optional[str], List[str]]:
    """Return ``(anchor_path, clip_paths)`` for the user's own voiceprint.

    Kept as separate files on purpose. One embedding per clip lets the model drop
    a clip that does not sound like the anchor and weight the rest by how much
    speech they carry — neither is possible once the audio is concatenated, where
    a bystander's 30 seconds is just more waveform. Callers must delete every
    returned path.

    ``share_of_anchor`` caps the SUM of the clips at that multiple of the anchor's
    length. It exists for exactly one caller —
    ``download_developer_profile_for_identification``, which concatenates the parts
    into a single waveform, where total seconds is the only thing keeping the
    anchor dominant. **Leave it None for the parts path**: there the model enforces
    ``ANCHOR_WEIGHT_FLOOR`` on the centroid regardless of how many seconds arrive,
    so a summed ceiling adds no protection and does real harm — at
    ``MAX_SAMPLE_SHARE_OF_PROFILE = 0.5`` a 47.3s anchor yields a 23.6s budget,
    which at 10s per clip is 2.4 clips, making ``MAX_PROFILE_CLIPS = 8``
    unreachable by construction. Measured on production audio for the account that
    prompted this: 3 of 39 samples were ever sent, and 13.6s of the 23.6s went to
    two clips the model then rejected as a different voice.
    """
    os.makedirs(temp_dir, exist_ok=True)
    bucket = _get_storage_client().bucket(speech_profiles_bucket)

    profile_blob = bucket.blob(_get_developer_profile_path(developer_id, external_user_id))
    if not profile_blob.exists():
        return None, []

    anchor_file = f'{temp_dir}/{developer_id}_{external_user_id}_profile.wav'
    profile_blob.download_to_filename(anchor_file)
    # A corrupt or truncated anchor download must not leave the file behind, and
    # must not raise: every caller treats a missing profile as "skip identification
    # for this conversation", whereas an exception propagates into the WS
    # auto-process thread and kills the whole background task.
    try:
        anchor_seconds = AudioSegment.from_wav(anchor_file).duration_seconds
    except Exception as e:
        print(f'[SPEECH_PROFILE] Unreadable profile for {external_user_id}: {e}')
        try:
            os.remove(anchor_file)
        except OSError:
            pass
        return None, []

    # Newest samples first: they reflect how the user sounds now, and the budget
    # below has to fall on somebody.
    samples_prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    sample_blobs = [b for b in bucket.list_blobs(prefix=samples_prefix) if b.name.endswith('.wav')]
    # tz-aware sentinel: blob.updated is tz-aware, and comparing it against a
    # naive datetime raises TypeError mid-sort.
    _oldest = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    sample_blobs.sort(key=lambda b: b.updated or _oldest, reverse=True)

    # Downloaded lazily rather than all at once: this user has 39 samples and the
    # count cap admits 8, so eagerly fetching every blob just to learn its duration
    # would be 31 wasted round-trips on every conversation.
    seconds_budget = (
        anchor_seconds * share_of_anchor if share_of_anchor is not None else None
    )
    clip_paths: List[str] = []
    used = 0.0
    for blob in sample_blobs:
        if len(clip_paths) >= MAX_PROFILE_CLIPS:
            break
        if seconds_budget is not None and used >= seconds_budget:
            break
        sample_file = f'{temp_dir}/{developer_id}_{external_user_id}_{blob.name.split("/")[-1]}'
        try:
            blob.download_to_filename(sample_file)
            sample_audio = AudioSegment.from_wav(sample_file)
        except Exception as e:
            print(f'[SPEECH_PROFILE] Skipping unreadable sample {blob.name}: {e}')
            try:
                os.remove(sample_file)
            except OSError:
                pass
            continue
        # One clip at a time, but through the shared allocator, so this path and the
        # people path cannot drift apart again — they had the same off-by-one-loop
        # bug independently.
        take = allocate_clip_seconds(
            [sample_audio.duration_seconds],
            max_clips=1,
            seconds_budget=None if seconds_budget is None else seconds_budget - used,
        )[0]
        if take <= 0:
            try:
                os.remove(sample_file)
            except OSError:
                pass
            continue
        take_ms = int(take * 1000)
        if take_ms < len(sample_audio):
            sample_audio[:take_ms].export(sample_file, format='wav')
        clip_paths.append(sample_file)
        used += take

    if len(sample_blobs) > len(clip_paths):
        caps = f'{MAX_PROFILE_CLIPS} clips x {WEIGHT_SATURATION_SECONDS:.0f}s'
        if seconds_budget is not None:
            caps += f', {seconds_budget:.0f}s total'
        print(
            f'[SPEECH_PROFILE] Profile for {external_user_id}: anchor {anchor_seconds:.0f}s '
            f'+ {used:.0f}s from {len(clip_paths)}/{len(sample_blobs)} samples '
            f'(caps: {caps})'
        )
    return anchor_file, clip_paths


# People whose voiceprint participates in a single match. Each one costs a GCS
# fetch plus a GPU embedding, and accuracy *drops* as the candidate set grows
# (Speechmatics caps identifiers at 50 and advises "minimize the number of
# speaker IDs to achieve optimal accuracy"). Best-enrolled people go first.
MAX_PEOPLE_FOR_MATCHING = int(os.getenv('SPEECH_PROFILE_MAX_PEOPLE', '10'))
# Clips per person pulled into the reference. Beyond this the extra audio is
# past the point where embeddings improve and only adds latency.
MAX_SAMPLES_PER_PERSON = 8
# Extra reference audio per person BEYOND their anchor, in seconds.
#
# ⚠️ **This used to include the anchor, and that made it a no-op cap that silently
# discarded every enrolment after the first.** The check sat at the top of the loop
# against a total that already held the whole previous clip, so the anchor (the
# person's longest recording, routinely 50-100s) blew straight past 30s on
# iteration 1 and every other clip was dropped. Production proof: the
# ``People references: {id}={n}s`` log line reported 84.2s for a person holding
# 84.2+56.7+56.7+56.7s, and 57.5s for one holding 57.5+36.1+31.6s — every figure
# exactly one recording. "I tagged this person a dozen times and they are still
# never recognized" was that, not a model limitation.
#
# It now bounds only the clips that ride ALONGSIDE the anchor, which is the
# quantity a budget can sensibly cap: the anchor is sent whole (its embedding is
# better the more audio it averages, and ``_anchor_weight`` does not scale with its
# length, so truncating it would cost accuracy for nothing).
#
# 30s (3 clips at WEIGHT_SATURATION_SECONDS) is a 3x improvement on the one clip the
# broken cap allowed, and **cost is not what bounds it** — measured with
# scripts/bench_speaker_identification_cost.py on the real hosted endpoint,
# 10 enrolled people at 8 clips each (99 GPU encodes) runs 11.5s median against a
# 6.6s floor: +4.9s per conversation, ~$24/month at 1000 conversations/day, and far
# under the caller's 120s timeout. What bounds it is evidence: pyannoteAI's
# "<=30s per voiceprint" is the only external guidance we have, and nothing here has
# yet shown clips 4-8 buy accuracy for a person. Raising it is affordable; do it with
# an eval, not by intuition.
MAX_PERSON_REFERENCE_SECONDS = float(os.getenv('SPEECH_PROFILE_PERSON_CLIP_SECONDS', '30'))
# A person needs at least this much enrolled speech before their voiceprint is
# allowed to claim a speaker. Under-enrolled references produce unstable
# embeddings, and a false "that was your mother" is much worse than leaving the
# speaker unlabelled. Industry anchors sit at 10-30s of net speech; our clips are
# transcript segments (speech-dense, little silence), so 8s is the floor here.
MIN_PERSON_REFERENCE_SECONDS = float(os.getenv('SPEECH_PROFILE_MIN_PERSON_SECONDS', '8'))
# How much collected "this is me" audio may be added to the user's own profile,
# as a multiple of the onboarding recording's length. Below 1.0 the anchor stays
# the majority of the reference, so unscreened samples can shift the embedding but
# never define it. See download_developer_profile_for_identification.
MAX_SAMPLE_SHARE_OF_PROFILE = float(os.getenv('SPEECH_PROFILE_MAX_SAMPLE_SHARE', '0.5'))
# Separate clips sent per identity, newest first. Each one costs a GCS fetch, a
# ~320KB upload part and a ~30ms GPU encode, so this bounds request size and
# latency as enrolment history grows.
# ⚠️ It is also what lets labelling keep helping. The model weights each clip by
# its agreement with the others (`_consensus_centroid`), so a bad clip fades as
# genuine ones accumulate — but only among clips that are actually sent. At 8, the
# ninth label pushed the oldest one out instead of outvoting a bad one (2026-11-04).
MAX_PROFILE_CLIPS = int(os.getenv('SPEECH_PROFILE_MAX_CLIPS', '24'))
# Mirrors CAMPPLUS_WEIGHT_SATURATION in modal/speech_profile_modal_campplus.py.
# The hosted model weights a clip by min(seconds, saturation)/saturation, so
# seconds taken from one clip beyond this point carry NO additional weight. They
# do still consume the shared budget below, which is why the cap matters here:
# spending budget past saturation on a single clip is provably wasted audio.
# Kept as its own constant rather than imported — this module must not depend on
# the Modal runtime — so the two have to be changed together.
WEIGHT_SATURATION_SECONDS = float(os.getenv('CAMPPLUS_WEIGHT_SATURATION', '10'))


def _download_blob_to(blob, dest: str) -> Optional[str]:
    try:
        blob.download_to_filename(dest)
        return dest
    except Exception as e:
        print(f'[SPEECH_PROFILE] Failed to download {blob.name}: {e}')
        return None


def allocate_clip_seconds(
    clip_seconds: List[float],
    *,
    max_clips: int,
    seconds_budget: Optional[float] = None,
    saturation: float = None,
) -> List[float]:
    """Seconds to take from each candidate clip, in order. ``0.0`` = do not send.

    Both identity paths (the user's own samples and each enrolled person's extra
    recordings) need the same allocation, and they had **the same bug written
    twice**: a running total compared against the cap at the top of the loop, which
    lets the FIRST clip through at any length and then starves every clip after
    it. On the user's path that produced 1 clip out of 64; on the people path it
    produced exactly one clip per person forever — verified in production, where
    every ``People references: {id}={n}s`` figure equalled that person's single
    longest recording. So the allocation lives here once, and both callers use it.

    Two independent bounds, and they answer different questions:

    * ``max_clips`` — how many separate recordings to average. Each costs a GCS
      fetch, an upload part and a GPU encode, so this is what keeps request size
      from growing with enrolment history.
    * ``seconds_budget`` — a ceiling on the SUM. Only meaningful for a caller that
      concatenates the parts into one waveform, where total seconds is the only
      thing holding the anchor's share. Pass ``None`` when the parts travel
      separately: the model then enforces ``ANCHOR_WEIGHT_FLOOR`` on the centroid
      itself, so a summed ceiling here is redundant — and, being redundant, it
      silently made ``max_clips`` unreachable (a 47.3s anchor gives a 23.6s budget,
      which at 10s per clip is 2.4 clips, so ``MAX_PROFILE_CLIPS = 8`` could never
      bind).

    ``saturation`` caps each clip individually at the point where the model stops
    weighting extra seconds (``min(seconds, saturation)/saturation``). Seconds past
    it buy no weight, so spending budget on them is provably wasted audio.
    """
    if saturation is None:
        saturation = WEIGHT_SATURATION_SECONDS
    takes: List[float] = []
    used = 0.0
    for seconds in clip_seconds:
        if len(takes) >= max_clips:
            # Not `break`: the return value is positionally aligned with the input
            # so callers can zip it back onto their blobs/paths.
            takes.append(0.0)
            continue
        room = saturation
        if seconds_budget is not None:
            room = min(room, seconds_budget - used)
        take = min(seconds, room)
        if take <= 0:
            takes.append(0.0)
            continue
        takes.append(take)
        used += take
    return takes


def download_developer_people_for_identification(
    developer_id: str,
    external_user_id: str,
    person_ids: Optional[List[str]] = None,
    temp_dir: str = '_temp',
) -> List[Dict]:
    """Assemble reference audio for the user's enrolled people.

    Returns ``[{'id', 'path', 'seconds', 'clip_paths'}, ...]`` for every person
    with enough enrolled speech, capped at ``MAX_PEOPLE_FOR_MATCHING``. ``path``
    is the person's longest clip — their anchor — and ``clip_paths`` holds their
    remaining clips as separate files so the model can screen each one against
    that anchor. Callers must delete ``path`` and every ``clip_paths`` entry.

    Unlike the user, a person has no recording made under controlled conditions;
    every clip came from a conversation. The longest one is the best available
    anchor (most speech, most likely to be the person the user was tagging), and
    a clip that disagrees with it is dropped rather than averaged in.

    These samples have been collected server-side since day one (every time the
    user tags "this is Alice" the matching clip is filed under
    ``people_profiles/{person_id}/``) but never reached the model, so a person the
    user had tagged a dozen times still had to be tagged again in the next
    conversation. This is what makes them recognizable.
    """
    os.makedirs(temp_dir, exist_ok=True)
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    base = _get_developer_people_prefix(developer_id, external_user_id)

    # One prefix listing for every person beats one call per person.
    by_person: Dict[str, List] = {}
    for blob in bucket.list_blobs(prefix=base):
        rest = blob.name[len(base):]
        if '/' not in rest or not rest.endswith('.wav'):
            continue
        pid = rest.split('/', 1)[0]
        if person_ids is not None and pid not in person_ids:
            continue
        by_person.setdefault(pid, []).append(blob)

    if not by_person:
        return []

    # Prefer people with the most enrolled audio: they have the most stable
    # embedding, and the cap has to fall on somebody.
    ordered = sorted(
        by_person.items(),
        key=lambda kv: sum(b.size or 0 for b in kv[1]),
        reverse=True,
    )

    people: List[Dict] = []
    skipped_short: List[str] = []
    skipped_capped: List[str] = []
    for pid, blobs in ordered:
        if len(people) >= MAX_PEOPLE_FOR_MATCHING:
            # Name them, do not just count them. A capped-out person is
            # indistinguishable from an unenrolled one from the app's side ("why is
            # my mother never recognized any more?"), and which people fall off the
            # end shifts with their byte totals, so a bare count cannot answer it.
            skipped_capped.append(pid)
            continue
        # Biggest blobs first: the longest clips carry the speaker's stable
        # speech, short interjections dilute it. The first one becomes the anchor.
        #
        # Fetch only what the allocation below can actually use — anchor + however
        # many saturated clips fit the budget — plus one spare to absorb a single
        # unreadable file. Downloading MAX_SAMPLES_PER_PERSON regardless meant 8
        # fetches per person to use 4, once per conversation, for every enrolled
        # person.
        usable_clips = min(
            MAX_PROFILE_CLIPS,
            math.ceil(MAX_PERSON_REFERENCE_SECONDS / max(WEIGHT_SATURATION_SECONDS, 1e-9)),
        )
        blobs = sorted(blobs, key=lambda b: b.size or 0, reverse=True)[
            : min(MAX_SAMPLES_PER_PERSON, usable_clips + 2)
        ]
        local_paths = []
        with ThreadPoolExecutor(max_workers=min(4, len(blobs))) as pool:
            futures = [
                pool.submit(
                    _download_blob_to,
                    blob,
                    f'{temp_dir}/person_{developer_id}_{pid}_{i}.wav',
                )
                for i, blob in enumerate(blobs)
            ]
            # Keep download order = blob order, so index 0 stays the longest clip.
            for fut in futures:
                path = fut.result()
                if path:
                    local_paths.append(path)

        readable: List[Tuple[str, float]] = []
        for path in local_paths:
            try:
                readable.append((path, AudioSegment.from_wav(path).duration_seconds))
            except Exception as e:
                print(f'[SPEECH_PROFILE] Skipping unreadable sample {path}: {e}')
                try:
                    os.remove(path)
                except OSError:
                    pass

        def _discard(path):
            try:
                os.remove(path)
            except OSError:
                pass

        if not readable:
            skipped_short.append(pid)
            continue

        # The anchor goes whole (see MAX_PERSON_REFERENCE_SECONDS). Only the clips
        # riding alongside it are allocated, through the same function the user's
        # own samples use — the two paths held the same bug independently, so they
        # now share one implementation of the arithmetic.
        anchor_path, anchor_seconds = readable[0]
        rest = readable[1:]
        takes = allocate_clip_seconds(
            [seconds for _p, seconds in rest],
            max_clips=MAX_PROFILE_CLIPS,
            seconds_budget=MAX_PERSON_REFERENCE_SECONDS,
        )
        clip_paths, clip_seconds = [], 0.0
        for (path, seconds), take in zip(rest, takes):
            if take <= 0:
                _discard(path)
                continue
            if take < seconds:
                # Truncate in place: seconds past saturation buy no weight but do
                # cost an upload part and an encode.
                try:
                    AudioSegment.from_wav(path)[: int(take * 1000)].export(
                        path, format='wav'
                    )
                except Exception as e:
                    print(f'[SPEECH_PROFILE] Could not truncate {path}: {e}')
                    _discard(path)
                    continue
            clip_paths.append(path)
            clip_seconds += take

        total_seconds = anchor_seconds + clip_seconds
        if total_seconds < MIN_PERSON_REFERENCE_SECONDS:
            skipped_short.append(pid)
            _discard(anchor_path)
            for path in clip_paths:
                _discard(path)
            continue

        people.append({
            'id': pid,
            'path': anchor_path,
            'clip_paths': clip_paths,
            'seconds': total_seconds,
            'anchor_seconds': anchor_seconds,
            'clip_count': len(clip_paths),
        })

    if skipped_short:
        print(
            f'[SPEECH_PROFILE] {len(skipped_short)} people under '
            f'{MIN_PERSON_REFERENCE_SECONDS}s of enrolled speech, not matched: '
            f'{skipped_short}'
        )
    if skipped_capped:
        print(
            f'[SPEECH_PROFILE] {len(skipped_capped)} people not used for matching '
            f'(cap {MAX_PEOPLE_FOR_MATCHING}, ranked by enrolled bytes): '
            f'{skipped_capped}'
        )
    if people:
        # ⚠️ Reported as `anchor+Nclip` and not as one total on purpose. A single
        # summed figure is exactly what hid the bug above for as long as it lasted:
        # "84.2s" reads like a healthy reference, and there is no way to tell from it
        # that the person's other three recordings were thrown away. Split, a
        # regression shows up as every person sitting at `+0clip`.
        print(
            '[SPEECH_PROFILE] People references: '
            + ', '.join(
                f"{p['id']}={p['anchor_seconds']:.1f}s+{p['clip_count']}clip"
                for p in people
            )
        )
    return people


def get_profile_duration(
    developer_id: str,
    external_user_id: str
) -> float:
    """
    Calculate total duration of speech profile (main + samples).

    Returns:
        Total duration in seconds, or 0 if no profile
    """
    bucket = _get_storage_client().bucket(speech_profiles_bucket)
    total_duration = 0.0

    # Check main profile
    profile_path = _get_developer_profile_path(developer_id, external_user_id)
    profile_blob = bucket.blob(profile_path)

    if not profile_blob.exists():
        return 0.0

    # Download main profile to get duration
    import io
    profile_data = profile_blob.download_as_bytes()
    audio = AudioSegment.from_file(io.BytesIO(profile_data), format='wav')
    total_duration += audio.duration_seconds

    # Get duration of all samples
    samples_prefix = _get_developer_samples_prefix(developer_id, external_user_id)
    sample_blobs = bucket.list_blobs(prefix=samples_prefix)

    for blob in sample_blobs:
        sample_data = blob.download_as_bytes()
        sample_audio = AudioSegment.from_file(io.BytesIO(sample_data), format='wav')
        total_duration += sample_audio.duration_seconds

    return total_duration
