"""Tests for the `product_faq` tool and the product manual behind it.

The tool exists because of three observed live failures on product questions
(recorded in utils/retrieval/product_manual.py's docstring): a charging question
routed into memory_search, a bluetooth question flatly refused, and a pricing
question answered "免费" off the App Store listing. The first two are annoying;
the third is the one that matters — a confident wrong answer. So the tests below
lean on two properties above all else:

* the routing questions that used to fail must now hit the right section, in both
  Chinese and English;
* a question the manual does not cover must come back *empty* with the contacts
  attached, never a nearest-neighbour section that invites a guess.

Plus a packaging guard: the manual is a .md file, so unlike every other change
here it can be broken by deployment rather than by code.
"""

import os
import unittest

os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")


class AManualParses(unittest.TestCase):
    def test_sections_have_ids_titles_keywords_and_body(self):
        from utils.retrieval.product_manual import load_sections

        sections = load_sections()
        self.assertGreaterEqual(len(sections), 8, "manual should cover the main topics")
        for s in sections:
            self.assertTrue(s.id)
            self.assertTrue(s.title)
            self.assertTrue(s.keywords, f"section {s.id} has no keywords")
            self.assertTrue(s.body.strip(), f"section {s.id} has an empty body")

    def test_ids_are_unique(self):
        from utils.retrieval.product_manual import load_sections

        ids = [s.id for s in load_sections()]
        self.assertEqual(len(ids), len(set(ids)))

    def test_every_section_has_chinese_and_english_keywords(self):
        """Users ask in either language; a section reachable in only one is a hole."""
        from utils.retrieval.product_manual import load_sections

        for s in load_sections():
            has_cjk = any(any("一" <= ch <= "鿿" for ch in k) for k in s.keywords)
            has_ascii = any(k.isascii() and k.isprintable() for k in s.keywords)
            self.assertTrue(has_cjk, f"section {s.id} has no Chinese keywords")
            self.assertTrue(has_ascii, f"section {s.id} has no English keywords")


