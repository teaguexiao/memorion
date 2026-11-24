"""What is allowed to enter a voiceprint (Phase 1).

Three gates, each closing a way the profile could get worse over time.

**Provenance.** Only a human confirmation may enrol audio. The matcher's own
verdicts used to flow back in: auto-identified segments were written through
assign-bulk, which is also the sample-collection trigger, so the profile was
retrained on its own output. That is a positive feedback loop — one wrong
auto-label pulls the reference toward the wrong voice, which makes the next wrong
label likelier. Biometric self-update needs a confirmation source outside the
matcher, and ours is the user tapping a name.

**Time axis.** Session recordings are VAD-trimmed before upload, so slicing them
with untrimmed transcript timestamps reads whatever happens to be at that offset
— often a different speaker, filed under this person's name. Which axis a stored
conversation uses depends on how it was created, so the axis has to be detected,
not assumed.

**Net speech.** A 6-second clip that is 5 seconds of pause carries almost no
speaker information. Every vendor with published enrolment numbers counts net
speech (AWS Voice ID 30s, Azure 20s); wall clock lets silence masquerade as
enrolment.

Run:
    cd backend && python3 tests/test_speech_sample_collector_quality.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

# Pure arithmetic, no model import — same helper the collector uses.
from utils.stt.timeline import segments_on_audio_axis  # noqa: E402


COLLECTOR_SRC_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'utils', 'speech_sample_collector.py'
)


def read_collector_source():
    with open(COLLECTOR_SRC_PATH) as f:
        return f.read()


def spans_aligned_to_audio(spans, kept_intervals, audio_duration):
    """Mirror of ``_spans_aligned_to_audio``.

    Copied rather than imported because importing the collector pulls in GCS and
    Firestore clients. ``ImplementationMatchesSource`` guards against drift.
    """
    from utils.stt.timeline import normalize_kept_intervals

    if not spans or not normalize_kept_intervals(kept_intervals):
        return spans
    max_end = max(e for _s, e in spans)
    if max_end <= audio_duration * 1.1 + 1.0:
        return spans
    remapped = segments_on_audio_axis(
        [{'start': s, 'end': e} for s, e in spans], kept_intervals
    )
    return [(r['start'], r['end']) for r in remapped]


class OnlyHumanConfirmationsEnrol(unittest.TestCase):
    def test_collector_rejects_non_manual_sources(self):
        src = read_collector_source()
        self.assertIn("if source != 'manual':", src)
        self.assertIn("source: str = 'manual'", src)

    def test_assign_endpoints_forward_the_source(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'routers', 'developer_conversations.py'
        )
        with open(path) as f:
            src = f.read()
        # All three assign endpoints trigger collection; each must pass provenance
        # through, or the default silently re-opens the loop for that endpoint.
        self.assertEqual(
            src.count("kwargs={'source': "), 3,
            "every collect_speech_samples_developer thread must forward `source`",
        )

    def test_source_defaults_to_manual_for_existing_clients(self):
        # The app and any existing API consumer omit the field; their calls really
        # are human taps, so the default must not break them.
        path = os.path.join(
            os.path.dirname(__file__), '..', 'routers', 'developer_conversations.py'
        )
        with open(path) as f:
            src = f.read()
        self.assertIn("default='manual'", src)
        self.assertIn("source: str = Query('manual'", src)


class TimeAxisIsDetectedNotAssumed(unittest.TestCase):
    # 2335s of transcript, VAD kept ~17s of speech.
    KEPT = [(0.0, 5.0), (600.0, 606.0), (1800.0, 1806.0)]
    AUDIO_SECONDS = 17.0

    def test_original_axis_spans_are_remapped(self):
        spans = [(601.0, 605.0), (1801.0, 1805.5)]
        out = spans_aligned_to_audio(spans, self.KEPT, self.AUDIO_SECONDS)
        for start, end in out:
            self.assertLessEqual(end, self.AUDIO_SECONDS + 0.001)
        self.assertNotEqual(out, spans, "overshooting spans must be remapped")

    def test_durations_survive_the_remap(self):
        out = spans_aligned_to_audio([(601.0, 605.0)], self.KEPT, self.AUDIO_SECONDS)
        self.assertAlmostEqual(out[0][1] - out[0][0], 4.0, places=3)

    def test_spans_already_on_the_trimmed_axis_are_left_alone(self):
        # The WS auto-process path stores remapped timestamps. Remapping twice
        # would collapse them toward zero and slice the wrong audio again.
        spans = [(1.0, 4.0), (6.0, 10.0)]
        out = spans_aligned_to_audio(spans, self.KEPT, self.AUDIO_SECONDS)
        self.assertEqual(out, spans)

    def test_legacy_sessions_without_intervals_pass_through(self):
        spans = [(601.0, 605.0)]
        for empty in (None, [], ()):
            self.assertEqual(spans_aligned_to_audio(spans, empty, self.AUDIO_SECONDS), spans)

    def test_malformed_intervals_do_not_crash_or_mangle(self):
        spans = [(601.0, 605.0)]
        for bad in ([{}], [None], ['nope'], [{'start': None, 'end': None}]):
            self.assertEqual(spans_aligned_to_audio(spans, bad, self.AUDIO_SECONDS), spans)

    def test_slight_overshoot_is_tolerated(self):
        # Duration derived from file size can disagree with the last timestamp by
        # a fraction of a second. That is not a wrong axis, and remapping such a
        # span would corrupt a correct one.
        spans = [(0.5, 17.4)]
        self.assertEqual(spans_aligned_to_audio(spans, self.KEPT, self.AUDIO_SECONDS), spans)

    def test_empty_spans_are_safe(self):
        self.assertEqual(spans_aligned_to_audio([], self.KEPT, self.AUDIO_SECONDS), [])


class NetSpeechGate(unittest.TestCase):
    """Wall-clock duration must not be sufficient on its own."""

    MIN_TOTAL_SPEECH = 6.0

    def _passes(self, net_speech):
        return net_speech >= self.MIN_TOTAL_SPEECH

    def test_silence_padded_clip_is_rejected(self):
        # 30s of wall clock, 2s of speech: passes MIN_COMBINED_DURATION (5s) but
        # carries almost no speaker information.
        self.assertFalse(self._passes(2.0))

    def test_speech_dense_clip_is_accepted(self):
        self.assertTrue(self._passes(9.5))

    def test_vad_failure_falls_back_instead_of_rejecting_everything(self):
        # None means "VAD unavailable". Treating that as 0 would stop all sample
        # collection the moment VAD broke — a silent, total regression.
        src = read_collector_source()
        self.assertIn('if net_speech is None:', src)
        self.assertIn('return combined, None', src)

    def test_silence_is_stripped_not_merely_measured(self):
        # Removing the pauses salvages an otherwise usable clip; every second of
        # silence that reaches the encoder dilutes the embedding.
        src = read_collector_source()
        self.assertIn('def _keep_speech_only', src)
        self.assertIn('return speech_only, net_speech', src)


class PersonReferenceFloor(unittest.TestCase):
    """A person needs enough enrolled audio before their voiceprint may claim."""

    def test_storage_module_enforces_a_minimum(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'database', 'developer_speech_profile.py'
        )
        with open(path) as f:
            src = f.read()
        self.assertIn('MIN_PERSON_REFERENCE_SECONDS', src)
        self.assertIn('MAX_PEOPLE_FOR_MATCHING', src)
        # The cap must be applied, not merely defined: accuracy degrades as the
        # candidate set grows, so an unbounded people list would hurt everyone.
        self.assertIn('if len(people) >= MAX_PEOPLE_FOR_MATCHING:', src)
        self.assertIn('< MIN_PERSON_REFERENCE_SECONDS', src)

    def test_reference_audio_is_capped(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'database', 'developer_speech_profile.py'
        )
        with open(path) as f:
            src = f.read()
        self.assertIn('MAX_PERSON_REFERENCE_SECONDS', src)
        # ⚠️ This test used to assert the literal line
        #     `if total_seconds >= MAX_PERSON_REFERENCE_SECONDS:`
        # and that is exactly how the bug survived: the line was the bug. The check
        # sat at the top of the loop against a total that already included the whole
        # previous clip, so the anchor (a person's longest recording, routinely
        # 50-100s) blew past the 30s cap on iteration 1 and every other clip was
        # discarded. Asserting the source text pinned it in place and read as
        # coverage. The cap is now verified through the behaviour it is supposed to
        # produce — see PersonClipsAccumulate below — and this test only checks that
        # the allocation goes through the shared function that both identity paths
        # use, so the two cannot drift apart again.
        self.assertNotIn('if total_seconds >= MAX_PERSON_REFERENCE_SECONDS:', src,
                         'the top-of-loop check is the bug; do not restore it')
        self.assertIn('seconds_budget=MAX_PERSON_REFERENCE_SECONDS', src)
        self.assertIn('takes = allocate_clip_seconds(', src)


class DurationCapTruncatesRatherThanOnlyBreaking(unittest.TestCase):
    """A single oversized span must not become the whole sample."""

    MAX = 60.0

    def _collect(self, spans):
        """Mirror of the cap arithmetic in both collector paths."""
        cap_ms = int(self.MAX * 1000)
        total = 0.0
        taken = []
        for start_s, end_s in sorted(spans, key=lambda se: se[1] - se[0], reverse=True):
            remaining_ms = cap_ms - int(total * 1000)
            if remaining_ms <= 0:
                break
            start_ms, end_ms = int(start_s * 1000), int(end_s * 1000)
            end_ms = min(end_ms, start_ms + remaining_ms)
            if end_ms <= start_ms:
                continue
            taken.append((start_ms, end_ms))
            total += (end_ms - start_ms) / 1000.0
        return total, taken

    def test_one_huge_span_is_truncated_to_the_cap(self):
        # The real failure: a diarization glitch produced ONE segment spanning a
        # 2713s conversation, and it was uploaded whole as a person's voiceprint.
        total, _ = self._collect([(0.0, 2713.0)])
        self.assertLessEqual(total, self.MAX + 0.001)

    def test_checking_only_at_loop_top_would_have_let_it_through(self):
        # Guards the fix itself: the old shape (break before appending) admits the
        # first span at any length, and spans are sorted longest-first.
        total = 0.0
        for start_s, end_s in [(0.0, 2713.0)]:
            if total >= self.MAX:
                break
            total += end_s - start_s
        self.assertGreater(total, self.MAX, "this is the bug the new arithmetic fixes")

    def test_many_small_spans_still_fill_up_to_the_cap(self):
        spans = [(i * 10.0, i * 10.0 + 9.0) for i in range(20)]  # 180s available
        total, taken = self._collect(spans)
        self.assertAlmostEqual(total, self.MAX, places=2)
        self.assertGreater(len(taken), 1, "the cap must be shared across clips")

    def test_under_cap_input_is_untouched(self):
        total, taken = self._collect([(0.0, 12.0), (20.0, 28.0)])
        self.assertAlmostEqual(total, 20.0, places=2)
        self.assertEqual(len(taken), 2)

    def test_both_collector_paths_truncate(self):
        src = read_collector_source()
        self.assertEqual(
            src.count('end_ms = min(end_ms, start_ms + remaining_ms)'), 2,
            'the developer path and the legacy app path both need the cap',
        )
        self.assertNotIn('if total_duration >= MAX_SAMPLE_DURATION:', src)


class TheLegacyPathIsMarkedAsMissingItsGuards(unittest.TestCase):
    """``collect_speech_samples_from_segments`` has no caller and no guards.

    It predates every protection its developer sibling grew: no ``source`` gate, no
    time-axis alignment, no net-speech floor. Each of those exists because of
    damage seen in production, so wiring this up as-is would silently reopen all
    three. It cannot simply be deleted (it is the old ``users/`` layout's entry
    point), so the next person to reach for it has to be told.
    """

    def test_it_still_has_no_callers(self):
        # The claim the docstring rests on. If someone connects it, this fails and
        # they are pointed at the guards they now need.
        root = os.path.join(os.path.dirname(__file__), '..')
        hits = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [
                d for d in dirnames
                if d not in ('venv', '__pycache__', '.git', 'node_modules', '_temp')
            ]
            for name in filenames:
                if not name.endswith('.py'):
                    continue
                full = os.path.join(dirpath, name)
                if os.path.basename(full) in (
                    'speech_sample_collector.py', os.path.basename(__file__)
                ):
                    continue
                with open(full, errors='ignore') as f:
                    if 'collect_speech_samples_from_segments' in f.read():
                        hits.append(os.path.relpath(full, root))
        self.assertEqual(hits, [], f'now called from {hits} — port the guards first')

    def test_the_docstring_names_every_missing_guard(self):
        src = read_collector_source()
        body = src.split('def collect_speech_samples_from_segments')[1]
        doc = body.split('"""')[1]
        self.assertIn('UNUSED', doc)
        for guard in ('source', 'time-axis', 'MAX_SAMPLE_DURATION', 'net-speech'):
            self.assertIn(guard, doc, f'{guard} guard must be named as missing')
        self.assertIn('collect_speech_samples_developer', doc,
                      'must point at the path that has the guards')

    def test_only_the_developer_path_gates_on_source(self):
        src = read_collector_source()
        self.assertIn("if source != 'manual':", src)
        self.assertEqual(src.count("if source != 'manual':"), 1)
        # And the gate sits in the developer function, not the legacy one.
        legacy = src.split('def collect_speech_samples_from_segments')[1]
        legacy = legacy.split('def collect_speech_samples_developer')[0]
        self.assertNotIn("source != 'manual'", legacy)


