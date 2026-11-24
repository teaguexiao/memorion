"""Chapter Ask: route -> persisted scope -> agent -> citations, without services."""

import asyncio
import copy
import json
from unittest.mock import patch

import pytest
from fastapi import HTTPException
from langchain_core.messages import AIMessage
from langchain_core.outputs import ChatGeneration, ChatResult

from test_chat_agent_loop import ScriptedToolModel


RECORDS = [
    {"id": "source-a", "created_at": "2026-10-17T01:00:00+00:00",
     "structured": {"title": "预算", "overview": "讨论报价", "emoji": "💬"},
     "transcript_segments": [{"speaker": "SPEAKER_00", "text": "预算370元，没有同意涨价，暗号ZX-904。"}]},
    {"id": "source-b", "created_at": "2026-10-17T02:00:00+00:00",
     "structured": {"title": "交付", "overview": "确认交付", "emoji": "💬"},
     "transcript_segments": [{"speaker": "SPEAKER_00", "text": "陈晓明周五发送报价，尾部标记TAIL-739。"}]},
]
for record in RECORDS:
    record.update(started_at=record['created_at'], finished_at=record['created_at'])
    for segment in record['transcript_segments']:
        segment.update(is_user=False, start=0, end=10)


def test_binding_validates_every_owner_scoped_source_and_persists():
    from routers import developer_chat as route
    from utils.retrieval import conversation_context as context
    with patch.object(context.dev_db, "get_conversation", side_effect=RECORDS) as fetch, \
         patch.object(route.dev_db, "create_v2_new_chat_session", return_value={"id": "s"}) as create:
        route.create_v2_chat_session(route.V2ChatSessionCreate(
            title="章节", context_conversation_ids=["source-a", "source-b", "source-a"]),
            title=None, context=("owner", "user"))
        assert [c.args for c in fetch.call_args_list] == [
            ("owner", "user", "source-a"), ("owner", "user", "source-b")]
        assert create.call_args.kwargs["context_conversation_ids"] == ["source-a", "source-b"]
    with patch.object(context.dev_db, "get_conversation", return_value=None), \
         patch.object(route.dev_db, "create_v2_new_chat_session") as create:
        with pytest.raises(HTTPException) as error:
            route.create_v2_chat_session(route.V2ChatSessionCreate(context_conversation_ids=["other-owner"]),
                                         title=None, context=("owner", "user"))
        assert error.value.status_code == 404
        create.assert_not_called()


def test_shared_message_query_chunks_filters_and_orders_within_user():
    from database import developer_data as db
    from types import SimpleNamespace
    from datetime import datetime, timezone
    calls = []
    records = [dict(id=str(i), chat_session_id=f's{i}', plugin_id=None,
                    created_at=datetime(2026, 1, 1, 0, i, tzinfo=timezone.utc)) for i in range(31)]
    records += [dict(records[-1], id='plugin', plugin_id='other'),
                dict(records[-1], id='reported', reported=True),
                dict(records[-1], id='unrelated', chat_session_id='outside')]

    class Query:
        def where(self, *, filter):
            calls.append((filter.field_path, filter.op_string, filter.value))
            self.ids = filter.value
            return self

        def stream(self):
            return [SimpleNamespace(to_dict=lambda r=r: r) for r in records
                    if r['chat_session_id'] in self.ids]

    user = SimpleNamespace(collection=lambda name: Query())
    with patch.object(db, '_get_user_ref', return_value=user) as owner:
        result = db.get_v2_messages('owner', 'user', chat_session_ids=[f's{i}' for i in range(31)] + ['s0'],
                                    limit=2, offset=1)
    owner.assert_called_once_with('owner', 'user')
    in_filters = [c for c in calls if c[1] == 'in']
    assert [len(c[2]) for c in in_filters] == [30, 1]
    assert all(c[0] == 'chat_session_id' for c in in_filters)
    assert [m['id'] for m in result] == ['29', '28']


def test_deleted_or_oversized_context_fails_before_message_write():
    from routers import developer_chat as route
    from models.chat import SendMessageRequest
    from utils.retrieval.conversation_context import load_conversation_context
    session = {"id": "s", "created_at": "2026-10-17T01:00:00Z", "context_conversation_ids": ["source-a"]}
    with patch.object(route.dev_db, "get_v2_chat_session_by_id", return_value=session), \
         patch.object(route.dev_db, "get_conversation", return_value=None), \
         patch.object(route.dev_db, "add_v2_message") as write:
        with pytest.raises(HTTPException) as error:
            route.send_message_v2(SendMessageRequest(text="暗号？"), "s", ("owner", "user"))
        assert error.value.status_code == 404
        write.assert_not_called()
    huge = {**RECORDS[0], "transcript_segments": [{"text": "字" * 600_001}]}
    with patch.object(route.dev_db, "get_conversation", return_value=huge):
        with pytest.raises(HTTPException) as error:
            load_conversation_context("owner", "user", ["source-a"])
        assert error.value.status_code == 413


