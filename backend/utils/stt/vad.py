"""
Voice Activity Detection (VAD) using Silero VAD model.

This module provides functions to detect speech segments in audio files.
"""

import threading
from enum import Enum

import numpy as np
import torch
from fastapi import HTTPException
from pydub import AudioSegment

from database import redis_db
from utils.stt.timeline import (
    merge_speech_spans,
    remap_segments_to_trimmed_axis as _remap_segments_to_trimmed_axis,
)

# Initialize Silero VAD model at module load time
torch.set_num_threads(1)
torch.hub.set_dir('pretrained_models')
_model, _utils = torch.hub.load(repo_or_dir='snakers4/silero-vad', model='silero_vad')
(_get_speech_timestamps, _save_audio, _read_audio, VADIterator, _collect_chunks) = _utils

# Lock to serialize access to the Silero VAD model — PyTorch inference on
# a single model instance is not thread-safe and concurrent calls corrupt
# internal state (RNN hidden tensors), leading to SEGV/ABRT crashes.
_vad_lock = threading.Lock()


class SpeechState(str, Enum):
    speech_found = 'speech_found'
    no_speech = 'no_speech'


def is_speech_present(data, vad_iterator, window_size_samples=256):
    """
    Check if speech is present in raw audio data using streaming VAD.

    Args:
        data: Raw audio bytes (16-bit PCM)
        vad_iterator: VADIterator instance
        window_size_samples: Window size for processing

    Returns:
        SpeechState.speech_found or SpeechState.no_speech
    """
    data_int16 = np.frombuffer(data, dtype=np.int16)
    data_float32 = data_int16.astype(np.float32) / 32768.0

    for i in range(0, len(data_float32), window_size_samples):
        chunk = data_float32[i : i + window_size_samples]
        if len(chunk) < window_size_samples:
            break
        speech_dict = vad_iterator(chunk, return_seconds=False)
        if speech_dict:
            vad_iterator.reset_states()
            return SpeechState.speech_found

    vad_iterator.reset_states()
    return SpeechState.no_speech


def get_speech_segments(file_path: str, sample_rate: int = 16000) -> list:
    """
    Detect speech segments in an audio file using Silero VAD.

    Args:
        file_path: Path to audio file (WAV format recommended)
        sample_rate: Sample rate of the audio file (default: 16000)

    Returns:
        List of segments: [{'start': float, 'end': float, 'duration': float}, ...]
        Times are in seconds.
    """
    wav = _read_audio(file_path, sampling_rate=sample_rate)
    with _vad_lock:
        timestamps = _get_speech_timestamps(wav, _model, sampling_rate=sample_rate)

    return [
        {
            'start': ts['start'] / sample_rate,
            'end': ts['end'] / sample_rate,
            'duration': (ts['end'] - ts['start']) / sample_rate,
        }
        for ts in timestamps
    ]


def vad_is_empty(file_path: str, return_segments: bool = False, cache: bool = False):
    """
    Detect voice activity in audio file using Silero VAD.

    Args:
        file_path: Path to audio file (WAV format)
        return_segments: If True, return list of speech segments. If False, return bool.
        cache: If True, cache results in Redis.

    Returns:
        If return_segments=True: List of segments [{'start': float, 'end': float, 'duration': float}, ...]
        If return_segments=False: bool (True if no speech detected, False if speech found)
    """
    caching_key = f'vad_is_empty:{file_path}'
    if cache:
        if exists := redis_db.get_generic_cache(caching_key):
            if return_segments:
                return exists
            return len(exists) == 0

    try:
        segments = get_speech_segments(file_path)

        if cache:
            redis_db.set_generic_cache(caching_key, segments, ttl=60 * 60 * 24)

        if return_segments:
            return segments

        is_empty = len(segments) == 0
        print(f'vad_is_empty: {is_empty} (segments: {len(segments)})')
        return is_empty

    except Exception as e:
        print(f'vad_is_empty error: {e}')
        if return_segments:
            return []
        return False


def vad_is_empty_streaming(file_path: str) -> bool:
    """Boolean speech check for long uploads, bounded to one PCM chunk in RAM.

    Do not collect all timestamps when the caller only needs one speech region.
    As with vad_is_empty, detector failures fall through to STT, not a permanent
    "no speech" rejection. Segment-producing callers keep their existing path.
    """
    from utils.audio_upload_media import pcm16_chunks

    try:
        for block in pcm16_chunks(file_path):
            samples = np.frombuffer(block, dtype='<i2').astype(np.float32) / 32768.0
            with _vad_lock:
                if _get_speech_timestamps(torch.from_numpy(samples), _model, sampling_rate=16000):
                    return False
        return True
    except Exception as e:
        print(f'vad_is_empty_streaming error: {type(e).__name__}')
        return False


