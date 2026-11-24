"""影子端点冒烟：真起 ASGI app、真打 HTTP、断言结构，并钉住「现有端点一字未变」。

计划 §1.5 C 要求的就是这件事。为什么不能只靠前面几个单测：那些测的是纯函数，
而端点上还叠了三层单测碰不到的东西 —— 依赖注入（`get_developer_id_from_api_key`）、
FastAPI 的响应序列化、以及 router 是否真的挂进了 `main.app`。少任何一层,
`/v1/timeline/{date}` 就是 404 或 500,而 49 个单测照样全绿。

**为什么用 TestClient 而不是 uvicorn + curl**：结论一样但可回归。uvicorn+curl 也真跑过
（2026-08-08，真 key 打真数据：12 张卡 → 8 章，与离线对照脚本同日结果一致；
`summarize=true` 时 3 次归纳 0 失败、5 章零 LLM 调用、8 个 emoji 全部合法），但那次跑完
就没了。下次有人给端点加 `response_model`（本代码库反复踩的坑）不会有任何东西报警。
这里把「不许有 response_model」直接写成断言。

鉴权整条链路 mock 掉：`dependency_overrides` 换掉 developer_id，`dev_db` 的取数与
`summarize_chapter` 也替成假的 —— 冒烟要验的是**接线**，不是 Firestore 和 LLM。

Run:
    cd backend && GOOGLE_APPLICATION_CREDENTIALS=/tmp/memorion-sa.json \
        python3 tests/test_timeline_endpoint_smoke.py
"""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402
from dependencies import get_developer_id_from_api_key  # noqa: E402
from routers import timeline as timeline_router  # noqa: E402

DEV_ID = 'dev-smoke'
UID = 'user-smoke'
DAY = '2026-08-07'

# 两条会话,段级 gap 3min < 8min 阈值 → 必须合成一章。这样冒烟同时验了
# 「合并真的发生了」,而不只是「端点返回 200」。
_BASE = datetime(2026, 8, 7, 13, 0, tzinfo=timezone.utc)


def _convo(cid, offset_min, n_seg=3, title='t'):
    started = _BASE + timedelta(minutes=offset_min)
    return {
        'id': cid,
        'source': 'app',
        'discarded': False,
        'started_at': started,
        'finished_at': started + timedelta(seconds=n_seg * 30),
        'structured': {'title': title, 'overview': f'overview of {cid}', 'emoji': '🧠',
                       'first_person_observation': ''},
        'transcript_segments': [
            {'text': f'{cid} sentence {i}', 'start': float(i * 30), 'end': float(i * 30 + 25),
             'speaker_id': 0, 'is_user': False}
            for i in range(n_seg)
        ],
    }


CONVOS = [_convo('c1', 0, title='第一段'), _convo('c2', 5, title='第二段')]


class TimelineEndpointSmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        main.app.dependency_overrides[get_developer_id_from_api_key] = lambda: DEV_ID
        cls.client = TestClient(main.app)

    @classmethod
    def tearDownClass(cls):
        main.app.dependency_overrides.clear()

    def _get(self, params=None, convos=None):
        params = {'external_user_id': UID, 'summarize': 'false', **(params or {})}
        with mock.patch.object(timeline_router.dev_db, 'get_user_timezone', return_value='Asia/Shanghai'), \
             mock.patch.object(timeline_router, 'get_day_conversations',
                               return_value=CONVOS if convos is None else convos):
            return self.client.get(f'/v1/timeline/{DAY}', params=params)

    def test_router_is_registered(self):
        """挂进 main.app 了 —— 忘了 include_router 时单测全绿但端点 404。"""
        paths = {getattr(r, 'path', '') for r in main.app.routes}
        self.assertIn('/v1/timeline/{date}', paths)

    def test_no_response_model_on_the_route(self):
        """刻意不声明 response_model：FastAPI 会静默丢掉未声明字段。

        这是本代码库反复踩过的坑（见 `developer_conversations.py` 的注释）。影子端点
        存在的意义就是把新旧对照的每个字段都吐出来,加了 response_model 就等于
        一边比对一边悄悄删字段。所以写成断言而不是注释。
        """
        route = next(r for r in main.app.routes if getattr(r, 'path', '') == '/v1/timeline/{date}')
        self.assertIsNone(getattr(route, 'response_model', None))

    def test_200_and_shape(self):
        resp = self._get()
        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        for key in ('date', 'timezone', 'mode', 'current_card_count', 'chapter_count',
                    'current', 'chapters'):
            self.assertIn(key, body)
        self.assertEqual(body['date'], DAY)
        self.assertEqual(body['timezone'], 'Asia/Shanghai')
        self.assertEqual(body['current_card_count'], 2)

    def test_merges_two_conversations_into_one_chapter(self):
        """gap=3min < 8min → 一章。端点上也要看到合并,不然只是纯函数自己对。"""
        body = self._get().json()
        self.assertEqual(body['chapter_count'], 1)
        self.assertEqual(body['chapters'][0]['source_conversation_ids'], ['c1', 'c2'])

    def test_summarize_false_makes_no_llm_call(self):
        """`summarize=false` 是「只看边界」的便宜路径,一次 LLM 都不许调。"""
        with mock.patch.object(timeline_router, 'summarize_chapter') as sc:
            resp = self._get()
            sc.assert_not_called()
        self.assertEqual(resp.status_code, 200)
        self.assertNotIn('title', resp.json()['chapters'][0])

    def test_summarize_true_presents_rollup_fields(self):
        fake = {'title': '合并标题', 'overview': 'ov', 'emoji': '📊',
                'first_person_observation': '', 'rollup': True}
        with mock.patch.object(timeline_router, 'summarize_chapter', return_value=fake) as sc:
            body = self._get(params={'summarize': 'true'}).json()
            sc.assert_called_once()
        ch = body['chapters'][0]
        self.assertEqual(ch['title'], '合并标题')
        self.assertEqual(ch['emoji'], '📊')
        self.assertTrue(ch['rollup'])
        # segment_refs 必须出现在响应里：Phase 3 的详情页要靠它下钻到原始 transcript,
        # 而它是 dict 列表,正是 response_model 最容易吞掉的形状。
        self.assertTrue(ch['segment_refs'])

    def test_junk_date_is_400_not_500(self):
        with mock.patch.object(timeline_router.dev_db, 'get_user_timezone', return_value='UTC'):
            bad = self.client.get('/v1/timeline/not-a-date', params={'external_user_id': UID})
        self.assertEqual(bad.status_code, 400, bad.text)

    def test_date_is_echoed_normalized(self):
        """`2026-8-7` 也能过 strptime,但回显必须是 `2026-08-07`。

        Phase 2 要用这个字符串当 Firestore doc id（`timeline_days/{YYYY-MM-DD}`）。
        原样回显调用方的写法 → 同一天两份文档,而「幂等覆写」是整个方案的地基。
        """
        with mock.patch.object(timeline_router.dev_db, 'get_user_timezone', return_value='Asia/Shanghai'), \
             mock.patch.object(timeline_router, 'get_day_conversations', return_value=[]):
            resp = self.client.get('/v1/timeline/2026-8-7', params={'external_user_id': UID})
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()['date'], '2026-08-07')

    def test_missing_external_user_id_is_422(self):
        resp = self.client.get(f'/v1/timeline/{DAY}')
        self.assertEqual(resp.status_code, 422)

    def test_empty_day_returns_empty_lists(self):
        body = self._get(convos=[]).json()
        self.assertEqual(body['chapter_count'], 0)
        self.assertEqual(body['current'], [])

    def test_datetimes_are_iso_strings(self):
        """端点自己做 isoformat（返回 dict,没有 response_model 帮忙序列化）。"""
        ch = self._get().json()['chapters'][0]
        self.assertIsInstance(ch['start'], str)
        self.assertIn('T', ch['start'])


