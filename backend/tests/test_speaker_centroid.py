"""How a voiceprint is assembled from several recordings (Phase 2).

A single recording is a poor definition of a voice. It captures one microphone,
one room, one mood, and scoring against it means comparing two noisy views of the
speaker rather than a view against the speaker. Averaging several recordings in
embedding space cancels that per-recording noise, which is why enrolment quality
improves with each clip instead of being fixed at whatever the first one caught.

Three things have to hold for that to be an improvement rather than a new way to
break:

**Direction only.** Cosine scoring ignores magnitude, so the average must too.
A plain mean does not: a chunk that encodes with a larger norm pulls the result
toward itself, and loud or clipped audio tends to do exactly that. Normalizing
each embedding before averaging is the difference between averaging voices and
averaging volumes.

**Length saturates.** A 10-second clip already yields a stable embedding. Weight
strictly by duration and one long recording outvotes five good short ones for no
accuracy gain — which is how a 45-minute mis-sliced "sample" became a voiceprint.

**The anchor keeps a floor.** Collected clips are labelled by a tap in a real
conversation and are sometimes the wrong person. The onboarding recording is the
only audio we know belongs to the user. Holding it to a fixed share of the total
means no quantity of bad clips can redefine the profile — the worst they can do
is add noise.

The geometry here uses cos≈0.65 between two recordings of one speaker, the
same-speaker operating range for CAM++ on real conversational audio.

Run:
    cd backend && python3 tests/test_speaker_centroid.py
"""

import math
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import numpy as np

MODAL_SRC_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'modal', 'speech_profile_modal_campplus.py'
)
DB_SRC_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'database', 'developer_speech_profile.py'
)
CALLER_SRC_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'utils', 'stt', 'speech_profile.py'
)


def read(path):
    with open(path) as f:
        return f.read()


# --- mirrors of the numeric helpers in the Modal module -------------------
# Reimplemented on numpy because importing the module needs torch + the Modal
# runtime. ImplementationMatchesSource below guards against drift.

WEIGHT_SATURATION_SECONDS = 10.0
ANCHOR_WEIGHT_FLOOR = 0.5
CLIP_AGREEMENT_MIN = 0.31
D = 192


def l2(v):
    return v / max(float(np.linalg.norm(v)), 1e-12)


def cos(a, b):
    return float(np.dot(l2(a), l2(b)))


def clip_weight(seconds):
    if seconds <= 0:
        return 0.0
    return min(seconds, WEIGHT_SATURATION_SECONDS) / WEIGHT_SATURATION_SECONDS


def anchor_weight(sample_weights, floor=ANCHOR_WEIGHT_FLOOR):
    floor = min(max(floor, 0.0), 0.99)
    total = sum(w for w in sample_weights if w > 0)
    return max(1.0, total * floor / (1.0 - floor))


def weighted_centroid(vectors, weights):
    acc = None
    for vec, weight in zip(vectors, weights):
        if weight <= 0:
            continue
        term = l2(vec) * weight
        acc = term if acc is None else acc + term
    return None if acc is None else l2(acc)


def screened_centroid(anchor, clips, floor=ANCHOR_WEIGHT_FLOOR):
    """``clips`` is ``[(embedding, seconds), ...]``. Mirrors _screened_centroid."""
    kept = [(e, s) for e, s in clips if cos(anchor, e) >= CLIP_AGREEMENT_MIN]
    weights = [clip_weight(s) for _e, s in kept]
    return weighted_centroid(
        [anchor] + [e for e, _s in kept], [anchor_weight(weights, floor)] + weights
    )


# --- synthetic speaker geometry ------------------------------------------

SAME_SPEAKER_COS = 0.65


class Voices:
    """Recordings of a speaker as points at a fixed cosine from their true voice."""

    def __init__(self, seed):
        self.rng = np.random.default_rng(seed)

    def unit(self):
        return l2(self.rng.standard_normal(D))

    def take(self, truth, agreement=SAME_SPEAKER_COS):
        """One recording of ``truth``: correct direction plus orthogonal noise."""
        return l2(agreement * truth + math.sqrt(1 - agreement ** 2) * self.unit())


class DirectionNotMagnitude(unittest.TestCase):
    def test_plain_mean_lets_a_loud_chunk_hijack_the_average(self):
        v = Voices(0)
        truth = v.unit()
        chunks = [v.take(truth, 0.9) for _ in range(4)]
        # Same encoder, different gain: one chunk lands with a much larger norm.
        chunks.append(v.unit() * 12.0)

        plain = np.mean(np.stack(chunks), axis=0)
        normalized = weighted_centroid(chunks, [1.0] * len(chunks))

        self.assertGreater(
            cos(normalized, truth), cos(plain, truth) + 0.15,
            'normalizing before averaging must resist the high-magnitude outlier',
        )

    def test_centroid_is_unit_length(self):
        v = Voices(1)
        c = weighted_centroid([v.unit(), v.unit()], [1.0, 3.0])
        self.assertAlmostEqual(float(np.linalg.norm(c)), 1.0, places=5)

    def test_scaling_an_input_does_not_change_the_result(self):
        v = Voices(2)
        a, b = v.unit(), v.unit()
        self.assertAlmostEqual(
            cos(weighted_centroid([a, b], [1.0, 1.0]),
                weighted_centroid([a * 50.0, b], [1.0, 1.0])),
            1.0, places=5,
        )

    def test_no_usable_vectors_returns_none(self):
        v = Voices(3)
        self.assertIsNone(weighted_centroid([v.unit()], [0.0]))