class ProfileKeepsTheOnboardingAnchorDominant(unittest.TestCase):
    """Collected samples may adjust the user's profile, never define it."""

    def test_share_cap_exists_and_is_below_one(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'database', 'developer_speech_profile.py'
        )
        with open(path) as f:
            src = f.read()
        self.assertIn('MAX_SAMPLE_SHARE_OF_PROFILE', src)
        self.assertIn("'SPEECH_PROFILE_MAX_SAMPLE_SHARE', '0.5'", src)
        # Applied, not merely defined — but applied to the ONE caller that needs it.
        # The share bounds total seconds, which is the only thing holding the anchor's
        # majority when the parts get concatenated into a single waveform. On the
        # parts path the model enforces ANCHOR_WEIGHT_FLOOR on the centroid itself, so
        # the same bound there is redundant and, being redundant, made
        # MAX_PROFILE_CLIPS unreachable (23.6s budget / 10s per clip = 2.4 clips).
        self.assertIn('share_of_anchor=MAX_SAMPLE_SHARE_OF_PROFILE', src,
                      'the concatenating caller must still request the share bound')
        self.assertIn('anchor_seconds * share_of_anchor', src)
        # And it must be the concatenating helper that asks for it. Scoped to that
        # function's body so a stray occurrence elsewhere cannot satisfy this.
        body = src.split('def download_developer_profile_for_identification')[1]
        body = body.split('def download_developer_profile_parts')[0]
        self.assertIn('share_of_anchor=MAX_SAMPLE_SHARE_OF_PROFILE', body)

    def test_budget_math_keeps_anchor_in_the_majority(self):
        for anchor_s, share in ((47.3, 0.5), (10.0, 0.5), (120.0, 0.5)):
            budget = anchor_s * share
            self.assertLess(budget, anchor_s,
                            'samples must never outweigh the onboarding recording')

    def test_unbounded_concatenation_is_what_broke_production(self):
        # 47s anchor + 57 samples totalling ~3200s: the anchor was 1.5% of the
        # reference, and the profile stopped matching its own owner.
        anchor_s, samples_s = 47.3, 3189.4
        self.assertLess(anchor_s / (anchor_s + samples_s), 0.02)
        capped = min(samples_s, anchor_s * 0.5)
        self.assertGreater(anchor_s / (anchor_s + capped), 0.66)

    def test_newest_samples_are_preferred(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'database', 'developer_speech_profile.py'
        )
        with open(path) as f:
            src = f.read()
        self.assertIn('reverse=True', src)
        # blob.updated is tz-aware; a naive sentinel raises mid-sort.
        self.assertIn('tzinfo=datetime.timezone.utc', src)


