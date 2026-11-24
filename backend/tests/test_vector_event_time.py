"""向量的时间戳必须是**对话发生时刻**，不是入库时刻。

`memory_search` 的时间过滤打的是 Pinecone metadata 的 `created_at`。而对话对象上的
`created_at` 是文档写入时刻（`developer_data.create_conversation` 和 `audio_upload.py`
都写 `now()`），真正的事件时间在 `started_at`。

两者在实时链路上几乎相同，所以这个 bug 在主链路上看不出来；在「先录后传」的路径上
（音频上传 / 手表 / SD 卡同步 / reprocess）2026-08-18 实测 p90 偏移 16.03h、max
20.17h。后果是**静默的**：8/13 录、8/14 上传的对话在「8 月 13 号我做了什么」的时间窗
里查不到，而检索返回空和「那天真的没说话」长得一模一样。

同一个时间还被当作抽 metadata 的 prompt 里的 `today`（`utils/llm/chat.py:768`）——
对话里说的「明天」是相对录音那一刻，传 created_at 会跨天算错。

这里断言的是**字段选择**，不是 embedding 或 Pinecone 本身，所以两者都用假的。
"""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

# 对齐 audio_upload 实测的 p90（16.03h）：录音在 8-13 晚，上传在 8-14 下午。
STARTED_AT = datetime(2026, 8, 13, 22, 30, tzinfo=timezone.utc)
CREATED_AT = datetime(2026, 8, 14, 14, 32, tzinfo=timezone.utc)
SKEW_SECONDS = int((CREATED_AT - STARTED_AT).total_seconds())


class FakeEmbedding:
    values = [0.0] * 8
    truncated = False
    token_count = 10


def _fake_conversation(started_at=STARTED_AT, created_at=CREATED_AT, source="audio_upload"):
    """够 save_structured_vector 用的最小对话对象。

    刻意用 SimpleNamespace 而不是真的 Conversation model：这个测试要钉的是「读了哪个
    字段」，构造一个完整的 pydantic 对象只会把断言埋进无关的必填字段里。
    """
    from types import SimpleNamespace

    return SimpleNamespace(
        id="conv-1",
        started_at=started_at,
        created_at=created_at,
        source=source,
        transcript_segments=[],
        photos=[],
        structured=SimpleNamespace(title="t", overview="o"),
        external_data={},
    )


class SaveStructuredVectorTests(unittest.TestCase):
    def _run(self, conversation):
        """跑 save_structured_vector，返回 (upsert 到的 metadata, 传给抽取器的时间)."""
        import utils.conversations.process_conversation as pc

        captured = {}

        def fake_upsert(uid, conv, vector, metadata):
            captured["metadata"] = metadata

        def fake_retrieve(uid, when, segments, tz, photos=None):
            captured["extractor_time"] = when
            return {"people": [], "topics": [], "entities": [], "dates": []}

        with mock.patch.object(pc, "upsert_vector2", fake_upsert), \
             mock.patch.object(pc, "retrieve_metadata_fields_from_transcript", fake_retrieve), \
             mock.patch.object(pc, "generate_embedding_document", return_value=FakeEmbedding()), \
             mock.patch.object(pc, "structured_as_embedding_text", return_value="text"), \
             mock.patch.object(pc.dev_db, "get_user_time_zone", return_value="UTC"):
            pc.save_structured_vector("uid", conversation, developer_id="dev")
        return captured

    def test_created_at_metadata_is_the_recording_time(self):
        """核心不变式：写进向量的 created_at 是 started_at，不是文档的 created_at。"""
        captured = self._run(_fake_conversation())
        self.assertEqual(captured["metadata"]["created_at"], int(STARTED_AT.timestamp()))
        self.assertNotEqual(captured["metadata"]["created_at"], int(CREATED_AT.timestamp()))

    def test_skew_would_have_been_16_hours(self):
        """把偏移量本身钉住 —— 说明这个测试测的不是个 1 秒的舍入差。"""
        captured = self._run(_fake_conversation())
        wrong = int(CREATED_AT.timestamp())
        self.assertEqual(wrong - captured["metadata"]["created_at"], SKEW_SECONDS)
        self.assertGreater(SKEW_SECONDS, 16 * 3600)

    def test_metadata_extractor_gets_the_recording_time(self):
        """抽取器那个时间参数是 prompt 里的 `today`，也必须是录音时刻。"""
        captured = self._run(_fake_conversation())
        self.assertEqual(captured["extractor_time"], STARTED_AT)

    def test_falls_back_to_created_at_when_started_at_missing(self):
        """omi 迁移数据可能没有 started_at —— 回退而不是崩，也不是写 0。"""
        captured = self._run(_fake_conversation(started_at=None))
        self.assertEqual(captured["metadata"]["created_at"], int(CREATED_AT.timestamp()))
        self.assertEqual(captured["extractor_time"], CREATED_AT)

    def test_indexed_at_records_the_write_instant(self):
        """入库时刻没有丢，它搬到了 indexed_at —— 审计脚本和回滚都靠它。"""
        before = int(datetime.now(timezone.utc).timestamp())
        captured = self._run(_fake_conversation())
        after = int(datetime.now(timezone.utc).timestamp())
        indexed_at = captured["metadata"]["indexed_at"]
        self.assertGreaterEqual(indexed_at, before)
        self.assertLessEqual(indexed_at, after)
        # 关键：indexed_at 必须和 created_at 分得开，否则这个字段毫无用处。
        self.assertNotEqual(indexed_at, captured["metadata"]["created_at"])

    def test_external_integration_branch_also_uses_event_time(self):
        """external_integration 分支是独立的一段代码，改漏了同样是静默的。"""
        import utils.conversations.process_conversation as pc
        from models.conversation import ConversationSource, ExternalIntegrationConversationSource

        conversation = _fake_conversation(source=ConversationSource.external_integration)
        conversation.external_data = {
            # 取 enum 而不是写字面量 —— `other` 的实际值是 'other_text'，硬编码会让
            # 这个分支静默走不到，测试却因为断言没被执行而显得"通过"。
            "text_source": ExternalIntegrationConversationSource.other.value,
            "text": "hello there",
        }
        captured = {}

        def fake_from_text(uid, when, text, tz, spec):
            captured["extractor_time"] = when
            return {"people": [], "topics": [], "entities": [], "dates": []}

        with mock.patch.object(pc, "upsert_vector2", lambda *a, **k: captured.setdefault("metadata", a[3])), \
             mock.patch.object(pc, "retrieve_metadata_from_text", fake_from_text), \
             mock.patch.object(pc, "generate_embedding_document", return_value=FakeEmbedding()), \
             mock.patch.object(pc, "structured_as_embedding_text", return_value="text"), \
             mock.patch.object(pc.dev_db, "get_user_time_zone", return_value="UTC"):
            pc.save_structured_vector("uid", conversation, developer_id="dev")

        self.assertEqual(captured["extractor_time"], STARTED_AT)
        self.assertEqual(captured["metadata"]["created_at"], int(STARTED_AT.timestamp()))


