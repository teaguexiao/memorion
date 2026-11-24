"""Grouping a day's conversations into semantically whole chapters.

A `conversation` is a *transmission artifact*, not a chapter. Its boundaries come
from whatever happened to interrupt the pipe: 120s of silence
(`developer_listen.py` CONVERSATION_CREATION_TIMEOUT), a WebSocket drop, a 60s
upload chunk, the edge of an uploaded file. Measured on real data, 46% of
adjacent conversation pairs are less than 5 minutes apart and 31.6% less than one
minute — those boundaries carry no meaning, and the user sees them as a day
shattered into cards.

This module is the projection that repairs it: a pure function from a day's
conversations to a list of chapters. Nothing here does IO, so the whole boundary
algorithm is unit-testable, and because it is pure, recomputation is idempotent —
chapters can be thrown away and rebuilt after a threshold or prompt change,
without touching the conversations underneath (which have already emitted
webhooks, counted usage and created People, and therefore must never be rewritten).

Two rules govern every boundary decision here:

**A boundary may only come from a physical or a semantic signal.** Real silence
(segment gaps, VAD) is physical; an LLM reading the content is semantic. Anything
produced by clock arithmetic (a duration cap) or by transmission slicing (chunk
size, file edges, batch-transcription ordering) is a *pseudo-boundary*, and this
module must never measure the distance between two pseudo-boundaries. In
particular there is deliberately **no maximum chapter duration** — see
`split_blocks_by_silence`.

**The rule is measured at the segment layer, not the conversation layer.**
Silence exists between segments; between conversations there is only whatever the
transport did. Under batch transcription the conversation layer degenerates
entirely: fixed-size chunks are contiguous, so conversation-level gaps are
identically zero, and a single three-hour upload has no gaps at all. A
conversation-level rule would silently merge such a day into one chapter. On real
data, moving the same 8-minute threshold from the conversation layer to the
segment layer takes the longest chapter from 463 minutes down to 64.8.

Absolute segment time is currently *derived* (`conversation.started_at +
segment.start`) because no segment in production carries an absolute `timestamp`.
That makes `started_at` the single anchor the whole layer rests on; see
`_segment_bounds` for how a stored timestamp is preferred once one exists.

Design notes and measurements: `backend/docs/真章节化-实施方案.md` §3.0, §3.05.
"""

from dataclasses import dataclass, field
from datetime import date as date_cls, datetime, timedelta, timezone
from difflib import SequenceMatcher
from typing import Dict, Iterable, List, Optional, Sequence, Tuple
from utils.conversation_visibility import conversation_is_hidden

# Bumping this invalidates the Phase 2 chapter cache: any change to the
# boundary algorithm below must come with a bump, or stale chapters survive.
ALGO_VERSION = 'seg-3-media-visibility'

# Silence long enough to end a chapter. Chosen from the measured segment-level
# gap distribution, which is extremely bimodal: 87.4% of gaps are under 30s
# (ordinary pauses between sentences) and the next mass is at hours (sleep, not
# wearing the device). Between 1 and 10 minutes there is a near-vacuum — 43 gaps
# out of 3679 segments — so any threshold inside that band gives nearly the same
# result. That insensitivity is the point: the boundary does not hinge on
# guessing this number right.
GAP_MERGE_MINUTES = 8

# Speech intervals this close are one continuous run. Purely a compaction step
# (it cannot change which chapter anything lands in, since 0.5s is far below the
# split threshold) — it keeps the block list proportional to speech runs rather
# than to segment count.
MERGE_ADJACENT_SECONDS = 0.5

# Cross-source duplicate detection: the same words, recorded twice, once by the
# live stream and once by the device's local storage. Clocks on the two paths
# disagree, hence the tolerance window.
DEDUP_OVERLAP_SECONDS = 30
DEDUP_TEXT_RATIO = 0.85

# Minimum length before a prefix relation counts as duplication (see
# `_is_duplicate`). Short utterances legitimately prefix one another — "好" is a
# prefix of "好的，我明白了" — and two people can say both within 30s. Long
# passages sharing an exact prefix cannot happen by chance.
MIN_CONTAINMENT_CHARS = 40

