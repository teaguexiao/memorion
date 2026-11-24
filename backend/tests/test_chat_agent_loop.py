"""End-to-end tests for the tool-calling chat agent (PR2).

Why end-to-end and not just source assertions: the overhaul plan (§13.10, and
CLAUDE.md) records that the last retrieval regression was two individually-correct
functions wired together wrong — retrieval ranked a conversation #1 but the
Firestore fetch reordered it away. The agent loop has the same shape of risk:
memory_search can return the right hits, the model can cite the right index, and
it can still all fall apart if `memories_found`'s order doesn't line up with the
`[index]` the model emitted. So the core tests drive the *real* create_react_agent
and the *real* execute_graph_chat with a scripted fake model, and assert the
citation round-trips through developer_chat.process_message.

These tests stub the two external boundaries (embedding + Firestore/Pinecone) so
they run offline, but everything between — the agent graph, the tools, the
citation accumulator, the answer assembly — is the production code path.
"""

import os
import re
import unittest
from datetime import datetime, timezone
from typing import Any, List, Optional
from unittest import mock

os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

from langchain_core.callbacks import CallbackManagerForLLMRun
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, AIMessageChunk, BaseMessage
from langchain_core.outputs import ChatGeneration, ChatGenerationChunk, ChatResult

# The three conversations a stubbed retrieval returns, in relevance order.
# ASML is #1 — the exact shape of the §13.10 regression.
FAKE_CONVERSATIONS = {
    "asml-1": {
        "id": "asml-1",
        "created_at": "2026-01-29T08:12:00+00:00",
        "structured": {"title": "ASML and chip manufacturing", "overview": "Discussed ASML's EUV lithography role.", "emoji": "🔬"},
        "transcript_segments": [{"text": "ASML makes EUV machines", "is_user": True, "speaker": "User"}],
    },
    "tsmc-2": {
        "id": "tsmc-2",
        "created_at": "2026-01-20T10:00:00+00:00",
        "structured": {"title": "TSMC fabs", "overview": "Talked about TSMC foundry capacity.", "emoji": "🏭"},
        "transcript_segments": [{"text": "TSMC fabs in Taiwan", "is_user": False, "speaker": "SPEAKER_1"}],
    },
    "intel-3": {
        "id": "intel-3",
        "created_at": "2026-01-10T09:00:00+00:00",
        "structured": {"title": "Intel roadmap", "overview": "Intel's process node roadmap.", "emoji": "💻"},
        "transcript_segments": [{"text": "Intel 18A", "is_user": False, "speaker": "SPEAKER_2"}],
    },
}

# Relevance order the fake retrieval hands back — ASML first.
RANKED_IDS = ["asml-1", "tsmc-2", "intel-3"]


class ScriptedToolModel(BaseChatModel):
    """A fake chat model that first calls memory_search, then answers citing [1].

    It reproduces exactly what a real tool-calling model does over an agent loop:
    turn 1 emits a tool_call (no text content), turn 2 — after the ToolMessage
    comes back — emits the final answer. `bind_tools` is a no-op passthrough so
    create_react_agent can bind our tools onto it.
    """

    answer_text: str = "You talked about ASML's role in EUV lithography[1]."

    @property
    def _llm_type(self) -> str:
        return "scripted-tool-model"

    def bind_tools(self, tools, **kwargs):
        return self

    def _has_tool_result(self, messages: List[BaseMessage]) -> bool:
        return any(m.type == "tool" for m in messages)

    def _generate(
        self,
        messages: List[BaseMessage],
        stop: Optional[List[str]] = None,
        run_manager: Optional[CallbackManagerForLLMRun] = None,
        **kwargs: Any,
    ) -> ChatResult:
        if self._has_tool_result(messages):
            msg = AIMessage(content=self.answer_text)
        else:
            msg = AIMessage(
                content="",
                tool_calls=[{"name": "memory_search", "args": {"query": "ASML chip manufacturing"}, "id": "call_1"}],
            )
        return ChatResult(generations=[ChatGeneration(message=msg)])

    def _stream(
        self,
        messages: List[BaseMessage],
        stop: Optional[List[str]] = None,
        run_manager: Optional[CallbackManagerForLLMRun] = None,
        **kwargs: Any,
    ):
        # A real streaming backend (ChatOpenAI) emits token chunks; reproduce that
        # so the test exercises the `data:` streaming path, not just _generate.
        if self._has_tool_result(messages):
            for token in self.answer_text.split(" "):
                yield ChatGenerationChunk(message=AIMessageChunk(content=token + " "))
        else:
            yield ChatGenerationChunk(
                message=AIMessageChunk(
                    content="",
                    tool_call_chunks=[
                        {"name": "memory_search", "args": '{"query": "ASML chip manufacturing"}', "id": "call_1", "index": 0}
                    ],
                )
            )


