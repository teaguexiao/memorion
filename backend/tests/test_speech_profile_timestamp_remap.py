"""Speaker identification must send timestamps on the SAVED audio's time axis.

The session wav is VAD-trimmed before it is stored, so its time axis is far
shorter than the transcript's. The app's ``POST /process`` sends segments on the
ORIGINAL axis and never saw the WS-side remap, so the hosted model received
timestamps pointing past the end of the file. Its clamp
(``seg_end = min(segment.end, audio_duration)``) then yields a negative span and
it skips EVERY segment, returns all-False, and the conversation looks like
passive media listening.

Observed in production: a 140-segment / 1372-word real conversation at 76.8
words-per-minute had 94% of its segments past the end of a 17s wav, got
``is_user=False`` everywhere, and was discarded as media playback (which also
suppressed its subtitle). 55% of conversations over two weeks had no is_user.

Run:
    cd backend && python3 tests/test_speech_profile_timestamp_remap.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

# utils.stt.timeline is pure arithmetic — importing it pulls in no model, so this
# test runs anywhere. It is the same code speech_profile.py calls in production.
from utils.stt.timeline import (  # noqa: E402
    remap_segments_to_trimmed_axis,
    segments_on_audio_axis as _segments_on_audio_axis,
)


MIN_SEGMENT_DURATION = 1.0  # mirrors modal/speech_profile_modal_campplus.py


def modal_usable_segments(segments, audio_duration):
    """Faithful copy of the hosted model's segment filter (campplus:224-228).

    Returns the indices the model would actually classify. Everything else is
    silently dropped, which is what produced all-False results.
    """
    usable = []
    for i, seg in enumerate(segments):
        seg_start = max(0.0, seg["start"])
        seg_end = min(seg["end"], audio_duration)
        if seg_end - seg_start < MIN_SEGMENT_DURATION:
            continue
        usable.append(i)
    return usable


class ProductionRegression(unittest.TestCase):
    """Reproduces the real failure with the real numbers."""

    # 2335s of transcript, VAD kept only ~17s of speech.
    KEPT = [(0.0, 5.0), (600.0, 606.0), (1800.0, 1806.0)]
    AUDIO_SECONDS = 17.0

    def _transcript_segments(self):
        return [
            {"start": 0.5, "end": 4.0, "speaker": "SPEAKER_01"},
            {"start": 601.0, "end": 605.0, "speaker": "SPEAKER_01"},
            {"start": 1801.0, "end": 1805.5, "speaker": "SPEAKER_01"},
        ]

    def test_without_remap_the_model_drops_everything(self):
        raw = self._transcript_segments()
        usable = modal_usable_segments(raw, self.AUDIO_SECONDS)
        # Only the first segment happens to fall inside the audio; the rest are
        # past the end and get clamped into a negative span.
        self.assertEqual(
            len(usable), 1,
            "pre-fix behaviour: segments beyond the trimmed audio are dropped",
        )

    def test_with_remap_every_segment_becomes_usable(self):
        remapped = _segments_on_audio_axis(self._transcript_segments(), self.KEPT)
        usable = modal_usable_segments(remapped, self.AUDIO_SECONDS)
        self.assertEqual(
            len(usable), 3,
            "after remapping, all speech lands inside the trimmed audio",
        )

    def test_remap_does_not_mutate_the_caller_segments(self):
        # The stored timestamps stay on the original axis on purpose: the app
        # renders them next to each transcript line.
        original = self._transcript_segments()
        before = [(s["start"], s["end"]) for s in original]
        _segments_on_audio_axis(original, self.KEPT)
        after = [(s["start"], s["end"]) for s in original]
        self.assertEqual(before, after)

    def test_remapped_timestamps_stay_within_audio(self):
        remapped = _segments_on_audio_axis(self._transcript_segments(), self.KEPT)
        for seg in remapped:
            self.assertLessEqual(seg["end"], self.AUDIO_SECONDS + 0.001)

    def test_speaker_keys_and_order_survive(self):
        # The vote loop zips `matches[i]` against the ORIGINAL segments, so the
        # copy must preserve both order and every non-timestamp field.
        raw = self._transcript_segments()
        remapped = _segments_on_audio_axis(raw, self.KEPT)
        self.assertEqual(len(remapped), len(raw))
        self.assertEqual(
            [s["speaker"] for s in remapped], [s["speaker"] for s in raw]
        )


class IntervalShapes(unittest.TestCase):
    """Firestore rejects nested arrays, so intervals round-trip as maps."""

    KEPT_TUPLES = [(0.0, 5.0), (600.0, 606.0)]
    KEPT_DICTS = [{"start": 0.0, "end": 5.0}, {"start": 600.0, "end": 606.0}]

    def _segs(self):
        return [{"start": 601.0, "end": 605.0}]

    def test_dict_shape_matches_tuple_shape(self):
        from_tuples = _segments_on_audio_axis(self._segs(), self.KEPT_TUPLES)
        from_dicts = _segments_on_audio_axis(self._segs(), self.KEPT_DICTS)
        self.assertEqual(
            (from_tuples[0]["start"], from_tuples[0]["end"]),
            (from_dicts[0]["start"], from_dicts[0]["end"]),
            "Firestore-persisted maps must remap identically to in-memory tuples",
        )

    def test_missing_intervals_pass_through_unchanged(self):
        # Legacy sessions have no audio_kept_intervals. Don't invent a mapping —
        # returning the input keeps behaviour identical to before the fix.
        segs = self._segs()
        for empty in (None, [], ()):
            out = _segments_on_audio_axis(segs, empty)
            self.assertIs(out, segs)

    def test_malformed_intervals_do_not_crash(self):
        segs = self._segs()
        for bad in ([{"start": None, "end": None}], [{}], [None], ["nope"]):
            out = _segments_on_audio_axis(segs, bad)
            self.assertIs(out, segs, f"malformed {bad!r} should pass through")

    def test_partially_malformed_intervals_use_the_valid_ones(self):
        out = _segments_on_audio_axis(
            self._segs(), [{"start": 0.0, "end": 5.0}, {}, {"start": 600.0, "end": 606.0}]
        )
        self.assertLessEqual(out[0]["end"], 11.0)


class RemapSemantics(unittest.TestCase):
    """Direct checks on the shared vad helper."""

    def test_gap_audio_is_collapsed(self):
        segs = [{"start": 100.0, "end": 101.0}]
        remap_segments_to_trimmed_axis(segs, [(0.0, 10.0), (100.0, 110.0)])
        # Second kept interval starts at trimmed-axis t=10.
        self.assertAlmostEqual(segs[0]["start"], 10.0, places=3)
        self.assertAlmostEqual(segs[0]["end"], 11.0, places=3)

    def test_segment_in_a_removed_gap_collapses_to_a_point(self):
        segs = [{"start": 50.0, "end": 55.0}]
        remap_segments_to_trimmed_axis(segs, [(0.0, 10.0), (100.0, 110.0)])
        # Falls entirely in removed silence -> zero-length, model skips it
        # (correct: there is no audio for it).
        self.assertAlmostEqual(segs[0]["start"], segs[0]["end"], places=3)

    def test_duration_is_preserved_inside_a_kept_interval(self):
        segs = [{"start": 602.0, "end": 604.5}]
        remap_segments_to_trimmed_axis(segs, [(0.0, 5.0), (600.0, 610.0)])
        self.assertAlmostEqual(segs[0]["end"] - segs[0]["start"], 2.5, places=3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