class MoreGenuineClipsMakeABetterVoiceprint(unittest.TestCase):
    """The point of the whole phase: enrolment must compound."""

    TRIALS = 300

    def _mean_target_score(self, n_clips):
        v = Voices(11)
        total = 0.0
        for _ in range(self.TRIALS):
            truth = v.unit()
            anchor = v.take(truth)
            unseen = v.take(truth)  # never enrolled — this is the test clip
            clips = [(v.take(truth), 10.0) for _ in range(n_clips)]
            total += cos(screened_centroid(anchor, clips), unseen)
        return total / self.TRIALS

    def test_score_against_an_unseen_recording_rises_with_each_clip(self):
        scores = {n: self._mean_target_score(n) for n in (0, 1, 3, 8)}
        self.assertLess(scores[0], scores[1])
        self.assertLess(scores[1], scores[3])
        self.assertLessEqual(scores[3], scores[8] + 0.01)
        # One recording can only reach C^2 (two noisy views compared to each
        # other); the centroid approaches C (a clean view compared to one noisy).
        self.assertLess(scores[0], SAME_SPEAKER_COS ** 2 + 0.05)
        self.assertGreater(scores[8], SAME_SPEAKER_COS ** 2 + 0.08)

    def test_non_target_scores_do_not_rise_with_it(self):
        # A better voiceprint must separate, not just inflate every score. If
        # non-target scores rose too, the gain would be an artefact and the
        # threshold would have to move with enrolment size.
        v = Voices(12)
        for n in (0, 8):
            total = 0.0
            for _ in range(self.TRIALS):
                truth, other = v.unit(), v.unit()
                anchor = v.take(truth)
                clips = [(v.take(truth), 10.0) for _ in range(n)]
                total += cos(screened_centroid(anchor, clips), v.take(other))
            self.assertLess(abs(total / self.TRIALS), 0.08,
                            f'non-target score drifted with {n} clips')


class LengthSaturates(unittest.TestCase):
    def test_weight_grows_then_plateaus(self):
        self.assertAlmostEqual(clip_weight(5.0), 0.5)
        self.assertAlmostEqual(clip_weight(10.0), 1.0)
        self.assertAlmostEqual(clip_weight(30.0), 1.0)
        self.assertAlmostEqual(clip_weight(2713.0), 1.0)

    def test_zero_and_negative_durations_carry_no_weight(self):
        self.assertEqual(clip_weight(0.0), 0.0)
        self.assertEqual(clip_weight(-4.0), 0.0)

    def test_one_long_clip_cannot_outvote_several_good_short_ones(self):
        v = Voices(21)
        truth = v.unit()
        anchor = v.take(truth)
        unseen = v.take(truth)
        # 45-minute mis-sliced clip that still passes the agreement gate,
        # against five honest 6-second clips.
        borderline = l2(0.35 * anchor + math.sqrt(1 - 0.35 ** 2) * v.unit())
        mixed = screened_centroid(
            anchor, [(borderline, 2713.0)] + [(v.take(truth), 6.0) for _ in range(5)]
        )
        long_only = screened_centroid(anchor, [(borderline, 2713.0)])
        self.assertGreater(cos(mixed, unseen), cos(long_only, unseen))


