"""Where a conversation's transcript sits in the audio file it plays back.

The times shown on transcript segments are not the wav's times. A live (WS)
recording's wav is the whole session with VAD silence removed, linked to one
conversation of that session: a conversation split off the session starts minutes
into the file, and a segment VAD judged silent has no audio left at all. An
uploaded recording is stored untrimmed under its own conversation id.

Every reader of a recording asks the same question — "where in this wav is that
segment?" — and gets this one answer: voiceprint matching, voiceprint enrolment
from manual tags, chapter evidence clips and app playback (tap a sentence to hear
it). They used to carry four variants that disagreed: two skipped restoring an
older client's times from the session transcript, so enrolment refused
conversations that matching accepted, and one guessed the axis from whether the
spans overshot the wav. A transcript without timestamp provenance is reported as
unavailable, never inferred from whether its spans happen to fit the wav (see
``restore_original_timestamps``).

Like ``utils.stt.timeline`` this module must stay cheap to import: no model, and
the database is imported only when the listen session actually has to be read.
"""

from typing import Any, List, Optional, Sequence, Tuple

from utils.stt.timeline import (
    UnknownTimestampAxis,
    normalize_kept_intervals,
    restore_original_timestamps,
    segments_on_audio_axis,
)


class RecordingAlignmentUnavailable(Exception):
    """The transcript cannot be placed on its recording's axis; ``str(e)`` says why."""


def session_id_from_audio_path(audio_path: str) -> str:
    """The WS writer names the wav after its session: ``{uid}/{session_id}.wav``."""
    return audio_path.rsplit('/', 1)[-1].rsplit('.', 1)[0]


def kept_intervals_hint(conversation: dict) -> Optional[list]:
    """``[]`` for an upload (stored untrimmed); ``None`` = read them from the listen session.

    The distinction is the point: ``None`` on an upload would look up a listen
    session that does not exist and report the recording as unalignable.
    """
    return [] if conversation.get('source') == 'audio_upload' else None


def segments_on_recording_axis(
    developer_id: str,
    external_user_id: str,
    session_id: str,
    segments: Sequence[dict],
    audio_kept_intervals: Optional[Sequence[Any]] = None,
) -> Tuple[List[dict], Any]:
    """Return ``(copies of segments on the wav's axis, the kept intervals used)``.

    ``audio_kept_intervals=None`` reads them from the listen session. Raises
    :class:`RecordingAlignmentUnavailable` instead of guessing.
    """
    session_doc = None
    if audio_kept_intervals is None:
        try:
            # Imported here: database → utils → this module is circular at load time.
            from database import developer_data as dev_db

            session_doc = dev_db.get_listen_session(developer_id, external_user_id, session_id)
        except Exception as e:
            print(f"[ALIGN] Could not read audio_kept_intervals for {session_id}: {e}")
            raise RecordingAlignmentUnavailable('could not read audio alignment metadata') from e
    return segments_on_session_wav(segments, session_doc, audio_kept_intervals)


def segments_on_session_wav(
    segments: Sequence[dict],
    session_doc: Optional[dict],
    kept_intervals: Optional[Sequence[Any]] = None,
) -> Tuple[List[dict], Any]:
    """:func:`segments_on_recording_axis` for callers that already hold the listen session.

    ``kept_intervals=None`` takes them from ``session_doc``, which also restores an
    older client's original times from the server's own transcript.
    """
    session_doc = session_doc or {}
    if kept_intervals is None:
        kept_intervals = session_doc.get('audio_kept_intervals')
    if kept_intervals is None:
        raise RecordingAlignmentUnavailable('audio alignment metadata missing')
    try:
        aligned = segments_on_audio_axis(
            restore_original_timestamps(segments, session_doc),
            kept_intervals, require_provenance=True,
        )
    except UnknownTimestampAxis as e:
        raise RecordingAlignmentUnavailable('legacy timestamp axis needs repair') from e
    return aligned, kept_intervals


def conversation_segments_on_wav(conversation: dict, session_doc: Optional[dict]) -> List[dict]:
    """A conversation's segments on its own wav's axis; ``session_doc`` is ``{}`` when it has none.

    Raises :class:`RecordingAlignmentUnavailable` instead of guessing.
    """
    aligned, _ = segments_on_session_wav(
        conversation.get('transcript_segments') or [], session_doc, kept_intervals_hint(conversation),
    )
    return aligned


def _has_audio(segment: dict, intervals: List[Tuple[float, float]]) -> bool:
    """Whether any of the segment's speech survived trimming.

    Not ``start == end`` after mapping: Soniox emits zero-length segments, and an
    untrimmed upload had 20 of them in 792 — all perfectly playable.
    """
    if not intervals:
        return True  # untrimmed: the wav holds everything
    a, b = segment.get('original_start'), segment.get('original_end')
    if a is None or b is None:
        return True  # given on the audio axis already; nothing to have been cut
    a, b = float(a), float(b)
    return any(min(b, end) > max(a, start) or start <= a <= end for start, end in intervals)


def conversation_audio_alignment(developer_id: str, external_user_id: str, conversation: dict) -> dict:
    """Payload of ``GET /v1/conversations/{id}/audio-alignment``.

    ``has_audio=False`` marks a segment VAD removed entirely; its mapped time is the
    next kept speech, so clients must not seek there as if it were this sentence.
    """
    audio_path = conversation.get('audio_path')
    if not audio_path:
        return {'aligned': False, 'reason': 'no audio linked', 'segments': []}
    try:
        aligned, kept = segments_on_recording_axis(
            developer_id, external_user_id, session_id_from_audio_path(audio_path),
            conversation.get('transcript_segments') or [], kept_intervals_hint(conversation),
        )
    except RecordingAlignmentUnavailable as e:
        return {'aligned': False, 'reason': str(e), 'segments': []}
    intervals = normalize_kept_intervals(kept)
    return {
        'aligned': True,
        'segments': [
            {
                'id': s.get('id'),
                'start': round(float(s.get('start') or 0.0), 2),
                'end': round(float(s.get('end') or 0.0), 2),
                'has_audio': _has_audio(s, intervals),
            }
            for s in aligned
        ],
    }
