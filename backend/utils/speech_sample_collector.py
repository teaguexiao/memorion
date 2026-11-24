"""
Auto-collect speech samples from manually tagged conversation segments.

When a user manually assigns a speaker (person_id or is_user) to transcript segments,
we extract the corresponding audio clips from the conversation recording and upload
them as speech samples. This way the speaker's voice profile grows over time and
future conversations can be auto-identified.

Two things make this subtler than "slice at segment.start/end":

1. **The audio and the timestamps are on different time axes.** A live session's
   wav is the whole session, VAD-trimmed; stored segments carry display times
   (rebased to the conversation) plus their STT times as provenance. Slicing with
   the wrong axis files somebody else's voice — or pure silence — under this
   speaker's name, so segments go through
   ``utils.stt.recording_alignment.conversation_segments_on_wav`` (the same answer
   voiceprint matching uses) and conversations it cannot align are not enrolled.

2. **Duration must be measured as net speech, not wall clock.** A 6-second segment
   that is 5 seconds of pause carries almost no speaker information. Every vendor
   with published numbers (AWS Voice ID 30s, Azure 20s) counts net speech
   explicitly, and a profile grown from silence-padded clips gets worse, not better.
"""

import math
import os
import uuid
from typing import List, Dict, Optional, Tuple

from pydub import AudioSegment

from models.transcript_segment import TranscriptSegment
from utils.other.storage import (
    get_conversation_recording_if_exists,
    upload_user_person_speech_sample,
    upload_additional_profile_audio,
    download_recording_from_path,
    upload_developer_person_speech_sample_from_file,
)
from database.developer_speech_profile import upload_developer_sample
from utils.stt.recording_alignment import RecordingAlignmentUnavailable, conversation_segments_on_wav
import database.developer_data as dev_db
import database.developer_speech_profile as dev_profile_db

# Minimum single clip duration (seconds) — clips shorter than this are skipped
MIN_CLIP_DURATION = 1.0
# Minimum combined duration (seconds) before uploading — avoids noisy short samples
MIN_COMBINED_DURATION = 5.0
# Maximum total sample duration (seconds) to collect per assignment call. This is
# a hard ceiling on what any single clip may contribute, not just a loop-exit
# check: a bad span (before the time-axis fix, a mis-mapped timestamp could span a
# whole conversation) once uploaded a 45-minute "sample" as one person's
# voiceprint, which is a multi-speaker recording masquerading as a reference.
MAX_SAMPLE_DURATION = 60.0
# Minimum NET SPEECH (VAD, silence excluded) for the whole upload. Chosen so a
# single careful tagging session is enough to make a person recognizable next time
# (which is the point of collecting at all), while still rejecting a handful of
# one-word replies. Note this is stricter than MIN_COMBINED_DURATION even though
# the number is larger: it counts only speech.
MIN_COMBINED_SPEECH_SECONDS = float(os.getenv('SPEECH_SAMPLE_MIN_TOTAL_SPEECH', '6.0'))
# Padding kept around each detected speech run, so word onsets/offsets survive.
SPEECH_KEEP_PAD_MS = 100
# Refuse to enrol from a session whose audio arrived inflated — the same bar
# `scripts/rescue_orphaned_listen_sessions.py` uses to refuse re-transcribing one.
#
# A duplicated-BLE-frame session is not "the right voice, recorded badly". The
# server-side opus decoder is stateful and predictive, so feeding it the same packet
# N times makes it DIVERGE into ~100Hz buzz — the speech is destroyed, not copied
# (established 2026-08-17: an 8.75x session yielded 0 transcript segments offline
# under every de-duplication strategy tried, while a 1.38x session from the same day
# and the same pipeline yielded 36 characters). Audio like that carries no speaker
# identity, and a voiceprint built on it is worse than no voiceprint.
#
# ⚠️ The ratio is the ONLY usable signal, and only as recorded at session end. Three
# candidate ways to detect inflation from the audio itself — adjacent-frame
# correlation, byte-identical frame share, 100Hz comb strength — were each falsified
# by healthy controls. So do not try to reconstruct this from the wav.
#
# ⚠️ Absent field means PASS, not fail. Only sessions after 2026-08-17 carry it (6 of
# this account's 24026 at the time of writing), and refusing everything older would
# turn a targeted guard into a total stop on enrolment.
MAX_SESSION_REALTIME_FACTOR = float(os.getenv('SPEECH_SAMPLE_MAX_REALTIME_FACTOR', '1.5'))