class ChaptersEndpointSmokeTests(unittest.TestCase):
    """`GET /v1/timeline/{date}/chapters` —— Phase 2 真正要上线给 App 的那个端点。

    与影子端点的区别就是它**有缓存**，所以冒烟要验的不是「算得对」（那是
    `test_timeline_store.py` 的事），而是三件只有在端点层才成立的事：

    1. 缓存命中时**不重算**。App 每次启动都会打这个端点,重算就是每次启动烧一遍 LLM。
    2. `refresh=true` 绕过 debounce 窗口（下拉刷新）。
    3. 响应里没有裸 datetime。返回 dict 没有 response_model 帮忙序列化,
       Firestore 递给的是 `DatetimeWithNanoseconds`,漏一处 App 侧就是 JSON 解析失败。
    """

    @classmethod
    def setUpClass(cls):
        main.app.dependency_overrides[get_developer_id_from_api_key] = lambda: DEV_ID
        cls.client = TestClient(main.app)

    @classmethod
    def tearDownClass(cls):
        main.app.dependency_overrides.clear()

    def setUp(self):
        patcher = mock.patch.object(timeline_router.edits_db, 'get_chapter_edits', return_value={})
        patcher.start()
        self.addCleanup(patcher.stop)
        tz_patcher = mock.patch.object(timeline_router.dev_db, 'get_user_timezone', return_value='Asia/Shanghai')
        tz_patcher.start()
        self.addCleanup(tz_patcher.stop)

    def _doc(self, computed_at=None):
        return {
            'id': DAY, 'date': DAY, 'timezone': 'Asia/Shanghai',
            'chapter_count': 1, 'source_conversation_ids': ['c1', 'c2'],
            'algo_version': timeline_router.ALGO_VERSION, 'rollup_version': timeline_router.ROLLUP_VERSION, 'fingerprint': 'fp',
            'model_config_version': timeline_router.MODEL_CONFIG_VERSION,
            'summary_fingerprint': timeline_router.resolve_summary_dependencies().fingerprint,
            'query_version': timeline_router.RECORDING_QUERY_VERSION,
            'computed_at': computed_at or _BASE, 'created_at': _BASE,
            'segment_refs_dropped': False,
            'chapters': [{
                'start': _BASE, 'end': _BASE + timedelta(minutes=8),
                'duration_seconds': 480.0, 'speech_seconds': 150.0,
                'source_conversation_ids': ['c1', 'c2'],
                'segment_refs': [{'conversation_id': 'c1', 'index': 0}],
                'voice_runs': [{'start': _BASE, 'end': _BASE + timedelta(minutes=2)}],
                'title': '合并标题', 'overview': 'ov', 'emoji': '📊',
                'first_person_observation': '', 'rollup': True, 'rollup_key': 'r1:fallback:abc',
            }],
        }

    def test_route_is_registered_without_response_model(self):
        route = next((r for r in main.app.routes
                      if getattr(r, 'path', '') == '/v1/timeline/{date}/chapters'), None)
        self.assertIsNotNone(route, '/chapters 没挂进 main.app')
        self.assertIsNone(getattr(route, 'response_model', None))

    def test_cache_hit_serves_without_recomputing(self):
        """已有缓存且不脏 → 直接返回,一次重算都不许发起。"""
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=self._doc()), \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=False), \
             mock.patch.object(timeline_router, 'recompute_day') as rc:
            resp = self.client.get(f'/v1/timeline/{DAY}/chapters', params={'external_user_id': UID})
            rc.assert_not_called()
        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        self.assertEqual(body['cache'], 'hit')
        self.assertEqual(body['chapters'][0]['title'], '合并标题')

    def test_cold_day_recomputes(self):
        """没算过 → 直接算。用户正在看这天,没有更便宜的答案可给。"""
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=None), \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'computed', 'document': self._doc()}) as rc:
            body = self.client.get(f'/v1/timeline/{DAY}/chapters',
                                   params={'external_user_id': UID}).json()
            rc.assert_called_once()
        self.assertEqual(body['cache'], 'computed')
        self.assertEqual(body['cache_reason'], 'cold')

    def test_dirty_inside_the_window_is_served_stale(self):
        """脏但没过 debounce 窗口 → 刻意返回旧的。

        窗口内重算是必然做白工：新语音还能落在 8min 合并间隙里并进同一章。
        """
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=self._doc()), \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=False), \
             mock.patch.object(timeline_router, 'recompute_day') as rc:
            body = self.client.get(f'/v1/timeline/{DAY}/chapters',
                                   params={'external_user_id': UID}).json()
            rc.assert_not_called()
        self.assertEqual(body['cache'], 'hit')

    def test_dirty_past_the_window_recomputes(self):
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=self._doc()), \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=True), \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'computed', 'document': self._doc()}) as rc:
            body = self.client.get(f'/v1/timeline/{DAY}/chapters',
                                   params={'external_user_id': UID}).json()
            rc.assert_called_once()
        self.assertEqual(body['cache_reason'], 'dirty')

    def test_refresh_bypasses_the_debounce_window(self):
        """下拉刷新：即使窗口没到也要算 —— 但 `should_recompute_now` 根本不该被问。"""
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=self._doc()), \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=False) as srn, \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'unchanged', 'document': self._doc()}) as rc:
            body = self.client.get(f'/v1/timeline/{DAY}/chapters',
                                   params={'external_user_id': UID, 'refresh': 'true'}).json()
            rc.assert_called_once()
            srn.assert_not_called()
        self.assertEqual(body['cache_reason'], 'refresh')

    def test_refresh_does_not_force_past_the_fingerprint(self):
        """`refresh` 绕过的是窗口,不是指纹 —— 否则连点两下刷新就是两次全天 LLM。"""
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=self._doc()), \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'unchanged', 'document': self._doc()}) as rc:
            self.client.get(f'/v1/timeline/{DAY}/chapters',
                            params={'external_user_id': UID, 'refresh': 'true'})
        self.assertIs(rc.call_args.kwargs.get('force'), False, rc.call_args)

    def test_locked_with_no_stored_doc_falls_back_to_the_cached_one(self):
        """并发首算时拿不到锁 → 返回手里那份,不许返回空章节列表。"""
        cached = self._doc()
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=cached), \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=True), \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'locked', 'document': None}):
            body = self.client.get(f'/v1/timeline/{DAY}/chapters',
                                   params={'external_user_id': UID}).json()
        self.assertEqual(body['cache'], 'locked')
        self.assertEqual(len(body['chapters']), 1)

    def test_never_computed_and_locked_returns_empty_not_500(self):
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=None), \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'locked', 'document': None}):
            resp = self.client.get(f'/v1/timeline/{DAY}/chapters', params={'external_user_id': UID})
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(resp.json()['chapters'], [])

    def test_no_raw_datetime_survives_serialization(self):
        """响应里任何深度都不许有裸 datetime —— 含 `chapters[].voice_runs[]` 里那两个。

        Firestore 递回来的是 `DatetimeWithNanoseconds`。**这条不是在测 handler 里的
        手工转换**：FastAPI 的 `jsonable_encoder` 本来就递归到任意深度,连这个子类
        也认，所以 handler 刻意不自己走一遍（见 `_serialize_day` 的注释 —— 手工版
        只够到顶层，多一层嵌套就要多一个特例，而漏了也看不出来，因为编码器兜住了）。

        它钉的是**别绕过编码器**：有人给路由加 `response_model`、或改成手搓
        `json.dumps` / `JSONResponse(content=...)` 时,这里必红。症状否则是
        App 侧 JSON 解析失败 —— 后端 200,前端白屏。
        """
        from google.api_core.datetime_helpers import DatetimeWithNanoseconds

        doc = self._doc(computed_at=DatetimeWithNanoseconds(2026, 8, 7, 13, 0, tzinfo=timezone.utc))
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=doc), \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=False):
            body = self.client.get(f'/v1/timeline/{DAY}/chapters',
                                   params={'external_user_id': UID}).json()

        # 断 ISO 形态而不只是 `isinstance(str)`：`str(datetime)` 也是 str,但它用空格
        # 分隔日期与时间,Dart 的 `DateTime.parse` 对它直接抛。所以要求那个 'T'。
        def _assert_iso(value, where):
            self.assertIsInstance(value, str, f'{where} 没序列化')
            self.assertIn('T', value, f'{where} 不是 ISO 形态: {value!r}')
            datetime.fromisoformat(value)

        ch = body['chapters'][0]
        for field in ('start', 'end'):
            _assert_iso(ch[field], f'chapters[0].{field}')
        for idx, run in enumerate(ch['voice_runs']):
            _assert_iso(run['start'], f'voice_runs[{idx}].start')
            _assert_iso(run['end'], f'voice_runs[{idx}].end')
        _assert_iso(body['computed_at'], 'computed_at')

    def test_date_is_normalized_before_it_becomes_a_doc_id(self):
        """`2026-8-7` 也能过 strptime —— 传给 Firestore 的必须是 `2026-08-07`。

        原样透传 = 同一天两份文档,而幂等覆写是整个缓存的地基。这条和影子端点那条
        测的是同一个不变量,但只有这一条上真的会写文档。
        """
        seen = {}

        def _record(dev, uid, day_str):
            seen['day'] = day_str
            return None  # 冷启动：让它走到 recompute,才能顺带验传下去的 `date` 对象

        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', side_effect=_record), \
             mock.patch.object(timeline_router, 'recompute_day',
                               return_value={'status': 'computed', 'document': self._doc()}) as rc:
            resp = self.client.get('/v1/timeline/2026-8-7/chapters', params={'external_user_id': UID})
        self.assertEqual(resp.status_code, 200, resp.text)
        self.assertEqual(seen['day'], DAY)
        self.assertEqual(rc.call_args.args[4].isoformat(), DAY)

    def test_junk_date_is_400(self):
        resp = self.client.get('/v1/timeline/nope/chapters', params={'external_user_id': UID})
        self.assertEqual(resp.status_code, 400, resp.text)

    def test_missing_external_user_id_is_422(self):
        self.assertEqual(self.client.get(f'/v1/timeline/{DAY}/chapters').status_code, 422)

    def test_shadow_and_chapters_routes_do_not_shadow_each_other(self):
        """`/{date}` 与 `/{date}/chapters` 都存在,且各自解析到自己的 handler。

        FastAPI 按注册顺序匹配。`/{date}` 先注册,若它的 date 参数吞掉 `xxx/chapters`,
        受害者是新端点,而症状是「返回了影子对照结构」而不是报错。
        """
        by_path = {getattr(r, 'path', ''): r for r in main.app.routes if 'GET' in getattr(r, 'methods', set())}
        self.assertEqual(by_path['/v1/timeline/{date}'].endpoint.__name__, 'get_timeline_shadow')
        self.assertEqual(by_path['/v1/timeline/{date}/chapters'].endpoint.__name__, 'get_day_chapters')

    def test_chapters_route_does_not_write_on_a_cache_hit(self):
        """命中缓存时一次 Firestore 写都不许发生。"""
        with mock.patch.object(timeline_router.dev_db, 'get_timeline_day', return_value=self._doc()), \
             mock.patch.object(timeline_router.dev_db, 'store_timeline_day') as store_fn, \
             mock.patch.object(timeline_router, 'should_recompute_now', return_value=False):
            self.client.get(f'/v1/timeline/{DAY}/chapters', params={'external_user_id': UID})
            store_fn.assert_not_called()


