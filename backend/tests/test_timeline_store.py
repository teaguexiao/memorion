"""章节缓存:覆写而非追加、指纹省掉 LLM、按天锁、debounce 窗口。

存在的理由:章节是投影,重算一遍在语义上永远安全 —— 但它**不便宜**(一次 Firestore
查询 + 每个合并章节一次 LLM)。所以这一层的正确性不在「算得对」,在「什么时候不算」
和「算的时候不会互相踩」。四件事各自都能静默出错:

1. **覆写而非追加。** doc id 就是日期,所以同一天写 100 次也只有一份文档。要是哪天
   有人把 `set()` 改成 `set(merge=True)` 或改成 `add()`,症状是**过时的章节不消失而是
   跟新章节并列** —— 用户看到重复卡片,而后端日志一片正常。
2. **指纹省掉 LLM。** App 每次启动都会请求今天的时间轴。若指纹对不上就重算,那就是
   每次启动烧一遍 LLM 钱。而指纹**故意不含 `updated_at`**:声纹回填 `is_user`、用户
   确认待办、事后改说话人都会动 `updated_at` 却动不了任何边界,含进去等于让这三件事
   各触发一次全天重算。
3. **按天锁。** 批量同步一次落库几十条同日会话,并发重算会互相覆盖(后写的赢,而它
   读到的可能是更旧的数据)。
4. **debounce 窗口必须 > 合并阈值 8min。** 窗口比阈值短的话必然做白工:刚算完,
   一段新语音落在合并间隙内又并进同一章,刚才那次算的结果从来就不是最终形态。
   而且 dirty marker 记的是**第一次**变脏的时间,不是最近一次 —— 每次写都刷新的话,
   480 个文件的批量同步会把到期时间永远往后推,这天永远不到期。

不连 Firestore、不连 Redis、不连 LLM:三者都用假实现替掉。假 Firestore 只实现
`get/set/collection/document`,因为「`set()` 是整文档覆写」正是 Firestore 的语义保证,
这里要测的是我们有没有用错它。

Run:
    cd backend && python3 tests/test_timeline_store.py
"""

import ast
import os
import sys
import threading
import time
import unittest
from datetime import date, datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
# `.env` 的这个变量指向容器路径，import database 时会在 macOS 上 OSError。
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

import database.developer_data as dev_db  # noqa: E402
from utils.llm.prompt_registry import ResolvedPrompt  # noqa: E402
from utils.timeline import rollup as rollup_mod  # noqa: E402
from utils.timeline import store  # noqa: E402
from utils.timeline.chaptering import ALGO_VERSION, GAP_MERGE_MINUTES  # noqa: E402
from utils.timeline.rollup import ROLLUP_VERSION  # noqa: E402
from utils.timeline.store import (  # noqa: E402
    DEBOUNCE_MINUTES,
    build_day_document,
    compute_fingerprint,
    day_lock_key,
    dirty_marker_key,
    mark_day_dirty,
    recompute_day,
    should_recompute_now,
    summarize_chapters,
)

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEV = 'dev-store'
UID = 'user-store'
DAY = date(2026, 8, 7)
DAY_STR = '2026-08-07'
_BASE = datetime(2026, 8, 7, 13, 0, tzinfo=timezone.utc)


# ---------------------------------------------------------------- 假实现


class FakeDoc:
    def __init__(self, store_dict, key):
        self._store = store_dict
        self._key = key

    def get(self):
        return self

    @property
    def exists(self):
        return self._key in self._store

    def to_dict(self):
        return self._store.get(self._key)

    def set(self, data, merge=False):
        # merge 语义也照实模拟：如果哪天有人加了 merge=True，用例要能看见后果。
        if merge and self._key in self._store:
            merged = dict(self._store[self._key])
            merged.update(data)
            self._store[self._key] = merged
        else:
            self._store[self._key] = data

    def collection(self, name):
        return FakeCollection(self._store, f'{self._key}/{name}')


class FakeCollection:
    def __init__(self, store_dict, prefix):
        self._store = store_dict
        self._prefix = prefix

    def document(self, doc_id):
        return FakeDoc(self._store, f'{self._prefix}/{doc_id}')


class FakeFirestore:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return FakeCollection(self.store, name)


class FakeRedis:
    """acquire_lock / release_lock / generic cache 的最小实现。

    锁用一把真 `threading.Lock` 护住 check-and-set —— 假实现自己 TOCTOU 的话，
    真实现的并发缺陷会被一起放过去（这个坑 `test_sync_idempotency` 里踩过）。
    """

    def __init__(self):
        self._mutex = threading.Lock()
        self.locks = {}
        self.cache = {}
        self.acquire_calls = []
        self.release_calls = []

    def acquire_lock(self, lock_key, ttl_seconds=60):
        with self._mutex:
            self.acquire_calls.append(lock_key)
            if lock_key in self.locks:
                return False
            self.locks[lock_key] = ttl_seconds
            return True

    def release_lock(self, lock_key):
        with self._mutex:
            self.release_calls.append(lock_key)
            self.locks.pop(lock_key, None)

    def acquire_owned_lock(self, lock_key, owner, ttl_seconds=60):
        with self._mutex:
            self.acquire_calls.append(lock_key)
            if lock_key in self.locks:
                return False
            self.locks[lock_key] = owner
            return True

    def renew_owned_lock(self, lock_key, owner, ttl_seconds=60):
        with self._mutex:
            return self.locks.get(lock_key) == owner

    def release_owned_lock(self, lock_key, owner):
        with self._mutex:
            self.release_calls.append(lock_key)
            if self.locks.get(lock_key) == owner:
                self.locks.pop(lock_key)

    def get_generic_cache(self, path):
        return self.cache.get(path)

    def set_generic_cache(self, path, data, ttl=None):
        self.cache[path] = data

    def delete_generic_cache(self, path):
        self.cache.pop(path, None)