class AnchorKeepsItsFloor(unittest.TestCase):
    def test_anchor_share_is_independent_of_clip_count(self):
        for n in (1, 5, 20, 100):
            weights = [1.0] * n
            a = anchor_weight(weights)
            self.assertAlmostEqual(a / (a + sum(weights)), ANCHOR_WEIGHT_FLOOR, places=6,
                                   msg=f'{n} clips shifted the anchor share')

    def test_a_single_clip_never_outweighs_the_anchor(self):
        self.assertGreaterEqual(anchor_weight([clip_weight(2713.0)]), 1.0)

    def test_anchor_weight_never_drops_below_one(self):
        # With no clips the anchor IS the profile; a zero weight would return None.
        self.assertEqual(anchor_weight([]), 1.0)
        self.assertEqual(anchor_weight([0.0, 0.0]), 1.0)

    def test_aligned_borderline_clips_cannot_pull_the_centroid_off_the_anchor(self):
        # Worst case the gate permits: many long clips, all just above threshold,
        # all leaning the same wrong way. This is the 57-sample production
        # scenario, except now bounded.
        v = Voices(31)
        truth = v.unit()
        anchor = v.take(truth)
        bad = l2(CLIP_AGREEMENT_MIN * anchor
                 + math.sqrt(1 - CLIP_AGREEMENT_MIN ** 2) * v.unit())
        centroid = screened_centroid(anchor, [(bad, 600.0)] * 20)
        self.assertGreater(cos(centroid, anchor), 0.7,
                           'the anchor must still dominate its own profile')

    def test_unbounded_averaging_would_have_failed_this(self):
        # Pins why the floor exists: equal weights let 20 bad clips win outright.
        v = Voices(31)
        truth = v.unit()
        anchor = v.take(truth)
        bad = l2(CLIP_AGREEMENT_MIN * anchor
                 + math.sqrt(1 - CLIP_AGREEMENT_MIN ** 2) * v.unit())
        naive = weighted_centroid([anchor] + [bad] * 20, [1.0] * 21)
        self.assertLess(cos(naive, anchor), cos(naive, bad),
                        'without a floor the clips define the profile, not the anchor')


class DisagreeingClipsAreDropped(unittest.TestCase):
    def test_a_different_speaker_is_rejected_not_averaged(self):
        v = Voices(41)
        truth = v.unit()
        anchor = v.take(truth)
        stranger = v.take(v.unit())
        with_stranger = screened_centroid(anchor, [(stranger, 30.0)])
        self.assertAlmostEqual(cos(with_stranger, anchor), 1.0, places=5,
                               msg='a rejected clip must not move the centroid at all')

    def test_the_gate_is_the_accept_threshold(self):
        # A clip that would not be recognized as this speaker cannot be evidence
        # of how they sound. Any looser and enrolment admits what matching won't.
        src = read(MODAL_SRC_PATH)
        self.assertIn("CAMPPLUS_CLIP_AGREEMENT_MIN', '0.31'", src)
        self.assertIn("CAMPPLUS_SIMILARITY_THRESHOLD', '0.31'", src)

    def test_screening_survives_an_all_bad_clip_set(self):
        v = Voices(42)
        anchor = v.take(v.unit())
        centroid = screened_centroid(anchor, [(v.unit(), 20.0) for _ in range(5)])
        self.assertIsNotNone(centroid)
        self.assertAlmostEqual(cos(centroid, anchor), 1.0, places=5)

    def test_one_admitted_bad_clip_costs_little(self):
        # Screening is not perfect; the cost of a near-threshold mistake has to
        # stay small, or a single slip undoes the gain from every good clip.
        v = Voices(43)
        clean = polluted = 0.0
        trials = 200
        for _ in range(trials):
            truth = v.unit()
            anchor, unseen = v.take(truth), v.take(truth)
            good = [(v.take(truth), 10.0) for _ in range(3)]
            bad = l2(CLIP_AGREEMENT_MIN * anchor
                     + math.sqrt(1 - CLIP_AGREEMENT_MIN ** 2) * v.unit())
            clean += cos(screened_centroid(anchor, good + [(v.take(truth), 10.0)]), unseen)
            polluted += cos(screened_centroid(anchor, good + [(bad, 10.0)]), unseen)
        self.assertLess((clean - polluted) / trials, 0.06)


class MeasuredOnProductionAudio(unittest.TestCase):
    """Facts from scripts/eval_enrolment_compounding.py on real enrolled audio.

    Leave-one-out over one user's 15 independently enrolled recordings (developer
    0f7c3ead, Aug 2026). Every held-out recording was excluded from enrolment, so
    nothing is scored against itself.

    ==========  ======  ==========  ==========
    reference   target  non-target  recognized
    ==========  ======  ==========  ==========
    anchor       0.390       0.236       9/15
    concat       0.449       0.251      11/15
    centroid     0.447       0.300      10/15
    ==========  ======  ==========  ==========

    The centroid raises the score against unseen recordings of the same speaker
    (0.390 -> 0.447) and recognizes one more of them. The non-target column rests
    on a single comparison identity that is itself borderline (0.244 against the
    user, just under the contamination screen), so it does not support a claim
    about separation either way — that is what Phase 3's calibration is for.
    """

    # Same-speaker agreement between two independent recordings of this user,
    # measured across 14 pairs: min 0.091, mean 0.392, max 0.821.
    OBSERVED_SAME_SPEAKER = (0.091, 0.392, 0.821)

    def test_the_gate_admits_a_useful_share_of_genuine_recordings(self):
        # At 0.31 the gate kept 109/195 genuine clips. A gate near the observed
        # mean would reject about half of what the user actually sounds like, and
        # the centroid degenerates to the anchor exactly when it does.
        low, mean, _high = self.OBSERVED_SAME_SPEAKER
        self.assertLess(CLIP_AGREEMENT_MIN, mean,
                        'a gate above mean same-speaker agreement rejects the '
                        'majority of the speaker\'s own recordings')
        self.assertGreater(CLIP_AGREEMENT_MIN, low,
                           'a gate below the observed floor screens nothing at all')

    def test_the_floor_is_what_bounds_a_bad_clip_not_the_gate(self):
        # Genuine clips reach down to 0.091 while a different speaker reached
        # 0.244: the two overlap, so no gate value separates them. That is why the
        # anchor weight floor exists, and why loosening the gate is survivable.
        v = Voices(51)
        truth = v.unit()
        anchor = v.take(truth)
        # A stranger who lands just above a loosened gate, repeated.
        intruder = l2(0.25 * anchor + math.sqrt(1 - 0.25 ** 2) * v.unit())
        loose = screened_centroid(anchor, [(intruder, 30.0)] * 10)
        self.assertGreater(cos(loose, anchor), 0.65,
                           'the floor must bound the damage a loosened gate admits')


