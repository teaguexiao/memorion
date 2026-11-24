"""Re-segmenting a speaker that streaming diarization merged into one.

Streaming diarization can only see a short window, so it sometimes collapses two
people who sound alike — a parent and child are the classic case — into a single
speaker_id. The per-speaker voice vote then ties (half the segments match the
user, half match someone else) and the whole speaker is written off as
'ambiguous', leaving the conversation with no is_user segment at all. The summary
LLM sees a transcript where "User" never speaks and files a real family
conversation as "[Media Recording]".

``_apply_speaker_matches`` now checks whether that tie is noise or a genuine
two-person mix. When both sides are large enough to be real speakers it splits
the speaker: each segment keeps its own voice decision instead of a single voted
label. This file pins that behaviour and, just as importantly, the cases where it
must NOT split — a normal single speaker whose ~20% per-segment noise would
otherwise be torn into a phantom second person.

Run:
    cd backend && python3 tests/test_speaker_resegmentation.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

from utils.stt.speech_profile import (  # noqa: E402
    _apply_speaker_matches,
    SPLIT_MIN_SEGMENTS,
    SPLIT_MIN_SHARE,
)


def seg(speaker_id):
    """A transcript segment before voice matching writes any label."""
    return {'speaker_id': speaker_id, 'is_user': False, 'person_id': None}


def m_user():
    return {'decision': 'user', 'is_user': True, 'person_id': None}


def m_person(pid):
    return {'decision': 'person', 'is_user': False, 'person_id': pid}


def m_none(reason='unknown'):
    return {'decision': reason, 'is_user': False, 'person_id': None}


def run(matches, protected=None):
    """Score N segments of one speaker (speaker_id=1) against the given matches."""
    segments = [seg(1) for _ in matches]
    return _apply_speaker_matches(segments, matches, protected or set())


class AMergedParentAndChildAreSplitApart(unittest.TestCase):
    """The bug this whole change exists to fix."""

    def test_a_balanced_tie_of_two_real_people_is_split_not_dropped(self):
        # 5 user + 5 the same person, one speaker_id. The vote ties; before this
        # the whole speaker went 'ambiguous' and no segment was is_user.
        matches = [m_user()] * 5 + [m_person('dad')] * 5
        segments, updated = run(matches)
        self.assertTrue(updated)
        users = [s for s in segments if s.get('is_user')]
        dads = [s for s in segments if s.get('person_id') == 'dad']
        self.assertEqual(len(users), 5, 'the user half must be recovered as is_user')
        self.assertEqual(len(dads), 5, "the other half keeps its own person decision")
        # Nobody in a split speaker is left flagged ambiguous.
        self.assertFalse(any(s.get('speaker_status') for s in segments))

    def test_the_user_half_is_no_longer_lost_to_media_misjudgement(self):
        # The regression symptom was zero is_user segments. Guard the count > 0.
        matches = [m_user()] * 4 + [m_person('dad')] * 6
        segments, _ = run(matches)
        self.assertTrue(any(s.get('is_user') for s in segments))

    def test_a_segment_the_model_could_not_place_stays_unlabelled_after_split(self):
        # Splitting honours each segment's own decision, so an abstaining segment
        # inside a split speaker gets no invented label.
        matches = [m_user()] * 4 + [m_person('dad')] * 4 + [m_none('ambiguous')] * 2
        segments, _ = run(matches)
        placed = [s for s in segments if s.get('is_user') or s.get('person_id')]
        self.assertEqual(len(placed), 8, 'only the decided segments get labels')

    def test_an_abstaining_segment_in_a_split_speaker_records_its_own_reason(self):
        # A segment that abstains inside a split speaker should carry its own
        # 'ambiguous'/'unknown' reason so the app can still ask about it.
        matches = [m_user()] * 4 + [m_person('dad')] * 4 + [m_none('ambiguous')] * 2
        segments, _ = run(matches)
        abstained = segments[-2:]
        self.assertTrue(all(s.get('speaker_status') == 'ambiguous' for s in abstained),
                        'abstained segments keep their prompt even after a split')

    def test_a_stale_prompt_is_cleared_when_a_split_segment_now_resolves(self):
        # Re-processing: a segment that previously abstained (carrying a stale
        # speaker_status) now matches the user. The old prompt must be cleared so
        # the app does not ask about a speaker that is already labelled.
        matches = [m_user()] * 4 + [m_person('dad')] * 4
        segments = [seg(1) for _ in matches]
        segments[0]['speaker_status'] = 'ambiguous'  # left over from a prior run
        _apply_speaker_matches(segments, matches, set())
        self.assertTrue(segments[0]['is_user'])
        self.assertNotIn('speaker_status', segments[0],
                         'a resolved split segment must not keep a stale prompt')


class NoiseIsStillSmoothedNotSplit(unittest.TestCase):
    """A split must never fire on the per-segment noise the vote exists to absorb."""

    def test_a_confident_user_with_a_couple_of_stray_person_hits_stays_the_user(self):
        # 9 user, 1 stray person hit: not a tie, and nowhere near the split bars.
        # This is an ordinary noisy single speaker and must resolve to the user.
        matches = [m_user()] * 9 + [m_person('dad')] * 1
        segments, _ = run(matches)
        self.assertTrue(all(s.get('is_user') for s in segments))
        self.assertFalse(any(s.get('person_id') for s in segments))

    def test_a_tie_where_the_minor_side_is_below_the_segment_floor_is_ambiguous(self):
        # Tie in counts but the smaller side is only SPLIT_MIN_SEGMENTS-1 segments
        # — too small to trust as a second person, so keep the old ambiguous call.
        minor = SPLIT_MIN_SEGMENTS - 1
        matches = [m_user()] * minor + [m_person('dad')] * minor
        segments, updated = run(matches)
        self.assertTrue(all(s.get('speaker_status') == 'ambiguous' for s in segments))
        self.assertFalse(any(s.get('is_user') or s.get('person_id') for s in segments))

    def test_a_user_slice_below_the_share_floor_is_not_split_out(self):
        # The user clears SPLIT_MIN_SEGMENTS in raw count but is a small slice of a
        # busy speaker dominated by one person — below SPLIT_MIN_SHARE. A few
        # stray user hits inside someone else's speaker are more likely per-segment
        # noise than a genuine merge, so the speaker resolves to the person and no
        # phantom user split is created.
        user_n = SPLIT_MIN_SEGMENTS  # clears the segment floor
        # Make the person side big enough that the user's share < SPLIT_MIN_SHARE.
        dad_n = user_n
        while user_n >= (user_n + dad_n) * SPLIT_MIN_SHARE:
            dad_n += 1
        matches = [m_user()] * user_n + [m_person('dad')] * dad_n
        segments, _ = run(matches)
        self.assertFalse(any(s.get('is_user') for s in segments),
                         'a small user slice of a busy speaker must not be split out')
        self.assertTrue(all(s.get('person_id') == 'dad' for s in segments),
                        'the dominant person takes the whole speaker')


class ExistingVotingBehaviourIsUnchanged(unittest.TestCase):
    """The refactor into a pure function must not move any pre-existing verdict."""

    def test_a_clear_user_speaker_resolves_to_user(self):
        segments, _ = run([m_user()] * 6)
        self.assertTrue(all(s.get('is_user') for s in segments))

    def test_a_clear_person_speaker_resolves_to_that_person(self):
        segments, _ = run([m_person('alice')] * 6)
        self.assertTrue(all(s.get('person_id') == 'alice' for s in segments))
        self.assertFalse(any(s.get('is_user') for s in segments))

    def test_all_abstentions_leave_an_unknown_prompt(self):
        segments, _ = run([m_none('unknown')] * 5)
        self.assertTrue(all(s.get('speaker_status') == 'unknown' for s in segments))

    def test_abstentions_do_not_outvote_confident_matches(self):
        # The documented regression: 4 confident user + 6 abstentions must still
        # resolve to the user, not be dragged to no-label.
        segments, _ = run([m_user()] * 4 + [m_none('unknown')] * 6)
        self.assertTrue(any(s.get('is_user') for s in segments))

    def test_a_protected_speaker_is_never_overwritten(self):
        # Manually tagged mid-recording: even a strong user vote must not touch it.
        segments = [seg(1) for _ in range(4)]
        segments[0]['person_id'] = 'manually_tagged'
        matches = [m_user()] * 4
        _apply_speaker_matches(segments, matches, {'SPEAKER_01'})
        self.assertEqual(segments[0]['person_id'], 'manually_tagged')
        self.assertFalse(segments[0]['is_user'])


class TwoStrangersWithNoUserAreNotSplit(unittest.TestCase):
    """We only split a tie that involves the user (decision C from design)."""

    def test_two_people_tied_without_the_user_stay_ambiguous(self):
        # dad vs mom tie, no user segments. Splitting strangers buys nothing (we
        # cannot attach either to the user) and risks tearing one noisy speaker.
        matches = [m_person('dad')] * 5 + [m_person('mom')] * 5
        segments, _ = run(matches)
        self.assertTrue(all(s.get('speaker_status') == 'ambiguous' for s in segments))


if __name__ == "__main__":
    unittest.main(verbosity=2)
