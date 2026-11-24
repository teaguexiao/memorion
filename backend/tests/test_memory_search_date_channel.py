"""`memory_search` 的日期通道：纯日期问题不该走语义排序。

一条对话的日期锚点在它的 metadata 里，不在正文里。所以「8 月 13 号我做了什么」没有
内容词可供向量匹配 —— `query_vectors_by_metadata` 拿 top_k=10000 回来后按语义相似度
排序，再截断到 `limit`，那天有 20 条对话时返回的是**语义噪声排序下的前 5 条**。

两条通道：

1. **显式**：`query` 为空 + 有 start/end → 直接按 `started_at` 取那段时间的对话。
   触发判据刻意是「query 是否为空」这个二值机械事实，**不是**「有没有内容词」——
   后者需要一个关键词长度下限，那是英文形态学假设，中文实词 2~3 字会整片落在下限
   之下。
2. **兜底**：有 query + 有 start/end + 向量返回 0 条 → 回退到日期通道，并在结果里标
   `matched_by="date_range"`。`query_vectors_by_metadata` 对「那段时间真没有对话」和
   「filter 把一切滤掉了」都返回 []，而后者是真实故障（存量向量的 `created_at` 是入库
   时刻）。标记让降级成为工具轨迹里的一个事实，而不是要模型去猜 —— 和
   `report_no_record` 同一个取向。
"""

import os
import sys
import unittest
from contextlib import ExitStack
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

DAY_START = "2026-08-13T00:00:00+00:00"
DAY_END = "2026-08-13T23:59:59+00:00"


def _convo(cid, hour, title, is_user=True):
    return {
        "id": cid,
        "started_at": datetime(2026, 8, 13, hour, tzinfo=timezone.utc),
        "created_at": datetime(2026, 8, 14, 14, tzinfo=timezone.utc),  # 次日才上传
        "structured": {"title": title, "overview": f"overview of {title}"},
        "transcript_segments": [{"text": "hi", "is_user": is_user, "start": 0, "end": 1}],
    }


IN_RANGE = [_convo("c-late", 21, "evening walk"), _convo("c-noon", 12, "lunch with A")]


class FakeEmbedding:
    values = [0.1] * 3072


class _Harness:
    """装好 stub 后返回 memory_search 工具，并记录各依赖是否被调用过。"""

    def __init__(self, stack, vector_ids=None, in_range=None):
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        self.calls = {"embedding": 0, "vector": 0, "range": 0, "by_ids": 0}

        def fake_embedding(_query):
            self.calls["embedding"] += 1
            return FakeEmbedding()

        def fake_vector(*args, **kwargs):
            self.calls["vector"] += 1
            return list(vector_ids or [])

        def fake_range(dev_db, developer_id, uid, start=None, end=None, limit=20, include_segments=False):
            self.calls["range"] += 1
            self.range_args = {
                "start": start, "end": end, "limit": limit, "include_segments": include_segments,
            }
            return list(in_range if in_range is not None else IN_RANGE)

        def fake_by_ids(developer_id, uid, ids):
            self.calls["by_ids"] += 1
            lookup = {c["id"]: c for c in IN_RANGE}
            return [lookup[i] for i in ids if i in lookup]

        stack.enter_context(
            mock.patch("utils.retrieval.agent_tools.generate_embedding_query", side_effect=fake_embedding)
        )
        stack.enter_context(
            mock.patch("utils.retrieval.agent_tools.query_vectors_by_metadata", side_effect=fake_vector)
        )
        stack.enter_context(
            mock.patch("utils.retrieval.agent_tools.get_conversations_in_range", side_effect=fake_range)
        )
        stack.enter_context(
            mock.patch("utils.retrieval.agent_tools.dev_db.get_conversations_by_ids", side_effect=fake_by_ids)
        )
        tools = make_agent_tools(RequestContext(uid="u", developer_id="d"), CitationAccumulator())
        self.tool = {t.name: t for t in tools}["memory_search"]

    def invoke(self, **kwargs):
        return self.tool.invoke(kwargs)