class ExistingEndpointsUnchangedTests(unittest.TestCase):
    """「确认现有 `/v1/conversations` 行为一字未变」—— 计划 §1.5 C 的原话。

    章节化是只读投影,理论上碰不到现有端点。但 `main.py` 加了一行 import 和一行
    `include_router`,而 FastAPI 是**按注册顺序**匹配路由的：新 router 若与既有路径
    形状撞车,受害者是老端点,且症状是「参数被解析成别的东西」这种不报错的形态。
    """

    @classmethod
    def setUpClass(cls):
        main.app.dependency_overrides[get_developer_id_from_api_key] = lambda: DEV_ID
        cls.client = TestClient(main.app)

    @classmethod
    def tearDownClass(cls):
        main.app.dependency_overrides.clear()

    def test_conversations_endpoint_still_resolves_to_its_own_handler(self):
        route = next(r for r in main.app.routes if getattr(r, 'path', '') == '/v1/conversations')
        self.assertEqual(route.endpoint.__module__, 'routers.developer_conversations')

    def test_timeline_path_does_not_shadow_any_existing_route(self):
        """`/v1/timeline` 下只有这两条,没有别的 router 也想要这个前缀。

        断的是**集合相等**而不是「条数 == N」：条数断言在加端点时必然要改数字,
        改的时候没人会去核对多出来的那条是谁的 —— 而这里要挡的恰恰是「别人也注册了
        `/v1/timeline/...`」。写成集合,新增自己的端点要显式登记,冒出第三方的立刻红。
        """
        matches = {r.path for r in main.app.routes if getattr(r, 'path', '').startswith('/v1/timeline')}
        self.assertEqual(matches, {'/v1/timeline/{date}', '/v1/timeline/{date}/chapters'})

    def test_conversations_list_response_unchanged(self):
        """带上一条假会话跑通 `/v1/conversations`,断言字段集合仍是老样子。

        补齐 `ConversationResponse` 的必填字段（`created_at`/`language`/`status`/
        `metadata`/`updated_at`）—— 少一个 FastAPI 就 ResponseValidationError,
        这本身就是「这个端点带 response_model」的证据。
        """
        from routers import developer_conversations as dc

        convo = dict(CONVOS[0])
        convo.update({'created_at': convo['started_at'], 'updated_at': convo['started_at'],
                      'language': 'zh', 'status': 'completed', 'metadata': {}})
        with mock.patch.object(dc.dev_db, 'get_conversations', return_value=[convo]):
            resp = self.client.get('/v1/conversations', params={'external_user_id': UID})
        self.assertEqual(resp.status_code, 200, resp.text)
        body = resp.json()
        self.assertIsInstance(body, list)
        self.assertEqual(body[0]['id'], 'c1')
        # `discarded` 必须在：它被 response_model 吞掉过一次,已被删除的媒体录音
        # 于是全部渲染进首页时间轴（见 developer_conversations.py 的注释）。
        self.assertIn('discarded', body[0])
        # 老端点从不返回章节字段 —— 影子端点不该把自己的模型渗进来。
        self.assertNotIn('source_conversation_ids', body[0])
        self.assertNotIn('segment_refs', body[0])

    def test_health_check_still_ok(self):
        resp = self.client.get('/health_check')
        self.assertEqual(resp.status_code, 200)


if __name__ == '__main__':
    unittest.main(verbosity=2)
