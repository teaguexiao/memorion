"""Public projection: never serialize a Conversation wholesale."""
import hashlib
import json
import math
from datetime import datetime, timezone


def active(record: dict, now: datetime) -> bool:
    if 'expires_at' not in record or record.get('revoked_at') or record.get('blocked_at'):
        return False
    mode, expiry = record.get('expiry_mode'), record.get('expires_at')
    if mode == 'never':
        return expiry is None
    return (mode == 'seven_days' and isinstance(expiry, datetime)
            and expiry.tzinfo is not None and expiry > now)


def public_content(conversation: dict, share: dict) -> dict:
    def text(value):
        return value if isinstance(value, str) else ''

    def seconds(value):
        try:
            number = float(value)
            return max(0, number) if math.isfinite(number) else 0
        except (TypeError, ValueError):
            return 0

    structured = conversation.get('structured') or {}
    speakers, segments = {}, []
    for segment in conversation.get('transcript_segments') or []:
        if not isinstance(segment, dict):
            continue
        # Only a local number crosses the public boundary. Neither a person's
        # name/id nor an is_user flag is emitted.
        speaker = str(segment.get('speaker_id', 0))
        if speaker not in speakers:
            speakers[speaker] = len(speakers) + 1
        start = seconds(segment.get('start'))
        segments.append({'speaker': speakers[speaker], 'start': start,
                         'end': max(start, seconds(segment.get('end'))),
                         'text': text(segment.get('text'))})
    payload = {
        'title': text(structured.get('title')),
        'overview': text(structured.get('overview')),
        'segments': segments,
        'duration_seconds': max((s['end'] for s in segments), default=0),
        'expires_at': share['expires_at'].isoformat() if share.get('expires_at') else None,
        'expiry_mode': share['expiry_mode'],
    }
    # Hash the actual public projection: existing write paths do not all bump
    # updated_at. No edit can be missed merely because a timestamp stayed put.
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, allow_nan=False).encode()
    if len(encoded) > 8 * 1024 * 1024:
        raise ValueError('Shared content is too large')
    payload['revision'] = hashlib.sha256(encoded).hexdigest()
    return payload