def _install_retrieval_stubs(stack: mock._patch, ranked_ids=None):
    """Patch embedding + Pinecone + Firestore so retrieval is deterministic/offline."""
    ranked_ids = ranked_ids if ranked_ids is not None else RANKED_IDS

    class FakeEmbedding:
        values = [0.1] * 3072

    stack.enter_context(mock.patch("utils.retrieval.agent_tools.generate_embedding_query", return_value=FakeEmbedding()))
    stack.enter_context(
        mock.patch("utils.retrieval.agent_tools.query_vectors_by_metadata", return_value=list(ranked_ids))
    )

    def fake_get_by_ids(developer_id, uid, ids):
        # Mirror the real contract: return dicts in the same order as `ids`,
        # skipping any that don't exist.
        return [FAKE_CONVERSATIONS[i] for i in ids if i in FAKE_CONVERSATIONS]

    stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_conversations_by_ids", side_effect=fake_get_by_ids))


class AToolSchemasHideIdentity(unittest.TestCase):
    """§9.5: uid/developer_id must never appear in a tool's schema."""

    def test_no_identity_params(self):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        tools = make_agent_tools(RequestContext(uid="u", developer_id="d"), CitationAccumulator())
        for tool in tools:
            keys = set(tool.args.keys())
            self.assertNotIn("uid", keys)
            self.assertNotIn("developer_id", keys)
            self.assertNotIn("external_user_id", keys)


class BMemorySearchPreservesRankAndHidesFullText(unittest.TestCase):
    """memory_search returns snippets in retrieval order, accumulates full dicts."""

    def test_order_and_snippet(self):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        with mock.patch.object(mock, "_dummy", create=True):
            pass
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_retrieval_stubs(stack)
            citations = CitationAccumulator()
            tools = {t.name: t for t in make_agent_tools(RequestContext(uid="u", developer_id="d"), citations)}
            out = tools["memory_search"].invoke({"query": "chips"})

        results = out["results"]
        # ASML ranked first must stay first, with index 1.
        self.assertEqual([r["id"] for r in results], RANKED_IDS)
        self.assertEqual(results[0]["index"], 1)
        self.assertEqual(results[0]["id"], "asml-1")
        # Snippet only — no transcript text leaked.
        for r in results:
            self.assertNotIn("transcript_segments", r)
            self.assertIn("snippet", r)
        # The accumulator holds the FULL dicts in the same 1-based order.
        self.assertEqual([c["id"] for c in citations.ordered], RANKED_IDS)
        self.assertIn("transcript_segments", citations.ordered[0])

    def test_dedup_keeps_stable_index(self):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_retrieval_stubs(stack)
            citations = CitationAccumulator()
            tools = {t.name: t for t in make_agent_tools(RequestContext(uid="u", developer_id="d"), citations)}
            tools["memory_search"].invoke({"query": "chips"})
            tools["memory_search"].invoke({"query": "chips again"})

        # Searching twice must not duplicate or renumber.
        self.assertEqual(len(citations), 3)
        self.assertEqual([c["id"] for c in citations.ordered], RANKED_IDS)


class CResolveTimeRangeInjectsTz(unittest.TestCase):
    """resolve_time_range's timezone comes from the request ctx, not a tool arg."""

    def test_tz_from_ctx(self):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools
        from datetime import datetime, timezone

        with mock.patch(
            "utils.retrieval.agent_tools.retrieve_context_dates_by_question",
            return_value=[datetime(2026, 1, 1, tzinfo=timezone.utc), datetime(2026, 1, 7, tzinfo=timezone.utc)],
        ):
            tools = {
                t.name: t
                for t in make_agent_tools(RequestContext(uid="u", developer_id="d", tz="Asia/Shanghai"), CitationAccumulator())
            }
            out = tools["resolve_time_range"].invoke({"expr": "last week"})
        self.assertEqual(out["timezone"], "Asia/Shanghai")
        self.assertTrue(out["start"].startswith("2026-01-01"))
        self.assertNotIn("tz", tools["resolve_time_range"].args)


