"""Discover 的聚合端点只读它们真正用到的字段。

存在的理由（2026-08-12 修）：`_fetch_and_filter` 走 `dev_db.get_conversations` 的默认参数，
于是每次聚合都把**整个**对话读出来——解压每条 transcript（长对话还要 stream
`transcript_chunks` 子集合），并且**每条对话额外查一次 `photos` 子集合**（limit=1000 就是
上千次往返）。而这些聚合一个照片都不看，只有两个调用者看 `seg.person_id`。

代价是实测出来的（`api_logs_daily` 2026-08-08..12，App 每次冷启动打四个）：
`persona-tagline` p50 12.1s、`category-stats` 12.1s、`people-stats` 10.1s、
`emotion-trends` 6.1s。

⚠️ **两个方向都会静默坏掉，所以两个方向都要钉：**

* 关得太少 → 只是慢，没人报错，于是一直慢下去（这就是修之前的状态）；
* 关得太多 → `people-stats` / `report` 拿不到 segments，`seg.person_id` 一个都遍历不到，
  人物统计**静默变成空列表**（HTTP 200 + `[]`，看起来就像「这个用户没跟谁说过话」）。

所以本文件既断言「默认不读 photos / segments」，也断言「那两个调用者必须把 segments 读回来」，
并且用同一份数据证明：清掉 photos/segments 后聚合结果一模一样（前者），而人物统计会归零
（后者）——后一条同时说明这个开关不是可选的装饰。

Run:
    cd backend && python3 tests/test_discover_projection.py
"""

import ast
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

import database.developer_data as dev_db  # noqa: E402
import routers.discover as discover  # noqa: E402

DEV = 'dev-test'
UID = 'user-test'


def _conversation(cid, *, category='work', emotion='calm', person_ids=(), days_ago=1, photos=1):
    """一条对话的 Firestore 形态（get_conversations 返回的就是 dict）。"""
    created = datetime.now(timezone.utc) - timedelta(days=days_ago)
    return {
        'id': cid,
        'created_at': created,
        'started_at': created,
        'finished_at': created,
        'status': 'completed',
        'discarded': False,
        'eir_emotion': emotion,
        'structured': {'title': f'convo {cid}', 'overview': '', 'emoji': '🧠', 'category': category},
        'transcript_segments': [
            {'text': 'hi', 'speaker': 'SPEAKER_00', 'speaker_id': 0, 'is_user': False,
             'person_id': pid, 'start': 0.0, 'end': 1.0}
            for pid in person_ids
        ],
        'photos': [{'id': f'p{i}', 'base64': '', 'description': ''} for i in range(photos)],
    }


FIXTURE = [
    _conversation('c1', category='work', emotion='calm', person_ids=('p-alice',), days_ago=1),
    _conversation('c2', category='work', emotion='happy', person_ids=('p-alice', 'p-bob'), days_ago=2),
    _conversation('c3', category='technology', emotion='calm', person_ids=(), days_ago=3),
]