# A segment's span is taken as given, even when it looks impossible next to its
# own text. Rejected alternative, with the measurement that killed it: the live
# chain's re-flush bug (fixed in `developer_listen.py`, see `flushed_segment_ids`)
# left 111 conversations holding a segment whose `end` kept growing while its text
# did not — the worst being 2101 characters claiming 17012s — so it is tempting to
# rebuild such a span from a characters-per-second rate.
#
# Measured over 408 user-days, doing that moves chapters ≥2h from 51 to 50 and
# glued chapters from 38 to 37, while the containment rule below gets 51→49 on its
# own. It buys ~nothing and costs correctness: of 3644 segments longer than 60s,
# 136 sit under 0.05 chars/sec and the samples are *real* sparse speech ("哇。" over
# 63.8s, "你这个人你以后去教。" over 262.6s), which such a rule would silently shorten.
# There is no clean break in that distribution to put a threshold in.
#
# It is also the wrong kind of rule by this module's own standard: a span derived
# from text length is clock arithmetic, i.e. a pseudo-boundary. Duplicate *content*
# is the real signal, and `_is_duplicate` is where it is acted on.

# Sources whose conversation boundaries are transmission artifacts, and may
# therefore be broken apart by segment-level silence. Everything else is treated
# as atomic — including unknown sources, deliberately: failing closed here means
# an unrecognised source can never have a boundary *invented* inside it.
#
# Real-time sources (`app`, `omi`) are atomic for a positive reason, not just
# caution: their boundaries already come from a physical signal (120s of silence),
# so an 8-minute gap *inside* one of them cannot legitimately exist — the flush
# rule would have ended it long before. Finding one means the data is anomalous,
# and splitting on anomalous data buys nothing.
BATCH_SOURCES = frozenset({'sdcard', 'audio_upload'})

# Preference order when two sources recorded the same words. The live path is
# kept because it is the one that carries speaker identity (`person_id`,
# `is_user` from voiceprint matching); the batch path usually has neither.
#
# ⚠️ This ranking only holds for hardware whose live stream is *stored*. On
# Memorion v1 (local storage) the live stream is a screen-only preview that never
# becomes a conversation, so the card — a `sdcard` source — is the complete and
# authoritative copy, and preferring `app` over it would be backwards.
#
# It is deliberately left as-is rather than made conditional: that design
# guarantees the two never coexist, so this ranking is never consulted for
# Memorion v1 audio. What it still decides, correctly, is DevKit1's `app` (whose
# BLE stream really is the only copy) against the watch's `audio_upload`.
# See docs/architecture/录音源与转录路径设计.md §7.3.
_REALTIME_SOURCES = frozenset({'app', 'omi', 'friend', 'openglass'})


@dataclass
class SegmentRef:
    """One transcript segment placed on the day's absolute time axis.

    Carries a back-reference to where it came from (`conversation_id` + `index`)
    rather than a copy of the segment, so a chapter stays cheap and the original
    transcript remains the single source of truth for drill-down.
    """

    conversation_id: str
    index: int
    source: str
    start: datetime
    end: datetime
    text: str
    has_speaker_identity: bool = False

    @property
    def splittable(self) -> bool:
        return _splittable(self.source)


@dataclass
class Block:
    """An indivisible unit of timeline that chapters are built out of.

    For a batch-transcribed conversation a block is one run of continuous speech,
    so silence inside the conversation can split it. For every other source the
    whole conversation is a single block, spanning its first to its last spoken
    word — never `started_at`/`finished_at`, which include transport padding.
    """

    start: datetime
    end: datetime
    conversation_id: str
    refs: List[SegmentRef] = field(default_factory=list)
    # True when the block claims timeline it cannot prove with transcript
    # content (see `_fallback_block`).
    empty: bool = False


def _splittable(source: Optional[str]) -> bool:
    return (source or '') in BATCH_SOURCES


def _as_utc(value) -> Optional[datetime]:
    """Firestore hands back aware datetimes; locally constructed ones may be naive."""
    if not isinstance(value, datetime):
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _source_rank(source: Optional[str]) -> int:
    return 0 if (source or '') in _REALTIME_SOURCES else 1


def _normalize_text(text: Optional[str]) -> str:
    """Collapse whitespace and case so the same sentence from two STT passes matches."""
    return ' '.join((text or '').lower().split())