class ClipsTravelSeparatelyEndToEnd(unittest.TestCase):
    """Per-clip screening is impossible if the pipeline concatenates first."""

    def test_storage_exposes_anchor_and_clips_separately(self):
        src = read(DB_SRC_PATH)
        self.assertIn('def download_developer_profile_parts', src)
        self.assertIn('MAX_PROFILE_CLIPS', src)
        self.assertIn("SPEECH_PROFILE_MAX_CLIPS', '24'", src)

    def test_people_carry_an_anchor_plus_clip_paths(self):
        src = read(DB_SRC_PATH)
        self.assertIn("'clip_paths': clip_paths", src)
        self.assertIn("'path': anchor_path", src)
        # The anchor is the longest recording and travels WHOLE. Truncating it to the
        # per-clip saturation would be wrong in a way nothing else catches: the
        # anchor's weight comes from _anchor_weight, which does not scale with its
        # length, so cutting it costs embedding quality and buys no budget back.
        body = src.split('def download_developer_people_for_identification')[1]
        self.assertIn('anchor_path, anchor_seconds = readable[0]', body)
        self.assertNotIn('anchor_seconds = min(', body)

    def test_caller_uploads_each_clip_as_its_own_part(self):
        src = read(CALLER_SRC_PATH)
        self.assertIn("'profile_clip_files'", src)
        self.assertIn("'people_clip_files'", src)
        self.assertIn("'people_clip_owners'", src)

    def test_caller_deletes_every_clip_it_downloaded(self):
        # These are per-request temp files; leaking them fills the container disk.
        src = read(CALLER_SRC_PATH)
        self.assertIn('[path for _pid, path in people_clip_parts]', src)
        self.assertIn('(profile_clip_paths if owns_profile else [])', src)

    def test_model_pairs_clips_to_owners_or_drops_them(self):
        src = read(MODAL_SRC_PATH)
        self.assertIn('people_clip_owners', src)
        self.assertIn('ignoring extra clips', src)

    def test_single_file_helper_still_works_for_legacy_callers(self):
        # routers/developer_speech_profile.py and the backfill script still want
        # one path; removing it would break them silently at import time.
        src = read(DB_SRC_PATH)
        self.assertIn('def download_developer_profile_for_identification', src)
        self.assertIn('download_developer_profile_parts(', src)

    def test_the_single_file_helper_cleans_up_when_the_anchor_is_corrupt(self):
        """A throw before the concat loop must not leak the parts it downloaded.

        `AudioSegment.from_wav(anchor)` raising left the anchor plus every clip in
        _temp/. On a long-lived container that is unbounded growth for the one user
        whose profile is broken — and it repeats on every conversation they record,
        because nothing about the failure is sticky.
        """
        src = read(DB_SRC_PATH)
        body = src.split('def download_developer_profile_for_identification')[1]
        body = body.split('def download_developer_profile_parts')[0]
        # The whole assemble must sit under one try/finally that discards the parts.
        self.assertIn('finally:', body)
        tail = body.split('finally:')[1]
        self.assertIn('_discard(anchor_path)', tail)
        self.assertIn('for path in clip_paths:', tail,
                      'clips leak too, not just the anchor')
        # And a failure has to report None rather than a path to a file that the
        # finally block just deleted. Split on the LAST except, since the inner one
        # only skips a single unreadable clip.
        self.assertIn('return None', body.rsplit('except Exception', 1)[1])