def metadata_heavy_records():
    records = copy.deepcopy(RECORDS)
    records[0]["transcript_segments"] = [
        {"id": f"storage-segment-{i:036d}", "text": f"片段{i}：预算370元，没有同意涨价，暗号ZX-904。",
         "speaker": "SPEAKER_00", "speaker_id": 0, "is_user": False, "person_id": None,
         "speaker_status": "ambiguous", "speaker_assignment_source": None,
         "start": i * 2, "end": i * 2 + 1, "original_start": i * 2,
         "original_end": i * 2 + 1, "timestamp_axis": "audio", "translations": [],
         "speech_profile_processed": False}
        for i in range(1595)
    ]
    return records


def test_context_capacity_counts_evidence_without_storage_metadata():
    from utils.retrieval.conversation_context import load_conversation_context, serialize_context_records
    records = metadata_heavy_records()
    original = copy.deepcopy(records)
    # Reproduce the production failure: short utterances with verbose metadata
    # cross the old JSON guard even though the complete evidence fits easily.
    assert len(json.dumps(records, ensure_ascii=False)) > 600_000
    with patch("utils.retrieval.conversation_context.dev_db.get_conversation",
               side_effect=lambda _d, _u, cid, **kw: next(c for c in records if c["id"] == cid)):
        loaded = load_conversation_context("d", "u", [c["id"] for c in records])
    serialized = serialize_context_records(loaded)
    assert len(serialized) < 600_000
    projected = json.loads(serialized)
    assert [s["text"] for s in projected[0]["transcript_segments"]] == [
        s["text"] for s in records[0]["transcript_segments"]]
    assert "TAIL-739" in projected[-1]["transcript_segments"][-1]["text"]
    segment = projected[0]["transcript_segments"][0]
    assert segment == {k: v for k, v in records[0]["transcript_segments"][0].items()
                       if k not in {"id", "speech_profile_processed", "person_id",
                                    "speaker_assignment_source", "translations"}}
    assert loaded == original  # Full source records still back citation storage.
    assert records == original


def test_scoped_tools_cannot_fetch_or_search_unrelated_recordings():
    from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools
    citations = CitationAccumulator()
    tools = {t.name: t for t in make_agent_tools(
        RequestContext(uid="u", developer_id="d", scoped_conversations=RECORDS), citations)}
    assert set(tools) == {"memory_search", "memory_get", "report_no_record"}
    with patch("utils.retrieval.agent_tools.generate_embedding_query") as embedding, \
         patch("utils.retrieval.agent_tools.dev_db.get_conversations_by_ids") as fetch:
        assert [r["id"] for r in tools["memory_search"].invoke({"query": "报价"})["results"]] == ["source-a", "source-b"]
        assert tools["memory_get"].invoke({"id": "unrelated", "format": "detailed"}) == {}
        assert "TAIL-739" in tools["memory_get"].invoke({"id": "source-b", "format": "detailed"})["segments"][0]["text"]
        embedding.assert_not_called()
        fetch.assert_not_called()
    many = [{**RECORDS[0], 'id': f'source-{i}'} for i in range(15)]
    many_tools = {t.name: t for t in make_agent_tools(
        RequestContext(uid='u', developer_id='d', scoped_conversations=many), CitationAccumulator())}
    assert len(many_tools['memory_search'].invoke({'query': '', 'limit': 1, 'speaker': 'user'})['results']) == 15


