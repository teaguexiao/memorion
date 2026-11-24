"""Pure time-axis math for VAD-trimmed audio.

Split out of ``utils.stt.vad`` on purpose: that module downloads and loads the
Silero VAD model at import time, which makes anything importing it slow and
untestable. The mapping below is plain arithmetic with no model dependency, and
it sits on the correctness path for speaker identification, so it needs to be
cheap to import and easy to test.

``utils.stt.vad`` re-exports ``remap_segments_to_trimmed_axis`` for backwards
compatibility.
"""

from copy import deepcopy
from typing import Any, Iterable, List, Sequence, Tuple


class UnknownTimestampAxis(ValueError):
    """A legacy transcript cannot safely be aligned to its recording."""


def stream_segment(segment: dict, display_offset: float) -> dict:
    """Keep STT coordinates while returning an independent display copy."""
    result = deepcopy(segment)
    result['original_start'] = float(segment.get('start', 0.0))
    result['original_end'] = float(segment.get('end', 0.0))
    result['timestamp_axis'] = 'display'
    result['start'] = round(result['original_start'] - display_offset, 3)
    result['end'] = round(result['original_end'] - display_offset, 3)
    return result


def conversation_segments(segments: Sequence[dict]) -> List[dict]:
    """Snapshot a batch and rebase its display times without losing STT times."""
    result = deepcopy(list(segments))
    if result:
        origin = min(float(s.get('start', 0.0)) for s in result)
        for s in result:
            if has_original_timestamps([s]) or s.get('timestamp_axis') in ('audio', 'stream'):
                s['timestamp_axis'] = 'display'
            s['start'] = round(float(s.get('start', 0.0)) - origin, 3)
            s['end'] = round(float(s.get('end', 0.0)) - origin, 3)
    return result


def has_original_timestamps(segments: Sequence[dict]) -> bool:
    return bool(segments) and all(
        s.get('original_start') is not None and s.get('original_end') is not None
        for s in segments
    )


def restore_original_timestamps(segments: Sequence[dict], session: dict) -> List[dict]:
    """Recover an older client's display times from the server's own transcript.

    Match text and speaker, never infer an axis from whether a span fits the WAV.
    Ambiguous/repeated sentences remain unresolved.
    """
    result = deepcopy(list(segments))
    canonical = session.get('transcript_segments') or []
    def key(s):
        return ((s.get('text') or '').strip(), s.get('speaker_id', s.get('speaker', 0)))
    if len(result) == len(canonical) and has_original_timestamps(canonical) and all(
        key(a) == key(b) for a, b in zip(result, canonical)
    ):
        for a, b in zip(result, canonical):
            a.update({k: b[k] for k in ('original_start', 'original_end')})
            a['timestamp_axis'] = 'display'
        return result
    candidates = {}
    for s in canonical:
        if has_original_timestamps([s]):
            candidates.setdefault(key(s), []).append(s)
    for s in result:
        if has_original_timestamps([s]):
            continue
        matches = candidates.get(key(s), [])
        if len(matches) == 1:
            s.update({k: matches[0][k] for k in ('original_start', 'original_end')})
            s['timestamp_axis'] = 'display'
    return result


def normalize_kept_intervals(kept_intervals: Iterable[Any]) -> List[Tuple[float, float]]:
    """Coerce kept intervals into ``[(start, end), ...]``, dropping junk.

    Accepts both the in-memory shape (tuples/lists) and the Firestore shape
    (``{"start": ..., "end": ...}`` maps — Firestore rejects nested arrays, so
    intervals have to round-trip as maps).
    """
    normalized: List[Tuple[float, float]] = []
    for interval in kept_intervals or ():
        if isinstance(interval, dict):
            start, end = interval.get('start'), interval.get('end')
        elif isinstance(interval, (list, tuple)) and len(interval) >= 2:
            start, end = interval[0], interval[1]
        else:
            continue
        if start is None or end is None:
            continue
        try:
            normalized.append((float(start), float(end)))
        except (TypeError, ValueError):
            continue
    return normalized


def transcribed_spans(segments: Sequence[dict]) -> List[Tuple[float, float]]:
    """Where STT heard speech, on the session audio's own axis.

    Only ``original_start``/``original_end`` count: display times are rebased to
    the conversation, and on-device STT (``custom_stt``) has its original times
    stripped because its clock can restart mid-session. Zero-length segments are
    kept — Soniox emits them for real words, and padding gives them audio.

    Never raises: the WS finally computes this inside the block that saves the
    recording, and an exception there loses the whole session's audio.
    """
    spans: List[Tuple[float, float]] = []
    for segment in segments or ():
        if not isinstance(segment, dict):
            continue
        start, end = segment.get('original_start'), segment.get('original_end')
        if start is None or end is None:
            continue
        try:
            start, end = float(start), float(end)
        except (TypeError, ValueError):
            continue
        if end >= start:
            spans.append((start, end))
    return spans