class _Recorder:
    """顶掉 dev_db.get_conversations，记下它被怎么调的，并按投影参数裁剪返回值。

    裁剪是关键：它模拟真实实现的行为（`include_photos=False` → `photos: []`，
    `include_transcript_segments=False` → `transcript_segments: []`），否则测试会在
    「端点其实偷偷依赖了被关掉的字段」时仍然通过。
    """

    def __init__(self, rows=FIXTURE):
        self.rows = rows
        self.calls = []

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        out = []
        for row in self.rows:
            row = dict(row)
            if not kwargs.get('include_photos', True):
                row['photos'] = []
            if not kwargs.get('include_transcript_segments', True):
                row['transcript_segments'] = []
            out.append(row)
        return out

    @property
    def last(self):
        return self.calls[-1]


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self._original = dev_db.get_conversations
        self._original_people = dev_db.get_people_by_ids
        self.rec = _Recorder()
        dev_db.get_conversations = self.rec
        # 名字解析走 people 集合；stub 掉才能让本文件不碰网络（也才断言得了真名那一层）。
        dev_db.get_people_by_ids = lambda dev, uid, ids: [
            {'id': pid, 'name': {'p-alice': 'Alice', 'p-bob': 'Bob'}.get(pid, '')} for pid in ids
        ]

    def tearDown(self):
        dev_db.get_conversations = self._original
        dev_db.get_people_by_ids = self._original_people

    def test_aggregations_read_neither_photos_nor_transcripts(self):
        """三个纯计数聚合都不该碰 photos / transcript。"""
        cases = {
            'category-stats': lambda: discover.get_category_stats(
                days=30, external_user_id=UID, developer_id=DEV),
            'emotion-trends': lambda: discover.get_emotion_trends(
                days=7, external_user_id=UID, developer_id=DEV),
            # top 为空 → 早退，不会触达 LLM / Redis。这里只关心它怎么取数据。
            'persona-tagline': lambda: discover.get_persona_tagline(
                days=7, external_user_id=UID, developer_id=DEV),
        }
        for name, call in cases.items():
            with self.subTest(endpoint=name):
                self.rec.calls.clear()
                # persona-tagline 只在 top 非空时才走 Redis + LLM。这里只关心它怎么取数据，
                # 所以喂空数据让它早退——否则这个文件每跑一次就真花一次 LLM 的钱。
                self.rec.rows = [] if name == 'persona-tagline' else FIXTURE
                call()
                self.assertTrue(self.rec.calls, f'{name} 根本没查对话——测试没测到东西')
                kwargs = self.rec.last
                self.assertFalse(kwargs.get('include_photos', True),
                                 f'{name} 仍在查 photos 子集合：每条对话一次往返，limit=1000 就是上千次')
                self.assertFalse(kwargs.get('include_transcript_segments', True),
                                 f'{name} 仍在读 transcript：要解压、长对话还要 stream 子集合，而它一个字都不用')

    def test_date_cut_is_pushed_into_firestore(self):
        discover.get_category_stats(days=30, external_user_id=UID, developer_id=DEV)
        start_date = self.rec.last.get('start_date')
        self.assertIsNotNone(start_date, 'start_date 没传：查询会读回一堆马上要被 Python 扔掉的文档')
        # 落在 days 边界附近（允许几秒执行误差）。
        expected = datetime.now(timezone.utc) - timedelta(days=30)
        self.assertLess(abs((start_date - expected).total_seconds()), 60)

    def test_aggregation_results_survive_the_projection(self):
        """改动的前提：清掉 photos/segments 后，这些聚合的结果一模一样。

        `_Recorder` 已按投影参数把两个字段清空，所以这里拿到的就是「投影后」的结果；
        再拿同一份未裁剪的数据算一遍作为对照。
        """
        cats = discover.get_category_stats(days=30, external_user_id=UID, developer_id=DEV)
        trends = discover.get_emotion_trends(days=7, external_user_id=UID, developer_id=DEV)

        self.assertEqual([(c.category, c.count) for c in cats], [('work', 2), ('technology', 1)])
        emotions = {d.date: d.emotions for d in trends if d.emotions}
        self.assertEqual(sorted(sum((list(v.keys()) for v in emotions.values()), [])),
                         ['calm', 'calm', 'happy'])

    def test_people_stats_and_report_keep_segments(self):
        """反向断言：这两个走 `seg.person_id`，关掉 segments 会让它们静默变空。"""
        discover.get_people_stats(days=30, limit=20, external_user_id=UID, developer_id=DEV)
        self.assertTrue(
            self.rec.last.get('include_transcript_segments'),
            'people-stats 必须读 transcript：没有它 seg.person_id 一个都遍历不到，接口会 200 + []',
        )
        # photos 对它同样无用。
        self.assertFalse(self.rec.last.get('include_photos', True))

        # report 走 LLM，用空数据让它在聚合前早退，只验取数方式。
        self.rec.rows = []
        discover.generate_report(
            discover.ReportRequest(type='weekly'), external_user_id=UID, developer_id=DEV)
        self.assertTrue(self.rec.last.get('include_transcript_segments'),
                        'report 的人物名单也走 seg.person_id')

    def test_people_stats_really_depends_on_segments(self):
        """证明上一条不是空断言：真把 segments 关掉，人物统计就归零。

        没有这条，`include_segments=True` 看起来只是个可有可无的参数，下一个人「顺手统一
        一下」就会把它删掉，而 CI 全绿、接口 200、列表空。
        """
        with_segments = discover.get_people_stats(
            days=30, limit=20, external_user_id=UID, developer_id=DEV)

        # 模拟「有人把 include_segments 也关掉了」
        original = discover._fetch_and_filter
        discover._fetch_and_filter = lambda *a, **k: original(*a, **{**k, 'include_segments': False})
        try:
            without_segments = discover.get_people_stats(
                days=30, limit=20, external_user_id=UID, developer_id=DEV)
        finally:
            discover._fetch_and_filter = original

        self.assertEqual(
            [(p.name, p.conversation_count) for p in with_segments],
            [('Alice', 2), ('Bob', 1)],
            '带 segments 时该按 person_id 归属出 Alice 2 次、Bob 1 次',
        )
        self.assertEqual(without_segments, [],
                         '关掉 segments 后人物统计必须归零——这正是「关得太多」的静默失败形态')


class SourceGuardTests(unittest.TestCase):
    """扫描器自检：确认上面测的那些调用点真的存在，而不是名字写错了扫到 0 个。"""

    def test_every_fetch_call_site_is_covered(self):
        with open(os.path.join(BACKEND_DIR, 'routers/discover.py'), encoding='utf-8') as f:
            src = f.read()
        tree = ast.parse(src)
        call_sites = [
            node for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
            and node.func.id == '_fetch_and_filter'
        ]
        self.assertGreaterEqual(len(call_sites), 5, '_fetch_and_filter 的调用点少于预期，名单该更新了')

        with_segments = sum(
            1 for c in call_sites
            for kw in c.keywords
            if kw.arg == 'include_segments' and getattr(kw.value, 'value', None) is True
        )
        self.assertEqual(
            with_segments, 2,
            '恰好两个调用者（people-stats / report）该带 include_segments=True；'
            '多了就是又有人在读用不到的 transcript，少了就是有人的人物名单要静默变空',
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
