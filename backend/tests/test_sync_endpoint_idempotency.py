"""`POST /v1/sync-local-files` 的接线：claim 在花钱之前，失败要释放，全跳过要 200。

前一个文件（`test_sync_idempotency.py`）测的是 claim 本身。这里测的是**端点怎么用它**
—— 正是「两个各自正确的函数接起来是错的」那类缺陷的位置。三条接线各自都能独立坏掉：

1. **claim 必须在 decode/VAD/转录之前**。放在之后，幂等就只省了存储，不省钱 ——
   而这个端点的成本几乎全在 Soniox + LLM 上。用例断言重传时**转录函数一次都没被调**。
   ⚠️ mock 必须打在 `transcribe_segment` 上：端点是「并发转录 → 串行落库 → 一次重算」
   三段式，不再走 `process_segment`（那个函数只服务端点外的单点调用）。打错位置的后果
   是 mock 静默失效、真的去调 Soniox。
2. **处理失败必须释放 claim**。不释放的话文件永久不可 claim：app 一直重发、后端一直
   跳过，那段录音静默永久丢失。重复可恢复（章节层有内容去重），丢音频不可恢复。
3. **整批都被跳过时要返回 200，不能报错**。app 只把非 2xx 当失败重试，这里报错会让它
   无限重发同一批。

顺带钉住 `source`：批量同步建的对话必须是 `sdcard`，不能是 `CreateConversation` 的默认
`omi`。这不是洁癖 —— `omi` 的语义是「2026-02 及以前从上游迁移进来的历史数据」，章节层
据此判定「边界来自物理静音、整条不可拆」，而批量文件的边界恰恰是传输产物、**应该**按
内部静音拆开（`chaptering._splittable`）。写错 source 会让整条批量链路走上相反的策略。

不连 Firestore、不连 Soniox：claim / 解码 / VAD / 转录全部 mock，测的是控制流。

Run:
    cd backend && python3 tests/test_sync_endpoint_idempotency.py
"""

import os
import sys
import tempfile
import unittest
from unittest import mock

from fastapi import HTTPException

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

import routers.sync as sync  # noqa: E402


def _seg():
    from models.transcript_segment import TranscriptSegment

    return TranscriptSegment(text='hello there', start=0.0, end=4.0, speaker='SPEAKER_00', is_user=False)


class FakeUpload:
    """够用的 UploadFile 替身：只需要 filename 和一个可 copyfileobj 的 file。"""

    def __init__(self, filename):
        self.filename = filename
        import io

        self.file = io.BytesIO(b'\x00' * 16)


def call_endpoint(files, developer_id='dev', uid='uid'):
    # Plain call, no asyncio.run: the handler is a sync `def` so FastAPI runs it in
    # its threadpool instead of on the event loop (see the docstring on
    # `sync.sync_local_files`). `asyncio.run` on a non-coroutine raises outright,
    # so this call site is what pins the handler's sync-ness from the test side.
    return sync.sync_local_files(files=files, ctx=(developer_id, uid))


