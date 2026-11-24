"""Open-set speaker decisions and enrolled-people matching (Phase 1).

Two changes are under test here.

**Open-set decision.** The old code took ``max(scores)`` and accepted it whenever
it cleared the threshold. That is a closed-set assumption — "the speaker is one of
the people we know" — and it is wrong for this product: most voices a wearable
hears (a colleague, a barista, a TV) belong to nobody enrolled. Two failures
follow. A stranger gets handed to whichever enrolled identity happens to score
highest above threshold. And when two enrolled people score within noise of each
other (common among family members), the winner is decided by a hair. So the
decision now returns ``unknown`` when nobody is close enough and ``ambiguous``
when the top two cannot be separated, and only ``accept`` otherwise.

**People matching.** ``endpoint_with_profile`` used to call
``classify_segments(..., people=[], ...)``. Samples for tagged people had been
collected server-side since day one but never reached the model, so a person
tagged a dozen times still had to be tagged again. The endpoint now takes them,
paired to their IDs by position — and must refuse to guess when that pairing is
inconsistent, because labelling a speaker with the wrong person's ID is worse
than not labelling them.

Run:
    cd backend && python3 tests/test_speaker_open_set_decision.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")


# The hosted model imports torch/torchaudio at call time, not import time, but it
# also imports `modal`, which is not a backend dependency. Re-declare the decision
# rule here from the same constants rather than importing the module. The copy is
# checked against the source in DecisionRuleMatchesSource below.
SIMILARITY_THRESHOLD = 0.31
SCORE_MARGIN = 0.06


def decide(scores, threshold=SIMILARITY_THRESHOLD, margin=SCORE_MARGIN):
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    top_id, top_score = ranked[0]
    if top_score <= threshold:
        return 'unknown', None, top_score
    if len(ranked) > 1 and (top_score - ranked[1][1]) < margin:
        return 'ambiguous', None, top_score
    return 'accept', top_id, top_score


class StrangerIsNotHandedToTheClosestEnrolledPerson(unittest.TestCase):
    """The case a closed-set argmax gets wrong."""

    def test_all_scores_below_threshold_is_unknown(self):
        decision, identity, _ = decide({'user': 0.22, 'p_mother': 0.28, 'p_wife': 0.19})
        self.assertEqual(decision, 'unknown')
        self.assertIsNone(identity, "an unmatched speaker must not be assigned an identity")

    def test_score_exactly_at_threshold_is_not_accepted(self):
        # Strictly-greater. The published operating point is where errors balance,
        # so a score sitting exactly on it carries no information.
        decision, _, _ = decide({'user': SIMILARITY_THRESHOLD})
        self.assertEqual(decision, 'unknown')

    def test_a_single_enrolled_identity_still_needs_the_threshold(self):
        # With one candidate there is no runner-up, so the threshold is the only
        # thing standing between a stranger and an is_user=True.
        self.assertEqual(decide({'user': 0.30})[0], 'unknown')
        self.assertEqual(decide({'user': 0.55})[0], 'accept')


class NearTiesAreNotResolvedByAHair(unittest.TestCase):
    def test_two_close_identities_are_ambiguous(self):
        decision, identity, _ = decide({'user': 0.61, 'p_brother': 0.58})
        self.assertEqual(decision, 'ambiguous')
        self.assertIsNone(identity)

    def test_a_clear_lead_is_accepted(self):
        decision, identity, _ = decide({'user': 0.61, 'p_brother': 0.40})
        self.assertEqual(decision, 'accept')
        self.assertEqual(identity, 'user')

    def test_margin_is_measured_against_the_runner_up_only(self):
        # A crowd of distant candidates must not make an otherwise clear win
        # ambiguous.
        scores = {'user': 0.70, 'a': 0.30, 'b': 0.29, 'c': 0.28, 'd': 0.27}
        self.assertEqual(decide(scores)[0], 'accept')

    def test_ambiguity_survives_when_both_are_strong(self):
        # Both well above threshold but indistinguishable: still refuse. A
        # confident wrong label is worse than an unlabelled speaker.
        self.assertEqual(decide({'p_mother': 0.82, 'p_aunt': 0.80})[0], 'ambiguous')

    def test_person_can_win_over_the_user(self):
        decision, identity, _ = decide({'user': 0.33, 'p_wife': 0.71})
        self.assertEqual(decision, 'accept')
        self.assertEqual(identity, 'p_wife', "people must be able to outrank the user")


class DecisionOutcomeIsReportedNotSwallowed(unittest.TestCase):
    """``unknown``/``ambiguous`` must be distinguishable from "not the user"."""

    def _match_for(self, scores):
        """Mirror of the per-segment dict classify_segments writes."""
        decision, identity, confidence = decide(scores)
        if decision != 'accept':
            return {
                'is_user': False,
                'confidence': confidence,
                'person_id': None,
                'decision': decision,
            }
        return {
            'is_user': identity == 'user',
            'confidence': confidence,
            'person_id': None if identity == 'user' else identity,
            'decision': 'user' if identity == 'user' else 'person',
        }

    def test_unknown_and_rejected_user_are_told_apart(self):
        unknown = self._match_for({'user': 0.10})
        matched_person = self._match_for({'user': 0.10, 'p_wife': 0.75})
        # Both have is_user False; only `decision` says why.
        self.assertFalse(unknown['is_user'])
        self.assertFalse(matched_person['is_user'])
        self.assertEqual(unknown['decision'], 'unknown')
        self.assertEqual(matched_person['decision'], 'person')

    def test_person_match_sets_person_id_and_clears_is_user(self):
        m = self._match_for({'user': 0.20, 'p_mother': 0.66})
        self.assertFalse(m['is_user'])
        self.assertEqual(m['person_id'], 'p_mother')

    def test_user_match_clears_person_id(self):
        m = self._match_for({'user': 0.66, 'p_mother': 0.20})
        self.assertTrue(m['is_user'])
        self.assertIsNone(m['person_id'])

    def test_non_accept_never_leaks_a_person_id(self):
        for scores in ({'user': 0.1, 'p_a': 0.2}, {'p_a': 0.80, 'p_b': 0.79}):
            m = self._match_for(scores)
            self.assertIsNone(m['person_id'])
            self.assertFalse(m['is_user'])


MIN_DECIDED_SEGMENTS = 2


class VoteLoopTreatsUndecidedAsNoEvidence(unittest.TestCase):
    """Abstentions are the absence of evidence, not evidence against.

    The vote used to count every non-``is_user`` segment as a vote for "not the
    user", including the ones where the model had said it could not tell. Then it
    required a person to hold half of ALL segments. Together those meant the
    model's own uncertainty outvoted the people it had recognized: four confident
    matches among ten segments lost to six abstentions (4*2 < 10) and the speaker
    went unlabelled. That is precisely the reported symptom — "I marked this person
    many times and they are still never recognized" — so the tally now runs over
    decided segments only.
    """

    def _vote(self, matches):
        """Condensed copy of the per-speaker vote in utils/stt/speech_profile.py."""
        yes = 0
        pids = {}
        decided = 0
        undecided = {}
        for m in matches:
            outcome = m.get('decision')
            if outcome in ('unknown', 'ambiguous'):
                undecided[outcome] = undecided.get(outcome, 0) + 1
                continue
            if m.get('is_user'):
                yes += 1
                decided += 1
            elif m.get('person_id'):
                pids[m['person_id']] = pids.get(m['person_id'], 0) + 1
                decided += 1
        if decided < min(MIN_DECIDED_SEGMENTS, len(matches)):
            return None, undecided
        ranked = sorted(pids.items(), key=lambda kv: kv[1], reverse=True)
        top_pid, top_count = ranked[0] if ranked else (None, 0)
        if (len(ranked) > 1 and ranked[1][1] == top_count) or (
            yes == top_count and yes > 0
        ):
            undecided['ambiguous'] = undecided.get('ambiguous', 0) + decided
            return None, undecided
        if yes > top_count:
            return 'user', undecided
        if top_pid and top_count * 2 >= decided:
            return top_pid, undecided
        return None, undecided

    def test_all_unknown_yields_no_label(self):
        matches = [{'is_user': False, 'person_id': None, 'decision': 'unknown'}] * 5
        label, undecided = self._vote(matches)
        self.assertIsNone(label)
        self.assertEqual(undecided, {'unknown': 5},
                         'unresolved speakers must be countable, by reason, for follow-up')

    def test_abstentions_do_not_outvote_confident_matches(self):
        # The regression this class exists for. Under the old rule: 4*2 < 10, no label.
        matches = [{'is_user': False, 'person_id': 'p_a', 'decision': 'person'}] * 4
        matches += [{'is_user': False, 'person_id': None, 'decision': 'unknown'}] * 6
        self.assertEqual(self._vote(matches)[0], 'p_a')

    def test_the_old_rule_would_have_failed_that(self):
        # Pins the arithmetic rather than trusting the description of it.
        confident, abstained = 4, 6
        self.assertLess(confident * 2, confident + abstained)

    def test_unknown_and_ambiguous_are_counted_apart(self):
        # They need different questions: "who was this?" vs "was this A or B?".
        matches = [{'is_user': False, 'person_id': None, 'decision': 'unknown'}] * 3
        matches += [{'is_user': False, 'person_id': None, 'decision': 'ambiguous'}] * 2
        self.assertEqual(self._vote(matches)[1], {'unknown': 3, 'ambiguous': 2})

    def test_a_lone_match_among_many_segments_is_not_enough(self):
        # One hit on a mis-diarized fragment must not become somebody's name.
        matches = [{'is_user': False, 'person_id': None, 'decision': 'unknown'}] * 9
        matches.append({'is_user': False, 'person_id': 'p_a', 'decision': 'person'})
        self.assertIsNone(self._vote(matches)[0])

    def test_a_short_speaker_can_still_be_labelled(self):
        # A speaker with a single segment cannot reach MIN_DECIDED_SEGMENTS; the
        # floor must not make short speakers permanently unlabellable.
        self.assertEqual(
            self._vote([{'is_user': True, 'person_id': None, 'decision': 'user'}])[0],
            'user',
        )

    def test_consistent_person_wins(self):
        matches = [{'is_user': False, 'person_id': 'p_a', 'decision': 'person'}] * 4
        self.assertEqual(self._vote(matches)[0], 'p_a')

    def test_user_and_person_are_compared_head_to_head(self):
        # Not "user beats everything else combined" — the two labels compete
        # directly, so a person the user tagged can win their own segments.
        matches = [{'is_user': True, 'person_id': None, 'decision': 'user'}] * 2
        matches += [{'is_user': False, 'person_id': 'p_a', 'decision': 'person'}] * 5
        self.assertEqual(self._vote(matches)[0], 'p_a')

    def test_an_even_split_between_two_people_yields_no_label(self):
        # 3 vs 3. max() would hand the speaker to whichever key it saw first.
        matches = [{'is_user': False, 'person_id': 'p_a', 'decision': 'person'}] * 3
        matches += [{'is_user': False, 'person_id': 'p_b', 'decision': 'person'}] * 3
        label, undecided = self._vote(matches)
        self.assertIsNone(label, 'a tie must not be resolved by dict ordering')
        self.assertEqual(undecided.get('ambiguous'), 6,
                         'a tie is worth asking about, not silently dropping')

    def test_a_tie_between_the_user_and_a_person_yields_no_label(self):
        matches = [{'is_user': True, 'person_id': None, 'decision': 'user'}] * 3
        matches += [{'is_user': False, 'person_id': 'p_a', 'decision': 'person'}] * 3
        self.assertIsNone(self._vote(matches)[0])

    def test_a_clear_majority_still_wins(self):
        # The tie guard must not make every mixed speaker unlabellable.
        matches = [{'is_user': False, 'person_id': 'p_a', 'decision': 'person'}] * 5
        matches += [{'is_user': False, 'person_id': 'p_b', 'decision': 'person'}] * 1
        self.assertEqual(self._vote(matches)[0], 'p_a')


class VoteLoopMatchesSource(unittest.TestCase):
    """Keeps the copy above honest about the shipped vote."""

    def _source(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'utils', 'stt', 'speech_profile.py'
        )
        with open(path) as f:
            return f.read()

    def test_abstentions_skip_the_tally_entirely(self):
        src = self._source()
        self.assertIn("if outcome in ('unknown', 'ambiguous'):", src)
        # `continue` before any vote is counted is what makes it "no evidence".
        head = src.split("if outcome in ('unknown', 'ambiguous'):")[1]
        self.assertIn('continue', head.split('pid =')[0])

    def test_the_person_share_is_measured_against_decided_segments(self):
        src = self._source()
        self.assertIn('top_count * 2 >= decided', src)
        self.assertNotIn('top_count * 2 >= total', src)

    def test_user_and_person_compete_directly(self):
        self.assertIn('if yes > top_count:', self._source())

    def test_reasons_are_kept_apart(self):
        src = self._source()
        self.assertIn('undecided[spk][outcome] += 1', src)

    def test_a_decided_floor_exists_and_respects_short_speakers(self):
        src = self._source()
        self.assertIn('MIN_DECIDED_SEGMENTS', src)
        self.assertIn('min(MIN_DECIDED_SEGMENTS, segment_counts[spk])', src)

    def test_ties_are_refused_rather_than_ordered(self):
        src = self._source()
        self.assertIn('ranked = sorted(pids.items()', src)
        self.assertIn('ranked[1][1] == top_count', src)
        # max() on the person tally is what silently picked a winner.
        self.assertNotIn('top_pid, top_count = max(pids.items()', src)

    def test_unresolved_reason_reaches_the_segment(self):
        src = self._source()
        self.assertIn("seg['speaker_status'] = reason", src)
        # And is cleared once a label is written, or a stale prompt outlives it.
        self.assertIn("seg.pop('speaker_status', None)", src)


class PeoplePairingGuard(unittest.TestCase):
    """people_ids and people_files are paired positionally; mismatches must abort."""

    @staticmethod
    def pair(people_ids, people_files):
        """Mirror of the pairing logic in endpoint_with_profile."""
        import json

        try:
            ids = json.loads(people_ids) if people_ids else []
        except (json.JSONDecodeError, TypeError):
            ids = []
        if people_files and len(ids) != len(people_files):
            return []  # drop entirely rather than mislabel
        return [{'id': str(pid), 'file': f} for pid, f in zip(ids, people_files)]

    def test_matched_lengths_pair_in_order(self):
        got = self.pair('["p_a", "p_b"]', ['fileA', 'fileB'])
        self.assertEqual([(p['id'], p['file']) for p in got], [('p_a', 'fileA'), ('p_b', 'fileB')])

    def test_mismatch_drops_all_people_rather_than_zipping_short(self):
        # zip() alone would silently pair p_a<->fileA and discard fileB, giving
        # someone else's audio a name. Refuse instead.
        self.assertEqual(self.pair('["p_a"]', ['fileA', 'fileB']), [])
        self.assertEqual(self.pair('["p_a", "p_b", "p_c"]', ['fileA', 'fileB']), [])

    def test_malformed_ids_json_drops_people(self):
        self.assertEqual(self.pair('not json', ['fileA']), [])

    def test_no_people_is_valid_and_yields_nothing(self):
        # The user-only path (match_people=False, or nobody enrolled yet).
        self.assertEqual(self.pair('[]', []), [])
        self.assertEqual(self.pair('', []), [])

    def test_numeric_ids_are_stringified(self):
        got = self.pair('[12, 34]', ['a', 'b'])
        self.assertEqual([p['id'] for p in got], ['12', '34'])


class DecisionRuleMatchesSource(unittest.TestCase):
    """Guards the copied rule above against drift from the deployed model."""

    def _source(self):
        path = os.path.join(
            os.path.dirname(__file__), '..', 'modal', 'speech_profile_modal_campplus.py'
        )
        with open(path) as f:
            return f.read()

    def test_default_threshold_and_margin_are_unchanged(self):
        src = self._source()
        self.assertIn("'CAMPPLUS_SIMILARITY_THRESHOLD', '0.31'", src)
        self.assertIn("'CAMPPLUS_SCORE_MARGIN', '0.06'", src)

    def test_endpoint_forwards_people_instead_of_an_empty_list(self):
        src = self._source()
        self.assertIn(
            'classify_segments(\n            audio_path, profile_path, people, transcript_segments,',
            src,
        )
        self.assertNotIn('classify_segments(audio_path, profile_path, [], transcript_segments)', src)

    def test_threshold_comparison_stays_exclusive(self):
        self.assertIn('if top_score <= SIMILARITY_THRESHOLD:', self._source())


if __name__ == "__main__":
    unittest.main(verbosity=2)
