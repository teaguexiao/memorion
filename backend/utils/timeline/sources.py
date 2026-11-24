"""Build summary inputs from a chapter's selected segments, not whole recordings."""

from collections import Counter
from typing import Dict, List

from utils.timeline.chaptering import _as_utc, _segment_bounds
from utils.timeline.summary_dependencies import digest
from utils.timeline.speakers import chapter_evidence, evidence_id


def _recording_keys(conversation_ids):
    """Compact stable anchors, extending only collisions to keep sources distinct.

    Six decimal digits cost much less context than a hex digest repeated on every
    segment. Adding unrelated recordings preserves an anchor unless its short
    identifier collides, in which case both affected inputs must be rerendered.
    """
    fingerprints = {cid: int(digest(cid), 16) for cid in conversation_ids}
    widths = {cid: 6 for cid in fingerprints}
    while True:
        keys = {cid: f'R{value % (10 ** widths[cid]):0{widths[cid]}d}'
                for cid, value in fingerprints.items()}
        counts = Counter(keys.values())
        collisions = [cid for cid, key in keys.items() if counts[key] > 1]
        if not collisions:
            return keys
        for cid in collisions:
            if widths[cid] >= 78:  # Full SHA-256 decimal representation.
                raise ValueError('Source fingerprints collide')
            widths[cid] += 3


def chapter_fragments(chapter: dict, by_id: Dict[str, dict]) -> List[dict]:
    fragments = []
    evidence = chapter_evidence(chapter, by_id)
    speaker_keys = _recording_keys({item['speaker_id'] for item in evidence.values()})
    evidence = {eid: dict(item, source_speaker_key='S' + speaker_keys[item['speaker_id']][1:])
                for eid, item in evidence.items()}
    refs = chapter.get('segment_refs') or []
    keys = _recording_keys(chapter.get('source_conversation_ids') or [])
    for cid in chapter.get('source_conversation_ids') or []:
        convo = by_id.get(cid)
        if not convo:
            continue
        structured = dict(convo.get('structured') or {})
        recording_key = keys[cid]
        structured['recording_key'] = recording_key
        structured['source_label'] = f"{recording_key}: Recording started {convo.get('started_at', 'unknown')}"
        segments = convo.get('transcript_segments') or []
        indices = list(dict.fromkeys(
            ref.get('index') for ref in refs if ref.get('conversation_id') == cid
            and isinstance(ref.get('index'), int) and not isinstance(ref.get('index'), bool)
            and 0 <= ref['index'] < len(segments)
        ))
        selected = [(index, segments[index]) for index in indices
                    if isinstance(segments[index], dict) and (segments[index].get('text') or '').strip()]
        if selected:
            lines = []
            for index, segment in selected:
                bounds = _segment_bounds(_as_utc(convo.get('started_at')), segment)
                timestamp = (bounds[0].isoformat() if bounds and segment.get('timestamp') is not None
                             else f"+{segment.get('start', 0)}s")
                eid = evidence_id(cid, segment, index)
                item = evidence[eid]
                # Recording and identity metadata is supplied once per batch.
                # Repeating UUIDs on thousands of short utterances can exceed
                # the request budget even when the actual speech is short.
                # Some legacy ASR segments contain whole paragraphs. Keep the
                # same source attribution on each bounded continuation so a
                # later model batch cannot lose the speaker of a long segment.
                text = segment['text']
                for start in range(0, len(text), 6000):
                    lines.append(f"[[speaker:{eid}]] {item['source_speaker_key']} {timestamp} {text[start:start + 6000]}")
            structured.update(
                source_text='\n'.join(lines),
                # Evidence-backed attribution needs a fresh summary even for
                # one recording: its old prose has no speaker references and
                # may cover other chapters. This intentionally incurs one lazy
                # regeneration per accessed day/version, within the existing
                # per-chapter/day batch budgets and shared inference cache.
                requires_rollup=True,
                # Only a chapter holding the whole recording may show that
                # recording's own summary when its rollup fails; for part of
                # one, that summary describes other chapters too.
                covers_recording={i for i, _ in selected} == {
                    i for i, seg in enumerate(segments) if isinstance(seg, dict) and (seg.get('text') or '').strip()},
                speaker_evidence={eid: item for eid, item in evidence.items() if item['conversation_id'] == cid},
            )
        elif refs and segments:
            # This source contributed no selected text (e.g. overlap removal).
            # Its full transcript/summary cannot supply evidence for this chapter.
            continue
        fragments.append(structured)
    return fragments