def _segment_bounds(anchor: Optional[datetime], seg: dict) -> Optional[Tuple[datetime, datetime]]:
    """Absolute start/end of a segment, preferring a stored absolute timestamp.

    `sync.py` writes an absolute `timestamp` but that path never runs on the live
    chain, so in practice every segment today is derived from `anchor`
    (= `conversation.started_at`). Reading `timestamp` first means that once
    firmware supplies real recording times and transcription lands them per
    segment, this module starts using them without a change here — which matters,
    because the derived form is only as correct as the anchor, and two write paths
    are known to set the anchor to the upload moment instead of the recording
    moment (`audio_upload.py` `now()` fallback, `wals.dart` byte-count
    back-calculation).
    """
    try:
        start_offset = float(seg.get('start') or 0.0)
        raw_end = seg.get('end')
        end_offset = float(raw_end) if raw_end is not None else start_offset
    except (TypeError, ValueError):
        return None
    duration = timedelta(seconds=max(0.0, end_offset - start_offset))

    stored = seg.get('timestamp')
    if isinstance(stored, datetime):
        start = _as_utc(stored)
        return start, start + duration
    if isinstance(stored, (int, float)) and not isinstance(stored, bool) and stored > 0:
        start = datetime.fromtimestamp(float(stored), tz=timezone.utc)
        return start, start + duration

    if anchor is None:
        return None
    return anchor + timedelta(seconds=start_offset), anchor + timedelta(seconds=start_offset) + duration


def collect_segment_refs(convos: Sequence[dict]) -> List[SegmentRef]:
    """Flatten every conversation's segments onto one absolute time axis.

    Discarded conversations are dropped here — that is a hard rule, not a caller
    preference. Status filtering is left to the caller, so an in-progress
    conversation can still appear in a live timeline.
    """
    refs: List[SegmentRef] = []
    for convo in convos or ():
        if conversation_is_hidden(convo):
            continue
        anchor = _as_utc(convo.get('started_at'))
        convo_id = convo.get('id') or ''
        source = convo.get('source') or ''
        for index, seg in enumerate(convo.get('transcript_segments') or ()):
            if not isinstance(seg, dict):
                continue
            text = (seg.get('text') or '').strip()
            if not text:
                continue
            bounds = _segment_bounds(anchor, seg)
            if bounds is None:
                continue
            start, end = bounds
            refs.append(
                SegmentRef(
                    conversation_id=convo_id,
                    index=index,
                    source=source,
                    start=start,
                    end=end,
                    text=text,
                    has_speaker_identity=bool(seg.get('is_user') or seg.get('person_id')),
                )
            )
    refs.sort(key=_ref_sort_key)
    return refs


def _ref_sort_key(ref: SegmentRef):
    # Fully specified so repeated runs over the same day are byte-identical:
    # idempotence is what makes the cache in Phase 2 safe to overwrite.
    return (ref.start, ref.end, ref.conversation_id, ref.index)


def _is_duplicate(a: SegmentRef, b: SegmentRef) -> bool:
    """Same words, same stretch of real time, two different conversations."""
    if a.conversation_id == b.conversation_id:
        # Two identical utterances inside one conversation are a real repetition
        # ("嗯" ... "嗯"), never a double recording.
        return False
    tolerance = timedelta(seconds=DEDUP_OVERLAP_SECONDS)
    if a.start - tolerance > b.end or b.start - tolerance > a.end:
        return False
    left, right = _normalize_text(a.text), _normalize_text(b.text)
    if left == right:
        return True
    # Containment, checked before similarity because the two are different
    # relations and this one is invisible to the other. The live chain's
    # re-flush bug emits copies that are strict prefix supersets of each other
    # (74 → 179 → 617 → 684 → 2101 characters of the same session), and pairwise
    # similarity between those is 0.068–0.585: a `ratio()` threshold high enough
    # to be safe can never catch them, while `startswith` catches all of them.
    if len(left) >= MIN_CONTAINMENT_CHARS and len(right) >= MIN_CONTAINMENT_CHARS:
        if left.startswith(right) or right.startswith(left):
            return True
    matcher = SequenceMatcher(None, left, right)
    # difflib's cheap upper bounds first: `ratio()` is O(n*m) and this runs over
    # every overlapping pair in a day.
    if matcher.real_quick_ratio() < DEDUP_TEXT_RATIO or matcher.quick_ratio() < DEDUP_TEXT_RATIO:
        return False
    return matcher.ratio() >= DEDUP_TEXT_RATIO