class TheClipBudgetReachesMoreThanOneClip(unittest.TestCase):
    """The seconds budget must not be spent entirely on the newest sample.

    ``download_developer_profile_parts`` walks samples newest-first and takes
    ``min(len(sample), budget - used)`` from each. Greedy, that makes
    MAX_PROFILE_CLIPS unreachable whenever the newest sample alone exceeds the
    budget — and the budget is only half the anchor, so one long sample is enough.
    Measured on production audio for developer 0f7c3ead: a 47.3s anchor gives a
    23.6s budget, the newest sample was 58.8s, and enrolment used 1 of 64 samples.

    This is the same shape as the drift<0.80 cutoff that could never fire: a cap
    that reads as implemented while being algebraically dead. So the test walks the
    allocation rather than asserting on the constant.
    """

    # The shipped allocator itself. It lives in the data-layer module but is a pure
    # function over floats, so it imports without GCS, pydub or torch — which is the
    # point of having factored it out: this test exercises production code rather
    # than a mirror that can drift away from it.
    @staticmethod
    def allocate(anchor_seconds, sample_seconds, max_clips=8, share=0.5,
                 saturation=WEIGHT_SATURATION_SECONDS):
        from database.developer_speech_profile import allocate_clip_seconds

        takes = allocate_clip_seconds(
            sample_seconds,
            max_clips=max_clips,
            seconds_budget=None if share is None else anchor_seconds * share,
            saturation=saturation,
        )
        return [t for t in takes if t > 0]

    PROD_ANCHOR = 47.3
    # Newest-first, as the loop sorts them. The newest one alone outruns the budget.
    PROD_SAMPLES = [58.8, 41.2, 33.0, 27.5, 22.1, 19.4, 15.8, 12.3, 11.0, 9.5]

    def test_the_greedy_loop_collapsed_to_a_single_clip(self):
        # Without the saturation cap: reproduces the 1/64 outcome exactly.
        taken = self.allocate(self.PROD_ANCHOR, self.PROD_SAMPLES,
                              saturation=float('inf'))
        self.assertEqual(len(taken), 1,
                         'this is the bug being fixed; if it no longer reproduces, '
                         'the reason to cap per clip is gone too')
        # And most of that single clip bought no weight at all.
        wasted = taken[0] - WEIGHT_SATURATION_SECONDS
        self.assertGreater(wasted, 10.0,
                           'budget spent past saturation is audio the model ignores')

    def test_capping_each_clip_at_saturation_reaches_the_clip_cap(self):
        taken = self.allocate(self.PROD_ANCHOR, self.PROD_SAMPLES)
        self.assertGreaterEqual(len(taken), 2,
                                'the whole point of MAX_PROFILE_CLIPS is >1 clip')
        self.assertTrue(all(t <= WEIGHT_SATURATION_SECONDS + 1e-9 for t in taken))

    def test_no_clip_carries_more_seconds_than_the_model_will_weigh(self):
        # A clip longer than saturation is indistinguishable from one at exactly
        # saturation, so the extra seconds can only crowd out another recording.
        taken = self.allocate(120.0, [300.0, 300.0, 300.0])
        self.assertTrue(all(t <= WEIGHT_SATURATION_SECONDS + 1e-9 for t in taken))

    def test_the_anchor_still_stays_dominant_in_seconds_when_asked(self):
        # The cap must not become a way to exceed the share bound: the concatenating
        # caller (download_developer_profile_for_identification) depends on it, and
        # it is the only caller that passes a share.
        for anchor in (12.0, 30.0, 47.3, 90.0):
            taken = self.allocate(anchor, [11.0] * 20, share=0.5)
            self.assertLessEqual(sum(taken), anchor * 0.5 + 1e-9,
                                 f'anchor {anchor}s lost its majority')

    def test_without_a_share_the_clip_cap_is_what_binds(self):
        """The parts path passes no share, and that is what makes the cap reachable.

        With one, the bound is algebraically dead: MAX_PROFILE_CLIPS=8 needs
        8 x saturation = 80s, while share=0.5 gives 0.5 x anchor, so the cap could
        only bind for an anchor of 160s+. Onboarding recordings are ~47s. Measured on
        production: 3 of 39 samples were ever sent.
        """
        anchor, samples = 47.3, [58.8, 41.2, 33.0, 27.5, 22.1, 19.4, 15.8, 12.3, 11.0]
        with_share = self.allocate(anchor, samples, share=0.5)
        self.assertLess(len(with_share), 4, 'this is the bound being removed')
        without = self.allocate(anchor, samples, share=None)
        self.assertEqual(len(without), 8, 'MAX_PROFILE_CLIPS must now be reachable')
        self.assertTrue(all(t <= WEIGHT_SATURATION_SECONDS + 1e-9 for t in without),
                        'per-clip saturation is still the only per-clip bound')

    def test_the_allocation_is_positionally_aligned_with_its_input(self):
        """Callers zip the takes back onto their blobs, so length must be preserved.

        Returning early (``break``) instead of padding with 0.0 would silently shift
        every later clip onto the wrong blob — and since the clips are all audio of
        the same identity, nothing downstream would look wrong.
        """
        from database.developer_speech_profile import allocate_clip_seconds

        takes = allocate_clip_seconds([12.0] * 10, max_clips=3)
        self.assertEqual(len(takes), 10)
        self.assertEqual(takes[3:], [0.0] * 7)

    def test_a_clip_is_never_admitted_as_a_useless_sliver(self):
        # A budget with 0.0s of room left must produce a skip, not a 0-length wav.
        from database.developer_speech_profile import allocate_clip_seconds

        takes = allocate_clip_seconds([10.0, 10.0], max_clips=8, seconds_budget=10.0)
        self.assertEqual(takes, [10.0, 0.0])

    def test_the_shipped_callers_use_the_allocator(self):
        src = read(DB_SRC_PATH)
        self.assertIn('def allocate_clip_seconds(', src)
        # Both identity paths, so the same off-by-one-loop bug cannot be written twice.
        user_body = src.split('def download_developer_profile_parts')[1]
        user_body = user_body.split('# People whose voiceprint participates')[0]
        self.assertIn('allocate_clip_seconds(', user_body)
        people_body = src.split('def download_developer_people_for_identification')[1]
        self.assertIn('allocate_clip_seconds(', people_body)
        # The two modules hold the same saturation value by copy, not by import.
        self.assertIn("CAMPPLUS_WEIGHT_SATURATION', '10'", src)
        self.assertIn("CAMPPLUS_WEIGHT_SATURATION', '10'", read(MODAL_SRC_PATH))