def vad_trim_silence_bytes(
    pcm_bytes: bytes,
    sample_rate: int = 16000,
    merge_gap: float = 1.0,
    pad_ms: int = 200,
    return_kept_intervals: bool = False,
    keep_spans=None,
):
    """
    Remove silence from raw PCM16 audio bytes using Silero VAD.

    🚨 **Silero alone cannot decide what to keep.** On real recordings it hears no
    speech where STT transcribed loud, clear lines (2026-11-02: 30 live conversations,
    half lost ≥30% of their lines; a 6.4-minute session at −15 dBFS had no frame
    ≥ 0.5 and its 40 lines all scored ≤ 0.06). It is not a threshold to tune — v4,
    v5 and v6 all miss them, and its state settles into "no speech" within ~30 s of
    such audio. Whatever was trimmed is gone for good: playback, voiceprint and
    chapter evidence all read this wav. So callers pass ``keep_spans`` — where STT
    heard speech — and they are kept no matter what Silero says.

    Args:
        pcm_bytes: Raw 16-bit PCM audio bytes (mono).
        sample_rate: Sample rate of the audio.
        merge_gap: Merge speech segments closer than this many seconds.
        pad_ms: Padding in milliseconds to add around each speech segment.
        return_kept_intervals: When True, also return the list of [start_s, end_s]
            intervals (in the ORIGINAL audio's time axis) that were kept. The
            caller can use these to remap STT segment timestamps onto the
            trimmed audio (so transcript segments stay aligned with the saved
            wav file even after silence removal).
        keep_spans: ``(start_s, end_s)`` spans on the same axis that must survive
            trimming (``utils.stt.timeline.transcribed_spans``). Merged and padded
            exactly like Silero's own speech segments.

    Returns:
        Trimmed PCM16 bytes. If `return_kept_intervals=True`, returns a tuple
        ``(trimmed_bytes, kept_intervals)`` where ``kept_intervals`` is a list
        of ``(start_s, end_s)`` pairs covering the original audio. Returns the
        original bytes (and an interval covering the whole audio) if VAD fails,
        or if neither VAD nor ``keep_spans`` found any speech.
    """
    bytes_per_sample = 2  # 16-bit
    if not pcm_bytes or len(pcm_bytes) < sample_rate * 2:  # less than 1 second
        if return_kept_intervals:
            total_s = len(pcm_bytes) / (sample_rate * bytes_per_sample)
            return pcm_bytes, [(0.0, total_s)] if total_s > 0 else []
        return pcm_bytes

    try:
        # Convert bytes to float32 tensor for Silero VAD
        data_int16 = np.frombuffer(pcm_bytes, dtype=np.int16)
        data_float32 = torch.FloatTensor(data_int16.astype(np.float32) / 32768.0)

        # Detect speech timestamps
        with _vad_lock:
            timestamps = _get_speech_timestamps(data_float32, _model, sampling_rate=sample_rate)
        detected = [(ts['start'] / sample_rate, ts['end'] / sample_rate) for ts in timestamps]
        extra = list(keep_spans or ())

        # VAD speech ∪ spans the caller must keep, merged and padded.
        total_samples = len(data_int16)
        intervals = merge_speech_spans(
            detected + extra, total_s=total_samples / sample_rate, merge_gap=merge_gap, pad_s=pad_ms / 1000,
        )
        if not intervals:
            if return_kept_intervals:
                total_s = len(pcm_bytes) / (sample_rate * bytes_per_sample)
                return pcm_bytes, [(0.0, total_s)]
            return pcm_bytes

        # Extract the kept spans from PCM bytes. Track kept intervals in seconds
        # so callers can remap timestamps.
        trimmed_parts = []
        kept_intervals = []
        for start_s, end_s in intervals:
            start_sample = max(0, int(start_s * sample_rate))
            end_sample = min(total_samples, int(end_s * sample_rate))
            if end_sample <= start_sample:
                continue
            start_byte = start_sample * bytes_per_sample
            end_byte = end_sample * bytes_per_sample
            trimmed_parts.append(pcm_bytes[start_byte:end_byte])
            kept_intervals.append((start_sample / sample_rate, end_sample / sample_rate))

        trimmed = b''.join(trimmed_parts)
        original_duration = len(pcm_bytes) / (sample_rate * bytes_per_sample)
        trimmed_duration = len(trimmed) / (sample_rate * bytes_per_sample)
        print(f"[VAD] Trimmed audio: {original_duration:.1f}s -> {trimmed_duration:.1f}s "
              f"({len(kept_intervals)} kept spans from {len(detected)} VAD + {len(extra)} transcribed, "
              f"removed {original_duration - trimmed_duration:.1f}s silence)")
        if return_kept_intervals:
            return trimmed, kept_intervals
        return trimmed

    except Exception as e:
        print(f"[VAD] vad_trim_silence_bytes error: {e}, returning original audio")
        if return_kept_intervals:
            total_s = len(pcm_bytes) / (sample_rate * bytes_per_sample)
            return pcm_bytes, [(0.0, total_s)] if total_s > 0 else []
        return pcm_bytes


# Re-exported from utils.stt.timeline (pure arithmetic, no model dependency) so
# existing importers keep working while callers that only need the time-axis math
# can avoid loading the Silero model this module downloads at import time.
remap_segments_to_trimmed_axis = _remap_segments_to_trimmed_axis


def apply_vad_for_speech_profile(file_path: str):
    """
    Apply VAD to a speech profile audio file, trimming silence.

    Args:
        file_path: Path to the audio file (will be overwritten with trimmed version)

    Raises:
        HTTPException: If audio contains no speech
    """
    print('apply_vad_for_speech_profile', file_path)
    voice_segments = vad_is_empty(file_path, return_segments=True)

    if len(voice_segments) == 0:
        raise HTTPException(status_code=400, detail="Audio is empty")

    # Merge segments that are close together (< 1 second apart)
    joined_segments = []
    for segment in voice_segments:
        if joined_segments and (segment['start'] - joined_segments[-1]['end']) < 1:
            joined_segments[-1]['end'] = segment['end']
        else:
            joined_segments.append(segment.copy())

    # Trim silence, keeping 1 second gaps between segments
    trimmed_aseg = AudioSegment.empty()
    for i, segment in enumerate(joined_segments):
        start = segment['start'] * 1000
        end = segment['end'] * 1000
        trimmed_aseg += AudioSegment.from_wav(file_path)[start:end]
        if i < len(joined_segments) - 1:
            trimmed_aseg += AudioSegment.from_wav(file_path)[end : end + 1000]

    trimmed_aseg.export(file_path, format="wav")