class ExplicitDateChannelTests(unittest.TestCase):
    def test_empty_query_with_range_bypasses_the_vector_entirely(self):
        """核心：不调 embedding、不查 Pinecone —— 这也是「省掉一次 embedding」的判据。"""
        with ExitStack() as stack:
            h = _Harness(stack)
            out = h.invoke(query="", start=DAY_START, end=DAY_END)

        self.assertEqual(h.calls["embedding"], 0)
        self.assertEqual(h.calls["vector"], 0)
        self.assertEqual(h.calls["range"], 1)
        self.assertEqual([r["id"] for r in out["results"]], ["c-late", "c-noon"])

    def test_whitespace_only_query_counts_as_empty(self):
        with ExitStack() as stack:
            h = _Harness(stack)
            h.invoke(query="   ", start=DAY_START, end=DAY_END)
        self.assertEqual(h.calls["range"], 1)
        self.assertEqual(h.calls["vector"], 0)

    def test_results_are_marked_as_date_matched(self):
        """标记必须在，否则模型分不清「那段时间的对话」和「匹配你查询的对话」。"""
        with ExitStack() as stack:
            h = _Harness(stack)
            out = h.invoke(query="", start=DAY_START, end=DAY_END)
        for row in out["results"]:
            self.assertEqual(row["matched_by"], "date_range")

    def test_parsed_bounds_are_forwarded(self):
        with ExitStack() as stack:
            h = _Harness(stack)
            h.invoke(query="", start=DAY_START, end=DAY_END)
        self.assertEqual(h.range_args["start"], datetime(2026, 8, 13, tzinfo=timezone.utc))
        self.assertEqual(h.range_args["end"], datetime(2026, 8, 13, 23, 59, 59, tzinfo=timezone.utc))

    def test_limit_is_capped_and_forwarded(self):
        """limit 走的是和语义检索同一个 cap，不能因为换了通道就绕过上限。"""
        from utils.retrieval.agent_tools import MAX_SEARCH_LIMIT

        with ExitStack() as stack:
            h = _Harness(stack)
            h.invoke(query="", start=DAY_START, end=DAY_END, limit=999)
        self.assertEqual(h.range_args["limit"], MAX_SEARCH_LIMIT)

    def test_empty_query_without_range_returns_empty(self):
        """没有日期就没有通道 —— 不能退化成拉全部历史。"""
        with ExitStack() as stack:
            h = _Harness(stack)
            out = h.invoke(query="")
        self.assertEqual(out["results"], [])
        self.assertEqual(h.calls["range"], 0)
        self.assertEqual(h.calls["vector"], 0)

    def test_open_ended_range_still_triggers(self):
        with ExitStack() as stack:
            h = _Harness(stack)
            h.invoke(query="", start=DAY_START)
        self.assertEqual(h.calls["range"], 1)

    def test_speaker_filter_still_applies_on_the_date_channel(self):
        """speaker="user" 在新通道上也必须生效,否则换条路就漏别人的话。"""
        with ExitStack() as stack:
            h = _Harness(stack, in_range=[_convo("c-other", 9, "someone else", is_user=False)])
            out = h.invoke(query="", start=DAY_START, end=DAY_END, speaker="user")
        self.assertEqual(out["results"], [])