class DayDb:
    """recompute_day 需要的 dev_db 面:取时区、取会话、读写 timeline_day。

    读写走真的 `dev_db.store_timeline_day` / `get_timeline_day`（底下垫假 Firestore），
    因为「覆写非追加」正是要验的那个函数的行为。
    """

    def __init__(self, convos, tz_name='UTC'):
        self.convos = list(convos)
        self.tz_name = tz_name
        self.store_calls = 0

    def get_user_timezone(self, dev, uid):
        return self.tz_name

    def get_conversations_by_recording_time(self, dev, uid, **kw):
        return list(self.convos)

    def store_timeline_day(self, dev, uid, date_str, document):
        self.store_calls += 1
        return dev_db.store_timeline_day(dev, uid, date_str, document)

    def get_timeline_day(self, dev, uid, date_str):
        return dev_db.get_timeline_day(dev, uid, date_str)


def convo(cid, offset_min, n_seg=3, title='t', source='app', overview='ov'):
    started = _BASE + timedelta(minutes=offset_min)
    return {
        'id': cid,
        'source': source,
        'discarded': False,
        'started_at': started,
        'created_at': started,
        'finished_at': started + timedelta(seconds=n_seg * 30),
        'updated_at': started,
        'structured': {'title': title, 'overview': overview, 'emoji': '🧠',
                       'first_person_observation': ''},
        'transcript_segments': [
            {'text': f'{cid} sentence {i}', 'start': float(i * 30), 'end': float(i * 30 + 25),
             'speaker_id': 0, 'is_user': False}
            for i in range(n_seg)
        ],
    }


class _FakeRollup:
    """替掉 rollup 的 LLM 半边，同时数调用次数。

    `prepare_rollup` 照旧真跑（它不花钱，且 `cache_key` 是被测对象），只把
    `run_rollup` 换成计数器。
    """

    def __init__(self):
        self.calls = 0

    def __call__(self, request, **kwargs):
        if request is None:
            return None
        self.calls += 1
        titles = ' + '.join((f.get('title') or '') for f in request.usable)
        return {'title': f'rolled[{titles}]', 'overview': 'merged', 'emoji': '📊',
                'first_person_observation': '', 'rollup': True}


def _local_prompt(key, fallback, label='production'):
    """`get_prompt` 的离线替身，返回的就是代码里的 fallback。

    必须替掉：`prepare_rollup` 会调 `get_prompt`，而它的解析链是「进程内缓存 → Redis
    → Supabase REST → 代码 fallback」。在本机这三层全部要等网络超时（Redis DNS 失败 +
    Supabase 3s），单测里那是纯噪声 —— 而且它足以让并发用例里的持锁线程在 join 窗口
    内跑不完，把「锁生效」测成「锁没生效」。
    """
    return ResolvedPrompt(key=key, content=fallback.content, config=dict(fallback.config),
                          version=None, label=label, is_fallback=True,
                          fallback_content=fallback.content)


class StoreTestBase(unittest.TestCase):
    def setUp(self):
        self.fake_fs = FakeFirestore()
        real_db = dev_db.db
        dev_db.db = self.fake_fs
        self.addCleanup(setattr, dev_db, 'db', real_db)

        self.redis = FakeRedis()
        self.rollup = _FakeRollup()
        patcher = mock.patch.object(store, 'run_rollup', self.rollup)
        patcher.start()
        self.addCleanup(patcher.stop)
        prompt_patcher = mock.patch.object(rollup_mod, 'get_prompt', _local_prompt)
        prompt_patcher.start()
        self.addCleanup(prompt_patcher.stop)

    def day_docs(self):
        """假 Firestore 里属于 timeline_days 的所有 key —— 用来数「有几份文档」。"""
        return [k for k in self.fake_fs.store if '/timeline_days/' in k]


# ---------------------------------------------------------------- 覆写而非追加