class DExecuteGraphChatEndToEnd(unittest.TestCase):
    """Drive the real create_react_agent + execute_graph_chat with the scripted model."""

    def _run(self, ranked_ids=None):
        import contextlib
        import utils.retrieval.graph as g
        from models.chat import Message
        from datetime import datetime, timezone

        with contextlib.ExitStack() as stack:
            _install_retrieval_stubs(stack, ranked_ids=ranked_ids)
            stack.enter_context(mock.patch("utils.retrieval.graph.create_llm", return_value=ScriptedToolModel()))
            stack.enter_context(mock.patch("utils.retrieval.graph.dev_db.get_user_time_zone", return_value="UTC"))
            stack.enter_context(mock.patch("utils.retrieval.agent_prompt.get_prompt_memories", return_value=("Alex", "facts\n- likes chips")))
            stack.enter_context(mock.patch("utils.retrieval.agent_prompt._get_language_instruction", return_value=""))

            msgs = [Message(id="m1", text="What did I discuss about ASML?", created_at=datetime.now(timezone.utc), sender="human", type="text")]
            return g.execute_graph_chat("u", msgs, developer_id="d", cited=True)

    def test_answer_citation_and_memories_order(self):
        answer, ask_for_nps, memories = self._run()
        self.assertIn("[1]", answer)
        self.assertTrue(ask_for_nps)
        # memories_found[0] must be the top-ranked ASML conversation — this is the
        # §13.10 assertion: the [1] in the answer resolves to the #1 retrieval hit.
        self.assertEqual(memories[0]["id"], "asml-1")

    def test_citation_roundtrips_through_process_message(self):
        """The [index] in the answer must map back to memories_found[index-1].

        Calls the same `resolve_cited_conversations` the router calls rather than
        re-deriving the mapping here: a test that reimplements the logic keeps
        passing when the shipped logic breaks.
        """
        from models.chat import resolve_cited_conversations

        answer, _, memories = self._run()
        clean, resolved = resolve_cited_conversations(answer, memories)
        self.assertEqual(len(resolved), 1)
        self.assertEqual(resolved[0]["id"], "asml-1")
        self.assertNotIn("[1]", clean)

    def test_reordered_retrieval_would_break_citation(self):
        """Reverse-guard: if retrieval ranked Intel first, [1] must resolve to Intel.

        Confirms the citation index tracks retrieval order rather than being fixed
        — the same property whose absence caused §13.10.
        """
        from models.chat import resolve_cited_conversations

        answer, _, memories = self._run(ranked_ids=["intel-3", "tsmc-2", "asml-1"])
        _, resolved = resolve_cited_conversations(answer, memories)
        self.assertEqual(resolved[0]["id"], "intel-3")


class DdCitationCap(unittest.TestCase):
    """The user-facing bound on conversation cards per answer.

    Pinned because the cap used to be two independent `[:5]` slices written as
    different expressions (one on the stored `memories_id`, one on the displayed
    `ai_message.memories`), so raising or lowering it in one place silently made
    the app show a different number of cards than the message recorded.
    """

    @staticmethod
    def _fake(n):
        return [{"id": f"c{i}"} for i in range(1, n + 1)]

    def test_caps_at_three(self):
        from models.chat import MAX_CITED_CONVERSATIONS, resolve_cited_conversations

        self.assertEqual(MAX_CITED_CONVERSATIONS, 3)
        _, resolved = resolve_cited_conversations("a[1] b[2] c[3] d[4] e[5]", self._fake(5))
        self.assertEqual([m["id"] for m in resolved], ["c1", "c2", "c3"])

    def test_cap_keeps_citation_order_not_retrieval_rank(self):
        """When the cap bites, it must drop the *last-mentioned* conversations.

        A `set` (the previous shape) sorts by index, so citing [5][4][1] would
        have kept 1,4,5 — i.e. silently substituted retrieval rank for the order
        the answer actually leans on.
        """
        from models.chat import resolve_cited_conversations

        _, resolved = resolve_cited_conversations("x[5] y[4] z[1] w[2]", self._fake(5))
        self.assertEqual([m["id"] for m in resolved], ["c5", "c4", "c1"])

    def test_repeated_index_counts_once(self):
        from models.chat import resolve_cited_conversations

        _, resolved = resolve_cited_conversations("a[1] b[1] c[2]", self._fake(5))
        self.assertEqual([m["id"] for m in resolved], ["c1", "c2"])

    def test_out_of_range_index_dropped_not_wrapped(self):
        """A hallucinated [9] must vanish, not index from the end of the list."""
        from models.chat import resolve_cited_conversations

        _, resolved = resolve_cited_conversations("a[9] b[0] c[2]", self._fake(3))
        self.assertEqual([m["id"] for m in resolved], ["c2"])

    def test_uncited_answer_left_untouched(self):
        """No markers means no rewrite — the text must survive byte-for-byte."""
        from models.chat import resolve_cited_conversations

        clean, resolved = resolve_cited_conversations("I have no record of that.", self._fake(3))
        self.assertEqual(clean, "I have no record of that.")
        self.assertEqual(resolved, [])

    def test_dead_voice_path_shares_the_bound(self):
        """utils/chat.py has no callers today; if revived it must not re-introduce 5."""
        with open(os.path.join(os.path.dirname(__file__), "..", "utils", "chat.py")) as fh:
            src = fh.read()
        self.assertNotIn("memories[:5]", src)
        self.assertEqual(len(re.findall(r"memories\[:MAX_CITED_CONVERSATIONS\]", src)), 2)