class TopUpTests(unittest.TestCase):
    """向量命中不足 capped 时用日期通道补齐。

    判据刻意是「比要的少」而不是「一条都没有」:零命中是罕见情形,常见的是**部分
    命中**,而它原本没人接 —— 2026-08-19 生产实测「8月16号我做了什么」只命中 2 个
    向量,而那天有 8 条对话,且那 2 条里有 1 条实际录于 8/15(正是 created_at 偏移
    带进来的)。

    过度触发是无害的:那段时间真的只有 2 条时,日期通道也只返回 2 条,结果不变。
    """

    def test_empty_vector_result_with_range_tops_up(self):
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=[])
            out = h.invoke(query="walk", start=DAY_START, end=DAY_END)

        self.assertEqual(h.calls["vector"], 1)
        self.assertEqual(h.calls["range"], 1)
        self.assertEqual([r["id"] for r in out["results"]], ["c-late", "c-noon"])
        for row in out["results"]:
            self.assertEqual(row["matched_by"], "date_range")

    def test_partial_hit_tops_up_and_keeps_semantic_rank_in_front(self):
        """核心用例:1 个向量命中 + 日期补齐,语义那条必须在最前且不带标记。"""
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=["c-noon"])
            out = h.invoke(query="lunch", start=DAY_START, end=DAY_END)

        self.assertEqual(h.calls["range"], 1)
        self.assertEqual([r["id"] for r in out["results"]], ["c-noon", "c-late"])
        # 语义命中不标记，补齐的才标记 —— 模型据此分得清两者。
        self.assertNotIn("matched_by", out["results"][0])
        self.assertEqual(out["results"][1]["matched_by"], "date_range")

    def test_filler_is_deduped_against_vector_hits(self):
        """日期通道会重复返回向量已命中的那条，不去重就会出现两行同一个对话。"""
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=["c-noon", "c-late"], in_range=IN_RANGE)
            out = h.invoke(query="lunch", start=DAY_START, end=DAY_END, limit=5)

        ids = [r["id"] for r in out["results"]]
        self.assertEqual(len(ids), len(set(ids)), f"出现重复: {ids}")
        self.assertEqual(ids, ["c-noon", "c-late"])

    def test_full_hits_do_not_trigger_top_up(self):
        """命中数已经够 capped 时不该多查一次 Firestore。"""
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=["c-noon", "c-late"])
            out = h.invoke(query="lunch", start=DAY_START, end=DAY_END, limit=2)

        self.assertEqual(h.calls["range"], 0)
        self.assertEqual([r["id"] for r in out["results"]], ["c-noon", "c-late"])
        self.assertNotIn("matched_by", out["results"][0])

    def test_no_range_never_tops_up(self):
        """没有日期边界时保持原行为:少就是少,不去拉全部历史充数。"""
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=["c-noon"])
            out = h.invoke(query="lunch")
        self.assertEqual(h.calls["range"], 0)
        self.assertEqual([r["id"] for r in out["results"]], ["c-noon"])

    def test_empty_vector_result_without_range_returns_empty(self):
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=[])
            out = h.invoke(query="walk")
        self.assertEqual(out["results"], [])
        self.assertEqual(h.calls["range"], 0)

    def test_ranked_order_preserved_when_vector_hits(self):
        """§13.10:检索相关性顺序必须原样透传,不许重排。"""
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=["c-noon", "c-late"])
            out = h.invoke(query="anything")
        self.assertEqual([r["id"] for r in out["results"]], ["c-noon", "c-late"])

    def test_results_never_exceed_the_cap(self):
        """补齐不能把返回条数顶过 limit。"""
        extra = [_convo(f"x{i}", i, f"t{i}") for i in range(1, 9)]
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=["c-noon"], in_range=extra)
            out = h.invoke(query="lunch", start=DAY_START, end=DAY_END, limit=3)
        self.assertEqual(len(out["results"]), 3)


class SegmentFetchTests(unittest.TestCase):
    """transcript segments 是压缩存的，长对话还在 transcript_chunks 子集合里 ——
    取一次要解压 + 每条一次额外查询，而窗口有 3 天宽、上限 500 条。只有按说话人
    过滤时才真的需要它们。"""

    def test_segments_not_fetched_when_speaker_filter_absent(self):
        with ExitStack() as stack:
            h = _Harness(stack)
            h.invoke(query="", start=DAY_START, end=DAY_END)
        self.assertFalse(h.range_args["include_segments"])

    def test_segments_fetched_when_filtering_by_speaker(self):
        """要按 is_user 过滤就必须真拿到 segments，否则过滤器恒为假、结果恒为空。"""
        with ExitStack() as stack:
            h = _Harness(stack)
            h.invoke(query="", start=DAY_START, end=DAY_END, speaker="user")
        self.assertTrue(h.range_args["include_segments"])

    def test_top_up_path_also_respects_the_speaker_need(self):
        with ExitStack() as stack:
            h = _Harness(stack, vector_ids=[])
            h.invoke(query="walk", start=DAY_START, end=DAY_END, speaker="user")
        self.assertTrue(h.range_args["include_segments"])


class SchemaTests(unittest.TestCase):
    def test_identity_still_absent_from_schema(self):
        """§9.5 的 prompt injection 防线:新分支不许把身份参数带进 schema。"""
        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        tools = {t.name: t for t in make_agent_tools(RequestContext(uid="u", developer_id="d"), CitationAccumulator())}
        keys = set(tools["memory_search"].args.keys())
        self.assertNotIn("uid", keys)
        self.assertNotIn("developer_id", keys)

    def test_docstring_tells_the_agent_how_to_use_the_date_channel(self):
        """通道靠 agent 主动用空 query 触发,所以 docstring 里必须写着怎么用。

        断言前先把空白折叠 —— docstring 会按行宽换行,`assertIn` 直接打原文会被一次
        无关的重排弄红,那种红是噪声不是信号。
        """
        import re

        from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

        tools = {t.name: t for t in make_agent_tools(RequestContext(uid="u", developer_id="d"), CitationAccumulator())}
        description = re.sub(r"\s+", " ", tools["memory_search"].description)
        self.assertIn("empty query with start/end", description)


if __name__ == "__main__":
    unittest.main(verbosity=2)
