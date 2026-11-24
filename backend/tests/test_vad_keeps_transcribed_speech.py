"""Trimming a live session must never cut a span STT transcribed.

2026-11-02: Silero heard no speech where Soniox transcribed loud, clear lines.
30 live conversations, half lost ≥30% of their lines from the stored wav; a
6.4-minute session at −15 dBFS had no frame ≥ 0.5 (its 40 lines all ≤ 0.06).
Not a threshold to tune: v4, v5 and v6 all miss them. The trimmed-away audio is
unrecoverable and every reader of the wav (tap-to-play, voiceprint, chapter
evidence) loses those lines, so the WS finally passes STT's spans as
``keep_spans`` and they survive no matter what Silero says.

Run:
    cd backend && python3 tests/test_vad_keeps_transcribed_speech.py
"""

import ast
import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from utils.stt.timeline import merge_speech_spans, transcribed_spans  # noqa: E402

SR = 16000


def rounded(spans):
    return [(round(a, 6), round(b, 6)) for a, b in spans]


class MergeSpeechSpans(unittest.TestCase):
    def test_vad_only_input_keeps_the_old_merge_and_padding(self):
        self.assertEqual(
            rounded(merge_speech_spans([(1.0, 2.0), (2.5, 3.0), (5.0, 6.0)], total_s=10)),
            [(0.8, 3.2), (4.8, 6.2)],
        )

    def test_union_of_vad_and_transcribed_spans(self):
        self.assertEqual(rounded(merge_speech_spans([(1.0, 2.0)] + [(7.0, 8.0)], total_s=10)), [(0.8, 2.2), (6.8, 8.2)])

    def test_unsorted_and_contained_spans(self):
        # A transcribed line inside a longer VAD span must not shorten it.
        self.assertEqual(rounded(merge_speech_spans([(6.0, 6.5), (1.0, 5.0), (2.0, 3.0)], total_s=10)), [(0.8, 5.2), (5.8, 6.7)])

    def test_clipped_to_the_audio(self):
        self.assertEqual(rounded(merge_speech_spans([(0.1, 0.5), (9.9, 12.0), (15.0, 16.0)], total_s=10)), [(0.0, 0.7), (9.7, 10.0)])

    def test_zero_length_span_gets_padding(self):
        self.assertEqual(rounded(merge_speech_spans([(4.0, 4.0)], total_s=10)), [(3.8, 4.2)])


class TranscribedSpans(unittest.TestCase):
    def test_only_the_stt_axis_counts(self):
        segments = [
            dict(start=0.0, end=2.0, original_start=95.0, original_end=97.0),  # display rebased; STT time is 95 s
            dict(start=5.0, end=6.0),  # custom_stt: original times stripped on purpose
            dict(original_start=100.0, original_end=100.0),  # zero-length Soniox segment
            dict(original_start='x', original_end=3),
            dict(original_start=9.0, original_end=8.0),
        ]
        self.assertEqual(transcribed_spans(segments), [(95.0, 97.0), (100.0, 100.0)])
        # Computed inside the block that saves the recording: junk must not raise.
        self.assertEqual(transcribed_spans([None, 'x', 3, {}]), [])
        self.assertEqual(transcribed_spans(None), [])


@contextlib.contextmanager
def silero(timestamps):
    """Import utils.stt.vad with a fake Silero that reports ``timestamps`` (samples)."""
    fake_utils = (lambda *a, **k: list(timestamps), None, None, None, None)
    sys.modules.pop('utils.stt.vad', None)
    with mock.patch('torch.hub.load', return_value=(object(), fake_utils)), mock.patch('torch.hub.set_dir'):
        import utils.stt.vad as vad
    try:
        yield vad
    finally:
        sys.modules.pop('utils.stt.vad', None)


def ramp(seconds):
    """PCM16 whose every sample encodes its own index, so slices are checkable."""
    return (np.arange(int(seconds * SR)) % 30000).astype(np.int16).tobytes()


def trim(vad, pcm, **kwargs):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = vad.vad_trim_silence_bytes(pcm, sample_rate=SR, return_kept_intervals=True, **kwargs)
    assert 'vad_trim_silence_bytes error' not in out.getvalue(), out.getvalue()  # the except path keeps everything
    return result


class TrimKeepsTranscribedSpeech(unittest.TestCase):
    def test_lines_silero_cannot_hear_are_kept(self):
        pcm = ramp(10)
        with silero([]) as vad:
            trimmed, kept = trim(vad, pcm, keep_spans=[(3.0, 4.0)])
        self.assertEqual(kept, [(2.8, 4.2)])
        self.assertEqual(trimmed, pcm[int(2.8 * SR) * 2:int(4.2 * SR) * 2])

    def test_vad_speech_and_transcribed_lines_are_both_kept(self):
        pcm = ramp(20)
        with silero([{'start': 1 * SR, 'end': 2 * SR}]) as vad:
            trimmed, kept = trim(vad, pcm, keep_spans=[(15.0, 16.0)])
        self.assertEqual(kept, [(0.8, 2.2), (14.8, 16.2)])
        self.assertEqual(len(trimmed), int((1.4 + 1.4) * SR) * 2)

    def test_without_keep_spans_behaviour_is_unchanged(self):
        pcm = ramp(10)
        with silero([{'start': 1 * SR, 'end': 2 * SR}]) as vad:
            _, kept = trim(vad, pcm)
        self.assertEqual(kept, [(0.8, 2.2)])
        with silero([]) as vad:
            trimmed, kept = trim(vad, pcm)
        self.assertEqual((trimmed, kept), (pcm, [(0.0, 10.0)]), 'nothing to go on: keep everything, as before')


class WiredIntoTheListenSession(unittest.TestCase):
    def test_ws_finally_passes_the_session_transcript(self):
        tree = ast.parse((ROOT / 'routers/developer_listen.py').read_text())
        calls = [n for n in ast.walk(tree)
                 if isinstance(n, ast.Call) and getattr(n.func, 'id', None) == 'vad_trim_silence_bytes']
        self.assertEqual(len(calls), 1)
        keep = next((kw.value for kw in calls[0].keywords if kw.arg == 'keep_spans'), None)
        self.assertIsNotNone(keep, 'trimming without keep_spans cuts lines Silero cannot hear')
        self.assertEqual(ast.unparse(keep), 'transcribed_spans(all_segments)')


if __name__ == '__main__':
    unittest.main()
