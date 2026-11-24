"""
Unit tests for should_discard_conversation duration/density rules.

Covers:
- Rule 0 (short duration) firing via segment start/end timing — the signal the
  real-time path (developer_listen.py) previously failed to feed in.
- Rule 0.5 (language density): long recording + sparse words → discard, with
  the 90s / 25-words-per-minute boundary conditions.

These rules are all pre-LLM, so the tests never reach any network/LLM call.

Run:
    cd backend && source venv/bin/activate  # (or just python3 — self-contained)
    python tests/test_discard_conversation.py
"""

import os
import sys
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Minimal env so importing the module (which builds LLM clients) doesn't crash.
os.environ.setdefault("OPENAI_API_KEY", "test")

import utils.llm.conversation_processing as cp
from utils.llm.conversation_processing import should_discard_conversation
from langchain_core.messages import AIMessage


class _FakeLLM:
    """Stands in for the discard LLM so 'keep' cases that fall through the
    rule pre-filters never make a real network call. Always votes keep."""

    def __init__(self, discard=False, is_media=False):
        self.discard = discard
        self.is_media = is_media
        self.calls = []

    def invoke(self, messages):
        self.calls.append(messages)
        return AIMessage(
            content='{"discard": %s, "is_media": %s}'
            % (str(self.discard).lower(), str(self.is_media).lower())
        )


class _Seg:
    """Attribute-style segment view, mirroring what the callers construct."""

    def __init__(self, text, is_user=True, start=None, end=None):
        self.text = text
        self.is_user = is_user
        self.start = start
        self.end = end


def _segments_from_words(total_words, span_seconds, is_user=True):
    """Build a single segment carrying `total_words` distinct words spread over
    `span_seconds`, so meaningful-word count and speaking span are controllable."""
    text = " ".join(f"word{i}" for i in range(total_words))
    return [_Seg(text=text, is_user=is_user, start=0.0, end=float(span_seconds))]


def _transcript(segments):
    return "\n".join(f"{'User' if s.is_user else 'Speaker 1'}: {s.text}" for s in segments)


class ShortDurationRule(unittest.TestCase):
    def test_short_speaking_span_discards(self):
        # 20s of speech via segment timing → Rule 0 discard (no wall-clock given)
        segs = _segments_from_words(40, span_seconds=20)
        self.assertTrue(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )

    def test_short_wall_clock_discards(self):
        segs = _segments_from_words(40, span_seconds=200)  # long speech span
        started = datetime(2026, 7, 28, 10, 0, 0)
        finished = started + timedelta(seconds=20)  # but short wall-clock
        self.assertTrue(
            should_discard_conversation(
                _transcript(segs), started_at=started, finished_at=finished,
                transcript_segments=segs,
            )
        )


class LanguageDensityRule(unittest.TestCase):
    def setUp(self):
        # Cases that pass the pre-filters fall through to the LLM; stub it so
        # "keep" assertions test the density boundary, not the network.
        self._orig_resolve_llm = cp.resolve_llm
        cp.resolve_llm = lambda resolved, default_llm: _FakeLLM()

    def tearDown(self):
        cp.resolve_llm = self._orig_resolve_llm

    def test_long_sparse_discards(self):
        # 120s, only 10 words → 5 words/min → discard
        segs = _segments_from_words(10, span_seconds=120)
        self.assertTrue(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )

    def test_below_90s_does_not_trigger_density(self):
        # 89s: too short to judge density. 20 words over 89s ≈ 13.5 w/min would
        # trip the density rule if it applied — but it must NOT at <90s. Words
        # kept >=8 so Rule 1 doesn't discard for a different reason.
        segs = _segments_from_words(20, span_seconds=89)
        self.assertFalse(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )

    def test_density_just_below_threshold_discards(self):
        # 90s with density = 24 words/min → 36 words → discard.
        segs = _segments_from_words(36, span_seconds=90)
        self.assertTrue(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )

    def test_density_at_threshold_keeps(self):
        # 120s with density = 25 words/min → 50 words → NOT discarded by density.
        # 50 meaningful words, unique → passes Rules 1/2; enough user speech that
        # it should fall through the rule pre-filters (kept, or handed to LLM).
        segs = _segments_from_words(50, span_seconds=120)
        self.assertFalse(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )

    def test_photos_bypass_density(self):
        from models.conversation import ConversationPhoto

        segs = _segments_from_words(10, span_seconds=120)  # would be discarded
        photos = [ConversationPhoto(base64="x", description="a vivid sunset over the bay")]
        self.assertFalse(
            should_discard_conversation(
                _transcript(segs), photos=photos, transcript_segments=segs
            )
        )