def test_default_ask_selects_normal_session_and_linked_empty_history_has_no_global_greeting():
    from database import developer_data as db
    from routers import developer_chat as route
    from types import SimpleNamespace
    from datetime import datetime, timezone
    normal = {"id": "normal", "created_at": datetime(2026, 10, 16, tzinfo=timezone.utc)}
    linked = {"id": "linked", "created_at": datetime(2026, 10, 17, tzinfo=timezone.utc),
              "context_conversation_ids": ["source-a"]}
    collection = SimpleNamespace(stream=lambda: [SimpleNamespace(to_dict=lambda: normal),
                                                 SimpleNamespace(to_dict=lambda: linked)])
    with patch.object(db, "_get_user_ref", return_value=SimpleNamespace(collection=lambda _: collection)):
        assert db.get_v2_chat_session("d", "u")["id"] == "normal"
    with patch.object(db, "get_v2_chat_session_by_id", return_value=linked), \
         patch.object(db, "get_v2_messages", return_value=[]), \
         patch.object(route, "initial_message_util") as greeting:
        assert route.get_messages_v2("linked", ("d", "u")) == []
        greeting.assert_not_called()
    # Only linked sessions exist: normal GET/DELETE must create/select a normal
    # session instead of falling back to an unfiltered message query.
    with patch.object(db, 'get_v2_chat_session', return_value=None), \
         patch.object(db, 'create_v2_new_chat_session', return_value=normal), \
         patch.object(db, 'get_v2_chat_sessions', return_value=[linked]), \
         patch.object(db, 'get_v2_messages', return_value=[{'id': 'ordinary'}]) as read:
        route.get_messages_v2(None, ('d', 'u'))
        assert read.call_args.kwargs['chat_session_ids'] == ['normal', 'linked']
    with patch.object(db, 'get_v2_chat_session', return_value=None), \
         patch.object(db, 'create_v2_new_chat_session', return_value=normal), \
         patch.object(db, 'get_v2_chat_sessions', return_value=[linked]), \
         patch.object(db, 'clear_v2_chat') as clear, \
         patch.object(db, 'delete_v2_chat_session') as delete, patch.object(route, 'initial_message_util'):
        route.clear_chat_messages_v2(None, ('d', 'u'))
        assert [call.kwargs['chat_session_id'] for call in clear.call_args_list] == ['linked', 'normal']
        delete.assert_called_once_with('d', 'u', 'linked')


def test_leaving_stream_cancels_model_task():
    from utils.retrieval import graph
    stopped = asyncio.Event()
    class SlowAgent:
        async def astream(self, *args, **kwargs):
            from langchain_core.messages import AIMessageChunk
            try:
                yield 'messages', (AIMessageChunk(content='start'), {'langgraph_node': 'model'})
                await asyncio.sleep(60)
            finally:
                stopped.set()
    async def exercise():
        with patch.object(graph, '_build_agent', return_value=SlowAgent()):
            stream = graph.execute_graph_chat_stream('u', [])
            assert (await anext(stream)).startswith('data: ')
            await stream.aclose()
            assert stopped.is_set()
    asyncio.run(exercise())


class ContextModel(ScriptedToolModel):
    expected_records: list = RECORDS

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        prompt = messages[0].content[0]["text"]
        assert messages[0].content[0]['cache_control'] == {'type': 'ephemeral'}
        assert all(marker in prompt for marker in ("370", "没有同意", "ZX-904", "TAIL-739", "source-a", "source-b"))
        assert "local to one recording" in prompt
        records = json.loads(prompt.split("<linked_records>\n", 1)[1].rsplit("\n</linked_records>", 1)[0])
        for index, (actual, expected) in enumerate(zip(records, self.expected_records), 1):
            assert actual["id"] == expected["id"] and actual["index"] == index
            assert [s["text"] for s in actual["transcript_segments"]] == [
                s["text"] for s in expected["transcript_segments"]]
        assert len(records) == len(self.expected_records)
        return ChatResult(generations=[ChatGeneration(message=AIMessage(content="370元，未同意涨价[1]；陈晓明周五发报价[2]。"))])

    def _stream(self, messages, stop=None, run_manager=None, **kwargs):
        from langchain_core.messages import AIMessageChunk
        from langchain_core.outputs import ChatGenerationChunk
        answer = self._generate(messages).generations[0].message.content
        yield ChatGenerationChunk(message=AIMessageChunk(content=answer))


