"""User corrections live separately from the recomputable chapter projection."""

import hashlib
import json
from datetime import datetime, timezone

from utils.timeline.speakers import present_speakers, chapter_evidence
from utils.timeline.chaptering import segment_day_into_chapters
from utils.timeline.summary_dependencies import digest


def chapter_edit_id(chapter: dict) -> str:
    """Use the span AND sources: one recording can occur in several chapters.

    Normalize timezone spellings so a mobile UTC selector matches Firestore
    timestamps. Never match a changed/split/merged chapter by its title alone.
    """
    def instant(value):
        if isinstance(value, str):
            value = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if not isinstance(value, datetime) or value.tzinfo is None:
            raise ValueError('Chapter timestamps must include a timezone')
        return value.astimezone(timezone.utc).isoformat()

    payload = [instant(chapter['start']), instant(chapter['end']),
               sorted(set(chapter['source_conversation_ids']))]
    return hashlib.sha256(json.dumps(payload).encode()).hexdigest()


def apply_chapter_edits(document: dict, edits: dict, sources=None) -> dict:
    """Overlay only user-owned fields; leave the stored AI summary untouched."""
    chapters = []
    for chapter in document.get('chapters') or []:
        edit = edits.get(chapter_edit_id(chapter), {})
        evidence = None
        if (chapter.get('_manual_overview_digest') == digest(edit.get('overview'))
                and '_manual_speaker_evidence' in chapter):
            evidence = chapter['_manual_speaker_evidence']
        elif sources is not None and edit.get('overview_speaker_display'):
            projected = chapter
            if not chapter.get('segment_refs'):
                projected = next((candidate for candidate in segment_day_into_chapters(list(sources.values()))
                                  if chapter_edit_id(candidate) == chapter_edit_id(chapter)), {})
            evidence = chapter_evidence(projected, sources)
        corrected = present_speakers(chapter, edit, evidence=evidence)
        corrected.pop('_manual_speaker_evidence', None)
        corrected.pop('_manual_overview_digest', None)
        chapters.append(corrected)
    return {**document, 'chapters': chapters}