# ⚠️ 本类里显式传 `speaker_attribution_available=True` 且 segments 全无 `is_user` 的用例，
# 测的是**当前生产不可达**的状态：三个调用点都用 `any(is_user)` 求这个参数，所以
# True ⟺ 至少有一段 is_user。它们守的是**函数契约**（将来若出现「先跑声纹、再判丢弃」的
# 调用点，这条媒体信号会重新可达），不是当下的生产行为。当下生产走的是
# `test_signal_is_actively_contradicted_when_attribution_never_ran` 那一支。
# 背景见 utils/llm/conversation_processing.py 里 Rule 3 上方的注释。
class NoUserSpeechRule(unittest.TestCase):
    """Rule 3: "no user speech" must be a SIGNAL to the LLM, not a verdict.

    `is_user` comes only from voiceprint matching, so a session-wide matching
    failure makes a genuine conversation indistinguishable from passive media
    listening. Rule 3 used to discard outright, which silently threw away real
    conversations (observed: 140 segments / 1372 words at 76.8 words-per-minute).
    """

    def setUp(self):
        self._orig_resolve_llm = cp.resolve_llm

    def tearDown(self):
        cp.resolve_llm = self._orig_resolve_llm

    def _install(self, llm):
        cp.resolve_llm = lambda resolved, default_llm: llm
        return llm

    def _no_user_segments(self):
        """Reproduces the real regression: many segments, none matched to the
        user, but a normal human speech density (>25 w/min, >80 words)."""
        segs = [
            _Seg(text=" ".join(f"word{i}_{j}" for j in range(12)), is_user=False,
                 start=float(i * 10), end=float(i * 10 + 9))
            for i in range(40)
        ]
        return segs

    def test_no_user_speech_is_not_an_automatic_discard(self):
        llm = self._install(_FakeLLM(discard=False))
        segs = self._no_user_segments()
        self.assertFalse(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True),
            "a real conversation whose voiceprint matching failed must survive",
        )
        self.assertTrue(llm.calls, "the media judgement must be delegated to the LLM")

    def test_no_user_speech_still_discarded_when_llm_says_media(self):
        # Genuine media playback: same shape, but the LLM judges it on content.
        llm = self._install(_FakeLLM(discard=True, is_media=True))
        segs = self._no_user_segments()
        self.assertTrue(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )

    def test_llm_receives_the_no_user_speech_signal(self):
        llm = self._install(_FakeLLM(discard=False))
        segs = self._no_user_segments()
        should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                    speaker_attribution_available=True)
        sent = "\n".join(m.content for m in llm.calls[0])
        self.assertIn("does NOT appear in any segment", sent)

    def test_signal_is_actively_contradicted_when_attribution_never_ran(self):
        """本类其余用例都显式传 `speaker_attribution_available=True`，因为它们要测的是
        「归属信息已经有了、但没人被认出来」那一支。这一条守另一支 —— 少了它，那些显式
        参数会让整个类对新的默认值（False）**结构上失明**：默认值翻转过一次，正是
        实时路径把 81% 的真实对话丢掉的原因。

        判据是「必须**主动反驳**」而不只是沉默：模板里那条 media bullet 会一直挂在那儿，
        只是不提这个信号，模型照旧会按 bullet 办事。
        """
        llm = self._install(_FakeLLM(discard=False))
        segs = self._no_user_segments()
        should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                    speaker_attribution_available=False)
        sent = "\n".join(m.content for m in llm.calls[0])
        self.assertIn("UNAVAILABLE", sent)
        self.assertIn("MUST NOT", sent)
        self.assertNotIn(
            "does NOT appear in any segment", sent,
            "归属信息还没产生时，不能把「没人被标成 User」当成证据递给模型",
        )

    def test_user_participation_still_short_circuits_without_llm(self):
        # Unchanged behaviour: long transcript WITH user speech skips the LLM.
        llm = self._install(_FakeLLM(discard=True, is_media=True))
        segs = [
            _Seg(text=" ".join(f"word{i}_{j}" for j in range(12)), is_user=True,
                 start=float(i * 10), end=float(i * 10 + 9))
            for i in range(40)
        ]
        self.assertFalse(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )
        self.assertFalse(llm.calls, "should not spend an LLM call when the user clearly spoke")

    def test_short_no_user_capture_still_discarded_by_earlier_rules(self):
        # Rule 0/0.5 run BEFORE Rule 3 and are untouched: a brief ambient
        # capture with no user speech must still be discarded without an LLM.
        llm = self._install(_FakeLLM(discard=False))
        segs = _segments_from_words(40, span_seconds=20, is_user=False)
        self.assertTrue(
            should_discard_conversation(_transcript(segs), transcript_segments=segs,
                                        speaker_attribution_available=True)
        )
        self.assertFalse(llm.calls, "pre-LLM rules must still fire first")


