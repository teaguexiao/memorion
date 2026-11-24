import json
import math
import os
import shutil
import time
import uuid
from collections import defaultdict
from typing import List, Optional, Tuple

import requests
from pydub import AudioSegment

from utils.other.storage import (
    get_profile_audio_if_exists,
    get_additional_profile_recordings,
    get_user_people_ids,
    get_user_person_speech_samples,
)
from utils.stt.recording_alignment import RecordingAlignmentUnavailable, segments_on_recording_axis

# A speaker needs at least this many decided segments before a label is written,
# unless they simply do not have that many segments at all. Guards against one
# stray match on a mis-diarized fragment becoming somebody's name.
MIN_DECIDED_SEGMENTS = int(os.getenv('SPEAKER_MIN_DECIDED_SEGMENTS', '2'))

# Re-segmentation ("split") of a merged speaker. Streaming diarization sometimes
# collapses two people who sound alike (e.g. a parent and child) into a single
# speaker_id. The per-speaker vote then ties — half the segments match the user,
# half match someone else — and the whole speaker is dropped as 'ambiguous',
# which is why a real conversation can end up with no is_user segment at all.
#
# When that tie is not noise but a genuine two-person mix, honour the per-segment
# voice decisions instead of voting them into a single label. Only split when
# BOTH sides are large enough to be real speakers rather than the ~20% per-segment
# error the vote exists to smooth over: each side needs at least
# SPLIT_MIN_SEGMENTS decided segments AND at least SPLIT_MIN_SHARE of the
# speaker's decided segments. Below either bar we keep the conservative
# 'ambiguous' verdict and let the app ask the user.
SPLIT_MIN_SEGMENTS = int(os.getenv('SPEAKER_SPLIT_MIN_SEGMENTS', '3'))
SPLIT_MIN_SHARE = float(os.getenv('SPEAKER_SPLIT_MIN_SHARE', '0.3'))


# The fields the hosted model reads. Text, translations and earlier labels are
# dead weight in the request, and the endpoint rejects a form part over 1MB with a
# 400 ("Part exceeded maximum size of 1024KB."), which skips identification for the
# whole recording: an 8-hour upload's 3387 segments were 1.1MB with them and 368KB
# without (2026-10-26 in production).
_MODEL_SEGMENT_FIELDS = ('start', 'end', 'speaker', 'speaker_id')


def _segments_for_request(segments: List[dict]) -> List[dict]:
    return [{**{key: seg.get(key) for key in _MODEL_SEGMENT_FIELDS}, 'text': '', 'is_user': False}
            for seg in segments]


def _speaker_key(seg: dict) -> str:
    """Stable per-speaker key tolerant of speaker_id being int or str.

    Using ``:02d`` directly crashes with "Unknown format code 'd' for object
    of type 'str'" when speaker_id arrives as a string from the client, so we
    coerce to int first and fall back to the raw speaker label.
    """
    spk = seg.get('speaker')
    if spk:
        return str(spk)
    raw = seg.get('speaker_id', 0)
    try:
        return f"SPEAKER_{int(raw):02d}"
    except (TypeError, ValueError):
        return f"SPEAKER_{raw}"


def _split_local_speaker_labels(segments: List[dict], eligible_keys: set) -> bool:
    """Keep each client speaker group consistent with its local identity.

    Installed clients display and manually assign names by speaker_id. Leaving
    distinct owners under one diarization ID would broadcast a name again in
    that client. Unresolved rows retain their diarization ID; named owners get
    separate IDs only when a group actually contains different identities.
    """
    groups = defaultdict(list)
    max_id = 0
    for seg in segments:
        groups[_speaker_key(seg)].append(seg)
        for value in (seg.get('speaker_id'), _speaker_key(seg).split('_')[-1]):
            try:
                max_id = max(max_id, int(value))
            except (TypeError, ValueError):
                pass
    changed = False
    for key, rows in groups.items():
        if key not in eligible_keys:
            continue
        owners = defaultdict(list)
        for seg in rows:
            owner = ('user', None) if seg.get('is_user') else (
                ('person', seg['person_id']) if seg.get('person_id') else ('unresolved', None))
            owners[owner].append(seg)
        if len(owners) < 2:
            continue
        for owner, owned in owners.items():
            if owner[0] == 'unresolved':
                continue
            max_id += 1
            for seg in owned:
                seg.update(speaker_id=max_id, speaker=f'SPEAKER_{max_id:02d}')
            changed = True
    return changed


