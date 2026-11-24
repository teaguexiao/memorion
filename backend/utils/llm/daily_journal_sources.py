"""Diary evidence: retain raw speech instead of summarizing summaries.

No source slicing or sampling. Missing transcripts fall back to the structured
notes; for recorded conversations the transcript is authoritative, avoiding
unsupported narrative flourishes in previously generated summaries.
"""

import logging
from datetime import datetime, timezone
from typing import Any, Optional


logger = logging.getLogger(__name__)


def parse_daily_journal_people(records: list[dict]) -> list[Any]:
    """Invalid historical profiles fall back to original Speaker N labels."""
    from models.other import Person
    from pydantic import ValidationError

    people = []
    for record in records:
        try:
            people.append(Person(**record))
        except (ValidationError, TypeError):
            logger.warning('Skipping invalid diary person profile; original speaker label retained')
    return people


def build_daily_journal_history(conversations: list[Any], people: Optional[list[Any]] = None) -> str:
    def recorded_at(conversation):
        dt = conversation.started_at or conversation.created_at or datetime.min.replace(tzinfo=timezone.utc)
        return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt.astimezone(timezone.utc)

    blocks = []
    for index, conversation in enumerate(sorted([c for c in conversations if not getattr(c, 'discarded', False)], key=recorded_at), 1):
        transcript = conversation.get_transcript(include_timestamps=False, people=people or []).strip()
        time_label = f'{recorded_at(conversation).isoformat()} UTC' if conversation.started_at or conversation.created_at else 'Recording time unknown'
        header = f'Conversation #{index}\n{time_label}\nSpeaker identities apply only within this conversation. Never link Speaker N across conversations.'
        if transcript:
            # Do not include the generated overview: it can contain inferred
            # emotions, outcomes, or quotes absent from the original speech.
            identified = any(line.startswith('User: ') for line in transcript.splitlines())
            attribution = ('Only User-labelled turns belong to the diary writer.' if identified else
                           'No turn is identified as User. Do not attribute any speech, action or commitment to the diary writer.')
            body = f'Speaker attribution: {attribution}\nTranscript (verbatim speech):\n{transcript}'
        else:
            notes = conversation.structured
            lines = [getattr(notes, 'title', ''), getattr(notes, 'overview', '')]
            lines.extend(f'Action item: {item.description}' for item in getattr(notes, 'action_items', []) or [])
            lines.extend(f'Event: {event.title}' for event in getattr(notes, 'events', []) or [])
            body = 'Summary notes (no verbatim transcript available):\n' + '\n'.join(line for line in lines if line)
        logger.info('Daily journal source %s: kind=%s chars=%s user_identified=%s', index,
                    'transcript' if transcript else 'summary', len(body), identified if transcript else False)
        blocks.append(f'{header}\n{body}')
    return '\n\n---------------------\n\n'.join(blocks)


def read_daily_journal_document(document) -> dict:
    """Hydrate a scheduled diary record, including chunked or compressed speech.

    Fail on unreadable transcript storage rather than silently writing a summary
    while the original speech exists. This performs reads only.
    """
    import json
    import zlib

    data = document.to_dict()
    if data.get('transcript_segments_chunked'):
        chunks = [chunk.to_dict() for chunk in document.reference.collection('transcript_chunks').stream()]
        chunks.sort(key=lambda chunk: chunk['index'])
        if not chunks or [chunk['index'] for chunk in chunks] != list(range(len(chunks))):
            raise ValueError('daily journal transcript chunks are missing or out of sequence')
        data['transcript_segments'] = json.loads(zlib.decompress(b''.join(chunk['data'] for chunk in chunks)))
    elif isinstance(data.get('transcript_segments'), bytes):
        data['transcript_segments'] = json.loads(zlib.decompress(data['transcript_segments']))
    if not isinstance(data.get('transcript_segments', []), list):
        raise ValueError('daily journal transcript segments must be a list')
    data.setdefault('id', document.id)
    return data