def _keep_speech_only(audio: AudioSegment, label: str = '') -> Tuple[AudioSegment, Optional[float]]:
    """Drop non-speech from ``audio``; return ``(audio, net_speech_seconds)``.

    Removing the silence is better than merely rejecting silence-heavy clips:
    every second of pause that reaches the encoder dilutes the embedding, so a
    tagged clip with long gaps still yields a usable voiceprint once the gaps are
    gone.

    ``net_speech_seconds`` is None when VAD is unavailable. Legacy assignment
    callers retain their wall-clock fallback; reviewed chapter enrollment must
    reject that result because its net-speech requirement cannot be checked.
    """
    tmp = f'_temp/vadcheck_{uuid.uuid4().hex[:8]}.wav'
    try:
        audio.export(tmp, format='wav')
        from utils.stt.vad import get_speech_segments

        speech = get_speech_segments(tmp)
        if not speech:
            return audio, 0.0
        total_ms = len(audio)
        kept = AudioSegment.empty()
        for s in speech:
            start_ms = max(0, int(s['start'] * 1000) - SPEECH_KEEP_PAD_MS)
            end_ms = min(total_ms, int(s['end'] * 1000) + SPEECH_KEEP_PAD_MS)
            if end_ms > start_ms:
                kept += audio[start_ms:end_ms]
        net = sum(s['duration'] for s in speech)
        return (kept if len(kept) > 0 else audio), net
    except Exception as e:
        print(f'[SpeechCollector] VAD unavailable{f" ({label})" if label else ""}: {e}')
        return audio, None
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _session_for_conversation(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
) -> dict:
    """The listen session behind this conversation's audio, or ``{}``.

    The session id is recoverable from the audio path the WS writer built
    (``{uid}/{session_id}.wav``), so no extra field is needed on the conversation.

    Read once and passed around: two callers need it (VAD intervals for the time
    axis, and the inflation ratio for the quality gate) and a second Firestore read
    per collection buys nothing.
    """
    audio_path = conversation.get('audio_path') or ''
    session_id = os.path.splitext(os.path.basename(audio_path))[0]
    if not session_id:
        return {}
    try:
        return dev_db.get_listen_session(developer_id, external_user_id, session_id) or {}
    except Exception as e:
        print(f'[SpeechCollector] Could not read listen session {session_id}: {e}')
        return {}


def _inflation_refusal(session: dict) -> Optional[str]:
    """Why this session's audio must not be enrolled, or None if it may be.

    Returns a human-readable reason so the caller can log what happened rather than
    silently collecting nothing — a silent skip here reads identically to "the
    segments were too short", and those need different fixes.
    """
    factor = session.get('audio_realtime_factor')
    if factor is None:
        return None  # predates the detector; see MAX_SESSION_REALTIME_FACTOR
    try:
        factor = float(factor)
    except (TypeError, ValueError):
        return None
    if factor <= MAX_SESSION_REALTIME_FACTOR:
        return None
    return (
        f'session audio arrived {factor:.2f}x realtime '
        f'(> {MAX_SESSION_REALTIME_FACTOR}) — duplicated BLE frames destroy the '
        f'speech rather than copying it, so this audio carries no voiceprint'
    )