class ImplementationMatchesSource(unittest.TestCase):
    """Keeps the numpy mirrors above honest about the shipped math."""

    def test_normalization_happens_before_averaging(self):
        src = read(MODAL_SRC_PATH)
        self.assertIn('stacked = torch.stack([_l2_normalize(e) for e in embeddings])', src)
        self.assertIn('return _l2_normalize(stacked.mean(dim=0))', src)
        # The un-normalized mean is what shipped before; it must be gone.
        self.assertNotIn('stacked = torch.stack(embeddings)', src)

    def test_constants_match(self):
        src = read(MODAL_SRC_PATH)
        self.assertIn("CAMPPLUS_WEIGHT_SATURATION', '10'", src)
        self.assertIn("CAMPPLUS_ANCHOR_FLOOR', '0.5'", src)

    def test_anchor_floor_formula_matches(self):
        src = read(MODAL_SRC_PATH)
        self.assertIn('return max(1.0, total_samples * floor / (1.0 - floor))', src)

    def test_centroid_normalizes_each_term_and_the_result(self):
        src = read(MODAL_SRC_PATH)
        self.assertIn('term = _l2_normalize(vec) * weight', src)
        self.assertIn('return _l2_normalize(acc)', src)

    def test_anchor_is_never_screened(self):
        src = read(MODAL_SRC_PATH)
        # The loop screens `clips`; the anchor is passed straight into the centroid.
        self.assertIn('[anchor] + [c[\'emb\'] for c, _ in kept]', src)
        # And when no clip survives, the anchor alone is the profile.
        self.assertIn('return anchor', src)