class ContaminatedPersonReferencesAreDropped(unittest.TestCase):
    """A 'person' reference holding the user's voice must not compete."""

    def _source(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'modal', 'speech_profile_modal_campplus.py'
        )
        with open(path) as f:
            return f.read()

    def test_guard_runs_before_the_person_is_enrolled_for_matching(self):
        src = self._source()
        self.assertIn('contamination = _cosine_score(profile_embedding, pemb)', src)
        self.assertIn('if contamination >= CONTAMINATION_MIN:', src)
        # Must skip the person, not merely log.
        guard = src.split('contamination = _cosine_score')[1]
        self.assertIn('continue', guard.split('people_embeddings[')[0])

    def test_dropped_person_never_reaches_the_score_table(self):
        src = self._source()
        # The assignment has to come after the guard, or a contaminated reference
        # still competes for the speaker.
        self.assertLess(
            src.index('if contamination >= CONTAMINATION_MIN:'),
            src.index('people_embeddings[person[\'id\']] = pemb'),
        )

    def test_encode_failure_still_skips_cleanly(self):
        src = self._source()
        self.assertIn("print(f\"[CAM++] Failed to encode person {person['id']}: {e}\")", src)


class ImplementationMatchesSource(unittest.TestCase):
    """Keeps the copied helper above honest."""

    def test_collector_aligns_with_the_lookup_matching_uses(self):
        src = read_collector_source()
        # A tag must enrol exactly the audio a later match compares against, and the
        # axis is never guessed from whether the spans happen to fit the wav.
        self.assertIn('segments = conversation_segments_on_wav(conversation, session)', src)
        self.assertNotIn('_spans_aligned_to_audio', src)
        self.assertNotIn('audio_duration * 1.1', src)

    def test_collector_reads_the_session_once(self):
        src = read_collector_source()
        # The session doc is read once and both consumers take it: the time axis and
        # the inflation gate.
        self.assertIn('def _session_for_conversation', src)
        self.assertIn('session = _session_for_conversation(developer_id, external_user_id, conversation)', src)
        self.assertIn('refusal = _inflation_refusal(session)', src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