class SaveVectorFromDictTests(unittest.TestCase):
    """实时链路那条（listen / App 主动 process）。它一直传的是 started_at，
    这里钉住的是参数语义没被改回去，以及 indexed_at 也在写。"""

    def test_event_time_lands_in_created_at_and_indexed_at_is_separate(self):
        import utils.conversations.process_conversation as pc

        captured = {}

        class FakeIndex:
            def upsert(self, vectors, namespace):
                captured["metadata"] = vectors[0]["metadata"]

        with mock.patch.object(pc, "generate_embedding_document", return_value=FakeEmbedding()), \
             mock.patch.object(pc, "structured_as_embedding_text", return_value="text"), \
             mock.patch.object(pc, "retrieve_metadata_fields_from_transcript",
                               return_value={"people": [], "topics": [], "entities": [], "dates": []}), \
             mock.patch.object(pc.dev_db, "get_user_time_zone", return_value="UTC"), \
             mock.patch("database.vector_db.index", FakeIndex()):
            pc.save_vector_from_dict(
                uid="uid",
                conversation_id="conv-1",
                structured={"title": "t", "overview": "o"},
                event_time=STARTED_AT,
                segments=[],
                developer_id="dev",
            )

        self.assertEqual(captured["metadata"]["created_at"], int(STARTED_AT.timestamp()))
        self.assertNotEqual(captured["metadata"]["indexed_at"], captured["metadata"]["created_at"])

    def test_signature_uses_event_time_not_created_at(self):
        """参数叫 created_at 时，两个调用点「照着名字传 conversation.created_at」是
        一步之遥。改名本身就是不变式的一部分。"""
        import inspect

        import utils.conversations.process_conversation as pc

        params = inspect.signature(pc.save_vector_from_dict).parameters
        self.assertIn("event_time", params)
        self.assertNotIn("created_at", params)


class CallSiteTests(unittest.TestCase):
    """两个调用点必须传 started_at。这是「两个各自正确的函数没接起来」的防线：
    上面的测试全绿而调用点传错，向量照样是入库时刻。"""

    def _assert_passes_started_at(self, path: str):
        import re

        with open(os.path.join(os.path.dirname(__file__), "..", path)) as f:
            source = f.read()
        call = re.search(r"save_vector_from_dict\((.*?)\n\s*\)", source, re.S)
        self.assertIsNotNone(call, f"{path}: 找不到 save_vector_from_dict 调用")
        body = call.group(1)
        self.assertRegex(body, r"event_time\s*=\s*started_at", f"{path}: 没有传 started_at")
        self.assertNotRegex(body, r"created_at\s*=", f"{path}: 还在用 created_at= 关键字")

    def test_listen_path_passes_started_at(self):
        self._assert_passes_started_at("routers/developer_listen.py")

    def test_app_process_path_passes_started_at(self):
        self._assert_passes_started_at("routers/developer_conversations.py")

    def test_no_caller_passes_the_document_timestamp(self):
        """全仓扫一遍，不许有人给 save_vector_from_dict 传 `created_at=`。

        钉死的理由是这一条真的漏过：`scripts/backfill_conversation_vectors.py` 当时取的是
        `conv.get('created_at') or conv.get('started_at')`（优先级正好反了），于是那个补
        向量的脚本每补一条就制造一条错时间戳。而它的调用被 `except Exception` 包着，改
        签名漏了它的症状是「一条都没补上、只打一屏 Error」——不会崩，所以不会被发现。

        按可达集扫而不是钉死文件名：新加一个调用点也要被这条断言覆盖。
        """
        import re

        backend = os.path.join(os.path.dirname(__file__), "..")
        offenders = []
        for root, dirs, files in os.walk(backend):
            dirs[:] = [d for d in dirs if not d.startswith((".venv", "__pycache__", ".git"))]
            for name in files:
                if not name.endswith(".py") or name == os.path.basename(__file__):
                    continue
                path = os.path.join(root, name)
                with open(path, encoding="utf-8") as f:
                    source = f.read()
                for call in re.finditer(r"save_vector_from_dict\(([^)]*)\)", source, re.S):
                    if re.search(r"\bcreated_at\s*=", call.group(1)):
                        offenders.append(os.path.relpath(path, backend))
        self.assertEqual(offenders, [], f"这些调用点还在传文档时间戳: {offenders}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