def _apply_speaker_matches(
    segments: List[dict],
    matches: List[dict],
    protected_speaker_keys: set,
    session_id: str = '',
) -> Tuple[List[dict], bool]:
    """Turn per-segment voice matches into is_user/person_id labels on segments.

    Split out from ``identify_developer_speakers`` so this pure decision logic can
    be unit-tested without the model call. Mutates ``segments`` in place and
    returns ``(segments, updated)``.

    Per-segment classification from the voice-profile model is noisy (~80%
    recall), which leaves the same speaker split between is_user true/false.
    Majority-vote at the speaker level so every segment of a given speaker gets
    one consistent label. Votes are counted only over segments the model actually
    decided. "I cannot tell" is the absence of evidence, not evidence against: an
    open-set abstention says the audio was too short, too noisy or too close to
    call, which is no reason to doubt the segments that did match. Folding
    abstentions into the negative tally meant a speaker with four confident
    matches and six abstentions got no label at all (4*2 < 10) — the model's own
    uncertainty outvoting the people it recognized. That is the shape of "I marked
    this person many times and they are still never recognized".
    """
    user_votes = defaultdict(int)     # speaker -> segments matching the user
    person_votes = defaultdict(lambda: defaultdict(int))  # speaker -> pid -> count
    decided_counts = defaultdict(int)  # speaker -> segments with any decision
    segment_counts = defaultdict(int)  # speaker -> segments seen
    # Unresolved segments, kept apart by reason: 'unknown' means nobody enrolled
    # was close enough ("who was this?"), 'ambiguous' means two enrolled
    # identities could not be separated ("was this A or B?"). The two need
    # different questions, so they are not collapsed into one counter.
    undecided = defaultdict(lambda: defaultdict(int))
    for i, seg in enumerate(segments):
        if i >= len(matches):
            continue
        if matches[i].get('scope') == 'local':
            continue  # Local audio evidence must never vote for distant sentences.
        spk = _speaker_key(seg)
        m = matches[i]
        segment_counts[spk] += 1
        outcome = m.get('decision')
        if outcome in ('unknown', 'ambiguous'):
            undecided[spk][outcome] += 1
            continue
        pid = m.get('person_id')
        if m.get('is_user'):
            user_votes[spk] += 1
            decided_counts[spk] += 1
        elif pid:
            person_votes[spk][pid] += 1
            decided_counts[spk] += 1

    speaker_decision = {}  # speaker -> ('user', None) | ('person', pid)
    # Speakers whose tie turned out to be two real people merged into one
    # diarization label. Their segments keep their own per-segment voice decision
    # instead of a single voted label (see SPLIT_MIN_* above).
    split_speakers = set()
    for spk, decided in decided_counts.items():
        if decided < min(MIN_DECIDED_SEGMENTS, segment_counts[spk]):
            # A lone match among many segments is as likely to be a diarization
            # slip as a real identification.
            continue
        yes = user_votes.get(spk, 0)
        pids = person_votes.get(spk) or {}
        ranked = sorted(pids.items(), key=lambda kv: kv[1], reverse=True)
        top_pid, top_count = ranked[0] if ranked else (None, 0)

        # Streaming diarization sometimes merges the user and one other person —
        # who sound alike — into a single speaker. That does not show up only as a
        # clean tie: an uneven split (the user speaks less than the person, or vice
        # versa) merges just the same, and the majority rule below would then hand
        # the whole speaker to the louder side and erase the other. So before any
        # winner-take-all vote, check for two substantial voices under one speaker:
        # the user AND the strongest person each holding enough decided segments to
        # be a real speaker rather than the ~20% per-segment noise the vote exists
        # to smooth. When both clear the bars, honour each segment's own decision.
        if (
            top_pid
            and yes >= SPLIT_MIN_SEGMENTS
            and top_count >= SPLIT_MIN_SEGMENTS
            and yes >= decided * SPLIT_MIN_SHARE
            and top_count >= decided * SPLIT_MIN_SHARE
        ):
            split_speakers.add(spk)
            continue

        # A tie is not a winner. max() would hand the speaker to whichever key
        # happened to come first, which is the vote-level version of the coin-flip
        # the per-segment margin already refuses to make.
        if (len(ranked) > 1 and ranked[1][1] == top_count) or (
            yes == top_count and yes > 0
        ):
            # Ask about it rather than leaving the speaker silently blank: the
            # segments themselves were decided, so 'unknown' would misdescribe what
            # happened.
            undecided[spk]['ambiguous'] += decided
            continue
        if yes > top_count:
            speaker_decision[spk] = ('user', None)
        elif top_pid and top_count * 2 >= decided:
            speaker_decision[spk] = ('person', top_pid)

    if split_speakers:
        print(
            f"[SPEECH_PROFILE] Split merged speakers for session {session_id}: "
            + ', '.join(
                f'{spk}(user={user_votes.get(spk, 0)}, '
                f'top_person={max((person_votes.get(spk) or {}).values(), default=0)})'
                for spk in split_speakers
            )
        )
    if undecided:
        print(
            f"[SPEECH_PROFILE] Unresolved speakers for session {session_id}: "
            + ', '.join(
                f'{spk}(' + ', '.join(f'{n} {why}' for why, n in reasons.items()) + ')'
                for spk, reasons in undecided.items()
            )
        )

    updated = False
    local_keys_with_evidence = set()
    for i, seg in enumerate(segments):
        spk = _speaker_key(seg)
        # Never overwrite a speaker the user manually tagged mid-recording.
        if spk in protected_speaker_keys:
            continue
        if i < len(matches) and matches[i].get('scope') == 'local':
            source = seg.get('speaker_assignment_source')
            if source == 'manual' or (source != 'auto' and (seg.get('is_user') or seg.get('person_id'))):
                continue  # Unproven legacy labels may be manual; preserve them.
            match = matches[i]
            outcome = match.get('decision')
            if outcome is None:
                continue  # An encoding/provider failure is not a new verdict.
            local_keys_with_evidence.add(spk)
            if source != 'auto':
                seg['speaker_assignment_source'] = 'auto'
                updated = True
            is_user = outcome == 'user' and bool(match.get('is_user'))
            pid = match.get('person_id') if outcome == 'person' else None
            reason = None if is_user or pid else (
                'ambiguous' if outcome == 'ambiguous' else 'unknown')
            # Protected manual speakers were skipped above. Remove a previous
            # automatic name when this same audio now fails identification.
            if (bool(seg.get('is_user')), seg.get('person_id')) != (is_user, pid):
                seg.update(is_user=is_user, person_id=pid)
                updated = True
            if reason is None:
                if seg.pop('speaker_status', None) is not None:
                    updated = True
            elif seg.get('speaker_status') != reason:
                seg['speaker_status'] = reason
                updated = True
            continue
        # Merged two-person speaker: trust this segment's own voice decision rather
        # than a single voted label. The user's segments become is_user; segments the
        # model matched to an enrolled person get that person_id; segments it could
        # not place keep their own unknown/ambiguous prompt (guessing a label would be
        # worse than an honest "Speaker N").
        if spk in split_speakers:
            m = matches[i] if i < len(matches) else {}
            decision = m.get('decision')
            if decision in (None, 'unknown', 'ambiguous'):
                # This segment abstained even though the speaker as a whole split
                # into two people. Record its own reason (or clear a stale one from
                # a previous run where this speaker resolved differently) so the app
                # never shows a prompt that no longer matches the outcome.
                reason = decision if decision in ('unknown', 'ambiguous') else None
                if seg.get('speaker_status') != reason:
                    if reason is None:
                        seg.pop('speaker_status', None)
                    else:
                        seg['speaker_status'] = reason
                    updated = True
                continue
            if seg.pop('speaker_status', None) is not None:
                updated = True
            if m.get('is_user'):
                if not seg.get('is_user') or seg.get('person_id') is not None:
                    seg['is_user'] = True
                    seg['person_id'] = None
                    updated = True
            else:
                pid = m.get('person_id')
                if seg.get('is_user') or seg.get('person_id') != pid:
                    seg['is_user'] = False
                    seg['person_id'] = pid
                    updated = True
            continue
        decision = speaker_decision.get(spk)
        if not decision:
            # Unresolved. Record why, so the app can ask the user instead of
            # leaving "Speaker 1" on screen with no way to know it was even
            # attempted. Written onto the segment because that is what gets
            # persisted; the reason the model gave is more useful than a bare
            # "unmatched", since 'unknown' and 'ambiguous' need different
            # questions. Cleared below once a label is written, so a stale prompt
            # cannot outlive the answer.
            reasons = undecided.get(spk)
            if reasons:
                reason = max(reasons.items(), key=lambda kv: kv[1])[0]
                if seg.get('speaker_status') != reason:
                    seg['speaker_status'] = reason
                    updated = True
            continue
        kind, pid = decision
        if seg.pop('speaker_status', None) is not None:
            updated = True
        if kind == 'user':
            if not seg.get('is_user') or seg.get('person_id') is not None:
                seg['is_user'] = True
                seg['person_id'] = None
                updated = True
        else:  # person
            if seg.get('is_user') or seg.get('person_id') != pid:
                seg['is_user'] = False
                seg['person_id'] = pid
                updated = True

    updated = _split_local_speaker_labels(segments, local_keys_with_evidence) or updated
    return segments, updated