def merge_speech_spans(
    spans: Iterable[Tuple[float, float]], *, total_s: float, merge_gap: float = 1.0, pad_s: float = 0.2,
) -> List[Tuple[float, float]]:
    """Speech spans → the intervals a trimmed wav keeps (sorted, disjoint, inside the audio).

    Spans closer than ``merge_gap`` join, each joined span gets ``pad_s`` on both
    sides, and anything outside ``[0, total_s]`` is clipped away. Input may be
    unsorted and overlapping: VAD and STT spans are mixed here.
    """
    merged: List[List[float]] = []
    for start, end in sorted((float(s), float(e)) for s, e in spans if e >= s):
        if merged and start - merged[-1][1] < merge_gap:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    kept: List[Tuple[float, float]] = []
    for start, end in merged:
        start, end = max(0.0, start - pad_s), min(total_s, end + pad_s)
        if end <= start:
            continue
        if kept and start <= kept[-1][1]:
            kept[-1] = (kept[-1][0], max(kept[-1][1], end))
        else:
            kept.append((start, end))
    return kept


def remap_segments_to_trimmed_axis(segments: Sequence[dict], kept_intervals: Iterable[Any]):
    """
    Remap STT transcript segment timestamps from the original (pre-trim)
    audio time axis to the trimmed audio time axis.

    Args:
        segments: list of dicts with 'start' and 'end' seconds (mutated in place).
        kept_intervals: list of (start_s, end_s) tuples in the original axis,
            in order, that were retained in the trimmed audio.

    Segments fully outside any kept interval are left with start==end so the
    caller can drop or skip them. Segments partially overlapping a kept
    interval are clipped to the overlap. Segments that span multiple kept
    intervals collapse the gaps.
    """
    intervals = normalize_kept_intervals(kept_intervals)
    if not intervals:
        for seg in segments:
            seg['start'] = 0.0
            seg['end'] = 0.0
        return segments

    # Cumulative trimmed-axis offset at the start of each kept interval.
    offsets = []
    cum = 0.0
    for s, e in intervals:
        offsets.append(cum)
        cum += max(0.0, e - s)

    def map_point(t: float) -> float:
        # Find which kept interval contains t; clamp if it falls in a gap.
        for (s, e), off in zip(intervals, offsets):
            if t < s:
                return off  # in a removed gap before this interval -> clamp to its start
            if t <= e:
                return off + (t - s)
        # past last kept interval
        last_s, last_e = intervals[-1]
        return offsets[-1] + max(0.0, last_e - last_s)

    for seg in segments:
        new_start = map_point(float(seg.get('start', 0.0)))
        new_end = map_point(float(seg.get('end', 0.0)))
        if new_end < new_start:
            new_end = new_start
        seg['start'] = round(new_start, 3)
        seg['end'] = round(new_end, 3)
    return segments


def segments_on_audio_axis(
    segments: Sequence[dict], kept_intervals: Iterable[Any], *, require_provenance: bool = False,
) -> List[dict]:
    """Return a COPY of ``segments`` with timestamps on the trimmed audio's axis.

    Display-normalized times must be restored from original_start/end before VAD
    mapping. Explicit audio-axis copies pass through unchanged, making repeated
    alignment safe. Production audio consumers require provenance; arithmetic
    callers may still explicitly map legacy original-axis fixtures.
    """
    intervals = normalize_kept_intervals(kept_intervals)
    if require_provenance and kept_intervals is not None:
        for seg in segments:
            if not has_original_timestamps([seg]) and seg.get('timestamp_axis') not in ('audio', 'stream'):
                raise UnknownTimestampAxis('Missing original STT timestamps or an explicit audio axis')
    if not intervals and not any(has_original_timestamps([s]) for s in segments):
        return segments if isinstance(segments, list) else list(segments)
    copies = deepcopy(list(segments))
    pending = []
    for seg in copies:
        if seg.get('timestamp_axis') == 'audio':
            continue  # Already mapped: applying VAD twice collapses valid clips.
        if seg.get('original_start') is not None and seg.get('original_end') is not None:
            seg['start'] = seg['original_start']
            seg['end'] = seg['original_end']
        elif intervals and require_provenance and seg.get('timestamp_axis') != 'stream':
            raise UnknownTimestampAxis('Missing original STT timestamps for trimmed audio')
        if intervals:
            pending.append(seg)
            seg['timestamp_axis'] = 'audio'
        elif has_original_timestamps([seg]):
            seg['timestamp_axis'] = 'stream'
    if intervals:
        remap_segments_to_trimmed_axis(pending, intervals)
    return copies