class UserParticipationAcceptsDicts(unittest.TestCase):
    """`_compute_user_participation` must handle dict segments.

    It used to do `s.is_user` directly, which raises AttributeError on plain
    dicts. Firestore reads and the WebSocket path both carry dicts, so the
    post-speaker-identification discard revisit (`_revisit_user_dependent_verdicts`)
    and the backfill script both hit this.
    """

    def test_dict_segments(self):
        segs = [
            {"text": "hello there friend", "is_user": True},
            {"text": "other speaker talking", "is_user": False},
        ]
        part = cp._compute_user_participation(segs)
        self.assertEqual(part["total_segments"], 2)
        self.assertEqual(part["user_segments"], 1)
        self.assertAlmostEqual(part["user_ratio"], 3 / 6, places=3)

    def test_attr_segments_still_work(self):
        segs = [_Seg("hello there friend", is_user=True), _Seg("other speaker talking", is_user=False)]
        part = cp._compute_user_participation(segs)
        self.assertEqual(part["user_segments"], 1)
        self.assertAlmostEqual(part["user_ratio"], 3 / 6, places=3)

    def test_missing_fields_do_not_crash(self):
        part = cp._compute_user_participation([{}, {"text": "hi"}])
        self.assertEqual(part["user_segments"], 0)
        self.assertEqual(part["user_ratio"], 0.0)

    def test_empty_returns_none(self):
        self.assertIsNone(cp._compute_user_participation([]))


class SummaryMediaVerdict(unittest.TestCase):
    def test_exact_media_sentinel_discards_even_when_classifier_kept(self):
        structured = {"title": "[Media Recording]"}
        self.assertTrue(cp.merge_discard_verdict(False, structured))

    def test_existing_discard_verdict_is_preserved(self):
        structured = {"title": "真实对话"}
        self.assertTrue(cp.merge_discard_verdict(True, structured))

    def test_normal_summary_stays_visible(self):
        structured = {"title": "一起写数学作业"}
        self.assertFalse(cp.merge_discard_verdict(False, structured))

    def test_nearby_title_is_not_treated_as_the_product_sentinel(self):
        structured = {"title": "Media Recording Notes"}
        self.assertFalse(cp.merge_discard_verdict(False, structured))

    def test_all_three_initial_processing_paths_merge_the_summary_verdict(self):
        backend_dir = os.path.dirname(os.path.dirname(__file__))
        expected = {
            "routers/developer_listen.py": (
                "should_discard = merge_discard_verdict(should_discard, structured)"
            ),
            "routers/developer_conversations.py": (
                "should_discard = merge_discard_verdict(should_discard, structured)"
            ),
            "utils/conversations/process_conversation.py": (
                "return structured, merge_discard_verdict(False, structured)"
            ),
        }
        for relative_path, call in expected.items():
            with open(os.path.join(backend_dir, relative_path), encoding="utf-8") as source_file:
                source = source_file.read()
            self.assertIn(call, source, f"{relative_path} 没合并摘要器的媒体判定")

    def test_batch_path_persists_the_merged_discard_value(self):
        backend_dir = os.path.dirname(os.path.dirname(__file__))
        with open(
            os.path.join(backend_dir, "utils/conversations/process_conversation.py"),
            encoding="utf-8",
        ) as source_file:
            source = source_file.read()
        self.assertIn(
            "developer_id=developer_id, discarded=discarded",
            source,
            "批处理算出了 discarded 却没传给 Conversation，入库仍会变回 false",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
