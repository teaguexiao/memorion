"""人物来源分层 + 存量归档的不变式（2026-08-12）。

现场：某账号 833 个人物，实测只有 **31 个（3.7%）**真说过话 —— 8 个有声纹样本、23 个
被 transcript 段落挂过 `person_id`。剩下 802 个是 `_extract_people_background` 按
「转录稿里被**提到**的名字」建出来的（prompt 见 `conversation_processing.py:1046`），
里面还混着 `债款`、`付条`、`风调` 这种把转录错误当人名建进去的。名单全是噪声时，
「识别其他人」这一页和「标记说话人」的选择器都没法用。

改法两层：新建的带 `source`（provenance），存量靠 `deleted` 归档（可回滚）。
这份测试要钉的都是**静默失效**的形态：

1. **缺字段的老文档不能被过滤掉**。`deleted` / `source` 都是后加的，Firestore 的 `==`
   过滤不匹配缺字段的文档 —— 用 where 表达这两个条件会把老文档**全部**漏掉，而老文档
   正是这里的大多数。所以过滤在 Python 层做（和 `get_memories` 同一形状）。
2. **过滤之后分页不能被截断**。先 limit 再过滤的话，一页 100 条会变成「100 条原始文档
   里的少数幸存者」，翻页永远翻不完 —— 存量复筛之后 96% 的文档都被过滤掉。
3. **去重必须看得见已归档的人**。只被提到一次不足以复活一个被归档的名字；看不见就会
   每条对话都把清理掉的 800 个人重新建回来，归档静默白做。
4. **去重不能用 `get_people(limit=N)`**。它按 created_at DESC 截断，超过 limit 时
   **最老的那批掉出去** → 老名字重新变成「不存在」→ 同名的人被反复建。实测已经 833 人，
   离原来的 limit=1000 只差 167。
5. **同名不能出现第二条**。名单默认藏掉 mention，用户手打一个已存在的名字时若直接新建，
   声纹样本会分散到两个 person_id 上。

Run:
    cd backend && python3 tests/test_people_provenance_and_archive.py
"""

import asyncio
import os
import re
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("BUCKET_SPEECH_PROFILES", "test-speech-profiles")

import database.developer_data as dev_db  # noqa: E402

DEV = "dev1"
UID = "user1"
T0 = datetime(2026, 8, 1, tzinfo=timezone.utc)


# ---------------------------------------------------------------- fake Firestore


class _FakeDoc:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _FakeDocRef:
    def __init__(self, store, doc_id):
        self._store = store
        self._id = doc_id

    def get(self):
        return _FakeDoc(self._id, self._store.get(self._id))

    def set(self, data):
        self._store[self._id] = dict(data)

    def create(self, data):
        if self._id in self._store:
            raise dev_db.AlreadyExists('Person exists')
        self.set(data)

    def update(self, payload):
        self._store.setdefault(self._id, {}).update(payload)


class _FakeQuery:
    def __init__(self, store, order_field=None, projection=None):
        self._store = store
        self._order_field = order_field
        self._projection = projection

    def order_by(self, field, direction=None):
        return _FakeQuery(self._store, order_field=field, projection=self._projection)

    def where(self, field, op, value):
        assert op == "in", f"fake query only implements 'in', got {op!r}"
        subset = {k: v for k, v in self._store.items() if v.get(field) in value}
        return _FakeQuery(subset, order_field=self._order_field, projection=self._projection)

    def select(self, fields):
        return _FakeQuery(self._store, order_field=self._order_field, projection=list(fields))

    def document(self, doc_id):
        return _FakeDocRef(self._store, doc_id)

    def collection(self, _name):
        return self

    def stream(self):
        items = list(self._store.items())
        if self._order_field:
            # ⚠️ 真实 Firestore 语义：order_by 的字段缺失时，文档**不会出现在结果里**。
            # 这不是模拟器的怪癖，是这个仓库反复踩到的静默丢数据形态。
            items = [(k, v) for k, v in items if self._order_field in v]
            items.sort(key=lambda kv: kv[1][self._order_field], reverse=True)
        for doc_id, data in items:
            if self._projection is not None:
                data = {k: v for k, v in data.items() if k in self._projection}
            yield _FakeDoc(doc_id, data)