class ClaimOrderingTests(unittest.TestCase):
    """claim 要挡在花钱那一步前面。"""

    def setUp(self):
        self.claimed = set()

        def fake_claim(developer_id, external_user_id, filename):
            key = (developer_id, external_user_id, os.path.basename(filename))
            if key in self.claimed:
                return False
            self.claimed.add(key)
            return True

        self.released = []

        def fake_release(developer_id, external_user_id, filename):
            key = (developer_id, external_user_id, os.path.basename(filename))
            self.claimed.discard(key)
            self.released.append(os.path.basename(filename))

        patches = [
            mock.patch.object(sync.dev_db, 'claim_synced_file', side_effect=fake_claim),
            mock.patch.object(sync.dev_db, 'release_synced_file_claim', side_effect=fake_release),
            # 解码/缝合/VAD/转录全部短路：它们碰真文件和真 API。
            mock.patch.object(sync, 'decode_files_to_wav', side_effect=lambda paths: list(paths)),
            # 缝合也要短路：它会去读真 wav 量时长。不 stub 的话它读不到、
            # 每个文件各自成轨 —— 结果恰好也对，但那是巧合，不该拿来当地基。
            mock.patch.object(
                sync, 'stitch_contiguous_files',
                side_effect=lambda paths: [(p, sync.get_timestamp_from_path(p)) for p in paths],
            ),
            mock.patch.object(sync, 'retrieve_vad_segments', side_effect=lambda path, out: out.add(path)),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

        # 打在 `transcribe_segment` 上，因为**它才是花钱的那一步**（Soniox）。
        # 端点已经拆成「并发转录 → 串行落库 → 一次重算」三段，所以这里不能再打
        # `process_segment` —— 那个函数还在（给端点外的单点调用用），但端点不走它，
        # 打上去等于没打：mock 不生效，真的转录会被调用。
        self.processed = []

        def fake_transcribe(path, transcripts):
            self.processed.append(path)
            transcripts[path] = ([_seg()], 'en')

        for target, side_effect in (
            ('transcribe_segment', fake_transcribe),
            ('store_segment', lambda *a, **k: None),
            ('resummarize_merged_conversations', lambda *a, **k: None),
        ):
            p = mock.patch.object(sync, target, side_effect=side_effect)
            p.start()
            self.addCleanup(p.stop)

        self._tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(mock.patch.object(sync.tempfile, 'tempdir', self._tmp))

    def test_invalid_file_releases_earlier_claim_and_removes_temporary_files(self):
        name = 'audio_1754700000.bin'
        with self.assertRaises(HTTPException) as response:
            call_endpoint([FakeUpload(name), FakeUpload('recording.bin')])

        self.assertEqual(response.exception.status_code, 400)
        self.assertEqual(self.claimed, set())
        self.assertEqual(os.listdir(self._tmp), [])
        self.assertEqual(self.processed, [])
        self.assertEqual(call_endpoint([FakeUpload(name)])['skipped_files'], [])
        self.assertEqual(len(self.processed), 1)
        self.assertEqual(os.listdir(self._tmp), [])

    def test_first_upload_is_processed(self):
        """第一次上传正常走完，两个文件都被处理。"""
        files = [FakeUpload('audio_phone_opus_16000_1_fs160_1754700000.bin'), FakeUpload('audio_1754700060.bin')]
        resp = call_endpoint(files)
        self.assertEqual(len(self.processed), 2)
        self.assertEqual(resp['skipped_files'], [])

    def test_retransmit_costs_nothing(self):
        """核心用例：同一个文件重传，**转录一次都不许再跑**。

        断言的是转录的调用次数而不是「结果里没有新对话」—— 后者在「claim 放在转录
        之后」的实现里同样成立，逮不到那个错。
        """
        name = 'audio_phone_opus_16000_1_fs160_1754700000.bin'
        call_endpoint([FakeUpload(name)])
        self.assertEqual(len(self.processed), 1)

        self.processed.clear()
        resp = call_endpoint([FakeUpload(name)])
        self.assertEqual(self.processed, [], '重传又跑了一次转录 —— claim 没挡在花钱前面')
        self.assertEqual(resp['skipped_files'], [name])

    def test_all_skipped_returns_ok_not_error(self):
        """整批都已同步时返回 200 + 空集合。

        app 只有收到非 2xx 才重试，这里抛错会让它对同一批无限重发。
        """
        name = 'audio_1754700000.bin'
        call_endpoint([FakeUpload(name)])
        resp = call_endpoint([FakeUpload(name)])
        self.assertEqual(resp['new_memories'], set())
        self.assertEqual(resp['updated_memories'], set())
        self.assertEqual(resp['skipped_files'], [name])

    def test_partial_retransmit_processes_only_the_new_file(self):
        """一批里混着已同步和新文件：只处理新的那个。

        这是 app 的真实形态 —— `syncAll` 的批次边界会重叠，每批总带着上批的尾巴。
        """
        old = 'audio_1754700000.bin'
        new = 'audio_1754700060.bin'
        call_endpoint([FakeUpload(old)])
        self.processed.clear()

        resp = call_endpoint([FakeUpload(old), FakeUpload(new)])
        self.assertEqual(len(self.processed), 1, '跳过的那个也被处理了')
        self.assertIn(new, self.processed[0])
        self.assertEqual(resp['skipped_files'], [old])

    def test_failure_releases_the_claim_so_audio_is_not_lost(self):
        """处理中抛异常 → claim 释放 → 重传能被接受。

        不释放的失败形态是最糟的那种：静默永久丢音频，没有任何报错。
        """
        name = 'audio_1754700000.bin'
        with mock.patch.object(sync, 'decode_files_to_wav', side_effect=RuntimeError('opus decode blew up')):
            with self.assertRaises(RuntimeError):
                call_endpoint([FakeUpload(name)])

        self.assertEqual(self.released, [name], 'claim 没被释放 —— 这段录音永远同步不上来了')

        # 重传必须真的能被接受并处理
        resp = call_endpoint([FakeUpload(name)])
        self.assertEqual(len(self.processed), 1)
        self.assertEqual(resp['skipped_files'], [])

    def test_claims_are_scoped_per_user(self):
        """两个用户上传同名文件（SD 卡命名不带 device，撞名是常态）互不影响。"""
        name = 'audio_1754700000.bin'
        call_endpoint([FakeUpload(name)], uid='user-a')
        self.processed.clear()
        resp = call_endpoint([FakeUpload(name)], uid='user-b')
        self.assertEqual(len(self.processed), 1, 'B 用户的音频被 A 用户的 claim 吃掉了')
        self.assertEqual(resp['skipped_files'], [])


class SourceTests(unittest.TestCase):
    """批量同步建的对话必须标 `sdcard`。"""

    def test_created_conversation_is_marked_sdcard(self):
        """`CreateConversation` 的默认 source 是 `omi`，在这里是错的。

        `omi` = 上游迁移的历史数据，章节层据此判「不可拆」；批量文件应当可拆。
        """
        from models.transcript_segment import TranscriptSegment

        segments = [TranscriptSegment(text='hello there', start=0.0, end=4.0, speaker='SPEAKER_00', is_user=False)]
        captured = {}

        def fake_process(uid, language, create_memory, developer_id=None):
            captured['source'] = create_memory.source
            return mock.Mock(id='conv-1')

        with mock.patch.object(sync, 'soniox_transcribe_file', return_value=(segments, 'en')), \
             mock.patch.object(sync.dev_db, 'get_closest_conversation_to_timestamps', return_value=None), \
             mock.patch.object(sync, 'process_conversation', side_effect=fake_process):
            response = {'new_memories': set(), 'updated_memories': set()}
            sync.process_segment('syncing/uid/1754700000.wav', 'uid', response, developer_id='dev')

        self.assertEqual(captured.get('source'), 'sdcard', f"批量同步写成了 {captured.get('source')}")


if __name__ == '__main__':
    unittest.main(verbosity=2)