def identify_developer_speakers(
    developer_id: str,
    external_user_id: str,
    session_id: str,
    segments: List[dict],
    protected_speaker_keys: Optional[set] = None,
    audio_kept_intervals=None,
    audio_wait_attempts: int = 6,
    audio_wait_seconds: float = 5.0,
    profile_path: Optional[str] = None,
    profile_clip_paths: Optional[List[str]] = None,
    match_people: bool = True,
    audio_gcs_path: Optional[str] = None,
) -> Tuple[List[dict], bool]:
    """Identify which segments are spoken by the developer's user via voice profile.

    Downloads the user's speech profile + the conversation audio, calls the
    hosted speech-profile model, then majority-votes per speaker to set
    ``is_user`` / ``person_id`` on each segment. Mutates ``segments`` in place
    and returns ``(segments, updated)``.

    ``protected_speaker_keys`` (``_speaker_key`` values) are speakers the user
    manually tagged mid-recording — the voice vote must NOT overwrite them, or
    the manual assignment would silently revert to a wrong owner/label.

    ``audio_kept_intervals`` are the VAD intervals kept when the session audio was
    trimmed. They are REQUIRED for correctness whenever the stored wav had silence
    removed: without them the model receives timestamps that point past the end of
    the audio and classifies nothing. Falls back to the session document when not
    supplied by the caller.

    ``audio_wait_attempts`` / ``audio_wait_seconds`` bound the retry that rides out
    the audio-upload race (the wav lands only when the WS session ends, which can be
    after the conversation is processed). Pass ``audio_wait_attempts=1`` to skip it.

    ``match_people`` also compares each speaker against the voiceprints of people
    the user has tagged before, so a person tagged once is recognized in later
    conversations. Set it False to verify against the user only (cheaper: one
    fewer GCS listing and one fewer GPU embedding per enrolled person).

    ``audio_gcs_path`` overrides where the audio is fetched from. Needed for
    conversations whose audio does not live at the session path — an uploaded
    recording is stored under its conversation id, not its session id.

    Returns ``updated=False`` (segments untouched) when any prerequisite is
    missing — endpoint not configured, no profile, audio not downloadable, or
    the model errors — so callers can safely skip persistence.
    """
    protected_speaker_keys = protected_speaker_keys or set()
    # Imported here to avoid a circular import at module load time.
    from database.developer_speech_profile import (
        download_developer_profile_parts as download_dev_profile_parts,
        download_developer_people_for_identification as download_dev_people,
    )
    from utils.other.storage import (
        get_conversation_recording_if_exists,
        download_recording_from_path,
    )

    if not segments:
        return segments, False

    endpoint_url = os.getenv('HOSTED_SPEECH_PROFILE_API_URL')
    if not endpoint_url or not os.getenv('SPEECH_PROFILE_SERVICE_TOKEN'):
        print("[SPEECH_PROFILE] Hosted speech profile service is not configured")
        return segments, False

    # Assembling the profile re-downloads the main wav plus EVERY additional
    # sample (serially, no timeout) — dozens of GCS round-trips. Callers that
    # process many conversations for one user should assemble it once and pass it
    # in via `profile_path`; `owns_profile` then keeps the shared file alive.
    owns_profile = profile_path is None
    profile_clip_paths = list(profile_clip_paths or [])
    # The profile and people downloads use fixed file names per user, and every call
    # deletes them when it finishes. Two concurrent calls for one user (two workers
    # in a backfill, or an assign racing a process) deleted each other's samples
    # mid-read ("Skipping unreadable sample … No such file"), so each call works in
    # its own directory.
    work_dir = os.path.join('_temp', f'voiceprint_{uuid.uuid4().hex}')
    if owns_profile:
        profile_path, profile_clip_paths = download_dev_profile_parts(
            developer_id, external_user_id, temp_dir=work_dir
        )
    if not profile_path:
        print(f"[SPEECH_PROFILE] Skipped: no speech profile for user {external_user_id}")
        shutil.rmtree(work_dir, ignore_errors=True)
        return segments, False

    storage_uid = f"dev_{developer_id}_{external_user_id}"
    # The session audio is uploaded to GCS when the WebSocket session ENDS, but a
    # conversation can be processed earlier (the app POSTs /process as soon as the
    # silence timer flushes). Retry briefly so that near-miss race loses only a few
    # seconds instead of the whole voiceprint match — production logged repeated
    # "Could not download audio" for exactly this.
    local_audio_path = None
    for attempt in range(audio_wait_attempts):
        if audio_gcs_path:
            local_audio_path = download_recording_from_path(audio_gcs_path)
        else:
            local_audio_path = get_conversation_recording_if_exists(storage_uid, session_id)
        if local_audio_path:
            break
        if attempt < audio_wait_attempts - 1:
            time.sleep(audio_wait_seconds)
    if not local_audio_path:
        print(
            f"[SPEECH_PROFILE] Could not download audio for session {session_id} "
            f"after {audio_wait_attempts} attempt(s) over "
            f"~{audio_wait_seconds * (audio_wait_attempts - 1)}s"
        )
        if owns_profile:
            shutil.rmtree(work_dir, ignore_errors=True)
        return segments, False

    def _skip_unaligned(reason):
        print(f"[SPEECH_PROFILE] Skipping session {session_id}: {reason}")
        paths = [local_audio_path]
        if owns_profile:
            paths += [profile_path] + profile_clip_paths
        for path in paths:
            try:
                os.remove(path)
            except OSError:
                pass
        shutil.rmtree(work_dir, ignore_errors=True)
        return segments, False

    # The stored wav is VAD-trimmed, so transcript timestamps must be mapped onto
    # its (shorter) axis before the model slices it. Shared with app playback;
    # falls back to the session document when the caller didn't pass the intervals.
    try:
        segments_for_model, audio_kept_intervals = segments_on_recording_axis(
            developer_id, external_user_id, session_id, segments, audio_kept_intervals,
        )
    except RecordingAlignmentUnavailable as e:
        return _skip_unaligned(str(e))

    if not any(s.get('end', 0.0) - s.get('start', 0.0) >= 1.0 for s in segments_for_model):
        return _skip_unaligned('no usable audio-aligned segments')

    # Guard-rail: if timestamps still overshoot the audio, the model will silently
    # classify nothing (it clamps end to the duration, gets a negative span and
    # skips the segment). Log loudly instead of returning all-False in silence —
    # this exact failure went unnoticed for two weeks.
    try:
        audio_seconds = os.path.getsize(local_audio_path) / 32000.0  # 16kHz mono PCM16
        ends = [s.get('end') or 0.0 for s in segments_for_model]
        overshoot = sum(1 for e in ends if e > audio_seconds + 1.0)
        if ends and overshoot / len(ends) > 0.5:
            print(
                f"[SPEECH_PROFILE] WARNING session {session_id}: {overshoot}/{len(ends)} segments "
                f"({100 * overshoot / len(ends):.0f}%) end past the {audio_seconds:.1f}s audio — "
                f"kept_intervals {'MISSING' if not audio_kept_intervals else 'present but insufficient'}. "
                f"Speaker identification will likely classify nothing."
            )
    except OSError:
        pass

    # Voiceprints of people the user has tagged before. Assembled here (not in the
    # hosted model) because the model has no credentials for the developer bucket.
    people = []
    if match_people:
        try:
            people = download_dev_people(developer_id, external_user_id, temp_dir=work_dir)
        except Exception as e:
            # Never let people assembly break the user's own is_user match.
            print(f"[SPEECH_PROFILE] Could not assemble people references: {e}")
            people = []

    # Every enrolment clip travels as its own part so the model can score it
    # against the anchor and reject it on its own. Concatenating them here would
    # throw away exactly the information that screening needs.
    people_clip_parts = [
        (str(p['id']), path) for p in people for path in (p.get('clip_paths') or [])
    ]

    open_files = []
    try:
        files = []
        for field, name, path in (
            ('audio_file', 'audio.wav', local_audio_path),
            ('profile_file', 'profile.wav', profile_path),
            *(('people_files', f"{p['id']}.wav", p['path']) for p in people),
            *(
                ('profile_clip_files', f'uclip_{i}.wav', path)
                for i, path in enumerate(profile_clip_paths)
            ),
            *(
                ('people_clip_files', f'pclip_{i}.wav', path)
                for i, (_pid, path) in enumerate(people_clip_parts)
            ),
        ):
            handle = open(path, 'rb')
            open_files.append(handle)
            files.append((field, (name, handle, 'audio/wav')))
        data = {
            'segments': json.dumps(_segments_for_request(segments_for_model)),
            'people_ids': json.dumps([p['id'] for p in people]),
            'people_clip_owners': json.dumps([pid for pid, _ in people_clip_parts]),
            'classification_scope': 'local' if not audio_kept_intervals else 'speaker',
        }
        # Local matching encodes the recording throughout, rather than only 30s
        # per diarization label. Long offline jobs need the model's full budget.
        response = requests.post(
            endpoint_url,
            files=files,
            data=data,
            headers=speech_profile_service_headers(),
            allow_redirects=False,
            timeout=900 if data['classification_scope'] == 'local' else 120,
        )

        if response.status_code != 200:
            print(f"[SPEECH_PROFILE] Modal error ({response.status_code})")
            return segments, False

        matches = response.json()
        return _apply_speaker_matches(
            segments, matches, protected_speaker_keys, session_id
        )
    except Exception as e:
        print(f"[SPEECH_PROFILE] Error in speech profile matching: {e}")
        return segments, False
    finally:
        for handle in open_files:
            try:
                handle.close()
            except OSError:
                pass
        # Only delete the profile when we assembled it here — a caller-supplied
        # one is shared across conversations and must outlive this call. People
        # references are always assembled here, so they always get cleaned up.
        cleanup = (
            [local_audio_path]
            + [p['path'] for p in people]
            + [path for _pid, path in people_clip_parts]
            + ([profile_path] if owns_profile else [])
            + (profile_clip_paths if owns_profile else [])
        )
        for path in cleanup:
            try:
                os.remove(path)
            except OSError:
                pass
        if owns_profile:
            shutil.rmtree(work_dir, ignore_errors=True)
        else:
            # A caller-supplied profile lives elsewhere; only people files are in here.
            try:
                os.rmdir(work_dir)
            except OSError:
                pass