def collect_speech_samples_from_segments(
    uid: str,
    conversation_id: str,
    segments: List[TranscriptSegment],
    assigned_segment_ids: List[str],
    assign_type: str,
    value: str,
):
    """Extract audio for assigned segments and upload as speech samples.

    UNUSED — the legacy non-developer path, kept for the old ``users/`` layout.
    Nothing in this repo calls it (verified by grep across backend, app and web).

    Do NOT wire this up without porting the four guards its developer sibling
    grew, because every one of them exists because of damage observed in
    production and this function has none of them:

    * ``source`` gating, so a matcher's own guess cannot enrol itself into the
      profile it was matched against (template poisoning).
    * time-axis alignment, so timestamps are not applied to a VAD-trimmed wav they
      do not belong to — that is what filed bystanders' voices under other names.
    * a per-clip ``MAX_SAMPLE_DURATION`` truncation rather than a loop-exit check,
      which is how one bad span became a 45-minute "sample".
    * a net-speech floor, so clips that are mostly silence do not dilute the
      voiceprint.

    Prefer ``collect_speech_samples_developer``.

    Args:
        uid: User ID
        conversation_id: Conversation ID (to find the recording)
        segments: All transcript segments of the conversation
        assigned_segment_ids: IDs of segments that were just assigned
        assign_type: 'is_user' or 'person_id'
        value: For is_user, truthy string; for person_id, the person's ID
    """
    # Only collect when assigning to a known identity (not un-assigning)
    if assign_type == 'is_user' and not value:
        return
    if assign_type == 'person_id' and not value:
        return

    # Download conversation recording
    audio_path = get_conversation_recording_if_exists(uid, conversation_id)
    if not audio_path:
        print(f'[SpeechCollector] No recording found for conversation {conversation_id}')
        return

    try:
        full_audio = AudioSegment.from_wav(audio_path)
    except Exception as e:
        print(f'[SpeechCollector] Failed to load audio: {e}')
        return

    # Build a map of assigned segments
    segment_map = {s.id: s for s in segments}
    assigned = [segment_map[sid] for sid in assigned_segment_ids if sid in segment_map]

    # Filter to segments long enough (low bar — even short clips help when accumulated)
    assigned = [s for s in assigned if (s.end - s.start) >= MIN_CLIP_DURATION]
    if not assigned:
        print(f'[SpeechCollector] No segments long enough to collect')
        return

    # Sort by duration descending — prefer longer clips
    assigned.sort(key=lambda s: s.end - s.start, reverse=True)

    # Extract and concatenate clips, up to MAX_SAMPLE_DURATION. The cap truncates
    # each clip rather than only breaking out of the loop — see the note on
    # MAX_SAMPLE_DURATION for what an unbounded first span did to real data.
    combined = AudioSegment.empty()
    total_duration = 0.0
    cap_ms = int(MAX_SAMPLE_DURATION * 1000)
    for seg in assigned:
        remaining_ms = cap_ms - int(total_duration * 1000)
        if remaining_ms <= 0:
            break
        start_ms = max(0, int(seg.start * 1000))
        end_ms = min(int(seg.end * 1000), len(full_audio))
        end_ms = min(end_ms, start_ms + remaining_ms)
        if end_ms <= start_ms:
            continue
        clip = full_audio[start_ms:end_ms]
        combined += clip
        total_duration += clip.duration_seconds

    if combined.duration_seconds < MIN_COMBINED_DURATION:
        print(f'[SpeechCollector] Combined audio too short ({combined.duration_seconds:.1f}s), need {MIN_COMBINED_DURATION}s')
        return

    # Export to temp file
    sample_id = str(uuid.uuid4())[:8]
    temp_path = f'_temp/{uid}_{sample_id}_speech_sample.wav'
    combined.export(temp_path, format='wav')

    try:
        if assign_type == 'is_user':
            # Append to user's own speech profile as additional recording
            # Uses {uid}/additional_profile_recordings/ path, which get_speech_profile_expanded() picks up
            upload_additional_profile_audio(temp_path, uid)
            print(f'[SpeechCollector] Uploaded user additional profile ({combined.duration_seconds:.1f}s)')
        elif assign_type == 'person_id':
            # Uses {uid}/people_profiles/{person_id}/ path, which get_people_with_speech_samples() picks up
            upload_user_person_speech_sample(temp_path, uid, value)
            print(f'[SpeechCollector] Uploaded person {value} speech sample ({combined.duration_seconds:.1f}s)')
    except Exception as e:
        print(f'[SpeechCollector] Upload failed: {e}')
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass
        try:
            os.remove(audio_path)
        except OSError:
            pass


