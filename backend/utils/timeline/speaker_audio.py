"""Resolve evidence playback offsets without guessing a legacy timestamp axis."""
import math
import os
import logging

from utils.stt.recording_alignment import RecordingAlignmentUnavailable, conversation_segments_on_wav

CHAPTER_CLIP_SECONDS = 20.0
CHAPTER_MIN_SPEECH_SECONDS = 10.0


def reviewed_clip(segments, index):
    """One contiguous, bounded quote; playback and enrollment share this policy."""
    segment = segments[index]
    start, end = float(segment['start']), float(segment['end'])
    if not math.isfinite(start + end) or start < 0 or end <= start:
        raise ValueError('Invalid audio bounds')
    end = min(end, start + CHAPTER_CLIP_SECONDS)
    reason = 'too_short' if end - start < CHAPTER_MIN_SPEECH_SECONDS else None
    for other_index, other in enumerate(segments):
        # Even equal ASR speaker labels can be wrong: refuse overlapping turns.
        if other_index != index and min(end, float(other['end'])) - max(start, float(other['start'])) > .2:
            reason = 'overlapping_speech'
            break
    return {'start': start, 'end': end, 'learning_blocked_reason': reason}


def audio_bounds(conversation, index, session):
    if not conversation.get('audio_path'):
        return None
    try:
        # Same axis answer as voiceprint and playback (utils/stt/recording_alignment.py).
        return reviewed_clip(conversation_segments_on_wav(conversation, session), index)
    except (RecordingAlignmentUnavailable, KeyError, ValueError, TypeError, IndexError):
        return None


def evidence_audio(db, developer_id, user_id, conversation, index):
    session_id = os.path.splitext(os.path.basename(conversation.get('audio_path') or ''))[0]
    try:
        session = db.get_listen_session(developer_id, user_id, session_id) if session_id else {}
    except Exception as exc:
        # Playback metadata is optional; the verified quotation and chapter-local
        # correction remain usable during a listen-session read failure.
        logging.getLogger(__name__).warning('Chapter audio session unavailable: %s', type(exc).__name__)
        session = {}
    return audio_bounds(conversation, index, session or {})
