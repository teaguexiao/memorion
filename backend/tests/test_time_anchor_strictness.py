"""批量上传的录制起始时间缺失即 400，绝不兜底 `now()`。

**为什么这条规则存在**：transcript segment 只存偏移量（`start`/`end` 相对录音开头），
段的绝对时间是**推导**出来的 —— `started_at + segment.start`。所以 `started_at` 是
整条对话里每一个段的唯一时间锚点，章节层完全建在它上面。

批量场景下「上传此刻」和「录制此刻」可能差一天以上（SD 卡攒一天再传）。兜底成
`now()` 的失败形态是最坏的那种：**静默、且不可检测**。对话自己看起来完全正常，只有
当天的时间线是错的 —— 录音落到错误的日期，或者跟那个时刻真实发生的其他录音粘在一起。
事后没有任何办法把兜底出来的时间戳和真实时间戳区分开，所以它不可恢复。报 400 反而可恢复。

⚠️ **不是所有 `now()` 兜底都错**，这里刻意只收紧批量路径：

| 路径 | 兜底 `now()` | 对不对 |
|---|---|---|
| `audio_upload.py`（本文件测的）| ❌ 已改成 400 | 音频早就录完了，now 是上传时刻 |
| `sync.py`（本文件测的锚点来自文件名时间戳）| 不涉及 | 时间戳从文件名解析，本来就是录制时间 |
| `create_conversation`（`in_progress`）| ✅ 保留 | 录音**此刻开始**，now 就是录制时间 |
| `/conversations/process` 的最后兜底 | ✅ 保留 | 实时路径，误差是处理延迟（秒级）|

第三、四行也在下面钉住了 —— 否则将来一次「统一时间处理」的重构很可能把它们一起改掉，
而那会让实时链路在缺 `started_at` 时开始报错。

Run:
    cd backend && python3 tests/test_time_anchor_strictness.py
"""

import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

from fastapi import HTTPException  # noqa: E402

import routers.audio_upload as audio_upload  # noqa: E402
from routers.audio_upload import _require_recording_started_at  # noqa: E402


class MissingAnchorTests(unittest.TestCase):
    """缺失 / 不合法的锚点必须 400，不能有任何默认值。"""

    def assert_400(self, value):
        with self.assertRaises(HTTPException) as ctx:
            _require_recording_started_at(value)
        self.assertEqual(ctx.exception.status_code, 400)
        return ctx.exception

    def test_none_is_rejected(self):
        """完全没传 —— 这是修复前会兜底成上传时刻的那个 case。"""
        exc = self.assert_400(None)
        self.assertIn('started_at is required', exc.detail)

    def test_empty_string_is_rejected(self):
        """空串。`?started_at=` 在 query string 里是很容易出现的形态。"""
        self.assert_400('')

    def test_whitespace_only_is_rejected(self):
        """只有空白 —— `if not started_at` 挡不住它，所以规则里要 `.strip()`。"""
        self.assert_400('   ')

    def test_unparseable_is_rejected_not_silently_defaulted(self):
        """垃圾值必须报错，不许 fallback。

        「解析失败就用 now()」是同一个 bug 换个位置：客户端时间格式一改，
        整条链路静默退回错误锚点，而 HTTP 依然 200。
        """
        for junk in ('yesterday', '1754700000', '2026-13-45T99:99:99', 'null'):
            with self.subTest(junk=junk):
                exc = self.assert_400(junk)
                self.assertIn('not a valid ISO-8601', exc.detail)

    def test_error_message_explains_why(self):
        """报错信息要说明「为什么必填」，否则调用方只会随便塞个值。"""
        exc = self.assert_400(None)
        self.assertIn('time anchor', exc.detail)


class ValidAnchorTests(unittest.TestCase):
    """合法输入原样解析，且一定带时区。"""

    def test_utc_iso_from_the_app_is_parsed(self):
        """app 发的正是这个形态：`DateTime.toUtc().toIso8601String()`。"""
        parsed = _require_recording_started_at('2026-08-09T03:14:15.926Z')
        self.assertEqual(parsed.tzinfo, timezone.utc)
        self.assertEqual((parsed.year, parsed.month, parsed.day, parsed.hour), (2026, 8, 9, 3))

    def test_offset_form_keeps_its_instant(self):
        """带偏移量的形态不许被当成 UTC 读 —— 那会平移 8 小时。"""
        parsed = _require_recording_started_at('2026-08-09T11:14:15+08:00')
        self.assertEqual(
            parsed.astimezone(timezone.utc),
            datetime(2026, 8, 9, 3, 14, 15, tzinfo=timezone.utc),
        )

    def test_naive_input_is_read_as_utc(self):
        """无时区的值按 UTC 读。

        不是随便选的：naive datetime 一碰到 aware 的就 `TypeError`（`finished_at =
        started_at + duration` 之后要和 `created_at` 一起比较），而所有客户端发的
        都是 UTC，所以按 UTC 读符合它们的本意，猜服务器本地时区才是错的。
        """
        parsed = _require_recording_started_at('2026-08-09T03:14:15')
        self.assertEqual(parsed.tzinfo, timezone.utc)

    def test_result_is_always_aware(self):
        """哨兵：任何合法输入的返回值都必须 aware。

        naive 值写进 Firestore 会被当成 UTC 存 —— 在非 UTC 的机器上就是静默平移。
        """
        for value in ('2026-08-09T03:14:15Z', '2026-08-09T03:14:15', '2026-08-09T11:14:15+08:00',
                      '2026-08-09 03:14:15', '2026-08-09T03:14:15.926543+00:00'):
            with self.subTest(value=value):
                self.assertIsNotNone(_require_recording_started_at(value).tzinfo)