def _extract_clips_from_segments(
    full_audio: AudioSegment,
    segments: list,
    assigned_segment_ids: List[str],
    get_id, get_start, get_end,
) -> Tuple[Optional[AudioSegment], Optional[float], List[str]]:
    """
    Extract and concatenate audio clips for assigned segments.
    Returns ``(combined_audio, net_speech_seconds, contributing_segment_ids)``, or
    ``(None, None, [])`` when the result is not worth uploading.
    ``net_speech_seconds`` is None when VAD was unavailable and the wall-clock
    rule was used instead.

    ``contributing_segment_ids`` lists only the segments whose audio actually
    reached the upload — not everything that was assigned. It becomes the
    sample's provenance, and it has to be exact in both directions: an id that
    did not contribute makes an unrelated cancel revoke this sample, and a
    missing id makes the right cancel walk past it. Segments get dropped here for
    three separate reasons (too short, MAX_SAMPLE_DURATION exhausted, span
    collapsed to nothing because VAD trimmed its audio away), so the list cannot
    be inferred from the input.

    get_id/get_start/get_end: accessor functions for segment fields
    (supports both TranscriptSegment objects and dicts). Their times must already
    be on the wav's axis (``conversation_segments_on_wav``).
    """
    segment_map = {get_id(s): s for s in segments}
    assigned = [(sid, segment_map[sid]) for sid in assigned_segment_ids if sid in segment_map]

    # Segments whose audio VAD trimmed away come back as start==end and are
    # dropped by the floor below.
    spans = [(get_start(s) or 0.0, get_end(s) or 0.0) for _sid, s in assigned]
    clips = [
        (sid, s, e)
        for (sid, _seg), (s, e) in zip(assigned, spans)
        if (e - s) >= MIN_CLIP_DURATION
    ]
    if not clips:
        print('[SpeechCollector] No segments long enough to collect')
        return None, None, []

    # Longest first: the longest clips carry the speaker's stable speech, and the
    # MAX_SAMPLE_DURATION cap has to fall somewhere.
    clips.sort(key=lambda c: c[2] - c[1], reverse=True)

    combined = AudioSegment.empty()
    total_duration = 0.0
    used_ids: List[str] = []
    cap_ms = int(MAX_SAMPLE_DURATION * 1000)
    for sid, start_s, end_s in clips:
        remaining_ms = cap_ms - int(total_duration * 1000)
        if remaining_ms <= 0:
            break
        start_ms = max(0, int(start_s * 1000))
        end_ms = min(int(end_s * 1000), len(full_audio))
        # Truncate the clip to what is left under the cap. Checking the total only
        # at the top of the loop lets the FIRST span through at any length, and
        # spans are sorted longest-first, so one bad span becomes the whole sample.
        end_ms = min(end_ms, start_ms + remaining_ms)
        if end_ms <= start_ms:
            continue
        clip = full_audio[start_ms:end_ms]
        combined += clip
        total_duration += clip.duration_seconds
        used_ids.append(sid)

    if combined.duration_seconds < MIN_COMBINED_DURATION:
        print(f'[SpeechCollector] Combined audio too short ({combined.duration_seconds:.1f}s), need {MIN_COMBINED_DURATION}s')
        return None, None, []

    # Strip the pauses, then judge on what is left. A clip that is mostly silence
    # would otherwise pass the wall-clock check and then weaken the voiceprint.
    speech_only, net_speech = _keep_speech_only(combined)
    if net_speech is None:
        return combined, None, used_ids  # VAD unavailable: wall-clock rule already passed
    if net_speech < MIN_COMBINED_SPEECH_SECONDS:
        print(
            f'[SpeechCollector] Only {net_speech:.1f}s of net speech in '
            f'{combined.duration_seconds:.1f}s of audio, need '
            f'{MIN_COMBINED_SPEECH_SECONDS}s — not collecting'
        )
        return None, None, []
    return speech_only, net_speech, used_ids