def _prefer(a: SegmentRef, b: SegmentRef) -> SegmentRef:
    """Which copy of a duplicated sentence to keep.

    Source rank and speaker identity come first because they carry information the
    other copy cannot supply (the live path has `person_id`; a batch upload does
    not). Length only breaks ties between otherwise equivalent copies — but it
    matters there: with containment matching the two copies are a prefix and its
    superset, so keeping the shorter one would silently truncate the sentence.
    """
    keys = (
        lambda r: _source_rank(r.source),
        lambda r: 0 if r.has_speaker_identity else 1,
        lambda r: -len(r.text or ''),
    )
    for key in keys:
        if key(a) != key(b):
            return a if key(a) < key(b) else b
    return a if _ref_sort_key(a) <= _ref_sort_key(b) else b


def dedup_segment_refs(refs: Sequence[SegmentRef]) -> Tuple[List[SegmentRef], List[SegmentRef]]:
    """Drop segments that are a second recording of speech already accounted for.

    This is the last line of defence against dual-source recording, and the only
    one that works when the two sources are different devices, since their ids can
    never collide.

    The other two defences, and why neither makes this one optional:

    1. Acquisition-side priority. On DevKit1 (no storage) the firmware picks one
       outlet per packet — BLE if the app is subscribed, otherwise nothing at all
       (`transport.c:867`) — and that choice leaks at every switchover. On
       Memorion v1 there is no switchover to leak at: the card is always written
       and the live stream never becomes a conversation, so the hardware
       contributes exactly one copy.
    2. chunk_id idempotency, which catches a re-upload of the same data but cannot
       see two *devices* recording the same wall-clock time at all.

    Neither covers Apple Watch, and that case is structurally un-arbitrable: the
    phone cannot even observe that the watch is recording (`WatchStatus` has no
    such field), let alone stop a watch that is nowhere near it. So this layer is
    not optional today and will not become optional when the storage hardware
    ships. See docs/architecture/录音源与转录路径设计.md §7.2.

    It is deliberately keyed on `conversation_id`, not on `source`, and that turns
    out to matter today rather than only after hardware ships: on real data it
    catches *same-source* duplicate writes — two `source=app` conversations created
    0.9s apart carrying the same 19 segments verbatim. Those are the write-path bug
    behind the measured 12.4% of overlapping adjacent pairs. Deduping them is right
    regardless of the root cause, because the chapter layer must not show the user
    the same sentence twice.

    Returns `(kept, dropped)`; the dropped list exists so the shadow comparison
    can show what was removed rather than having segments vanish silently.
    """
    kept: List[SegmentRef] = []
    dropped: List[SegmentRef] = []
    tolerance = timedelta(seconds=DEDUP_OVERLAP_SECONDS)
    # How far back to scan for a match. `kept` is start-ordered, so anything
    # starting earlier than (this ref's start − tolerance − the longest segment
    # seen so far) cannot still overlap, and the walk can stop.
    longest = timedelta(0)
    for ref in sorted(refs, key=_ref_sort_key):
        cutoff = ref.start - tolerance - longest
        replaced_at = None
        for position in range(len(kept) - 1, -1, -1):
            candidate = kept[position]
            if candidate.start < cutoff:
                break
            if _is_duplicate(candidate, ref):
                replaced_at = position
                break
        longest = max(longest, ref.end - ref.start)
        if replaced_at is None:
            kept.append(ref)
            continue
        incumbent = kept[replaced_at]
        winner = _prefer(incumbent, ref)
        kept[replaced_at] = winner
        dropped.append(ref if winner is incumbent else incumbent)
    kept.sort(key=_ref_sort_key)
    return kept, dropped


def _fallback_block(convo: dict) -> Optional[Block]:
    """A zero-length block for a conversation with no usable transcript.

    Such a conversation exists on the user's timeline today (they can see the
    card), so dropping it would make the chapter layer quietly lose data — worse
    than an imprecise boundary. But it cannot prove it occupied any span either,
    so it claims a single instant instead of `started_at`→`finished_at`; letting a
    content-less conversation claim hours would glue unrelated chapters together.
    """
    anchor = _as_utc(convo.get('started_at'))
    if anchor is None:
        return None
    return Block(start=anchor, end=anchor, conversation_id=convo.get('id') or '', refs=[], empty=True)