def speech_profile_service_headers() -> dict[str, str]:
    token = os.getenv('SPEECH_PROFILE_SERVICE_TOKEN')
    if not token:
        raise RuntimeError('Speech profile service token is missing')
    return {'X-Speech-Profile-Token': token}


# Agreement a freshly collected clip must show with the user's onboarding recording
# before it is STORED as enrolment audio.
#
# Deliberately the same number as CLIP_AGREEMENT_MIN in the hosted model, and that
# choice is the whole argument for the gate: a clip below it is already refused by
# the matcher every single time it is loaded, so declining to store it cannot change
# any match. It only stops the corpus from filling with audio that will never be
# used — measured on one production profile, 31 of 39 stored samples were below the
# cross-user baseline and 26 were below this line, i.e. two thirds of what had been
# collected was dead weight competing for the reference budget.
#
# Raising it above 0.31 WOULD change behaviour (it would refuse clips the matcher
# would have accepted), so it stays here until there is calibration data to justify
# a stricter line.
COLLECT_AGREEMENT_MIN = float(os.getenv('CAMPPLUS_CLIP_AGREEMENT_MIN', '0.31'))


def embed_wavs(paths: List[str], timeout: float = 300.0) -> List[Optional[List[float]]]:
    """L2-normalized speaker embeddings for local wavs, positionally aligned.

    ``None`` in a slot the encoder could not handle. Raises on transport failure so
    callers can tell "the encoder said this is not a voice" from "the encoder was
    unreachable" — those two must not lead to the same decision.
    """
    endpoint_url = os.getenv('CAMPPLUS_EMBED_URL')
    if not endpoint_url:
        raise RuntimeError('Speech profile encoder URL is missing')
    headers = speech_profile_service_headers()
    handles = []
    try:
        files = []
        for path in paths:
            handle = open(path, 'rb')
            handles.append(handle)
            files.append(('files', (os.path.basename(path), handle, 'audio/wav')))
        response = requests.post(
            endpoint_url, files=files, headers=headers, timeout=timeout, allow_redirects=False
        )
    finally:
        for handle in handles:
            try:
                handle.close()
            except OSError:
                pass
    if response.status_code != 200:
        raise RuntimeError(f'embed endpoint {response.status_code}')

    def _l2(vec):
        norm = math.sqrt(sum(x * x for x in vec)) or 1.0
        return [x / norm for x in vec]

    return [_l2(v) if v else None for v in response.json()]


