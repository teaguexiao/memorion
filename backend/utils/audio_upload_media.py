"""Bounded-memory decoding and validation for offline recording uploads."""

import subprocess
import tempfile
import wave
from dataclasses import dataclass

MAX_AUDIO_DURATION_SECONDS = 8 * 60 * 60
TRANSCRIPTION_CHUNK_SECONDS = 2 * 60 * 60


def convert_to_wav_16k(input_path: str, output_path: str, *, max_duration=None) -> bool:
    # Decode directly to disk. pydub holds the entire 48 kHz PCM plus copies in
    # Python RAM; a 103-minute recording can kill a 2 GiB API container.
    # 180s bounds wall-clock decoding, not media duration: the documented local
    # 6,178s recording converted in about 2s. Keep a finite resource watchdog.
    result = subprocess.run(
        ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-xerror',
         '-threads', '1', '-filter_threads', '1', '-i', input_path,
         '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
         '-t', str((MAX_AUDIO_DURATION_SECONDS if max_duration is None else max_duration) + 1), '-y', output_path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180,
    )
    return result.returncode == 0


def validate_audio_file(file_path: str, min_duration: float = 5.0, max_duration: float = MAX_AUDIO_DURATION_SECONDS):
    """Read canonical WAV metadata and its last frame without loading the audio."""
    try:
        with wave.open(file_path, 'rb') as audio:
            frames = audio.getnframes()
            duration = frames / audio.getframerate()
            if audio.getcomptype() != 'NONE' or audio.getnchannels() != 1 or audio.getsampwidth() != 2:
                return False, 'Invalid audio file: expected mono PCM16 WAV', duration
            if frames:
                audio.setpos(frames - 1)
                if len(audio.readframes(1)) != 2:
                    return False, 'Invalid audio file: truncated WAV', duration
            if duration < min_duration:
                return False, f'Audio duration ({duration:.1f}s) is too short. Minimum is {min_duration}s', duration
            if duration > max_duration:
                return False, f'Audio duration ({duration:.1f}s) is too long. Maximum is {max_duration}s', duration
            return True, '', duration
    except (OSError, EOFError, wave.Error, ZeroDivisionError):
        return False, 'Invalid audio file: unreadable WAV', 0


def pcm16_chunks(file_path: str, seconds: int = 30):
    """Overlap 0.5 s so speech crossing a chunk boundary is still detected."""
    with wave.open(file_path, 'rb') as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise ValueError('Expected normalized mono PCM16 at 16 kHz')
        overlap = b''
        while block := audio.readframes(16000 * seconds):
            yield overlap + block
            overlap = block[-16000:]


def needs_transcription_chunks(path):
    """Only normalized WAVs use this path; keep other STT callers compatible."""
    try:
        with wave.open(str(path), 'rb') as audio:
            return audio.getnframes() > audio.getframerate() * TRANSCRIPTION_CHUNK_SECONDS
    except (OSError, EOFError, wave.Error):
        return False


@dataclass(frozen=True)
class AudioChunk:
    path: str
    start_seconds: float
    core_start_seconds: float
    core_end_seconds: float

    def tokens(self, tokens):
        # One second of context on each side preserves words at the cut. Each
        # token belongs to exactly one core by its midpoint, without rebasing
        # leading silence or merging unrelated speaker IDs across STT jobs.
        result = []
        for token in tokens:
            start = token.get('start_ms', 0) + self.start_seconds * 1000
            duration = token.get('duration_ms', 0)
            midpoint = start + duration / 2
            if self.core_start_seconds * 1000 <= midpoint < self.core_end_seconds * 1000:
                result.append({**token, 'start_ms': start})
        return result


def transcription_chunks(path, chunk_seconds=TRANSCRIPTION_CHUNK_SECONDS):
    """Yield disk-backed PCM chunks; at most one chunk file and 1 s in RAM."""
    with wave.open(str(path), 'rb') as source, tempfile.TemporaryDirectory(prefix='stt-chunk-') as folder:
        rate = source.getframerate()
        total = source.getnframes()
        chunk_frames = int(chunk_seconds * rate)
        if chunk_frames <= 0:
            raise ValueError('Chunk duration must be positive')
        for core_start in range(0, total, chunk_frames):
            core_end = min(total, core_start + chunk_frames)
            start, end = max(0, core_start - rate), min(total, core_end + rate)
            target = f'{folder}/chunk.wav'
            source.setpos(start)
            with wave.open(target, 'wb') as output:
                output.setparams(source.getparams())
                remaining = end - start
                while remaining:
                    count = min(rate, remaining)
                    block = source.readframes(count)
                    if len(block) != count * source.getnchannels() * source.getsampwidth():
                        raise ValueError('Truncated recording during transcription split')
                    output.writeframesraw(block)
                    remaining -= count
            yield AudioChunk(target, start / rate, core_start / rate, core_end / rate)