def build_blocks(
    convos: Sequence[dict],
    refs: Sequence[SegmentRef],
    deduped_away: Iterable[SegmentRef] = (),
) -> List[Block]:
    """Turn surviving segments into the indivisible units chapters are made of.

    `deduped_away` is what `dedup_segment_refs` dropped, and it is required to
    tell apart two cases that both arrive here as "this conversation owns no
    segments": one that never had a usable transcript (gets a placeholder block,
    see `_fallback_block`) and one whose every segment was a duplicate of another
    conversation's. Giving the second a placeholder resurrects it as an empty
    chapter card — measured on real data: of 94 verbatim-duplicate pairs, dedup
    caught all 94, yet 3 still rendered as two chapters, the second holding
    0 segments and 0 speech seconds. The duplicate the user should never have
    seen came back as a blank card.
    """
    by_conversation: Dict[str, List[SegmentRef]] = {}
    for ref in refs:
        by_conversation.setdefault(ref.conversation_id, []).append(ref)
    fully_deduped = {ref.conversation_id for ref in deduped_away} - set(by_conversation)

    blocks: List[Block] = []
    for convo in convos or ():
        if conversation_is_hidden(convo):
            continue
        convo_id = convo.get('id') or ''
        own = by_conversation.get(convo_id) or []
        if not own:
            if convo_id in fully_deduped:
                # Every word it held is already on the timeline under another
                # conversation. It is not missing data; it is redundant data.
                continue
            fallback = _fallback_block(convo)
            if fallback is not None:
                blocks.append(fallback)
            continue
        if _splittable(convo.get('source')):
            blocks.extend(_speech_runs(convo_id, own))
        else:
            blocks.append(
                Block(
                    start=own[0].start,
                    end=max(r.end for r in own),
                    conversation_id=convo_id,
                    refs=list(own),
                )
            )
    blocks.sort(key=lambda b: (b.start, b.end, b.conversation_id))
    return blocks


def _speech_runs(conversation_id: str, refs: Sequence[SegmentRef]) -> List[Block]:
    """Split one conversation's segments into runs of continuous speech."""
    runs: List[Block] = []
    for ref in sorted(refs, key=_ref_sort_key):
        if runs and (ref.start - runs[-1].end).total_seconds() <= MERGE_ADJACENT_SECONDS:
            runs[-1].end = max(runs[-1].end, ref.end)
            runs[-1].refs.append(ref)
            continue
        runs.append(Block(start=ref.start, end=ref.end, conversation_id=conversation_id, refs=[ref]))
    return runs


def split_blocks_by_silence(blocks: Sequence[Block], gap_minutes: float = GAP_MERGE_MINUTES) -> List[List[Block]]:
    """Group blocks into chapters, breaking only on real silence.

    Silence is the *only* break condition. There is deliberately no duration cap,
    and adding one would be a regression: measured on 23 chapters over 45 minutes,
    14 have no trustworthy internal split point at all (largest internal gap under
    one minute, several negative because the intervals overlap), and the 9 that do
    top out at 3.5–7.2 minutes — all *below* the merge threshold, so using them as
    split points contradicts the merge rule. Recursively cutting at 45 minutes
    moved 265 chapters to 294 (+11%) without shifting p90 at all, at the price of
    37 chapters cut mid-sentence. Grouping by local day already provides the only
    honest upper bound.

    Gaps are measured against the group's running maximum end, not the previous
    block's end: blocks can overlap or nest (12.4% of adjacent conversation pairs
    do), and comparing against a block that ended early would manufacture a gap
    that no listener experienced.
    """
    threshold = timedelta(minutes=gap_minutes)
    groups: List[List[Block]] = []
    running_end: Optional[datetime] = None
    for block in blocks:
        if groups and (block.start - running_end) < threshold:
            groups[-1].append(block)
            running_end = max(running_end, block.end)
        else:
            groups.append([block])
            running_end = block.end
    return groups


def _refine_semantically(groups: List[List[Block]]) -> List[List[Block]]:
    """Second pass, reserved: split a chapter where the topic changed mid-speech.

    Identity for now. Silence cannot detect "kept talking but moved on to
    something else", and no physical signal ever will — only reading the content
    can. The current data does not justify building it yet (the live path's
    disease is over-cutting: 46% of boundaries are spurious, while only 9.8% of
    conversations exceed 30 minutes), but that measurement describes the live
    path. Once hardware records offline for hours at a stretch, continuous
    multi-hour recordings become normal and the balance shifts.

    When it is implemented it must trigger on *content* — transcript length past a
    threshold, then let the LLM look for a real topic turn and return the group
    unchanged when it finds none. Triggering on elapsed time would be the
    duration cap we just rejected, wearing a different name.
    """
    return groups