class EExecuteGraphChatStreamEndToEnd(unittest.TestCase):
    """Streaming path: SSE prefixes, no leaked tool-turn, callback_data populated.

    Driven through asyncio.run rather than IsolatedAsyncioTestCase: the latter's
    teardown does not cleanly cancel the agent's background task, hanging the
    runner. The wait_for gives the run a hard ceiling.
    """

    def test_stream_contract(self):
        import asyncio
        import contextlib
        import utils.retrieval.graph as g
        from models.chat import Message
        from datetime import datetime, timezone

        callback_data = {}
        chunks = []

        async def drive():
            with contextlib.ExitStack() as stack:
                _install_retrieval_stubs(stack)
                stack.enter_context(mock.patch("utils.retrieval.graph.create_llm", return_value=ScriptedToolModel()))
                stack.enter_context(mock.patch("utils.retrieval.graph.dev_db.get_user_time_zone", return_value="UTC"))
                stack.enter_context(mock.patch("utils.retrieval.agent_prompt.get_prompt_memories", return_value=("Alex", "facts\n- likes chips")))
                stack.enter_context(mock.patch("utils.retrieval.agent_prompt._get_language_instruction", return_value=""))

                msgs = [Message(id="m1", text="What did I discuss about ASML?", created_at=datetime.now(timezone.utc), sender="human", type="text")]
                async for chunk in g.execute_graph_chat_stream("u", msgs, developer_id="d", cited=True, callback_data=callback_data):
                    chunks.append(chunk)

        asyncio.run(asyncio.wait_for(drive(), timeout=60))

        # Stream must terminate with the sentinel None.
        self.assertIsNone(chunks[-1])
        emitted = [c for c in chunks if c is not None]
        data_chunks = [c for c in emitted if c.startswith("data:")]
        think_chunks = [c for c in emitted if c.startswith("think:")]

        # Answer text came through as data:, progress as think:.
        self.assertTrue(data_chunks)
        self.assertTrue(think_chunks, "expected a think: progress event from memory_search")
        joined = "".join(c[len("data:"):] for c in data_chunks)
        self.assertIn("[1]", joined)
        # The empty tool-selection turn must not have leaked as data:.
        self.assertNotIn("memory_search", joined)

        # callback_data contract for process_message.
        self.assertIn("[1]", callback_data["answer"])
        self.assertEqual(callback_data["memories_found"][0]["id"], "asml-1")
        self.assertTrue(callback_data["ask_for_nps"])


class NestedLeakModel(BaseChatModel):
    """A fake model that emits raw JSON — stands in for the structured-output call
    that resolve_time_range makes internally via retrieve_context_dates_by_question."""

    @property
    def _llm_type(self) -> str:
        return "nested-leak-model"

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        return ChatResult(generations=[ChatGeneration(message=AIMessage(content='{"dates_range": ["2026-07-23", "2026-08-06"]}'))])

    def _stream(self, messages, stop=None, run_manager=None, **kwargs):
        yield ChatGenerationChunk(message=AIMessageChunk(content='{"dates_range": ["2026-07-23", "2026-08-06"]}'))


class TimeRangeScriptedModel(ScriptedToolModel):
    """Agent model that calls resolve_time_range first, then memory_search, then answers.

    Reproduces the production shape of the leak: the user asked "recently", the agent
    resolves the range (a tool that makes its own LLM call), then searches, then answers.
    """

    def _pick(self, messages):
        called = {m.name for m in messages if getattr(m, "type", None) == "tool"}
        if "resolve_time_range" not in called:
            return AIMessage(content="", tool_calls=[{"name": "resolve_time_range", "args": {"expr": "recently"}, "id": "c0"}])
        if "memory_search" not in called:
            return AIMessage(content="", tool_calls=[{"name": "memory_search", "args": {"query": "ASML"}, "id": "c1"}])
        return AIMessage(content=self.answer_text)

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        return ChatResult(generations=[ChatGeneration(message=self._pick(messages))])

    def _stream(self, messages, stop=None, run_manager=None, **kwargs):
        import json
        msg = self._pick(messages)
        if msg.tool_calls:
            tc = msg.tool_calls[0]
            yield ChatGenerationChunk(message=AIMessageChunk(content="", tool_call_chunks=[{"name": tc["name"], "args": json.dumps(tc["args"]), "id": tc["id"], "index": 0}]))
        else:
            for token in msg.content.split(" "):
                yield ChatGenerationChunk(message=AIMessageChunk(content=token + " "))