def _chapter_clip_is_distorted(audio):
    """Reject severe waveform clipping; VAD and human review cover other gates."""
    samples = audio.get_array_of_samples()
    if not samples:
        return True
    peak = (1 << (8 * audio.sample_width - 1)) - 1
    return sum(abs(value) >= peak * .995 for value in samples) / len(samples) > .01


def _discard_paths(*paths) -> None:
    for path in paths:
        if not path:
            continue
        try:
            os.remove(path)
        except OSError:
            pass


def _screen_collected_sample(
    developer_id: str,
    external_user_id: str,
    sample_path: str,
    assign_type: str,
    value: str,
) -> Optional[float]:
    """cos(user's onboarding anchor, this clip), or None when it cannot be judged.

    The user's onboarding recording is the only audio in the system we know belongs
    to a specific named person — they made it alone, on purpose. So it is the anchor
    for BOTH assign types, but the two read the score in opposite directions:

    * ``is_user`` — a high score confirms the tag, a low one contradicts it.
    * ``person_id`` — a high score means the user's own voice is being filed under
      somebody else's name, which is the failure that makes a person's reference
      start winning the user's segments.

    Note what this deliberately does NOT do for ``person_id``: score the clip against
    that person's existing samples. Those samples are themselves unscreened
    conversation audio with no trusted anchor behind them, so agreement with them is
    as likely to mean "consistent with the same mistake" as "consistent with the same
    person" — and disagreement would block the legitimate case of a person whose
    first enrolment was wrong. Only the user's anchor is trustworthy enough to
    exclude on.
    """
    from utils.stt.speech_profile import score_sample_against_anchor

    score = score_sample_against_anchor(developer_id, external_user_id, sample_path)
    if score is None:
        print(
            '[SpeechCollector-Dev] Could not screen this clip against the user anchor '
            '— enrolling unscreened (the matcher screens it again at match time)'
        )
        return None
    target = 'user' if assign_type == 'is_user' else f'person {value}'
    print(f'[SpeechCollector-Dev] Clip scores cos={score:.3f} vs user anchor ({target})')
    return score


def _reject_by_anchor_cos(anchor_cos: float, assign_type: str) -> bool:
    """Whether a scored clip must not be stored. See ``_screen_collected_sample``."""
    from utils.stt.speech_profile import COLLECT_AGREEMENT_MIN

    if assign_type == 'is_user':
        if anchor_cos < COLLECT_AGREEMENT_MIN:
            print(
                f'[SpeechCollector-Dev] Refusing to enrol as the user: cos='
                f'{anchor_cos:.3f} < {COLLECT_AGREEMENT_MIN} — the matcher would '
                f'reject this clip on every future conversation anyway'
            )
            return True
        return False
    # person_id: the exclusion is symmetric but the direction flips.
    if anchor_cos >= COLLECT_AGREEMENT_MIN:
        print(
            f'[SpeechCollector-Dev] Refusing to enrol under a person: cos='
            f'{anchor_cos:.3f} >= {COLLECT_AGREEMENT_MIN} vs the USER anchor — this '
            f'is the user\'s own voice, and filing it here is what makes that person '
            f'start winning the user\'s segments'
        )
        return True
    return False


def _correct_tracked_durations(
    developer_id: str,
    external_user_id: str,
    revoked: List[Dict],
) -> None:
    """Subtract revoked samples from the enrolled-seconds counters.

    ``speech_samples_duration`` is what the profile screen reports as "how much of
    your voice we have", so leaving it counting audio that is no longer in the
    read path tells the user their voiceprint is better enrolled than it is.

    Clamped at zero afterwards because the counter predates provenance: samples
    collected before this existed were counted up but carry no
    ``duration_seconds``, so the totals and the revokable audio do not
    reconcile, and ``Increment`` alone would happily go negative.
    """
    by_target: Dict[Tuple[str, str], float] = {}
    for item in revoked:
        seconds = item.get('duration_seconds') or 0.0
        if seconds <= 0:
            continue
        key = (item.get('assign_type') or '', item.get('target_id') or '')
        by_target[key] = by_target.get(key, 0.0) + seconds

    for (assign_type, target_id), seconds in by_target.items():
        try:
            if assign_type == 'is_user':
                dev_db.increment_speech_samples_duration(
                    developer_id, external_user_id, -seconds, clamp_at_zero=True,
                )
            elif assign_type == 'person_id' and target_id and target_id != 'unknown':
                dev_db.increment_person_speech_samples_duration(
                    developer_id, external_user_id, target_id, -seconds,
                    clamp_at_zero=True,
                )
        except Exception as e:
            print(
                f'[SpeechCollector-Dev] Could not adjust enrolled seconds for '
                f'{assign_type}:{target_id}: {e}'
            )