def _merged_voice_runs(blocks: Sequence[Block]) -> List[Tuple[datetime, datetime]]:
    """The chapter's spans of actual speech, as a disjoint ascending sequence.

    Built from segment intervals rather than block spans, for two reasons. An
    atomic (live) block spans its conversation's internal pauses, so its span
    overstates speech. And overlapping recordings of the same moment must collapse
    into one interval — production really does hold three conversations claiming
    the same 84 minutes (`closest_memory` append + a duplicate transcription pass),
    and un-merged spans there sum to 99.8min inside an 83.7min chapter. Anything
    that adds these up — a timeline bar, an unworn-gap calculation, an hours
    counter — would then report more speech than the chapter contains.
    """
    intervals = sorted(
        ((ref.start, ref.end) for block in blocks for ref in block.refs),
        key=lambda pair: pair[0],
    )
    merged: List[Tuple[datetime, datetime]] = []
    for start, end in intervals:
        if merged and start <= merged[-1][1]:
            if end > merged[-1][1]:
                merged[-1] = (merged[-1][0], end)
            continue
        merged.append((start, end))
    return merged


def _merged_speech_seconds(blocks: Sequence[Block]) -> float:
    """Wall-clock seconds with someone actually speaking, double-counting nothing."""
    return sum((end - start).total_seconds() for start, end in _merged_voice_runs(blocks))


def _chapter_from_blocks(blocks: Sequence[Block]) -> dict:
    refs = sorted((ref for block in blocks for ref in block.refs), key=_ref_sort_key)
    conversation_ids: List[str] = []
    for block in blocks:
        if block.conversation_id and block.conversation_id not in conversation_ids:
            conversation_ids.append(block.conversation_id)
    start = blocks[0].start
    end = max(b.end for b in blocks)
    voice_runs = _merged_voice_runs(blocks)
    return {
        'start': start,
        'end': end,
        'duration_seconds': (end - start).total_seconds(),
        'speech_seconds': sum((e - s).total_seconds() for s, e in voice_runs),
        'source_conversation_ids': conversation_ids,
        # Segment-level provenance, not just conversation ids: a batch-transcribed
        # conversation can be split across chapters, so a chapter cannot be
        # described by whole conversations alone. Carried even though the current
        # (live-only) data never actually splits one, to avoid a data-model
        # migration when it does.
        'segment_refs': [{'conversation_id': r.conversation_id, 'index': r.index} for r in refs],
        # Disjoint and ascending, and consistent with `speech_seconds` above — see
        # `_merged_voice_runs`. Blocks are NOT usable here: they can nest.
        'voice_runs': [{'start': s, 'end': e} for s, e in voice_runs],
        'algo_version': ALGO_VERSION,
    }


def segment_day_into_chapters(convos: Sequence[dict], tz: Optional[str] = None) -> List[dict]:
    """One day's conversations to chapter boundaries. Pure: no IO, no LLM.

    `tz` is accepted for symmetry with the caller and for future rules that need
    local wall-clock context; day membership is decided before this call, by
    `filter_convos_for_local_day`.

    Returns boundary and provenance only. Titles and summaries are a separate,
    LLM-calling step (`summarize_chapter`) so that everything about *where* a
    chapter begins stays testable without a network.
    """
    refs, dropped = dedup_segment_refs(collect_segment_refs(convos))
    blocks = build_blocks(convos, refs, deduped_away=dropped)
    if not blocks:
        return []
    groups = _refine_semantically(split_blocks_by_silence(blocks))
    return [_chapter_from_blocks(group) for group in groups if group]


def filter_convos_for_local_day(convos: Iterable[dict], tz, day: date_cls) -> List[dict]:
    """Keep conversations whose `started_at` falls on `day` in the user's timezone.

    Attribution is by `started_at`, so a conversation running 23:40–00:20 belongs
    entirely to the day it began — one conversation, one chapter, one day.

    Note this is *not* what `dev_db.get_conversations` filters on: that query
    ranges over `created_at`, which for batch-synced audio can be a day or more
    after the recording. Callers must widen the query window and filter here.
    """
    kept = []
    for convo in convos or ():
        started_at = _as_utc(convo.get('started_at'))
        if started_at is None:
            continue
        if started_at.astimezone(tz).date() == day:
            kept.append(convo)
    kept.sort(key=lambda c: (_as_utc(c.get('started_at')), c.get('id') or ''))
    return kept
