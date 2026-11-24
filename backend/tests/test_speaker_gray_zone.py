"""The gray zone: what happens when the matcher cannot decide (Phase 3).

An open-set matcher that refuses to guess is behaving correctly, but a refusal
that goes nowhere is indistinguishable from a bug. Before this, the only trace of
an unresolved speaker was a server log line: the app showed "Speaker 1" with no
way to know identification had even been attempted, and the user's only recourse
was to tag the same person again — which is exactly the loop they complained
about.

So a refusal now carries a reason, the reason reaches the client, and answering
enrols the audio (the assign endpoints already do that, gated on
``source='manual'``). Each answered prompt makes the next match better, which is
what turns single-shot recognition into something that compounds.

Two failure modes this file guards:

**A stale question.** A prompt that outlives its answer asks the user to identify
someone already named. The mark must be cleared the moment a label is written.

**A dropped field.** FastAPI response models silently discard undeclared fields,
so a field can be persisted correctly and still never reach the app — the same
way ``discarded`` once made every conversation look meaningful.

Run:
    cd backend && python3 tests/test_speaker_gray_zone.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

CALLER_SRC = os.path.join(os.path.dirname(__file__), '..', 'utils', 'stt', 'speech_profile.py')
ROUTER_SRC = os.path.join(
    os.path.dirname(__file__), '..', 'routers', 'developer_conversations.py'
)


def read(path):
    with open(path) as f:
        return f.read()


def group_unresolved(segments):
    """Mirror of ``_unresolved_speakers``.

    Copied rather than imported because the router pulls in Firestore, Redis and
    the LLM clients at import time. ``ImplementationMatchesSource`` guards drift.
    """
    by_speaker = {}
    for seg in segments:
        reason = seg.get('speaker_status')
        if not reason or seg.get('is_user') or seg.get('person_id'):
            continue
        try:
            sid = int(seg.get('speaker_id') or 0)
        except (TypeError, ValueError):
            continue
        entry = by_speaker.setdefault(sid, {'segments': 0, 'reasons': {}})
        entry['segments'] += 1
        entry['reasons'][reason] = entry['reasons'].get(reason, 0) + 1
    out = []
    for sid, entry in sorted(by_speaker.items()):
        reason = max(entry['reasons'].items(), key=lambda kv: kv[1])[0]
        out.append({'speaker_id': sid, 'segments': entry['segments'], 'reason': reason})
    return out


def seg(sid, status=None, is_user=False, person_id=None):
    return {'speaker_id': sid, 'speaker_status': status,
            'is_user': is_user, 'person_id': person_id}


class TheUserIsAskedAboutSpeakersNotSentences(unittest.TestCase):
    def test_many_segments_become_one_question(self):
        segments = [seg(1, 'unknown') for _ in range(8)]
        got = group_unresolved(segments)
        self.assertEqual(len(got), 1, 'one prompt per speaker, not per segment')
        self.assertEqual(got[0], {'speaker_id': 1, 'segments': 8, 'reason': 'unknown'})

    def test_each_speaker_gets_its_own_question(self):
        segments = [seg(1, 'unknown'), seg(2, 'ambiguous'), seg(1, 'unknown')]
        got = group_unresolved(segments)
        self.assertEqual([g['speaker_id'] for g in got], [1, 2])
        self.assertEqual([g['reason'] for g in got], ['unknown', 'ambiguous'])

    def test_the_dominant_reason_wins(self):
        # Mixed reasons across one speaker's segments: the question has to be one
        # question, so the more common reason picks its wording.
        segments = [seg(3, 'unknown')] * 4 + [seg(3, 'ambiguous')]
        self.assertEqual(group_unresolved(segments)[0]['reason'], 'unknown')

    def test_output_is_ordered_by_speaker(self):
        segments = [seg(5, 'unknown'), seg(0, 'unknown'), seg(2, 'unknown')]
        self.assertEqual([g['speaker_id'] for g in group_unresolved(segments)], [0, 2, 5])


class NoQuestionOutlivesItsAnswer(unittest.TestCase):
    def test_a_labelled_speaker_is_never_asked_about(self):
        # Belt and braces: the mark is cleared when a label is written, and the
        # grouping ignores any that survived — e.g. written by an older build.
        self.assertEqual(group_unresolved([seg(1, 'unknown', person_id='p_a')]), [])
        self.assertEqual(group_unresolved([seg(1, 'unknown', is_user=True)]), [])

    def test_writing_a_label_clears_the_mark(self):
        src = read(CALLER_SRC)
        self.assertIn("seg.pop('speaker_status', None)", src)
        # Clearing must count as a change, or the cleared mark is never persisted
        # and the prompt reappears on the next read.
        clear = src.split("seg.pop('speaker_status', None)")[1]
        self.assertIn('updated = True', clear.split("if kind == 'user':")[0])

    def test_segments_with_no_mark_are_silent(self):
        self.assertEqual(group_unresolved([seg(1), seg(2)]), [])

    def test_malformed_speaker_ids_do_not_crash(self):
        for bad in (None, 'x', {}, []):
            group_unresolved([{'speaker_status': 'unknown', 'speaker_id': bad}])


class TheFieldReachesTheClient(unittest.TestCase):
    """A response model drops undeclared fields — silently."""

    def test_segment_response_declares_the_status(self):
        src = read(ROUTER_SRC)
        self.assertIn('class SegmentResponse(BaseModel):', src)
        body = src.split('class SegmentResponse(BaseModel):')[1].split('class ')[0]
        self.assertIn('speaker_status', body,
                      'undeclared fields are dropped, so the app would never see it')

    def test_identify_response_carries_the_questions(self):
        src = read(ROUTER_SRC)
        self.assertIn('class UnresolvedSpeaker(BaseModel):', src)
        body = src.split('class IdentifySpeakersResponse(BaseModel):')[1].split('def ')[0]
        self.assertIn('unresolved', body)

    def test_unresolved_is_returned_on_both_paths(self):
        # Nothing matched is precisely when the user most needs to be asked, so
        # the early return has to carry the list too.
        src = read(ROUTER_SRC)
        self.assertEqual(src.count('unresolved=unresolved'), 2,
                         'both the matched and the unmatched return need it')

    def test_matched_reflects_labels_not_bookkeeping(self):
        # `updated` is now true when only a reason was recorded. Reporting that as
        # matched=True would tell the app a speaker was identified when none was.
        src = read(ROUTER_SRC)
        self.assertIn('matched=changed > 0', src)


class ImplementationMatchesSource(unittest.TestCase):
    """Keeps the copied helper honest."""

    def test_grouping_skips_labelled_and_unmarked_segments(self):
        src = read(ROUTER_SRC)
        self.assertIn('if not reason or seg.get("is_user") or seg.get("person_id"):', src)

    def test_grouping_picks_the_dominant_reason(self):
        src = read(ROUTER_SRC)
        self.assertIn('reason = max(entry["reasons"].items(), key=lambda kv: kv[1])[0]', src)

    def test_grouping_sorts_by_speaker(self):
        self.assertIn('for sid, entry in sorted(by_speaker.items()):', read(ROUTER_SRC))


if __name__ == "__main__":
    unittest.main(verbosity=2)