def collect_speech_samples_developer(
    developer_id: str,
    external_user_id: str,
    conversation: dict,
    assigned_segment_ids: List[str],
    assign_type: str,
    value: str,
    source: str = 'manual',
    chapter_operation_id: Optional[str] = None,
    before_upload=None,
):
    """
    Extract audio for assigned segments and upload as speech samples (Developer API).

    Args:
        developer_id: Developer ID
        external_user_id: External user identifier
        conversation: Conversation dict with 'transcript_segments' and 'audio_path'
        assigned_segment_ids: IDs of segments that were just assigned
        assign_type: 'is_user' or 'person_id'
        value: For is_user, truthy string; for person_id, the person's ID
        source: Where the assignment came from. Only ``'manual'`` — a human saying
            "this is me / this is Alice" — may enrol audio. Anything else is
            rejected, because feeding the model's own guesses back into the
            profile it was matched against is textbook template poisoning: one
            wrong auto-label pulls the centroid toward the wrong voice, which
            makes the next wrong label more likely. Biometric self-update needs a
            confirmation source outside the matcher, and ours is the user.

    A manual assignment is symmetric: it enrols audio for the identity it names,
    and it retracts whatever these same segments previously enrolled for a
    DIFFERENT identity. Both halves matter and both are handled here rather than
    at the three call sites, which already hand us exactly the right arguments:

    * clearing the speaker (``value`` empty) — the user is saying "this was not
      that person", and the reason is either that voiceprint matching got it wrong
      or that they tagged it wrong themselves. Either way the tag that justified
      the enrolment is gone, so the sample goes too;
    * reassigning A → B — same retraction, plus a fresh sample for B. Without the
      retraction, "I marked this wrong, it's actually B" left A's bogus voiceprint
      untouched and A kept winning the same segments in the next conversation.

    Note the asymmetry with auto assignments: a wrong AUTO label never produced a
    sample (``source`` gating above), so there is nothing to roll back in that
    case. What's wrong there is the reference the matcher used, and only the user
    rebuilding that person's voiceprint fixes it.
    """
    if source != 'manual':
        print(f'[SpeechCollector-Dev] Ignoring non-manual assignment (source={source})')
        return {'status': 'not_eligible'}

    conversation_id = conversation.get('id')
    # Runs before the early return below so that CLEARING a speaker still reaches
    # it — that path collects nothing, and is precisely when revocation matters.
    if chapter_operation_id is None:
        try:
            revoked = dev_profile_db.revoke_samples_from_segments(
                developer_id,
                external_user_id,
                conversation_id,
                assigned_segment_ids,
                keep_target=(assign_type, value) if value else None,
                reason='unassigned' if not value else 'reassigned',
            )
            _correct_tracked_durations(developer_id, external_user_id, revoked)
        except Exception as e:
            # Never let revocation stop enrolment: a stale sample is a worse
            # voiceprint, a missing one is no voiceprint at all.
            print(f'[SpeechCollector-Dev] Revocation failed: {e}')

    if assign_type == 'is_user' and not value:
        return {'status': 'not_eligible'}
    if assign_type == 'person_id' and not value:
        return {'status': 'not_eligible'}

    audio_gcs_path = conversation.get('audio_path')
    if not audio_gcs_path:
        return {'status': 'audio_unavailable'}

    # Read the session before downloading anything: when the audio is inflated there
    # is no point paying for the wav, the VAD pass or the encoder.
    session = _session_for_conversation(developer_id, external_user_id, conversation)
    refusal = _inflation_refusal(session)
    if refusal:
        print(f'[SpeechCollector-Dev] Not enrolling from {conversation_id}: {refusal}')
        return {'status': 'not_eligible'}

    local_audio_path = download_recording_from_path(audio_gcs_path)
    if not local_audio_path:
        print(f'[SpeechCollector-Dev] Could not download audio from {audio_gcs_path}')
        return {'status': 'not_eligible'}

    try:
        full_audio = AudioSegment.from_wav(local_audio_path)
    except Exception as e:
        _discard_paths(local_audio_path)
        return {'status': 'audio_unavailable'}

    try:
        # The same axis answer voiceprint matching uses, so a tag enrols exactly
        # the audio a later match will compare against.
        segments = conversation_segments_on_wav(conversation, session)
    except RecordingAlignmentUnavailable as e:
        print(f'[SpeechCollector-Dev] Not enrolling from {conversation_id}: {e}')
        _discard_paths(local_audio_path)
        return {'status': 'not_eligible'}
    if chapter_operation_id:
        from utils.timeline.speaker_audio import reviewed_clip, CHAPTER_MIN_SPEECH_SECONDS
        try:
            if len(assigned_segment_ids) != 1:
                raise ValueError('Review exactly one quotation')
            index = next(i for i, s in enumerate(segments) if s.get('id') == assigned_segment_ids[0])
            clip = reviewed_clip(segments, index)
            if clip['learning_blocked_reason']:
                _discard_paths(local_audio_path)
                return {'status': clip['learning_blocked_reason']}
            # Never collect the unplayed remainder of a long quotation.
            segments = [{**segments[index], 'start': clip['start'], 'end': clip['end']}]
            audio_clip = full_audio[int(clip['start'] * 1000):int(clip['end'] * 1000)]
            if _chapter_clip_is_distorted(audio_clip):
                _discard_paths(local_audio_path)
                return {'status': 'distorted_audio'}
        except (StopIteration, ValueError, KeyError, TypeError):
            _discard_paths(local_audio_path)
            return {'status': 'audio_unavailable'}
    combined, net_speech, used_segment_ids = _extract_clips_from_segments(
        full_audio, segments, assigned_segment_ids,
        get_id=lambda s: s.get('id'),
        get_start=lambda s: s.get('start', 0),
        get_end=lambda s: s.get('end', 0),
    )

    if combined is None:
        try:
            os.remove(local_audio_path)
        except OSError:
            pass
        return {'status': 'not_eligible'}

    quality_unavailable = net_speech is None or not math.isfinite(net_speech)
    if chapter_operation_id and (quality_unavailable or net_speech < CHAPTER_MIN_SPEECH_SECONDS):
        _discard_paths(local_audio_path)
        return {'status': 'quality_unavailable' if quality_unavailable else 'insufficient_speech'}

    sample_id = str(uuid.uuid4())[:8]
    temp_path = f'_temp/dev_{developer_id}_{sample_id}_speech_sample.wav'
    combined.export(temp_path, format='wav')

    added_duration = combined.duration_seconds
    print(
        f'[SpeechCollector-Dev] Collected {added_duration:.1f}s'
        + (f' ({net_speech:.1f}s net speech before trimming)' if net_speech else '')
    )

    # Whose voice is this, actually? Every gate before this point measures the audio
    # (long enough, speech-dense enough, from an uninflated session) and none of them
    # measures the SPEAKER — which is why 31 of 39 stored samples on the account that
    # prompted this work were somebody else, most of them not remotely borderline
    # (cos -0.073 to 0.294 against the user's own onboarding recording).
    anchor_cos = _screen_collected_sample(
        developer_id, external_user_id, temp_path, assign_type, value,
    )
    if anchor_cos is not None and _reject_by_anchor_cos(anchor_cos, assign_type):
        _discard_paths(temp_path, local_audio_path)
        return {'status': 'not_eligible'}

    # Byte-identical to something already enrolled? Then it is a repeated call, not a
    # second recording, and storing it would let one clip carry N times its weight.
    try:
        audio_bytes = open(temp_path, 'rb').read()
        duplicate = dev_profile_db.find_duplicate_sample(
            developer_id, external_user_id, audio_bytes,
            person_id=value if assign_type == 'person_id' else None,
        )
    except Exception as e:
        if chapter_operation_id:
            _discard_paths(temp_path, local_audio_path)
            return {'status': 'failed'}
        # A failed listing must not cost the enrolment; a duplicate is a weighting
        # problem, a missing sample is a recall problem.
        print(f'[SpeechCollector-Dev] Duplicate check failed: {e}')
        audio_bytes, duplicate = None, None
    if duplicate and not chapter_operation_id:
        print(
            f'[SpeechCollector-Dev] Identical audio already enrolled as {duplicate} '
            f'— not storing a second copy'
        )
        _discard_paths(temp_path, local_audio_path)
        return {'status': 'not_eligible'}

    # Provenance travels with the wav. This is the only record of which tag
    # enrolled which audio, and it cannot be reconstructed later — see
    # ``sample_provenance``.
    provenance = dev_profile_db.sample_provenance(
        source=source,
        assign_type=assign_type,
        target_id=value if assign_type == 'person_id' else 'user',
        conversation_id=conversation_id or '',
        segment_ids=used_segment_ids,
        duration_seconds=added_duration,
        net_speech_seconds=net_speech,
        anchor_cos=anchor_cos,
    )
    if chapter_operation_id:
        provenance['chapter_operation_id'] = chapter_operation_id
    if before_upload is not None and not before_upload():
        _discard_paths(temp_path, local_audio_path)
        return {'status': 'stale'}
    if chapter_operation_id:
        # Chapter corrections do not rewrite source tags. Explicit learning must
        # still retract contradictory samples, including those collected from the
        # conversation page or another chapter. Wait until quality/lease checks
        # pass, and touch only the segments that actually contributed audio.
        revoked = []
        try:
            dev_profile_db.revoke_samples_from_segments(
                developer_id, external_user_id, conversation_id, used_segment_ids,
                keep_target=(assign_type, value if assign_type == 'person_id' else 'user'),
                reason='reassigned', revoked_samples=revoked, strict=True,
            )
        except Exception as e:
            # Never add a second identity while an old contradictory sample may
            # remain. The chapter endpoint keeps failed attempts retryable.
            print(f'[SpeechCollector-Dev] Chapter reassignment cleanup failed: {e}')
            _discard_paths(temp_path, local_audio_path)
            return {'status': 'failed'}
        finally:
            _correct_tracked_durations(developer_id, external_user_id, revoked)
        if duplicate:
            _discard_paths(temp_path, local_audio_path)
            return {'status': 'already_enrolled'}
        if before_upload is not None and not before_upload():
            _discard_paths(temp_path, local_audio_path)
            return {'status': 'stale'}
    try:
        if assign_type == 'is_user':
            # Upload as additional speech sample for the developer user profile
            # Uses developers/{dev_id}/users/{ext_user_id}/samples/ path
            if audio_bytes is None:
                audio_bytes = open(temp_path, 'rb').read()
            upload_developer_sample(
                developer_id, external_user_id, audio_bytes, metadata=provenance,
            )
            # Track accumulated duration on the user document
            dev_db.increment_speech_samples_duration(
                developer_id, external_user_id, added_duration,
            )
            print(f'[SpeechCollector-Dev] Uploaded user sample ({added_duration:.1f}s)')
        elif assign_type == 'person_id':
            # Uses developers/{dev_id}/users/{ext_user_id}/people_profiles/{person_id}/ path
            upload_developer_person_speech_sample_from_file(
                developer_id, external_user_id, value, temp_path, sample_id,
                metadata=provenance,
            )
            # Track accumulated duration on the person document
            dev_db.increment_person_speech_samples_duration(
                developer_id, external_user_id, value, added_duration,
            )
            print(f'[SpeechCollector-Dev] Uploaded person {value} sample ({added_duration:.1f}s)')
        return {'status': 'enrolled', 'duration_seconds': added_duration}
    except Exception as e:
        print(f'[SpeechCollector-Dev] Upload failed: {e}')
        return {'status': 'failed'}
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass
        try:
            os.remove(local_audio_path)
        except OSError:
            pass