class FStreamDoesNotLeakToolInternalLLM(unittest.TestCase):
    """Regression: a tool's own LLM call must not leak its tokens into the answer.

    resolve_time_range internally runs a structured-output model to parse dates. That
    nested call streams under langgraph_node="tools"; before the node filter, its raw
    {"dates_range": [...]} JSON was forwarded to the user as answer text (observed live
    in production on 2026-08-06). Only the "model" node is user-facing.
    """

    def test_no_tool_internal_json_in_data_stream(self):
        import asyncio
        import contextlib
        import utils.retrieval.graph as g
        from models.chat import Message
        from datetime import datetime, timezone

        callback_data = {}
        chunks = []
        nested = NestedLeakModel()

        def fake_resolve(expr, tz):
            # Mirror the real function: it invokes an LLM inside the tool call.
            nested.invoke("parse dates")
            return [datetime(2026, 7, 23, tzinfo=timezone.utc), datetime(2026, 8, 6, tzinfo=timezone.utc)]

        async def drive():
            with contextlib.ExitStack() as stack:
                _install_retrieval_stubs(stack)
                stack.enter_context(mock.patch("utils.retrieval.graph.create_llm", return_value=TimeRangeScriptedModel()))
                stack.enter_context(mock.patch("utils.retrieval.graph.dev_db.get_user_time_zone", return_value="UTC"))
                stack.enter_context(mock.patch("utils.retrieval.agent_tools.retrieve_context_dates_by_question", side_effect=fake_resolve))
                stack.enter_context(mock.patch("utils.retrieval.agent_prompt.get_prompt_memories", return_value=("Alex", "facts")))
                stack.enter_context(mock.patch("utils.retrieval.agent_prompt._get_language_instruction", return_value=""))

                msgs = [Message(id="m1", text="What did I discuss about AI recently?", created_at=datetime.now(timezone.utc), sender="human", type="text")]
                async for chunk in g.execute_graph_chat_stream("u", msgs, developer_id="d", cited=True, callback_data=callback_data):
                    chunks.append(chunk)

        asyncio.run(asyncio.wait_for(drive(), timeout=60))

        data_chunks = [c for c in chunks if c is not None and c.startswith("data:")]
        joined = "".join(c[len("data:"):] for c in data_chunks)
        # The nested tool LLM's raw JSON must never reach the user.
        self.assertNotIn("dates_range", joined)
        self.assertNotIn("dates_range", callback_data.get("answer", ""))
        # The real answer still comes through.
        self.assertIn("[1]", joined)


class GSystemPromptIsCacheableAndTimeless(unittest.TestCase):
    """§6.1: the system prompt is a cache_control SystemMessage with no clock in it.

    The stable prefix + session-stable facts must be a single cacheable block, and
    the current time must NOT appear in it — a datetime in a cached prefix changes
    every request and drives cache_read_input_tokens to a permanent zero (§143).
    """

    def _build(self, cited=True):
        import contextlib
        from utils.retrieval.agent_prompt import build_system_prompt

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch("utils.retrieval.agent_prompt.get_prompt_memories", return_value=("Alex", "you already know...\n- likes chips")))
            stack.enter_context(mock.patch("utils.retrieval.agent_prompt._get_language_instruction", return_value=""))
            return build_system_prompt("u", tz="Asia/Shanghai", cited=cited)

    def test_returns_cache_control_system_message(self):
        from langchain_core.messages import SystemMessage

        msg = self._build()
        self.assertIsInstance(msg, SystemMessage)
        # One content block, marked for caching.
        self.assertIsInstance(msg.content, list)
        self.assertEqual(len(msg.content), 1)
        block = msg.content[0]
        self.assertEqual(block["type"], "text")
        self.assertEqual(block.get("cache_control"), {"type": "ephemeral"})

    def test_no_clock_and_no_timezone_leak_in_prefix(self):
        from datetime import datetime, timezone

        text = self._build().content[0]["text"]
        # Persona + facts are here...
        self.assertIn("Memorion", text)
        self.assertIn("likes chips", text)
        self.assertIn("[index]", text)  # cited block present
        # ...but nothing that changes per request.
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        self.assertNotIn(today, text)
        self.assertNotIn("Current time", text)
        self.assertNotIn("This week", text)
        # tz string must not have been baked into the cached prefix either.
        self.assertNotIn("Asia/Shanghai", text)

    def test_cited_block_tells_the_model_to_search_before_answering_from_facts(self):
        """The facts block must not be presented as an alternative to searching.

        Measured on production 2026-08-10: 4 of 36 real questions since July got an
        answer describing a specific recorded conversation with no citation, because
        the model answered from the injected `{{user_facts}}` prefix instead of
        calling memory_search. Facts carry no index, so there was nothing to cite —
        the citation rules were being followed, and the answer still arrived with no
        card. Asserting the instruction here rather than only in the eval harness
        because a prompt edit that drops it would show up as a slow metric drift
        weeks later, not as a failure.
        """
        text = self._build(cited=True).content[0]["text"]
        self.assertIn("not a substitute for searching", text)
        self.assertIn("memory_search first", text)
        # The facts block itself must still be there — the instruction narrows how
        # the model uses it, it does not remove it.
        self.assertIn("likes chips", text)

    def test_search_first_instruction_is_scoped_to_cited_turns(self):
        """It rides in `cited_block`, so an uncited turn must not carry it.

        An uncited turn collects no indexes, so pushing it to search for the sake of
        a citation would buy latency and nothing else.
        """
        text = self._build(cited=False).content[0]["text"]
        self.assertNotIn("not a substitute for searching", text)
        self.assertNotIn("[index]", text)