class ProfileHealthIsObservedNotEnforced(unittest.TestCase):
    """Health metrics are logged; they must not change any match.

    The screen already bounds a bad clip (each clip is scored against the anchor,
    and the anchor holds half the weight regardless). Adding a second rule here
    that silently discarded a whole enrolment set would be an unmeasured change to
    the operating point — and the four identities production has with more than one
    recording are nowhere near enough to calibrate one. So these numbers exist to
    make a poisoned enrolment findable in the logs, and nothing else.

    Thresholds come from scripts/measure_profile_health.py over every enrolled
    identity (2026-08-04):

        drift      min 0.900  mean 0.931  max 1.000   (n=4)
        coherence  0.688                              (n=1 — see below)

    The 0.688 is the one profile independently known to be contaminated (30 of 40
    clips dropped, 48 files flagged by screen_speech_samples.py). It is also the
    ONLY identity in production with two clips long enough for coherence to be a
    real measurement; the rest hold a single clip, where coherence is that clip
    agreeing with itself. The clean-side reference therefore comes from the
    chopping experiment (COHERENCE_BY_CLIP_SECONDS below) rather than from the
    fleet. One positive and one negative example is thin, and the comment in the
    Modal module says so.
    """

    OBSERVED_DRIFT = (0.900, 0.931, 1.000)
    OBSERVED_CONTAMINATED_COHERENCE = 0.688

    def drift(self, anchor, clips):
        c = screened_centroid(anchor, clips)
        return cos(c, anchor)

    def coherence(self, anchor, clips):
        c = screened_centroid(anchor, clips)
        kept = [(e, s) for e, s in clips if cos(anchor, e) >= CLIP_AGREEMENT_MIN]
        return sum(cos(c, e) for e, _s in kept) / len(kept) if kept else 1.0

    def test_a_clean_enrolment_stays_close_to_its_anchor(self):
        v = Voices(701)
        truth = v.unit()
        anchor = v.take(truth, 0.90)
        clips = [(v.take(truth, 0.75), 12.0) for _ in range(6)]
        self.assertGreater(self.drift(anchor, clips), 0.80,
                           'genuine recordings of one speaker must not read as drift')

    @staticmethod
    def at_cos(anchor, toward, agreement):
        """A point at exactly ``agreement`` from ``anchor``, leaning toward ``toward``."""
        perp = toward - float(np.dot(l2(anchor), l2(toward))) * l2(anchor)
        return l2(agreement * l2(anchor) + math.sqrt(1 - agreement ** 2) * l2(perp))

    @staticmethod
    def drift_floor(floor=ANCHOR_WEIGHT_FLOOR, gate=CLIP_AGREEMENT_MIN):
        """Lowest drift the construction can produce, in closed form.

        The centroid is ``a·anchor + s·clipmean`` with ``a/(a+s) = floor``, and no
        kept clip sits closer to the anchor than ``gate``. The worst case is every
        clip identical and exactly on the gate, which gives

            (a + s·g) / sqrt(a² + s² + 2·a·s·g).
        """
        a, s = floor, 1 - floor
        return (a + s * gate) / math.sqrt(a * a + s * s + 2 * a * s * gate)

    def test_borderline_clips_of_another_speaker_show_up_as_drift(self):
        # Each clip clears the 0.31 gate on its own, so the screen keeps them all —
        # exactly the case the counts in the log cannot distinguish from healthy
        # enrolment, and the reason a distance metric was worth adding.
        v = Voices(702)
        anchor = v.unit()
        other = v.unit()
        clips = [(self.at_cos(anchor, v.take(other, 0.95), 0.40), 30.0) for _ in range(8)]
        kept = [c for c in clips if cos(anchor, c[0]) >= CLIP_AGREEMENT_MIN]
        self.assertEqual(len(kept), len(clips), 'the gate is not what catches this')
        clean = [(v.take(anchor, 0.75), 30.0) for _ in range(8)]
        self.assertLess(self.drift(anchor, clips), self.drift(anchor, clean),
                        'a poisoned set must read as more drifted than a clean one')

    def test_a_threshold_below_the_algebraic_floor_could_never_fire(self):
        # The mistake this pins: 0.80 looks like a sensible "far from the anchor"
        # cutoff and is unreachable, because the anchor holds half the weight and
        # no kept clip is worse than the gate. A metric with a dead threshold reads
        # as implemented and detects nothing, which is worse than no metric.
        floor = self.drift_floor()
        self.assertGreater(floor, 0.80,
                           'drift cannot go below ~0.809 at floor=0.5 gate=0.31')
        self.assertGreater(self.shipped('CAMPPLUS_DRIFT_WARN'), floor,
                           'the shipped warning must sit inside the reachable range')

    def test_the_floor_moves_with_the_gate_and_the_anchor_weight(self):
        # Both are env-tunable, so the warning cannot be a bare constant forever;
        # this records the dependency rather than the number.
        self.assertLess(self.drift_floor(gate=0.10), self.drift_floor(gate=0.31))
        self.assertLess(self.drift_floor(floor=0.3), self.drift_floor(floor=0.5))

    @staticmethod
    def shipped(name):
        """The default in the Modal source, so the test reads the shipped value."""
        src = read(MODAL_SRC_PATH)
        return float(src.split(f"'{name}', '")[1].split("'")[0])

    def test_the_coherence_warning_separates_the_known_bad_profile(self):
        warn = self.shipped('CAMPPLUS_COHERENCE_WARN')
        self.assertGreater(warn, self.OBSERVED_CONTAMINATED_COHERENCE,
                           'must fire on the profile known to hold another voice (0.688)')
        # And stay clear of clean audio at the duration gate, which is the only
        # clean-side evidence available — production has no second multi-clip
        # identity to compare against.
        self.assertLess(warn, self.COHERENCE_BY_CLIP_SECONDS[6],
                        'must not fire on a healthy profile — a warning that always '
                        'fires is a warning nobody reads')

    def test_the_clean_side_evidence_is_one_experiment_not_a_fleet(self):
        # Guards against the threshold's provenance being forgotten. If a later
        # reader believes it was calibrated across many healthy profiles, they will
        # trust it more than it deserves.
        src = read(MODAL_SRC_PATH)
        self.assertIn('exactly ONE identity has two clips long enough', src,
                      'the comment must keep saying how thin the evidence is')

    def test_the_drift_warning_sits_below_everything_observed(self):
        low, _mean, _high = self.OBSERVED_DRIFT
        warn = self.shipped('CAMPPLUS_DRIFT_WARN')
        self.assertLess(warn, low,
                        'drift is the backstop, not the primary signal: it should '
                        'only fire on enrolment worse than the current worst')

    # Coherence measured on pieces of ONE speaker's onboarding recording — audio
    # that is single-speaker by construction, so any dip is the metric's own
    # length sensitivity and not contamination.
    COHERENCE_BY_CLIP_SECONDS = {3: 0.785, 4: 0.861, 6: 0.913, 8: 0.937, 12: 0.967}

    def test_coherence_is_confounded_by_clip_length(self):
        # The reason the warning is gated on duration. Chopping clean audio finer
        # makes it look less coherent, which at 3s lands within 0.04 of the 0.75
        # threshold — close enough that short legitimate samples would trip it.
        by_len = self.COHERENCE_BY_CLIP_SECONDS
        self.assertLess(by_len[3], by_len[6])
        self.assertLess(by_len[6], by_len[12])
        warn = self.shipped('CAMPPLUS_COHERENCE_WARN')
        self.assertLess(by_len[3] - warn, 0.05,
                        'clean 3s audio sits near the threshold, so short clips '
                        'must be excluded rather than warned about')

    def test_the_gate_is_set_where_length_stops_mattering(self):
        floor = self.shipped('CAMPPLUS_COHERENCE_MIN_SECONDS')
        self.assertGreaterEqual(self.COHERENCE_BY_CLIP_SECONDS[int(floor)], 0.90,
                                'at the cutoff, clean audio must be comfortably clear '
                                'of the threshold')
        src = read(MODAL_SRC_PATH)
        self.assertIn("c['seconds'] >= COHERENCE_MIN_CLIP_SECONDS", src)
        self.assertIn('len(long_enough) >= 2', src,
                      'coherence between fewer than two clips is not a measurement')

    def test_excluding_short_clips_costs_almost_no_coverage(self):
        # Production enrolment clip durations (79 clips): min 5.4s, median 62.8s,
        # 3.8% under 6s. The duration gate is nearly free here — worth pinning,
        # because if collection ever starts producing short clips the gate would
        # silently switch the metric off.
        share_under_6s = 0.038
        self.assertLess(share_under_6s, 0.10)

    def test_a_mostly_rejected_enrolment_is_reported(self):
        # The loudest signal and the cheapest to read. The contaminated profile
        # drops 30 of 40; healthy ones drop none.
        src = read(MODAL_SRC_PATH)
        self.assertIn('drop_ratio >= DROP_RATIO_WARN', src)
        self.assertIn('total >= DROP_RATIO_MIN_CLIPS', src,
                      'one clip dropped out of one is not evidence of anything')
        self.assertEqual(self.shipped('CAMPPLUS_DROP_RATIO_WARN'), 0.5)

    def test_two_speakers_averaged_together_read_as_low_coherence(self):
        # Both halves agree with the anchor but not with each other: the shape of a
        # reference built from two similar-sounding people.
        v = Voices(703)
        truth = v.unit()
        anchor = v.take(truth, 0.95)
        cousin = l2(0.45 * anchor + 0.89 * v.unit())
        clips = [(v.take(truth, 0.70), 10.0) for _ in range(3)]
        clips += [(v.take(cousin, 0.70), 10.0) for _ in range(3)]
        self.assertLess(self.coherence(anchor, clips),
                        self.coherence(anchor, [(v.take(truth, 0.70), 10.0) for _ in range(6)]))

    def test_an_anchor_only_profile_is_perfectly_healthy(self):
        # No clips is not a warning: it is every user who has only ever onboarded.
        v = Voices(704)
        anchor = v.unit()
        # assertAlmostEqual, not assertEqual: normalizing a vector against itself
        # lands at 1.0000000000000002 in float64.
        self.assertAlmostEqual(self.drift(anchor, []), 1.0, places=9)
        self.assertAlmostEqual(self.coherence(anchor, []), 1.0, places=9)

    def test_the_metrics_do_not_touch_the_returned_centroid(self):
        src = read(MODAL_SRC_PATH)
        health = src.split('drift = _cosine_score(centroid, anchor)')[1]
        body = health.split('return centroid')[0]
        for mutation in ('centroid =', 'kept =', 'return anchor'):
            self.assertNotIn(mutation, body,
                             'the health check must observe, not decide')

    def test_the_warning_is_greppable(self):
        src = read(MODAL_SRC_PATH)
        self.assertIn('PROFILE_HEALTH', src)
        self.assertIn('CAMPPLUS_DRIFT_WARN', src)
        self.assertIn('CAMPPLUS_COHERENCE_WARN', src)

    def test_the_measurement_script_reproduces_the_thresholds(self):
        # The numbers in the comment are only trustworthy if the script that
        # produced them mirrors the shipped construction.
        script = read(os.path.join(
            os.path.dirname(__file__), '..', 'scripts', 'measure_profile_health.py'
        ))
        self.assertIn('def theoretical_floor', script,
                      'the script must report the dead-threshold bound it exists to prevent')
        self.assertIn('cos(anchor, e) >= CLIP_AGREEMENT_MIN', script)
        self.assertIn('total * floor / (1.0 - floor)', script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