@pytest.mark.parametrize("records", [RECORDS, metadata_heavy_records()], ids=["short", "metadata-heavy"])
def test_route_stream_and_followup_preserve_scope_and_citations(records):
    from routers import developer_chat as route
    from models.chat import SendMessageRequest
    session = {"id": "s", "created_at": "2026-10-17T01:00:00Z", "title": "章节",
               "context_conversation_ids": ["source-a", "source-b"]}
    history = []
    def add(_d, _u, message):
        history.insert(0, message)
    async def collect(response):
        return "".join([part async for part in response.body_iterator])
    with patch.object(route.dev_db, "get_v2_chat_session_by_id", return_value=session), \
         patch.object(route.dev_db, "get_conversation", side_effect=lambda _d, _u, cid, **kw: next(c for c in records if c["id"] == cid)) as fetch, \
         patch.object(route.dev_db, "add_v2_message", side_effect=add), \
         patch.object(route.dev_db, "add_v2_message_to_chat_session"), \
         patch.object(route.dev_db, "get_v2_messages", side_effect=lambda *a, **kw: history.copy()), \
         patch.object(route.dev_db, "get_user_time_zone", return_value="Asia/Shanghai"), \
         patch("utils.retrieval.graph.create_llm", return_value=ContextModel(expected_records=records)):
        for question in ("预算和交付安排？", "刚才说的暗号是什么？"):
            stream = asyncio.run(collect(route.send_message_v2(SendMessageRequest(text=question), "s", ("d", "u"))))
            assert "done: " in stream
            assert history[0]["memories_id"] == ["source-a", "source-b"]
            assert history[0]["chat_session_id"] == "s"
        assert fetch.call_count == 4  # Both sources freshly validated on both turns.
        assert len(history) == 4


class SharedFollowupModel(ScriptedToolModel):
    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        history = "\n".join(str(message.content) for message in messages[1:])
        assert "预算和交付安排" in history
        assert "370元" in history
        assert "Source recording IDs: source-a, source-b" in history
        assert "继续刚才的章节" in history
        return ChatResult(generations=[ChatGeneration(message=AIMessage(content="继续：预算370元，周五交付报价。"))])

    def _stream(self, messages, stop=None, run_manager=None, **kwargs):
        from langchain_core.messages import AIMessageChunk
        from langchain_core.outputs import ChatGenerationChunk
        yield ChatGenerationChunk(message=AIMessageChunk(content=self._generate(messages).generations[0].message.content))


def test_chapter_turn_and_main_followup_use_same_durable_default_history():
    from routers import developer_chat as route
    from models.chat import SendMessageRequest
    session = {"id": "shared", "created_at": "2026-10-17T01:00:00Z", "title": "Shared"}
    history = []
    def add(_d, _u, message):
        history.insert(0, message)
    async def collect(response):
        return "".join([part async for part in response.body_iterator])
    with patch.object(route.dev_db, "get_v2_chat_session", return_value=session), \
         patch.object(route.dev_db, "get_v2_chat_sessions", return_value=[session]), \
         patch.object(route.dev_db, "get_conversation", side_effect=lambda _d, _u, cid, **kw: next(c for c in RECORDS if c["id"] == cid)), \
         patch.object(route.dev_db, "add_v2_message", side_effect=add), \
         patch.object(route.dev_db, "add_v2_message_to_chat_session"), \
         patch.object(route.dev_db, "get_v2_messages", side_effect=lambda *a, **kw: history.copy()) as read, \
         patch.object(route.dev_db, "get_user_time_zone", return_value="Asia/Shanghai"):
        with patch("utils.retrieval.graph.create_llm", return_value=ContextModel()):
            result = asyncio.run(collect(route.send_message_v2(SendMessageRequest(
                text="预算和交付安排？", context_conversation_ids=["source-a", "source-b"]), None, ("d", "u"))))
        assert "done: " in result
        assert history[0]["memories_id"] == ["source-a", "source-b"]
        with patch("utils.retrieval.graph.create_llm", return_value=SharedFollowupModel()):
            result = asyncio.run(collect(route.send_message_v2(SendMessageRequest(
                text="继续刚才的章节"), None, ("d", "u"))))
        assert "done: " in result
        assert len(history) == 4
        assert all(message["chat_session_id"] == "shared" for message in history)
        assert route.get_messages_v2(None, ("d", "u")) == history
        assert read.call_args.kwargs["chat_session_ids"] == ["shared"]


def test_legacy_chapter_sources_are_available_in_default_history():
    from routers import developer_chat as route
    legacy = {"id": "chapter", "context_conversation_ids": ["source-a"]}
    with patch.object(route.dev_db, "get_v2_chat_sessions", return_value=[legacy, {"id": "independent"}]), \
         patch.object(route.dev_db, "get_v2_messages", return_value=[
             {"id": "question", "sender": "human", "chat_session_id": "chapter", "text": "预算？"}]) as read:
        messages = route.shared_chat_messages("d", "u", "default", limit=100)
        assert messages[0]["context_conversation_ids"] == ["source-a"]
        assert read.call_args.kwargs['chat_session_ids'] == ['default', 'chapter']