class HTimeContextRidesTheMessageTail(unittest.TestCase):
    """§6.2: the per-turn clock is prepended to the latest human turn, after the
    system cache breakpoint — so the model sees "now" without invalidating cache."""

    def test_time_block_on_latest_human_turn(self):
        import utils.retrieval.graph as g
        from models.chat import Message
        from datetime import datetime, timezone

        msgs = [
            Message(id="m1", text="hi", created_at=datetime.now(timezone.utc), sender="human", type="text"),
            Message(id="m2", text="what did I say?", created_at=datetime.now(timezone.utc), sender="human", type="text"),
        ]
        lc = g._to_lc_messages(msgs, tz="Asia/Shanghai")
        self.assertEqual(len(lc), 2)
        # Earlier turn keeps its text; only the latest carries the time header.
        # Its content is a block list, not a bare string — with two human turns
        # the second-to-last is also the history cache anchor (§6.2), so it gets
        # wrapped with cache_control. Asserting a bare string here breaks the
        # moment the second breakpoint lands, which is exactly what happened.
        self.assertEqual(lc[0].content, [{
            "type": "text",
            "text": "hi",
            "cache_control": {"type": "ephemeral"},
        }])
        self.assertIn("Current time:", lc[1].content)
        self.assertIn("This week:", lc[1].content)
        self.assertIn("Asia/Shanghai", lc[1].content)
        self.assertTrue(lc[1].content.rstrip().endswith("what did I say?"))

    def test_no_time_block_when_no_human_turn(self):
        import utils.retrieval.graph as g
        from models.chat import Message
        from datetime import datetime, timezone

        msgs = [Message(id="a1", text="prior answer", created_at=datetime.now(timezone.utc), sender="ai", type="text")]
        lc = g._to_lc_messages(msgs, tz="UTC")
        self.assertEqual(lc[0].content, "prior answer")


class _FakeDoc:
    """Stand-in for a Firestore DocumentSnapshot from the projected todo query."""

    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    def to_dict(self):
        return self._data


def _todo_conversations():
    """Two conversations' worth of action items covering every filter branch."""
    return [
        _FakeDoc("conv-new", {
            "status": "completed", "discarded": False,
            "created_at": datetime(2026, 8, 5, tzinfo=timezone.utc),
            "structured": {"title": "Standup", "action_items": [
                {"description": "ship the deploy", "completed": False, "confirmed": True,
                 "due_date": datetime(2026, 8, 10, tzinfo=timezone.utc), "due_hint": ""},
                {"description": "pending suggestion", "completed": False, "confirmed": False},
                {"description": "already done", "completed": True, "confirmed": True},
            ]},
        }),
        _FakeDoc("conv-old", {
            "status": "completed", "discarded": False,
            "created_at": datetime(2026, 7, 1, tzinfo=timezone.utc),
            "structured": {"title": "Trip planning", "action_items": [
                # legacy row: no `confirmed` key at all -> must be treated as confirmed
                {"description": "book the hotel", "completed": False, "due_hint": "this week"},
            ]},
        }),
        _FakeDoc("conv-discarded", {
            "status": "completed", "discarded": True,
            "created_at": datetime(2026, 8, 6, tzinfo=timezone.utc),
            "structured": {"title": "Noise", "action_items": [
                {"description": "should never appear", "completed": False, "confirmed": True},
            ]},
        }),
    ]


def _install_todo_stubs(stack):
    """Patch the projected Firestore query chain used by _scan_action_items."""
    docs = _todo_conversations()

    class FakeQuery:
        def where(self, *a, **k): return self
        def select(self, *a, **k): return self
        def limit(self, *a, **k): return self
        def order_by(self, *a, **k): return self
        def stream(self): return iter(docs)

    class FakeUserRef:
        def collection(self, name): return FakeQuery()

    stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db._get_user_ref", return_value=FakeUserRef()))


def _todo_tools(stack, ctx=None):
    from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

    ctx = ctx or RequestContext(uid="u", developer_id="d")
    return {t.name: t for t in make_agent_tools(ctx, CitationAccumulator())}