class BManualIsPackagedForProduction(unittest.TestCase):
    """The manual is data, not code — it can be lost at build time, silently.

    `Dockerfile` does `COPY . .`, so the only way it goes missing in the image is
    a `.dockerignore` rule. If that happens the tool degrades to "no sections" for
    every question, which reads to the user exactly like the manual saying nothing
    — the failure is invisible from the outside. Assert the location it must live
    in stays inside a copied path and unignored.
    """

    def test_manual_lives_under_utils_retrieval(self):
        from utils.retrieval.product_manual import MANUAL_PATH

        self.assertTrue(MANUAL_PATH.exists(), f"manual missing at {MANUAL_PATH}")
        self.assertEqual(MANUAL_PATH.parent.name, "retrieval")
        self.assertEqual(MANUAL_PATH.parent.parent.name, "utils")

    def test_dockerignore_does_not_exclude_markdown_or_utils(self):
        import pathlib

        root = pathlib.Path(__file__).resolve().parents[1]
        patterns = [
            line.strip()
            for line in (root / ".dockerignore").read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
        for bad in ("*.md", "**/*.md", "utils/", "utils"):
            self.assertNotIn(bad, patterns, f".dockerignore would drop the manual: {bad}")


class CLookupRoutesTheQuestionsThatUsedToFail(unittest.TestCase):
    """The three live failure modes, plus their English equivalents."""

    def _ids(self, query, **kw):
        from utils.retrieval.product_manual import lookup

        return [s["id"] for s in lookup(query, **kw)["sections"]]

    def test_charging_question_hits_device_basics(self):
        # Used to be answered by searching the user's own recordings.
        self.assertIn("device-basics", self._ids("怎么充电？电池能用多久"))
        self.assertIn("device-basics", self._ids("how do I charge it and how long does the battery last"))

    def test_bluetooth_trouble_hits_troubleshooting(self):
        # Used to be refused as "不在我能查到的记忆范围内".
        self.assertIn("device-troubleshooting", self._ids("蓝牙连不上怎么办"))
        self.assertIn("device-troubleshooting", self._ids("my device won't connect over bluetooth"))

    def test_pricing_question_hits_account_section(self):
        # Used to be answered "免费" off the App Store listing.
        self.assertIn("account", self._ids("Memorion 多少钱"))
        self.assertIn("account", self._ids("how much does Memorion cost"))

    def test_repair_question_hits_support(self):
        for q in ("设备坏了怎么维修", "保修怎么算", "how do I get it repaired", "warranty and returns"):
            with self.subTest(q=q):
                ids = self._ids(q)
                self.assertTrue(
                    {"support", "device-troubleshooting"} & set(ids),
                    f"{q!r} routed to {ids}",
                )

    def test_capability_and_recording_questions(self):
        self.assertIn("what-is-memorion", self._ids("我能用 Memorion 做什么"))
        self.assertIn("recording", self._ids("怎么暂停录音"))
        self.assertIn("recording", self._ids("how do I stop recording"))

    def test_held_out_questions_all_route_somewhere(self):
        """Coverage sweep over questions the keyword lists were not tuned against.

        Written before the keywords were adjusted, then used to find the gaps —
        four of these originally missed ("怎么让它认出我说话", "how heavy is it",
        "how do I train my voice", "who do I email for a refund"). Kept as a
        regression net: editing the manual must not un-route a real question.
        """
        cases = {
            "它能听懂日语吗": "languages",
            "does it support japanese": "languages",
            "我的数据存在哪里安全吗": "privacy-data",
            "is my data encrypted": "privacy-data",
            "怎么让它认出我说话": "voice-recognition",
            "how do I train my voice": "voice-recognition",
            "转写人名总是错怎么办": "voice-recognition",
            "每天晚上的推送怎么关": "notifications",
            "how do I turn off notifications": "notifications",
            "怎么导出我的所有数据": "privacy-data",
            "how do I export my data": "privacy-data",
            "设备防水吗": "device-basics",
            "is it waterproof": "device-basics",
            # Adjacent-but-not-equivalent: the manual says *daily* waterproof, so
            # this must reach that section to be correctly refused rather than
            # missing and leaving the model to reason from nothing.
            "我能戴着它游泳吗": "device-basics",
            "can I wear it swimming": "device-basics",
            "能戴着洗澡吗": "device-basics",
            "有多重": "device-basics",
            "how heavy is it": "device-basics",
            "怎么删掉一段录音": "privacy-data",
            "can I delete recordings": "privacy-data",
            "怎么把待办同步到提醒事项": "privacy-data",
            "怎么退出登录": "account",
            "where do I see the transcript": "after-recording",
            "who do I email for a refund": "support",
            "保修怎么算": "support",
        }
        for q, expected in cases.items():
            with self.subTest(q=q):
                self.assertIn(expected, self._ids(q))

    def test_limit_is_capped(self):
        from utils.retrieval.product_manual import MAX_SECTION_LIMIT, lookup

        out = lookup("录音 充电 隐私 通知 语言 维修 价格", limit=99)
        self.assertLessEqual(len(out["sections"]), MAX_SECTION_LIMIT)


class DMissReturnsNothingRatherThanAGuess(unittest.TestCase):
    """A question outside the manual must not get a plausible-adjacent section.

    This is the property that separates keyword lookup from a similarity search
    here: on a miss, the model needs to *know* it missed, or it fills the gap —
    which is how the pricing answer went wrong in the first place.
    """

    def test_unrelated_question_returns_empty_with_topics(self):
        from utils.retrieval.product_manual import lookup

        for q in ("今天上海天气怎么样", "帮我写一段 python 代码"):
            with self.subTest(q=q):
                out = lookup(q)
                self.assertEqual(out["sections"], [], f"{q!r} should not match the manual")
                self.assertTrue(out["available_topics"], "a miss should still say what IS covered")
                self.assertIn("team@memorion.me", out["guidance"])

    def test_guidance_carries_both_contacts_on_a_hit_too(self):
        from utils.retrieval.product_manual import lookup

        out = lookup("怎么充电")
        self.assertTrue(out["sections"])
        self.assertIn("support@memorion.me", out["guidance"])
        self.assertIn("team@memorion.me", out["guidance"])


class EManualExcludesUnbuiltFeatures(unittest.TestCase):
    """The manual must not promise app features that are placeholders or mock data.

    Confirmed by inventory of the app: ring/flash to locate a lost device is a
    "coming soon" snackbar (device_detail_page.dart `_showFindDeviceSoon`), the
    sync page's Wi-Fi "Fast Transfer" toggle is inert, and local storage's 8GB
    total is a hardcoded constant. Documenting any of them as usable would send
    users hunting for a button that does nothing.
    """

    def _text(self):
        from utils.retrieval.product_manual import load_sections

        return "\n".join(s.body for s in load_sections())

    def test_no_ring_to_find_device_promise(self):
        text = self._text()
        # The topic may be mentioned, but only as unsupported.
        if "响铃" in text:
            self.assertIn("暂不支持", text, "ring-to-locate may only appear as unsupported")

    def test_no_fast_transfer_or_fake_capacity(self):
        text = self._text()
        self.assertNotIn("快速传输", text)
        # The local-storage page's 8GB total is a hardcoded constant, not the real
        # device capacity. Quoting it would give users a fabricated spec.
        self.assertNotIn("8GB", text)
        self.assertNotIn("8 GB", text)

    def test_storage_is_described_without_inventing_a_capacity(self):
        """The phone-side cache is real and worth documenting; the device's own
        capacity is not published, so it must be an explicit "ask support"."""
        from utils.retrieval.product_manual import load_sections

        basics = next(s for s in load_sections() if s.id == "device-basics")
        self.assertIn("本地存储", basics.body)
        self.assertIn("没有公开参数", basics.body)

    def test_no_subscription_or_quota_claims(self):
        """Subscription was removed and everyone is unlimited; don't reintroduce it."""
        from utils.retrieval.product_manual import load_sections

        account = next(s for s in load_sections() if s.id == "account")
        self.assertIn("没有订阅入口", account.body)


class FToolSurface(unittest.TestCase):
    """product_faq is registered, identity-free, and returns the manual's payload."""

    def _tools(self):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        return {t.name: t for t in make_agent_tools(RequestContext(uid="u", developer_id="d"), CitationAccumulator())}

    def test_registered_and_hides_identity(self):
        tool = self._tools()["product_faq"]
        keys = set(tool.args.keys())
        self.assertEqual(keys, {"query", "limit"})

    def test_invoking_returns_sections(self):
        out = self._tools()["product_faq"].invoke({"query": "电池能用几天"})
        self.assertTrue(out["sections"])
        self.assertIn("4 天", out["sections"][0]["content"])

    def test_needs_no_developer_id(self):
        """Unlike the data tools, the manual is not per-user — it must still work
        when developer_id is absent (e.g. an unbound key)."""
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        tools = {t.name: t for t in make_agent_tools(RequestContext(uid="u", developer_id=None), CitationAccumulator())}
        out = tools["product_faq"].invoke({"query": "怎么充电"})
        self.assertTrue(out["sections"])

    def test_emits_a_progress_thought(self):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        thoughts = []

        class FakeCallback:
            def put_thought_nowait(self, text):
                thoughts.append(text)

        ctx = RequestContext(uid="u", developer_id="d", callback=FakeCallback())
        tools = {t.name: t for t in make_agent_tools(ctx, CitationAccumulator())}
        tools["product_faq"].invoke({"query": "怎么充电"})
        self.assertTrue(thoughts)


class GSystemPromptPointsAtTheTool(unittest.TestCase):
    """The prompt must route product questions to product_faq and away from web_search.

    Without the policy line the tool exists but goes unused — the model already
    "knows" what Memorion is and answers from that instead.
    """

    def test_policy_line_in_fallback_and_registry_seed_match(self):
        import json
        import pathlib
        import re

        root = pathlib.Path(__file__).resolve().parents[1]
        src = (root / "utils/retrieval/agent_prompt.py").read_text(encoding="utf-8")
        fallback = re.search(r'_SYSTEM_PROMPT_FALLBACK = """(.*?)"""', src, re.DOTALL).group(1)

        self.assertIn("product_faq", fallback)
        self.assertIn("web_search returns the App Store page", fallback)

        seed = json.loads((root / "scripts/benchmark/seed_prompts/chat.json").read_text(encoding="utf-8"))
        entry = next(e for e in seed if e["key"] == "chat.agent_system")
        # The registry seed is what actually ships; a drifted seed means the
        # deployed prompt never learns about the tool.
        self.assertEqual(entry["content"], fallback)


if __name__ == "__main__":
    unittest.main()