class OverwriteTests(StoreTestBase):
    def test_source_is_rendered_once_per_chapter(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        with mock.patch.object(rollup_mod, 'render_fragments', wraps=rollup_mod.render_fragments) as render:
            recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(render.call_count, 1)

    def test_large_multibyte_projection_cannot_replace_a_stored_day(self):
        db = DayDb([convo('c1', 0)])
        original = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        import copy
        oversized = copy.deepcopy(original)
        oversized['chapters'][0]['overview'] = '汉' * 350000
        with self.assertRaises(dev_db.TimelineDocumentTooLarge):
            db.store_timeline_day(DEV, UID, DAY_STR, oversized)
        self.assertEqual(db.get_timeline_day(DEV, UID, DAY_STR), original)

    def test_nullable_chapters_on_matching_fingerprint(self):
        db = DayDb([])
        original = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        original['chapters'] = None
        db.store_timeline_day(DEV, UID, DAY_STR, original)
        self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'unchanged')

    def test_oversized_day_preserves_cache_without_partial_inference(self):
        db = DayDb([convo('solo', 0)])
        original = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        previous_calls = self.rollup.calls
        db.convos = [convo(f'c{i}', i * 30, n_seg=1, overview='') for i in range(3)]
        for item in db.convos:
            item['transcript_segments'][0]['text'] = 'x' * (rollup_mod.MAX_FRAGMENT_BLOCK_CHARS * 6)
        with self.assertRaises(rollup_mod.RollupBudgetExceeded):
            recompute_day(db, self.redis, DEV, UID, DAY, force=True)
        self.assertEqual(self.rollup.calls, previous_calls)
        self.assertEqual(db.store_calls, 1)
        self.assertEqual(db.get_timeline_day(DEV, UID, DAY_STR), original)

    def test_three_writes_leave_one_document(self):
        """同一天连续重算 3 次 → 只有一份文档（计划 Phase 2 单测第 2 条）。"""
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        for _ in range(3):
            recompute_day(db, self.redis, DEV, UID, DAY, force=True)
        self.assertEqual(len(self.day_docs()), 1, self.day_docs())

    def test_doc_id_is_the_normalized_date(self):
        """doc id 就是日期本身 —— 这是「幂等覆写」得以成立的全部机制。

        换成自动 id（`add()` / uuid）的话，重算就不再是覆写而是新增一份，而症状是
        用户同一天看到两套章节。所以这里断言的是 id 的**取值**，不只是「有一份文档」：
        「只有一份」在自动 id 下第一次跑也是真的。
        """
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        key = self.day_docs()[0]
        self.assertTrue(key.endswith(f'/timeline_days/{DAY_STR}'), key)
        self.assertEqual(self.fake_fs.store[key]['id'], DAY_STR)
        self.assertEqual(self.fake_fs.store[key]['date'], DAY_STR)

    def test_recomputing_a_second_day_does_not_touch_the_first(self):
        """按天隔离：算 8-08 不许动到 8-07 的文档。"""
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        day7 = dict(self.fake_fs.store[f'developer_data/{DEV}/users/{UID}/timeline_days/{DAY_STR}'])

        db.convos = [convo('c9', 0)]
        recompute_day(db, self.redis, DEV, UID, date(2026, 8, 8))
        self.assertEqual(len(self.day_docs()), 2, self.day_docs())
        self.assertEqual(self.fake_fs.store[f'developer_data/{DEV}/users/{UID}/timeline_days/{DAY_STR}'],
                         day7)

    def test_stale_chapter_disappears_instead_of_accumulating(self):
        """章节数从 2 掉到 1 时，多出来那章必须真的消失。

        这是「覆写」这个决定的全部意义。追加/merge 的症状是过时章节与新章节并列，
        用户看到重复卡片，而日志一片正常 —— 没有任何东西会报错。
        """
        # 两条相距 30min > 8min → 2 章
        db = DayDb([convo('c1', 0), convo('c2', 30)])
        first = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(first['chapter_count'], 2)

        # 删掉第二条 → 1 章
        db.convos = [convo('c1', 0)]
        second = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(second['chapter_count'], 1)

        stored = self.fake_fs.store[self.day_docs()[0]]
        self.assertEqual(len(stored['chapters']), 1, '过时章节没被覆写掉')
        self.assertEqual(stored['source_conversation_ids'], ['c1'])

    def test_a_field_from_an_older_document_shape_does_not_survive(self):
        """旧版文档里有、当前写入方不再产出的字段，必须消失。

        `chapters` 是**一个数组字段**，所以 `merge=True` 并不会让章节并列 —— 那个突变
        单靠章节数测不出来（试过，绿的）。merge 真正的后果在**顶层字段**：一次
        schema 变更（改名、去掉某字段）之后，旧字段会永远留在文档里，而下游读到的是
        两代 schema 的混合物。`created_at` 是唯一刻意保留的例外。

        这条也顺带钉住「文档是重建的，不是打补丁的」这个语义 —— 章节是投影，
        投影不该带着上一代的残迹。
        """
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        key = self.day_docs()[0]

        # 模拟上一代 schema 留下的字段
        self.fake_fs.store[key] = {**self.fake_fs.store[key], 'legacy_chapter_titles': ['旧字段']}
        recompute_day(db, self.redis, DEV, UID, DAY, force=True)

        self.assertNotIn('legacy_chapter_titles', self.fake_fs.store[key],
                         '旧 schema 的字段活过了重算 —— 文档是被打补丁而不是重建的')
        self.assertIn('created_at', self.fake_fs.store[key], '`created_at` 是刻意保留的例外')

    def test_created_at_survives_overwrite_but_computed_at_moves(self):
        """首次计算时间要留住，`computed_at` 才能表达「这次重算发生在何时」。"""
        db = DayDb([convo('c1', 0)])
        t1 = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)
        t2 = datetime(2026, 8, 7, 21, 0, tzinfo=timezone.utc)
        first = recompute_day(db, self.redis, DEV, UID, DAY, now=t1)['document']
        second = recompute_day(db, self.redis, DEV, UID, DAY, force=True, now=t2)['document']
        self.assertEqual(first['created_at'], t1)
        self.assertEqual(second['created_at'], t1)
        self.assertEqual(second['computed_at'], t2)

    def test_segment_refs_are_dropped_not_truncated_past_cap(self):
        """超过上限就整体丢掉 refs，不许截半截。

        半截列表会让这天的**后半段**静默无法下钻，而文档看起来是完整的 ——
        Phase 3 的详情页靠 refs 打开原始 transcript。
        """
        cap = dev_db.TIMELINE_DAY_MAX_SEGMENT_REFS
        doc = {
            'date': DAY_STR,
            'chapters': [
                {'start': _BASE, 'end': _BASE, 'segment_refs':
                    [{'conversation_id': 'c1', 'index': i} for i in range(cap // 2 + 10)]},
                {'start': _BASE, 'end': _BASE, 'segment_refs':
                    [{'conversation_id': 'c2', 'index': i} for i in range(cap // 2 + 10)]},
            ],
            'computed_at': _BASE,
        }
        written = dev_db.store_timeline_day(DEV, UID, DAY_STR, doc)
        self.assertTrue(written['segment_refs_dropped'])
        self.assertEqual([ch['segment_refs'] for ch in written['chapters']], [[], []])

    def test_segment_refs_kept_under_cap(self):
        db = DayDb([convo('c1', 0)])
        written = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertFalse(written['segment_refs_dropped'])
        self.assertTrue(written['chapters'][0]['segment_refs'])

    def test_store_does_not_mutate_callers_document(self):
        """`store_timeline_day` 加 id/created_at 时不许改调用方手里的 dict。

        recompute 拿同一个 document 既落库又返回；就地改会让「返回值 == 落库值」
        这件事变成巧合。
        """
        doc = build_day_document(day=DAY_STR, timezone_name='UTC', chapters=[],
                                 fingerprint='fp', computed_at=_BASE)
        snapshot = dict(doc)
        dev_db.store_timeline_day(DEV, UID, DAY_STR, doc)
        self.assertEqual(doc, snapshot)
        self.assertNotIn('id', doc)


# ---------------------------------------------------------------- 指纹


class FingerprintTests(StoreTestBase):
    def test_same_day_same_fingerprint(self):
        convos = [convo('c1', 0), convo('c2', 5)]
        self.assertEqual(compute_fingerprint(convos), compute_fingerprint(list(convos)))

    def test_arrival_order_does_not_change_fingerprint(self):
        """批量转录的落库顺序是调度产物 —— 顺序变了不算数据变了。"""
        convos = [convo('c1', 0), convo('c2', 5), convo('c3', 40)]
        self.assertEqual(compute_fingerprint(convos), compute_fingerprint(list(reversed(convos))))

    def test_algo_version_change_invalidates(self):
        """`ALGO_VERSION` 变更必须触发重算（计划 Phase 2 单测第 1 条）。

        否则阈值改进永远到不了历史数据 —— 这是「章节可重算」这个地基的全部收益。
        """
        convos = [convo('c1', 0)]
        before = compute_fingerprint(convos)
        with mock.patch.object(store, 'ALGO_VERSION', 'seg-99'):
            after = compute_fingerprint(convos)
        self.assertNotEqual(before, after)

    def test_rollup_version_change_invalidates(self):
        convos = [convo('c1', 0)]
        before = compute_fingerprint(convos)
        with mock.patch.object(store, 'ROLLUP_VERSION', 'r99'):
            after = compute_fingerprint(convos)
        self.assertNotEqual(before, after)

    def test_query_version_rebuilds_old_cache_once_without_resummarizing_unchanged_audio(self):
        db = DayDb([convo('c1', 0)])
        with mock.patch.object(store, 'RECORDING_QUERY_VERSION', 'created-at-slack'):
            old = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(old['query_version'], 'created-at-slack')
        result = recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(result['status'], 'computed')
        self.assertEqual(result['document']['query_version'], store.RECORDING_QUERY_VERSION)
        self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'unchanged')

    def test_algo_version_bump_triggers_a_real_recompute(self):
        """端到端：版本一变，`recompute_day` 从 unchanged 翻回 computed。"""
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'unchanged')
        with mock.patch.object(store, 'ALGO_VERSION', 'seg-99'):
            self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'computed')

    def test_updated_at_alone_does_not_invalidate(self):
        """声纹回填 / 确认待办 / 改说话人都会动 `updated_at`，却动不了任何边界。

        含进指纹的后果是这三件事各触发一次全天 LLM 重算，产出与缓存一字不差。
        这条用例就是那个决定本身 —— 把它写成断言，否则「加上 updated_at 更保险」
        看起来永远是对的。
        """
        a = convo('c1', 0)
        b = convo('c1', 0)
        b['updated_at'] = b['updated_at'] + timedelta(hours=3)
        self.assertEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_speaker_reassignment_invalidates_source_attribution(self):
        """Source-grounded summaries now consume speaker identity."""
        a = convo('c1', 0)
        b = convo('c1', 0)
        for seg in b['transcript_segments']:
            seg['is_user'] = True
            seg['person_id'] = 'user'
        self.assertNotEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_edited_transcript_text_invalidates(self):
        """正文是归纳的输入 —— 改了字就必须重算摘要。"""
        a = convo('c1', 0)
        b = convo('c1', 0)
        b['transcript_segments'][1]['text'] = '完全不同的一句话'
        self.assertNotEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_same_length_summary_correction_invalidates(self):
        a = convo('c1', 0, overview='budget 37')
        b = convo('c1', 0, overview='budget 73')
        self.assertNotEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_moved_segment_time_invalidates(self):
        """段的时间是边界的唯一来源。"""
        a = convo('c1', 0)
        b = convo('c1', 0)
        b['transcript_segments'][2]['start'] = 9999.0
        self.assertNotEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_resummarized_conversation_invalidates(self):
        """碎片自己被重新摘要过 → 引用它的章节标题也该变。"""
        a = convo('c1', 0, title='老标题')
        b = convo('c1', 0, title='新标题')
        self.assertNotEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_becoming_discarded_invalidates(self):
        """被判为媒体播放的对话要从章节里消失，所以 discarded 必须在指纹里。"""
        a = convo('c1', 0)
        b = convo('c1', 0)
        b['discarded'] = True
        self.assertNotEqual(compute_fingerprint([a]), compute_fingerprint([b]))

    def test_unchanged_day_makes_no_llm_call_and_no_write(self):
        """App 每次启动都会请求今天 —— 命中缓存必须零 LLM、零写入。"""
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        calls_after_first, writes_after_first = self.rollup.calls, db.store_calls
        self.assertGreaterEqual(calls_after_first, 1)

        result = recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(result['status'], 'unchanged')
        self.assertEqual(self.rollup.calls, calls_after_first)
        self.assertEqual(db.store_calls, writes_after_first)

    def test_force_bypasses_fingerprint(self):
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY, force=True)['status'], 'computed')


# ---------------------------------------------------------------- 逐章复用摘要


class SummaryReuseTests(StoreTestBase):
    def test_strict_rebuild_does_not_overwrite_on_provider_failure(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        writes = db.store_calls
        db.convos[1]['transcript_segments'][0]['text'] = 'new evidence'
        with mock.patch.object(store, 'run_rollup', return_value={'title': 'fallback', 'rollup': 'failed'}):
            with self.assertRaisesRegex(RuntimeError, 'not overwritten'):
                recompute_day(db, self.redis, DEV, UID, DAY, force=True, fail_on_summary_error=True)
        self.assertEqual(db.store_calls, writes)
        self.assertFalse(self.redis.locks)

    def test_failed_rollup_is_retried_on_explicit_recompute(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        with mock.patch.object(store, 'run_rollup', return_value={'title': 'fallback', 'rollup': 'failed'}):
            recompute_day(db, self.redis, DEV, UID, DAY)
        result = recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(result['status'], 'computed')
        self.assertIs(result['document']['chapters'][0]['rollup'], True)

    def test_untouched_chapter_reuses_its_stored_summary(self):
        """晚到一条会话不该让全天重新归纳一遍。

        批量同步天天产生这个形态：一天已经算好，又来一个文件。按天复用做不到这件事，
        必须逐章复用 —— 否则一条晚到数据的代价是整天的 LLM 费用。
        """
        db = DayDb([convo('c1', 0), convo('c2', 5), convo('c3', 60), convo('c4', 65)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(self.rollup.calls, 2)  # 两章各归纳一次

        # 晚到一条并进后一章（65+5=70min，与 c4 相距 5min < 8min）
        db.convos.append(convo('c5', 70))
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(self.rollup.calls, 3, '第一章被重新归纳了 —— 逐章复用失效')

        stored = self.fake_fs.store[self.day_docs()[0]]
        self.assertEqual(stored['chapters'][0]['title'], 'rolled[t + t]')
        self.assertEqual(stored['chapters'][1]['source_conversation_ids'], ['c3', 'c4', 'c5'])

    def test_reuse_requires_matching_rollup_key(self):
        """章节身份没变但归纳输入变了（碎片被重新摘要）→ 必须重新调。

        只按 (start, end, ids) 复用会让「碎片重新摘要过」这件事静默失效。
        """
        db = DayDb([convo('c1', 0, title='A'), convo('c2', 5, title='B')])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(self.rollup.calls, 1)

        db.convos[1]['transcript_segments'][0]['text'] = 'B corrected budget 37'
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(self.rollup.calls, 2)
        stored = self.fake_fs.store[self.day_docs()[0]]
        self.assertEqual(stored['chapters'][0]['title'], 'rolled[A + B]')

    def test_single_conversation_chapter_generates_attribution_once(self):
        """Existing conversation prose has no evidence-linked speaker subjects."""
        db = DayDb([convo('solo', 0, title='独占一章')])
        doc = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(self.rollup.calls, 1)
        self.assertTrue(doc['chapters'][0]['rollup'])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(self.rollup.calls, 1)

    def test_reuse_across_a_prompt_version_change(self):
        """dashboard 上改了 prompt（resolved.version 变）→ 缓存的摘要必须作废。"""
        db = DayDb([convo('c1', 0, title='A'), convo('c2', 5, title='B')])
        chapters = [{'start': _BASE, 'end': _BASE, 'source_conversation_ids': ['c1', 'c2'],
                     'segment_refs': [], 'voice_runs': []}]
        with mock.patch.object(store, 'prepare_rollup') as prep:
            prep.return_value = mock.Mock(usable=[{}, {}], batches=['one'], cache_key='v1:abc')
            first = summarize_chapters(chapters, db.convos)
            self.assertEqual(self.rollup.calls, 1)
            previous = {'chapters': [dict(first[0])]}

            # 同一个 key → 复用
            summarize_chapters(chapters, db.convos, previous=previous)
            self.assertEqual(self.rollup.calls, 1)

            # key 变了（prompt 被改） → 重算
            prep.return_value = mock.Mock(usable=[{}, {}], batches=['one'], cache_key='v2:abc')
            summarize_chapters(chapters, db.convos, previous=previous)
            self.assertEqual(self.rollup.calls, 2)


# ---------------------------------------------------------------- 按天锁


class DayLockTests(StoreTestBase):
    def test_transient_renewal_error_retries_without_discarding_result(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        original = self.redis.renew_owned_lock
        calls = []

        def recover(*args, **kwargs):
            calls.append(1)
            if len(calls) == 1:
                raise ConnectionError('brief interruption')
            return original(*args, **kwargs)

        with mock.patch.object(self.redis, 'renew_owned_lock', side_effect=recover):
            result = recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(result['status'], 'computed')
        self.assertEqual(self.rollup.calls, 1)
        self.assertEqual(db.store_calls, 1)
        self.assertEqual(len(calls), 2)

    def test_lost_lease_cannot_write_or_delete_replacement_owner(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        key = day_lock_key(DEV, UID, DAY_STR)

        def replace_owner(*args, **kwargs):
            self.redis.locks[key] = 'replacement-owner'
            return []

        with mock.patch.object(store, 'summarize_chapters', side_effect=replace_owner):
            with self.assertRaisesRegex(RuntimeError, 'ownership lost'):
                recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(db.store_calls, 0)
        self.assertEqual(self.redis.locks[key], 'replacement-owner')

    def test_heartbeat_renews_during_slow_summary(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        renewed = threading.Event()
        original = self.redis.renew_owned_lock

        def renew(*args, **kwargs):
            renewed.set()
            return original(*args, **kwargs)

        def slow_summary(chapters, *args, **kwargs):
            self.assertTrue(renewed.wait(2), 'No renewal while summarization was still running')
            return chapters

        with mock.patch.object(store, 'LOCK_RENEW_SECONDS', 0.01), \
             mock.patch.object(self.redis, 'renew_owned_lock', side_effect=renew), \
             mock.patch.object(store, 'summarize_chapters', side_effect=slow_summary):
            self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'computed')
        self.assertEqual(db.store_calls, 1)

    def test_query_limit_does_not_overwrite_existing_day(self):
        from utils.timeline.day_query import MAX_FETCH, DayQueryLimitExceeded
        db = DayDb([convo('c1', 0)])
        original = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        db.convos = [convo(str(i), -2000) for i in range(MAX_FETCH)]
        with self.assertRaises(DayQueryLimitExceeded):
            recompute_day(db, self.redis, DEV, UID, DAY, force=True)
        self.assertEqual(db.store_calls, 1)
        self.assertEqual(db.get_timeline_day(DEV, UID, DAY_STR), original)

    def test_key_is_scoped_per_developer_user_and_day(self):
        keys = {
            day_lock_key(DEV, UID, DAY_STR),
            day_lock_key(DEV, UID, '2026-08-08'),
            day_lock_key(DEV, 'other-user', DAY_STR),
            day_lock_key('other-dev', UID, DAY_STR),
        }
        self.assertEqual(len(keys), 4, f'锁 key 撞了：{keys}')

    def test_five_concurrent_recomputes_only_one_executes(self):
        """并行发起 5 个同一天重算：只有 1 个真跑，其余 bail（计划 Phase 2 并发用例）。

        批量同步一次落库几十条同日会话，并发重算会互相覆盖 —— 而且后写的那份可能
        是基于更旧的数据算的。
        """
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        started = threading.Event()
        release = threading.Event()
        real_segment = store.segment_day_into_chapters

        def slow_segment(convos, tz):
            started.set()
            release.wait(5)
            return real_segment(convos, tz)

        statuses = []
        lock = threading.Lock()

        def run():
            with mock.patch.object(store, 'segment_day_into_chapters', slow_segment):
                result = recompute_day(db, self.redis, DEV, UID, DAY, force=True)
            with lock:
                statuses.append(result['status'])

        holder = threading.Thread(target=run)
        holder.start()
        self.assertTrue(started.wait(5), '持锁线程没进到重算')

        others = []
        for _ in range(4):
            t = threading.Thread(target=lambda: statuses.append(
                recompute_day(db, self.redis, DEV, UID, DAY, force=True)['status']))
            t.start()
            others.append(t)
        for t in others:
            t.join(5)

        release.set()
        holder.join(5)

        self.assertEqual(sorted(statuses), ['computed', 'locked', 'locked', 'locked', 'locked'], statuses)
        self.assertEqual(db.store_calls, 1)

    def test_force_still_respects_the_lock(self):
        """两次「下拉刷新」也不许并发进去 —— force 跳过的是指纹，不是锁。"""
        db = DayDb([convo('c1', 0)])
        self.redis.acquire_lock(day_lock_key(DEV, UID, DAY_STR))
        result = recompute_day(db, self.redis, DEV, UID, DAY, force=True)
        self.assertEqual(result['status'], 'locked')
        self.assertEqual(db.store_calls, 0)

    def test_locked_returns_the_stored_document_not_none(self):
        """拿不到锁时返回已有文档 —— 持锁方在算同样的东西，最多旧一轮。"""
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.redis.acquire_lock(day_lock_key(DEV, UID, DAY_STR))
        result = recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(result['status'], 'locked')
        self.assertIsNotNone(result['document'])
        self.assertEqual(result['document']['date'], DAY_STR)

    def test_lock_is_released_even_when_recompute_raises(self):
        """算崩了也得放锁，否则这一天在 TTL 到期前谁都算不了。"""
        db = DayDb([convo('c1', 0)])
        with mock.patch.object(store, 'segment_day_into_chapters', side_effect=RuntimeError('boom')):
            with self.assertRaises(RuntimeError):
                recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertNotIn(day_lock_key(DEV, UID, DAY_STR), self.redis.locks)

    def test_lock_ttl_is_bounded(self):
        """崩掉的持锁方不能永久占着这一天。"""
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(self.redis.acquire_calls[0], day_lock_key(DEV, UID, DAY_STR))
        self.assertGreater(store.LOCK_TTL_SECONDS, 0)
        self.assertLessEqual(store.LOCK_TTL_SECONDS, 900)


# ---------------------------------------------------------------- debounce


class DebounceTests(StoreTestBase):
    def test_window_exceeds_merge_threshold(self):
        """窗口必须 > 合并阈值，否则必然做白工。

        窗口比 8min 短的话：刚算完，一段新语音落在合并间隙内又并进同一章 ——
        刚才那次算出来的章节从来就不是最终形态。这条断言就是那个不变量本身。
        """
        self.assertGreater(DEBOUNCE_MINUTES, GAP_MERGE_MINUTES)

    def test_no_marker_means_nothing_to_do(self):
        self.assertFalse(should_recompute_now(self.redis, DEV, UID, DAY))

    def test_fresh_marker_is_not_due_yet(self):
        now = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)
        mark_day_dirty(self.redis, DEV, UID, DAY, now=now)
        self.assertFalse(should_recompute_now(self.redis, DEV, UID, DAY,
                                              now=now + timedelta(minutes=DEBOUNCE_MINUTES - 1)))

    def test_marker_past_the_window_is_due(self):
        now = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)
        mark_day_dirty(self.redis, DEV, UID, DAY, now=now)
        self.assertTrue(should_recompute_now(self.redis, DEV, UID, DAY,
                                             now=now + timedelta(minutes=DEBOUNCE_MINUTES)))

    def test_marker_keeps_the_first_dirty_time_not_the_latest(self):
        """480 个文件的批量同步不许把到期时间永远往后推。

        每次写都刷新时间戳的话，只要还有文件在落，这天就永远不到期 —— 用户同步完
        8 小时录音，章节一次都没重算。这是「记第一次」这个决定的理由。
        """
        first = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)
        mark_day_dirty(self.redis, DEV, UID, DAY, now=first)
        for i in range(1, 60):
            mark_day_dirty(self.redis, DEV, UID, DAY, now=first + timedelta(seconds=i * 10))
        stamp = self.redis.cache[dirty_marker_key(DEV, UID, DAY_STR)]['dirty_since']
        self.assertEqual(stamp, first.isoformat())
        self.assertTrue(should_recompute_now(self.redis, DEV, UID, DAY,
                                             now=first + timedelta(minutes=DEBOUNCE_MINUTES)))

    def test_unparseable_marker_is_treated_as_due(self):
        """读不出来的 marker 说明这天脏了但不知道多久 —— 宁可多算一次。

        多算的代价被指纹挡住（status=unchanged，零 LLM）；漏算的代价是用户永远
        看到旧章节。
        """
        self.redis.cache[dirty_marker_key(DEV, UID, DAY_STR)] = {'dirty_since': 'not-a-timestamp'}
        self.assertTrue(should_recompute_now(self.redis, DEV, UID, DAY))

    def test_recompute_clears_the_marker(self):
        mark_day_dirty(self.redis, DEV, UID, DAY)
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertNotIn(dirty_marker_key(DEV, UID, DAY_STR), self.redis.cache)

    def test_unchanged_recompute_also_clears_the_marker(self):
        """指纹没变也要清 marker，否则之后每次触发都重跑同一次比对。"""
        db = DayDb([convo('c1', 0)])
        recompute_day(db, self.redis, DEV, UID, DAY)
        mark_day_dirty(self.redis, DEV, UID, DAY)
        self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'unchanged')
        self.assertNotIn(dirty_marker_key(DEV, UID, DAY_STR), self.redis.cache)

    def test_marker_ttl_outlives_the_window(self):
        """marker 活得比窗口久，否则它会在到期前先过期 —— 这天永远不重算。"""
        self.assertGreater(store.DIRTY_TTL_SECONDS, DEBOUNCE_MINUTES * 60)

    def test_marking_never_raises_when_redis_is_down(self):
        """标记失败不许拖垮对话处理 —— 章节缓存是对话之上的便利。"""
        with mock.patch.object(store, 'mark_day_dirty', side_effect=RuntimeError('redis down')):
            store.mark_conversation_day_dirty(DEV, UID, _BASE)  # 不抛就算过

    def test_marking_attributes_by_local_day(self):
        """跨夜按 `started_at` 的本地日归属，和 `filter_convos_for_local_day` 一致。"""
        started = datetime(2026, 8, 7, 16, 30, tzinfo=timezone.utc)  # UTC+8 → 8-08 00:30
        with mock.patch.object(dev_db, 'get_user_timezone', return_value='Asia/Shanghai'), \
             mock.patch('database.redis_db.r', None), \
             mock.patch('database.redis_db.get_generic_cache', self.redis.get_generic_cache), \
             mock.patch('database.redis_db.set_generic_cache', self.redis.set_generic_cache):
            store.mark_conversation_day_dirty(DEV, UID, started)
        self.assertIn(dirty_marker_key(DEV, UID, '2026-08-08'), self.redis.cache)

    def test_marking_ignores_a_missing_started_at(self):
        with mock.patch.object(dev_db, 'get_user_timezone', return_value='UTC'):
            store.mark_conversation_day_dirty(DEV, UID, None)
        self.assertEqual(self.redis.cache, {})


# ---------------------------------------------------------------- 幂等


class IdempotencyTests(StoreTestBase):
    def test_two_forced_recomputes_are_byte_identical_apart_from_computed_at(self):
        """强制重算两次：除 `computed_at` 外逐字节相同（计划 Phase 2「幂等真跑」的可回归版）。

        这是整个缓存能安全覆写的前提。真数据那一跑（见文末 real-run 脚本）验的是
        同一件事，但那次跑完就没了。
        """
        db = DayDb([convo('c1', 0), convo('c2', 5), convo('c3', 40)])
        t = datetime(2026, 8, 7, 20, 0, tzinfo=timezone.utc)
        first = recompute_day(db, self.redis, DEV, UID, DAY, force=True, now=t)['document']
        second = recompute_day(db, self.redis, DEV, UID, DAY, force=True,
                               now=t + timedelta(hours=1))['document']

        volatile = {'computed_at'}
        self.assertEqual({k: v for k, v in first.items() if k not in volatile},
                         {k: v for k, v in second.items() if k not in volatile})
        self.assertNotEqual(first['computed_at'], second['computed_at'])

    def test_ten_runs_produce_the_same_fingerprint(self):
        db = DayDb([convo('c1', 0), convo('c2', 5)])
        prints = set()
        for _ in range(10):
            prints.add(recompute_day(db, self.redis, DEV, UID, DAY, force=True)['document']['fingerprint'])
        self.assertEqual(len(prints), 1)

    def test_document_records_both_versions(self):
        """文档自带版本号：不然「这份缓存是哪版算法算的」无从判断。"""
        db = DayDb([convo('c1', 0)])
        doc = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(doc['algo_version'], ALGO_VERSION)
        self.assertEqual(doc['rollup_version'], ROLLUP_VERSION)

    def test_empty_day_stores_an_empty_document_not_nothing(self):
        """空的一天也要落一份文档 —— 否则每次请求都算成「冷启动」再算一遍。"""
        db = DayDb([])
        result = recompute_day(db, self.redis, DEV, UID, DAY)
        self.assertEqual(result['status'], 'computed')
        self.assertEqual(result['document']['chapters'], [])
        self.assertEqual(len(self.day_docs()), 1)
        self.assertEqual(recompute_day(db, self.redis, DEV, UID, DAY)['status'], 'unchanged')

    def test_late_arriving_conversation_updates_the_day(self):
        """补一条 `started_at` 在过去的会话，重算后该天章节合理更新（计划「晚到数据」）。"""
        db = DayDb([convo('c2', 60)])
        first = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(first['source_conversation_ids'], ['c2'])

        db.convos.insert(0, convo('c1', 0))  # 更早，且相距 60min > 8min → 独立成章
        second = recompute_day(db, self.redis, DEV, UID, DAY)['document']
        self.assertEqual(second['status'] if 'status' in second else 'computed', 'computed')
        self.assertEqual(second['chapter_count'], 2)
        self.assertEqual(second['source_conversation_ids'], ['c1', 'c2'])
        self.assertLess(second['chapters'][0]['start'], second['chapters'][1]['start'])


# ---------------------------------------------------------------- 调用点存在性


class CallPointTests(unittest.TestCase):
    """四条写入路径都必须自己标记 dirty —— 少一条就是一整类对话的章节永不更新。

    用 AST 而不是 import：`developer_listen` 依赖 opuslib/deepgram 等原生包，本地
    venv 常装不全，import 断言会退化成环境问题而不是回归信号（照
    `test_realtime_memory_extraction.py` 的做法）。

    这类缺陷的先例就在本仓库：`extract_memories_from_segments` 与
    `new_memories_extractor` 各自都对，但没有任何实时路径调用它们，生产上
    `source='app'` 的 2900+ 条录音记忆产出为 0，持续了整整一个发布周期。
    """

    def _source_of(self, rel_path, func_name):
        with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as fh:
            src = fh.read()
        tree = ast.parse(src)
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
                return ast.get_source_segment(src, node)
        raise AssertionError(f'{rel_path} 里找不到函数 {func_name}')

    def test_process_conversation_developer_marks(self):
        """音频上传 / SD 卡同步 / reprocess 都走这里。"""
        body = self._source_of('utils/conversations/process_conversation.py',
                               'process_conversation_developer')
        self.assertIn('_mark_timeline_day_dirty(', body)

    def test_app_process_endpoint_marks(self):
        """POST /v1/conversations/process —— App 主动处理。"""
        body = self._source_of('routers/developer_conversations.py', '_do_process_conversation')
        self.assertIn('mark_timeline_day_dirty(', body)

    def test_listen_auto_process_marks(self):
        """静音 120s 切分 / WS 断开兜底建出的对话。"""
        body = self._source_of('routers/developer_listen.py', '_auto_process_conversation')
        self.assertIn('mark_timeline_day_dirty(', body)

    def test_finish_endpoint_marks(self):
        """`/finish` 由调用方直接给 title/overview —— 那正是归纳要引用的东西。"""
        body = self._source_of('routers/developer_conversations.py', 'finish_conversation')
        self.assertIn('mark_timeline_day_dirty(', body)

    def test_delete_reads_started_at_before_deleting(self):
        """删除路径必须先读后删。

        `started_at` 是「该重算哪天」的唯一依据，删完就没了。漏标的后果是被删掉的
        对话继续留在缓存的章节里 —— 用户删了却还看得见。
        """
        body = self._source_of('routers/developer_conversations.py', 'delete_conversation')
        get_pos = body.find('dev_db.get_conversation(')
        del_pos = body.find('dev_db.delete_conversation(')
        self.assertGreater(get_pos, -1, '删除前没有读取对话')
        self.assertGreater(del_pos, -1)
        self.assertLess(get_pos, del_pos, '读取发生在删除之后 —— started_at 已经没了')
        self.assertIn('mark_timeline_day_dirty(', body)

    def test_mark_helper_never_raises(self):
        """两个包装器都必须 try/except 全吞。"""
        for path, name in (('routers/developer_conversations.py', 'mark_timeline_day_dirty'),
                           ('utils/conversations/process_conversation.py', '_mark_timeline_day_dirty')):
            with self.subTest(path=path):
                body = self._source_of(path, name)
                self.assertIn('try:', body)
                self.assertIn('except Exception', body)

    def test_lock_key_is_spelled_in_exactly_one_place(self):
        """`timeline_day:` 前缀只许出现在 `day_lock_key` 里。

        两处拼装同一把锁 = 两把锁，而且失败是静默的：双方都以为自己独占。
        `listen_session_lock_key` 就是为这个存在的。
        """
        hits = []
        for root, _dirs, files in os.walk(BACKEND_DIR):
            # `tests/` 放过：测试当然要提这个前缀（本文件就在提）。风险在于**生产代码**
            # 里第二处拼装。
            if any(part in root for part in ('/venv', '/.git', '/node_modules',
                                             '__pycache__', '/tests')):
                continue
            for name in files:
                if not name.endswith('.py'):
                    continue
                path = os.path.join(root, name)
                with open(path, encoding='utf-8', errors='ignore') as fh:
                    for lineno, line in enumerate(fh, start=1):
                        if "'timeline_day:" in line or '"timeline_day:' in line:
                            hits.append((os.path.relpath(path, BACKEND_DIR), lineno))
        self.assertEqual([h[0] for h in hits], ['utils/timeline/store.py'], hits)


if __name__ == '__main__':
    unittest.main(verbosity=2)