def cosine(a: List[float], b: List[float]) -> float:
    """Cosine of two already-normalized embeddings."""
    return sum(x * y for x, y in zip(a, b))


def score_sample_against_anchor(
    developer_id: str,
    external_user_id: str,
    sample_path: str,
) -> Optional[float]:
    """cos(onboarding anchor, ``sample_path``), or None when it cannot be judged.

    None is returned for every reason that is NOT "this is a different voice":
    the user has no onboarding recording, the anchor will not download, the encoder
    is unreachable or refused a file. Callers must treat None as "no opinion" and
    proceed — a cold Modal container must never be able to stop a user from
    enrolling, and the matcher screens the clip again at match time anyway.
    """
    from database.developer_speech_profile import download_developer_anchor

    anchor_path = download_developer_anchor(developer_id, external_user_id)
    if not anchor_path:
        return None
    try:
        vectors = embed_wavs([anchor_path, sample_path])
    except Exception as e:
        print(f'[SPEECH_PROFILE] Encoder unavailable for collection screening: {e}')
        return None
    finally:
        try:
            os.remove(anchor_path)
        except OSError:
            pass
    if len(vectors) < 2 or vectors[0] is None or vectors[1] is None:
        print('[SPEECH_PROFILE] Encoder returned no embedding for anchor or sample')
        return None
    return cosine(vectors[0], vectors[1])


def get_speech_profile_expanded(uid: str):
    main = get_profile_audio_if_exists(uid, download=True)
    if not main:
        return None
    parts = get_additional_profile_recordings(uid, download=True)
    aseg = AudioSegment.from_wav(main)
    for part in parts:
        aseg += AudioSegment.from_wav(part)
    path = f'_temp/{uid}_complete_speech_profile.wav'
    aseg.export(path, format='wav')
    return path


def get_people_with_speech_samples(uid: str):
    people_ids = get_user_people_ids(uid)
    people = []
    for pid in people_ids:
        file_paths = get_user_person_speech_samples(uid, pid, download=True)
        aseg = AudioSegment.empty()
        for path in file_paths:
            aseg += AudioSegment.from_wav(path)
        path = f'_temp/{uid}_{pid}_complete_speech_profile.wav'
        aseg.export(path, format='wav')
        people.append({'id': pid, 'path': path})
    return people