class CheckRunsBeforeSpendingMoneyTests(unittest.TestCase):
    """400 必须发生在解码 / VAD / Soniox 转录之前。"""

    def test_endpoint_rejects_before_touching_the_file(self):
        """核心用例：缺锚点时，端点连临时目录都不建、更不碰转录。

        断言的是「昂贵的下游一次都没被调用」而不是「返回了 400」—— 后者在
        「先转录、写库前才校验」的实现里同样成立，逮不到那个错。而那个错代价很实：
        一次 Soniox 转录 + 一次 summary LLM，全为了最后报 400。
        """
        from unittest import mock

        called = []

        class FakeUpload:
            filename = 'audio.wav'
            file = None

        with mock.patch.object(audio_upload, 'decode_opus_to_wav', side_effect=lambda *a, **k: called.append('decode')), \
             mock.patch.object(audio_upload, 'convert_to_wav_16k', side_effect=lambda *a, **k: called.append('convert')), \
             mock.patch.object(audio_upload, 'vad_is_empty', side_effect=lambda *a, **k: called.append('vad')), \
             mock.patch.object(audio_upload, 'soniox_transcribe_file', side_effect=lambda *a, **k: called.append('stt')), \
             mock.patch.object(audio_upload, 'os') as fake_os:
            with self.assertRaises(HTTPException) as ctx:
                # Plain call, no asyncio.run: the handler is a sync `def` (see its
                # docstring — the pipeline blocks for minutes and must not run on
                # the event loop).
                audio_upload.upload_audio_for_conversation(
                    file=FakeUpload(),
                    language='multi',
                    started_at=None,
                    save_recording=False,
                    auto_process=True,
                    use_vad=True,
                    ctx=('dev', 'uid'),
                )

        self.assertEqual(ctx.exception.status_code, 400)
        self.assertEqual(called, [], f'校验之前就跑了 {called} —— 这些是要花钱的')
        fake_os.makedirs.assert_not_called()


class SyncAnchorsAreAwareTests(unittest.TestCase):
    """`sync.py` 的锚点必须带时区。

    这里的锚点不来自请求参数，而是从文件名里解析出的 Unix 时间戳，所以它天生就是
    录制时间、不需要「必填」校验。它的坑是另一个：`datetime.fromtimestamp(ts)`
    不带 `tz=` 返回的是**服务器本地的 naive 时间**，Firestore 拿到 naive 值会当作
    UTC 存 —— 于是在任何非 UTC 的机器上，每条批量同步的录音都偏移若干小时。
    生产容器目前恰好跑 UTC，这正是这类 bug 会在别处、更晚才炸的原因。
    """

    def test_process_segment_writes_aware_anchors(self):
        from unittest import mock

        from models.transcript_segment import TranscriptSegment

        import routers.sync as sync

        segments = [TranscriptSegment(text='hello there', start=0.0, end=42.0, speaker='SPEAKER_00', is_user=False)]
        captured = {}

        def fake_process(uid, language, create_memory, developer_id=None):
            captured['started_at'] = create_memory.started_at
            captured['finished_at'] = create_memory.finished_at
            return mock.Mock(id='conv-1')

        with mock.patch.object(sync, 'soniox_transcribe_file', return_value=(segments, 'en')), \
             mock.patch.object(sync.dev_db, 'get_closest_conversation_to_timestamps', return_value=None), \
             mock.patch.object(sync, 'process_conversation', side_effect=fake_process):
            response = {'new_memories': set(), 'updated_memories': set()}
            sync.process_segment('syncing/uid/1754700000.wav', 'uid', response, developer_id='dev')

        self.assertIsNotNone(captured['started_at'].tzinfo, 'started_at 是 naive 的 —— 非 UTC 机器上会静默平移')
        self.assertIsNotNone(captured['finished_at'].tzinfo, 'finished_at 是 naive 的')
        # 锚点必须就是文件名里的那个时刻，不是「现在」
        self.assertEqual(
            captured['started_at'], datetime.fromtimestamp(1754700000, tz=timezone.utc),
            'started_at 不等于文件名时间戳 —— 锚点被别的东西覆盖了',
        )
        # finished_at = 锚点 + 语音跨度，不是锚点 + 0
        self.assertEqual((captured['finished_at'] - captured['started_at']).total_seconds(), 42.0)


class LivePathsKeepTheirDefaultsTests(unittest.TestCase):
    """反向哨兵：实时路径的 `now()` 兜底**不许**被一并收紧。

    这两处的 `now` 就是真实录制时间（一个是「录音此刻开始」，一个是「录完立刻上传」），
    收紧它们只会让实时链路在缺参数时开始报错，没有任何收益。之所以写成测试：
    一次「统一时间戳处理」的重构极可能顺手把四处都改成必填。
    """

    def test_create_conversation_still_defaults_to_now(self):
        """`create_conversation` 建的是 `in_progress` 会话，now 即录制起点。"""
        import inspect

        import database.developer_data as dev_db

        src = inspect.getsource(dev_db.create_conversation)
        self.assertIn('started_at or now', src, 'create_conversation 的 now 兜底被去掉了 —— 它在这里是对的')

    def test_process_endpoint_still_derives_from_now(self):
        """`/conversations/process` 从 now 反推，误差只有处理延迟。"""
        import inspect

        import routers.developer_conversations as dc

        src = inspect.getsource(dc)
        self.assertIn(
            'datetime.now(timezone.utc) - timedelta(seconds=speech_span)', src,
            '实时 process 路径的 now 反推被去掉了 —— 它在这里是对的',
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