class _FakeUserRef:
    def __init__(self, store):
        self._store = store

    def collection(self, _name):
        return _FakeQuery(self._store)


class PeopleStoreTestCase(unittest.TestCase):
    def setUp(self):
        self.store = {}
        patcher = mock.patch.object(
            dev_db, "_get_user_ref", return_value=_FakeUserRef(self.store)
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        ensure = mock.patch.object(dev_db, "_ensure_user_exists")
        ensure.start()
        self.addCleanup(ensure.stop)

    def add(self, person_id, name, minutes=0, **fields):
        data = {"id": person_id, "name": name, "created_at": T0 + timedelta(minutes=minutes)}
        data.update(fields)
        self.store[person_id] = data
        return data

    def names(self, **kwargs):
        kwargs.setdefault("limit", 100)
        return [p["name"] for p in dev_db.get_people(DEV, UID, **kwargs)]


# ---------------------------------------------------------------- get_people filters


class MissingFieldsSurviveFiltering(PeopleStoreTestCase):
    """缺 `deleted` / `source` 的老文档必须原样返回 —— 它们是存量里的大多数。"""

    def test_legacy_docs_without_deleted_or_source_are_kept(self):
        self.add("a", "存量甲")
        self.add("b", "存量乙")

        self.assertEqual(set(self.names()), {"存量甲", "存量乙"})

    def test_unknown_source_is_not_treated_as_mention(self):
        """未知 ≠ mention。存量 802 个靠 `deleted` 排掉，不靠 source —— 谁只是被提到过，
        事后无法从文档本身重建，把「未知」当 mention 会连真说话人一起藏掉。"""
        self.add("a", "存量未知来源")

        self.assertEqual(self.names(include_mentions=False), ["存量未知来源"])


class ArchivedPeopleAreHidden(PeopleStoreTestCase):
    def test_deleted_is_excluded_by_default(self):
        self.add("a", "留下的")
        self.add("b", "归档的", deleted=True)

        self.assertEqual(self.names(), ["留下的"])

    def test_include_deleted_brings_them_back(self):
        self.add("a", "留下的", minutes=1)
        self.add("b", "归档的", minutes=0, deleted=True)

        self.assertEqual(self.names(include_deleted=True), ["留下的", "归档的"])

    def test_deleted_false_is_not_confused_with_missing(self):
        """回滚写的是 `deleted=False`，不是删字段。False 必须当成「没归档」。"""
        self.add("a", "回滚过的", deleted=False)

        self.assertEqual(self.names(), ["回滚过的"])


class MentionsAreHiddenFromTheRoster(PeopleStoreTestCase):
    def test_mentions_excluded_when_asked(self):
        self.add("a", "说过话的", minutes=1, source=dev_db.PERSON_SOURCE_SPEAKER_MAPPING)
        self.add("b", "只被提到的", minutes=0, source=dev_db.PERSON_SOURCE_MENTION)

        self.assertEqual(self.names(include_mentions=False), ["说过话的"])

    def test_mentions_included_by_default(self):
        """数据层默认全给 —— 按名字去重的调用点必须看得见 mention，否则重复建。"""
        self.add("a", "只被提到的", source=dev_db.PERSON_SOURCE_MENTION)

        self.assertEqual(self.names(), ["只被提到的"])

    def test_manual_and_speaker_mapping_both_survive(self):
        self.add("a", "手动建的", minutes=2, source=dev_db.PERSON_SOURCE_MANUAL)
        self.add("b", "映射出的", minutes=1, source=dev_db.PERSON_SOURCE_SPEAKER_MAPPING)
        self.add("c", "被提到的", minutes=0, source=dev_db.PERSON_SOURCE_MENTION)

        self.assertEqual(self.names(include_mentions=False), ["手动建的", "映射出的"])


class PaginationIsNotEatenByFiltering(PeopleStoreTestCase):
    """过滤在 limit **之后**做的话，一页就只剩少数幸存者 —— 而复筛后 96% 都被过滤掉。"""

    def setUp(self):
        super().setUp()
        # 交替：偶数留、奇数归档。created_at 递增，get_people 按 DESC 返回。
        for i in range(40):
            self.add(f"p{i}", f"人{i}", minutes=i, deleted=bool(i % 2))

    def test_a_full_page_is_returned_despite_heavy_filtering(self):
        page = self.names(limit=10)

        self.assertEqual(len(page), 10, "一页要给满 10 个存活的，不是「前 10 条原始文档的幸存者」")
        self.assertEqual(page, [f"人{i}" for i in range(38, 18, -2)])

    def test_offset_walks_the_filtered_list_not_the_raw_one(self):
        first = self.names(limit=5, offset=0)
        second = self.names(limit=5, offset=5)

        self.assertEqual(first, [f"人{i}" for i in range(38, 28, -2)])
        self.assertEqual(second, [f"人{i}" for i in range(28, 18, -2)])
        self.assertEqual(set(first) & set(second), set(), "翻页不能重复")


# ---------------------------------------------------------------- name index


class NameIndexSeesEverything(PeopleStoreTestCase):
    def test_archived_names_still_count_as_existing(self):
        """核心：被提到一次不能复活一个归档过的名字。看不见 = 归档静默白做。"""
        self.add("a", "李飞飞", deleted=True)

        index = dev_db.get_people_name_index(DEV, UID)

        self.assertIn("李飞飞", index)
        self.assertTrue(index["李飞飞"]["deleted"])

    def test_docs_missing_created_at_are_still_indexed(self):
        """索引刻意不 order_by：order_by 会**静默丢掉**缺该字段的文档，而丢掉一个名字
        就等于让它被重新建一遍。同一份数据 get_people 看不到它，索引必须看到。"""
        self.store["x"] = {"id": "x", "name": "没有创建时间的"}

        self.assertEqual(self.names(), [], "order_by 的真实语义：缺字段就不返回")
        self.assertIn("没有创建时间的", dev_db.get_people_name_index(DEV, UID))

    def test_index_is_not_truncated_by_a_limit(self):
        """833 人的账号离原来的 limit=1000 只差 167 —— 越过之后去重会静默失效。"""
        for i in range(1500):
            self.add(f"p{i}", f"人{i}", minutes=i)

        self.assertEqual(len(dev_db.get_people_name_index(DEV, UID)), 1500)

    def test_lookup_is_case_insensitive_and_trimmed(self):
        self.add("a", "  Alice  ")

        self.assertIn("alice", dev_db.get_people_name_index(DEV, UID))

    def test_duplicate_names_prefer_the_live_non_mention_record(self):
        """存量里已经有同名多条。升级/复用时必须挑最像真人的那条，否则样本挂错 id。"""
        self.add("ghost", "王伟", minutes=0, deleted=True, source=dev_db.PERSON_SOURCE_MENTION)
        self.add("real", "王伟", minutes=1, source=dev_db.PERSON_SOURCE_SPEAKER_MAPPING)
        self.add("mention", "王伟", minutes=2, source=dev_db.PERSON_SOURCE_MENTION)

        self.assertEqual(dev_db.get_people_name_index(DEV, UID)["王伟"]["id"], "real")

    def test_nameless_docs_are_skipped(self):
        self.store["x"] = {"id": "x", "name": ""}

        self.assertEqual(dev_db.get_people_name_index(DEV, UID), {})


# ---------------------------------------------------------------- soft delete round trip


class ArchiveRoundTrip(PeopleStoreTestCase):
    def test_archive_then_restore_returns_the_person_to_the_roster(self):
        self.add("a", "被提到的", source=dev_db.PERSON_SOURCE_MENTION)

        self.assertTrue(dev_db.soft_delete_person(DEV, UID, "a", reason="cleanup"))
        self.assertEqual(self.names(), [])

        dev_db.restore_person(DEV, UID, "a")
        self.assertEqual(self.names(), ["被提到的"])

    def test_archive_records_the_reason_so_a_rollback_can_target_it(self):
        self.add("a", "被提到的")

        dev_db.soft_delete_person(DEV, UID, "a", reason="archive_mentioned_only_people")

        self.assertEqual(self.store["a"]["deleted_reason"], "archive_mentioned_only_people")

    def test_restore_can_promote_the_source(self):
        """「被提到的人后来真说话了」：撤销归档 + 改判来源，同一条记录，不新建。"""
        self.add("a", "李飞飞", deleted=True, source=dev_db.PERSON_SOURCE_MENTION)

        dev_db.restore_person(DEV, UID, "a", source=dev_db.PERSON_SOURCE_SPEAKER_MAPPING)

        self.assertEqual(self.store["a"]["source"], dev_db.PERSON_SOURCE_SPEAKER_MAPPING)
        self.assertEqual(self.names(include_mentions=False), ["李飞飞"])

    def test_archiving_a_missing_person_reports_failure(self):
        self.assertFalse(dev_db.soft_delete_person(DEV, UID, "nope"))
        self.assertIsNone(dev_db.restore_person(DEV, UID, "nope"))


class CreatePersonRecordsProvenance(PeopleStoreTestCase):
    def test_explicit_chapter_person_creation_preserves_namesakes_and_is_retryable(self):
        self.add('existing', '小草')
        created = dev_db.create_chapter_person(DEV, UID, 'new-person', '小草')
        retried = dev_db.create_chapter_person(DEV, UID, 'new-person', '小草')
        self.assertEqual(created, retried)
        self.assertEqual(created['source'], 'manual')
        self.assertEqual(set(self.store), {'existing', 'new-person'})

    def test_chapter_retry_does_not_overwrite_a_renamed_or_archived_person(self):
        for fields in ({'name': '新名字'}, {'name': '小草', 'deleted': True}):
            with self.subTest(fields=fields):
                self.add('new-person', **fields)
                before = dict(self.store['new-person'])
                with self.assertRaises(ValueError):
                    dev_db.create_chapter_person(DEV, UID, 'new-person', '小草')
                self.assertEqual(self.store['new-person'], before)

    def test_source_is_stored_when_given(self):
        created = dev_db.create_person(DEV, UID, "小草", source=dev_db.PERSON_SOURCE_MENTION)

        self.assertEqual(created["source"], dev_db.PERSON_SOURCE_MENTION)
        self.assertEqual(self.store[created["id"]]["source"], dev_db.PERSON_SOURCE_MENTION)

    def test_no_source_key_is_written_when_omitted(self):
        """缺省要留成「未知」，不能落成空串 —— 空串会被当成一个真的 source 值去比。"""
        created = dev_db.create_person(DEV, UID, "小草")

        self.assertNotIn("source", created)


# ---------------------------------------------------------------- by-ids asymmetry


class ByIdsKeepsArchivedNames(PeopleStoreTestCase):
    def test_archived_person_still_resolves_by_id(self):
        """段落上挂着 person_id 时要取回名字。归档只是不进**名单**，历史转录稿不该退回
        Speaker N。这条和 get_people 刻意相反，写在这里免得以后被「统一」掉。"""
        self.add("a", "归档的", deleted=True)

        got = dev_db.get_people_by_ids(DEV, UID, ["a"])

        self.assertEqual([p["name"] for p in got], ["归档的"])


# ---------------------------------------------------------------- call-site invariants


def _read(rel_path):
    with open(os.path.join(BACKEND_DIR, rel_path), encoding="utf-8") as fh:
        return fh.read()


def _function_source(rel_path, func_name):
    """抠出一个函数（含嵌套 def）的源码。用于没有 seam 可插的调用点断言。"""
    source = _read(rel_path)
    match = re.search(rf"^([ \t]*)def {re.escape(func_name)}\b", source, re.M)
    assert match, f"{func_name} not found in {rel_path}"
    indent = len(match.group(1))
    lines = source[match.start():].splitlines()

    # ⚠️ 先把**多行签名**整段吃掉，再开始用缩进判结束。签名的收尾 `) -> X:` 就落在 def
    # 自己的缩进层上，直接套「回到 def 缩进就结束」的话，每个多行签名的函数都只会抠出
    # 一行 —— 而断言「源码里没有 X」在空字符串上是恒真的，静默通过。
    body, depth, in_signature = [], 0, True
    for line in lines:
        body.append(line)
        if in_signature:
            depth += line.count("(") - line.count(")")
            if depth == 0 and line.rstrip().endswith(":"):
                in_signature = False
            continue
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            body.pop()
            break
    assert not in_signature, f"{func_name}: 签名没闭合，抠出来的是残缺片段"
    return "\n".join(body)


class DedupCallSitesUseTheFullIndex(unittest.TestCase):
    """两个提取调用点都在闭包/嵌套函数里，没法直接调 —— 只能对源码下断言。

    ⚠️ 这两处**必须一起改**：同一个提取器的两个调用点（实时链路 / reprocess 链路）。
    历史上「改漏一处」在这个仓库是反复出现的形态，而且都是静默的。
    """

    CALL_SITES = [
        ("routers/developer_listen.py", "_extract_people_background"),
        ("utils/conversations/process_conversation.py", "_extract_and_create_people"),
    ]

    def test_dedup_uses_the_name_index(self):
        for path, func in self.CALL_SITES:
            with self.subTest(func=func):
                src = _function_source(path, func)
                self.assertIn("get_people_name_index", src)

    def test_dedup_does_not_use_a_truncated_listing(self):
        for path, func in self.CALL_SITES:
            with self.subTest(func=func):
                src = _function_source(path, func)
                self.assertNotRegex(
                    src, r"get_people\((?!.*name_index)",
                    "去重不能用 get_people(limit=N)：按 created_at 截断会让最老的名字"
                    "静默消失并被重新建（见 get_people_name_index 的注释）",
                )

    def test_extracted_people_are_tagged_as_mentions(self):
        # 断言必须挂在 `create_person(...)` 这个调用上。只查「函数里出现过这个常量」是
        # 恒真的 —— 注释和 name_index 的那行也带着它，把 source= 去掉照样通过（实测）。
        for path, func in self.CALL_SITES:
            with self.subTest(func=func):
                src = _function_source(path, func)
                self.assertRegex(
                    src, r"create_person\([^)]*PERSON_SOURCE_MENTION",
                    "提取出来的人物必须落 source='mention'，否则和真说话人再也分不开",
                )

    def test_a_mention_never_resurrects_an_archived_person(self):
        """名字命中索引就 `continue`，不 restore —— 只被提一次不足以复活。"""
        for path, func in self.CALL_SITES:
            with self.subTest(func=func):
                src = _function_source(path, func)
                self.assertNotIn("restore_person", src)


class SpeakerMappingPromotesInsteadOfDuplicating(unittest.TestCase):
    def test_it_restores_and_retags_a_matching_record(self):
        src = _function_source("routers/developer_listen.py", "_auto_process_conversation")
        mapping = src[src.index("map_speakers_to_names(transcript_text)"):]
        mapping = mapping[: mapping.index("Write the resolved names back")]

        self.assertIn("restore_person", mapping,
                      "同名已存在（可能是 mention、可能已归档）时要升级它，不能建第二条")
        self.assertIn("PERSON_SOURCE_SPEAKER_MAPPING", mapping)
        self.assertIn("get_people_name_index", mapping)


# ---------------------------------------------------------------- endpoints


class ListEndpointHidesMentionsByDefault(unittest.TestCase):
    def setUp(self):
        import routers.developer_people as people_router

        self.router = people_router
        self.calls = []
        patches = [
            mock.patch.object(people_router.dev_db, "get_people", side_effect=self._get_people),
            mock.patch.object(people_router, "get_developer_people_speech_sample_counts",
                              return_value={}),
        ]
        for p in patches:
            p.start()
        self.addCleanup(lambda: [p.stop() for p in patches])

    def _get_people(self, **kwargs):
        self.calls.append(kwargs)
        return []

    def test_default_excludes_mentions(self):
        """默认值反转是有意的：833 个名字里 802 个是噪声，老客户端不发这个参数也要受益
        （不需要发新版 App）。"""
        import inspect

        sig = inspect.signature(self.router.list_people)
        self.assertIs(sig.parameters["include_mentions"].default.default, False)

    def test_the_flag_is_threaded_to_the_data_layer(self):
        asyncio.run(self.router.list_people(
            external_user_id=UID, limit=100, offset=0,
            include_speech_samples=False, include_mentions=False, developer_id=DEV,
        ))

        self.assertEqual(self.calls[0]["include_mentions"], False)


class CreateEndpointReusesAnExistingName(unittest.TestCase):
    def setUp(self):
        import routers.developer_people as people_router

        self.router = people_router
        self.created = []
        self.restored = []
        self.index = {}
        patches = [
            mock.patch.object(people_router.dev_db, "get_people_name_index",
                              side_effect=lambda **kw: self.index),
            mock.patch.object(people_router.dev_db, "create_person",
                              side_effect=self._create),
            mock.patch.object(people_router.dev_db, "restore_person",
                              side_effect=self._restore),
        ]
        for p in patches:
            p.start()
        self.addCleanup(lambda: [p.stop() for p in patches])

    def _create(self, **kwargs):
        self.created.append(kwargs)
        return {"id": "new", "name": kwargs["name"], "source": kwargs.get("source")}

    def _restore(self, **kwargs):
        self.restored.append(kwargs)
        return {"id": kwargs["person_id"], "name": "李飞飞", "source": kwargs.get("source")}

    def call(self, name, metadata=None):
        return asyncio.run(self.router.create_person(
            person_data=self.router.PersonCreate(
                external_user_id=UID, name=name, metadata=metadata or {}
            ),
            developer_id=DEV,
        ))

    def test_an_archived_mention_is_promoted_not_duplicated(self):
        """名单藏掉了 mention，所以用户手打的名字很可能「已存在但看不见」。直接新建会让
        声纹样本分散到两个 person_id 上 —— 那正是这轮要修的问题。"""
        self.index["李飞飞"] = {"id": "old", "deleted": True,
                                "source": dev_db.PERSON_SOURCE_MENTION}

        result = self.call("李飞飞")

        self.assertEqual(self.created, [], "同名已存在时不许新建")
        self.assertEqual(self.restored[0]["person_id"], "old")
        self.assertEqual(self.restored[0]["source"], dev_db.PERSON_SOURCE_MANUAL)
        self.assertEqual(result["id"], "old")

    def test_a_brand_new_name_is_created_as_manual(self):
        result = self.call("新的人")

        self.assertEqual(self.restored, [])
        self.assertEqual(self.created[0]["source"], dev_db.PERSON_SOURCE_MANUAL)
        self.assertEqual(result["id"], "new")

    def test_matching_is_case_insensitive_and_trimmed(self):
        self.index["alice"] = {"id": "old", "deleted": False, "source": None}

        self.call("  Alice ")

        self.assertEqual(self.created, [])


class ChatToolSkipsMentions(unittest.TestCase):
    def test_people_lookup_asks_for_speakers_only(self):
        """`people_lookup` 回答的是「我都跟谁聊过」。只被提到的 Person 文档除了名字什么
        都没有，进 chat 上下文只是噪声（名字本身在转录稿里，memory_search 搜得到）。"""
        src = _function_source("utils/retrieval/agent_tools.py", "people_lookup")

        self.assertIn("include_mentions=False", src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