class ITodoListHonorsConfirmGate(unittest.TestCase):
    """§PR4: unconfirmed action items are pending the user's tap and must stay hidden.

    The `confirmed` flag gates a real product flow — an LLM-extracted item only
    enters the to-do list after the user accepts it. Surfacing one as if it were
    already on the list would make the agent lie about the user's own data. A
    missing key means legacy data (pre-feature) and counts as confirmed.
    """

    def test_open_items_exclude_unconfirmed_and_completed(self):
        import contextlib
        from datetime import datetime, timezone

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_list"].invoke({"status": "open"})

        texts = [i["text"] for i in out["items"]]
        self.assertIn("ship the deploy", texts)
        self.assertIn("book the hotel", texts)          # legacy, no confirmed key
        self.assertNotIn("pending suggestion", texts)   # confirmed=False
        self.assertNotIn("already done", texts)         # completed
        self.assertNotIn("should never appear", texts)  # discarded conversation

    def test_completed_status_and_provenance(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_list"].invoke({"status": "completed"})

        self.assertEqual([i["text"] for i in out["items"]], ["already done"])
        item = out["items"][0]
        # Provenance lets the agent say where a to-do came from.
        self.assertEqual(item["source_conversation_id"], "conv-new")
        self.assertEqual(item["source_conversation_title"], "Standup")
        # Composite handle, since action items have no id of their own.
        self.assertEqual(item["id"], "conv-new:2")

    def test_newest_conversation_first(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_list"].invoke({"status": "all"})

        # conv-new (2026-08-05) sorts before conv-old (2026-07-01).
        self.assertEqual(out["items"][0]["source_conversation_id"], "conv-new")
        self.assertEqual(out["items"][-1]["source_conversation_id"], "conv-old")

    def test_due_before_drops_items_without_a_real_deadline(self):
        """A vague 'this week' lives in due_hint with no due_date; a cutoff must
        not silently promote it to a made-up deadline."""
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_list"].invoke(
                {"status": "open", "due_before": "2026-08-15T00:00:00+00:00"}
            )

        texts = [i["text"] for i in out["items"]]
        self.assertEqual(texts, ["ship the deploy"])   # has due_date 2026-08-10
        self.assertNotIn("book the hotel", texts)      # due_hint only, no due_date


class JTodoWriteRoundTripsTheHandle(unittest.TestCase):
    """The id todo_list emits must resolve back to the right (conversation, index)."""

    def test_complete_maps_handle_to_conversation_and_index(self):
        import contextlib

        seen = {}

        def fake_update(developer_id, uid, conversation_id, item_idx, **kwargs):
            seen.update(dict(conversation_id=conversation_id, item_idx=item_idx, kwargs=kwargs))
            return {"description": "ship the deploy", "completed": True}

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.update_action_item", side_effect=fake_update))
            out = _todo_tools(stack)["todo_write"].invoke({"action": "complete", "id": "conv-new:0"})

        self.assertTrue(out["ok"])
        self.assertEqual(seen["conversation_id"], "conv-new")
        self.assertEqual(seen["item_idx"], 0)
        self.assertEqual(seen["kwargs"], {"completed": True})
        self.assertEqual(out["status"], "completed")

    def test_uuid_ids_with_colon_safe_rsplit(self):
        """rsplit, not split: only the trailing segment is the index."""
        from utils.retrieval.agent_tools import _parse_todo_handle

        self.assertEqual(_parse_todo_handle("a:b:c:7"), ("a:b:c", 7))
        self.assertEqual(_parse_todo_handle("f795a383-5ece-4981:3"), ("f795a383-5ece-4981", 3))
        self.assertIsNone(_parse_todo_handle("no-index-here"))
        self.assertIsNone(_parse_todo_handle("conv:notanint"))
        self.assertIsNone(_parse_todo_handle(""))

    def test_bad_handle_is_rejected_not_guessed(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_write"].invoke({"action": "complete", "id": "garbage"})
        self.assertFalse(out["ok"])

    def test_create_requires_text(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_write"].invoke({"action": "create"})
        self.assertFalse(out["ok"])

    def test_unknown_action_rejected(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            _install_todo_stubs(stack)
            out = _todo_tools(stack)["todo_write"].invoke({"action": "archive", "id": "conv-new:0"})
        self.assertFalse(out["ok"])


class KPeopleLookupMatchesByName(unittest.TestCase):
    """No name index exists in Firestore, so matching happens in Python."""

    def test_case_insensitive_substring(self):
        import contextlib

        people = [
            {"id": "p1", "name": "Maya", "created_at": datetime(2026, 1, 1, tzinfo=timezone.utc)},
            {"id": "p2", "name": "Mayank", "created_at": datetime(2026, 2, 1, tzinfo=timezone.utc)},
            {"id": "p3", "name": "Tom", "created_at": datetime(2026, 3, 1, tzinfo=timezone.utc)},
        ]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_people", return_value=people))
            out = _todo_tools(stack)["people_lookup"].invoke({"name": "may"})

        names = [p["display_name"] for p in out["people"]]
        self.assertEqual(names, ["Maya", "Mayank"])
        # Semantic field name, not a raw UUID key.
        self.assertIn("person_id", out["people"][0])

    def test_no_name_lists_everyone(self):
        import contextlib

        people = [{"id": "p1", "name": "Maya", "created_at": None}]
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_people", return_value=people))
            out = _todo_tools(stack)["people_lookup"].invoke({})
        self.assertEqual(len(out["people"]), 1)


class LUserProfileSectionsAreSelective(unittest.TestCase):
    """`sections` exists so a turn doesn't pay for the whole profile."""

    def test_only_requested_section_is_fetched(self):
        import contextlib

        called = []

        def fake_memories(developer_id, uid, limit=None, status=None):
            called.append("facts")
            return [{"content": "likes chips", "category": "interesting"}]

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_memories", side_effect=fake_memories))
            prefs = stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_user_preferences", return_value={"language": "en"}))
            out = _todo_tools(stack)["get_user_profile"].invoke({"sections": "facts"})

        self.assertEqual(called, ["facts"])
        self.assertEqual(out["facts"][0]["content"], "likes chips")
        self.assertNotIn("preferences", out)
        prefs.assert_not_called()

    def test_one_failing_section_does_not_sink_the_others(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_memories", side_effect=RuntimeError("boom")))
            stack.enter_context(mock.patch("utils.retrieval.agent_tools.dev_db.get_user_preferences", return_value={"language": "zh"}))
            out = _todo_tools(stack)["get_user_profile"].invoke({"sections": "facts,preferences"})

        self.assertNotIn("facts", out)
        self.assertEqual(out["preferences"], {"language": "zh"})


class MWebSearchWrapsTavily(unittest.TestCase):
    """web_search is a thin wrapper over the Tavily REST call.

    The tool must (a) normalize Tavily's result shape to {title,url,snippet,score}
    the model can cite, (b) never raise into the agent loop on a bad key / network
    error — a failed search degrades to empty results, not a crashed turn, and
    (c) forward the recency window and cap the result count.
    """

    def _fake_response(self, payload, status=200):
        class FakeResp:
            status_code = status

            def raise_for_status(self):
                if status != 200:
                    import requests as _rq
                    raise _rq.HTTPError(f"status {status}")

            def json(self):
                return payload

        return FakeResp()

    def test_normalizes_results_and_forwards_recency(self):
        import contextlib

        captured = {}

        def fake_post(url, json=None, headers=None, timeout=None):
            captured["url"] = url
            captured["json"] = json
            captured["auth"] = (headers or {}).get("Authorization")
            return self._fake_response(
                {
                    "results": [
                        {"title": "OpenAI news", "url": "https://x.com/a",
                         "content": "Latest release details.", "score": 0.9},
                        {"title": "No content", "url": "https://x.com/b", "score": 0.1},
                    ]
                }
            )

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, {"TAVILY_API_KEY": "tvly-test"}))
            stack.enter_context(mock.patch("utils.retrieval.agent_websearch.requests.post", side_effect=fake_post))
            out = _todo_tools(stack)["web_search"].invoke({"query": "openai news", "recency": "week"})

        self.assertEqual(captured["url"], "https://api.tavily.com/search")
        self.assertEqual(captured["auth"], "Bearer tvly-test")
        self.assertEqual(captured["json"]["time_range"], "week")
        results = out["results"]
        self.assertEqual(results[0]["title"], "OpenAI news")
        self.assertEqual(results[0]["url"], "https://x.com/a")
        self.assertEqual(results[0]["snippet"], "Latest release details.")
        # A result without content still normalizes cleanly to an empty snippet.
        self.assertEqual(results[1]["snippet"], "")

    def test_caps_result_count_and_ignores_bad_recency(self):
        import contextlib

        captured = {}

        def fake_post(url, json=None, headers=None, timeout=None):
            captured["json"] = json
            return self._fake_response({"results": []})

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, {"TAVILY_API_KEY": "tvly-test"}))
            stack.enter_context(mock.patch("utils.retrieval.agent_websearch.requests.post", side_effect=fake_post))
            _todo_tools(stack)["web_search"].invoke({"query": "q", "recency": "fortnight", "limit": 99})

        self.assertEqual(captured["json"]["max_results"], 10)   # capped to MAX_WEB_RESULTS
        self.assertNotIn("time_range", captured["json"])        # unknown window dropped

    def test_missing_key_degrades_to_empty(self):
        import contextlib

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, {}, clear=False))
            stack.enter_context(mock.patch.dict(os.environ, {"TAVILY_API_KEY": ""}))
            # requests.post must never be reached without a key.
            post = stack.enter_context(mock.patch("utils.retrieval.agent_websearch.requests.post"))
            out = _todo_tools(stack)["web_search"].invoke({"query": "q"})

        self.assertEqual(out["results"], [])
        post.assert_not_called()

    def test_network_error_degrades_to_empty(self):
        import contextlib
        import requests as _rq

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, {"TAVILY_API_KEY": "tvly-test"}))
            stack.enter_context(mock.patch(
                "utils.retrieval.agent_websearch.requests.post",
                side_effect=_rq.ConnectionError("down"),
            ))
            out = _todo_tools(stack)["web_search"].invoke({"query": "q"})

        self.assertEqual(out["results"], [])


if __name__ == "__main__":
    unittest.main()
