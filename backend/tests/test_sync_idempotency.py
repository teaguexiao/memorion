"""同一个音频文件重传多少次，都只许被转录一次。

存在的理由：`POST /v1/sync-local-files` 原来**完全没有幂等**。它的成本全在
「decode → VAD → Soniox → LLM」这条链上，所以重复一次不是多存一份数据，是多花一份钱、
多产一条对话。而重传在这条链路上是**常态而非异常**：

1. app 侧任一批次失败就整批重发（`wals.dart` `_syncWal` / `syncAll` 的 catch 里
   只 `continue`，wal 保持未 synced）；
2. `syncAll` 上传 `wals[left..right]`（闭区间）但只把 `left..right-1` 标成 synced ——
   **每 10 个文件就有 1 个在成功后仍被重发**，而且是永久重发。本次一并修了 app 侧，
   但存量安装包还在跑旧代码，后端不能指望客户端正确。

去重句柄是**文件名**，不是 app 的 `Wal.id`。这点容易搞错：计划书写的是「app 侧
`Wal.id = '${device}_$timerStart'` 已是稳定 id，后端收下它去重即可」，但
`syncLocalFiles` 发出去的是 `basename(file.path)`，`Wal.id` 从来没上过网。好在两种
文件名形态都嵌了录制起始秒，所以文件名同样稳定：

- 缓冲 wal：`audio_{device}_{codec}_{rate}_{ch}_fs{n}_{timerStart}.bin`
- SD 卡分块：`audio_{timerStart}.bin`（`_flushToDisk`，不带 device）

⚠️ 用 Firestore 的 `create()` 而不是 `get()` 后 `set()`：前者在文档已存在时抛
`AlreadyExists`，是原子的 check-and-set。后者是 TOCTOU，并发两份都会通过 ——
这个坑本仓库踩过，一段录音出了两条对话（见 `listen_session_lock_key`）。
`chunk_size=5` 的并发上传正好是能触发它的形态，所以并发用例是必需的。

不连 Firestore：用一个模拟 `create()` 语义（含并发）的假 client 替掉 `db`，
这样测的是我们的分支逻辑，而 `create()` 本身的原子性是 Firestore 的保证。

Run:
    cd backend && python3 tests/test_sync_idempotency.py
"""

import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
# `.env` 的这个变量指向容器路径，import database 时会在 macOS 上 OSError。
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

from google.api_core.exceptions import AlreadyExists  # noqa: E402

import database.developer_data as dev_db  # noqa: E402


class FakeDoc:
    """一个文档：只需要 create / delete / get / set 四个能力。

    `create` 用一把锁模拟 Firestore 的原子 check-and-set —— 没有这把锁，假实现自己
    就是 TOCTOU，会把真实现的并发缺陷一起放过去。
    """

    _lock = threading.Lock()

    def __init__(self, store, key):
        self._store = store
        self._key = key

    def create(self, data):
        with FakeDoc._lock:
            if self._key in self._store:
                raise AlreadyExists(f'{self._key} already exists')
            self._store[self._key] = data

    def delete(self):
        self._store.pop(self._key, None)

    def get(self):
        return self

    @property
    def exists(self):
        return self._key in self._store

    def to_dict(self):
        return self._store.get(self._key)

    def set(self, data, merge=False):
        self._store[self._key] = data

    def collection(self, name):
        return FakeCollection(self._store, f'{self._key}/{name}')


class FakeCollection:
    def __init__(self, store, prefix):
        self._store = store
        self._prefix = prefix

    def document(self, doc_id):
        return FakeDoc(self._store, f'{self._prefix}/{doc_id}')


class FakeDb:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return FakeCollection(self.store, name)


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeDb()
        self._real_db = dev_db.db
        dev_db.db = self.fake
        # `_ensure_user_exists` 会 get 再 set 用户文档，假 client 支持得了，
        # 但它不是被测对象 —— 用户文档存在与否不影响 claim 的语义。
        self.addCleanup(setattr, dev_db, 'db', self._real_db)

    def test_first_claim_wins_second_is_refused(self):
        """同一个文件名 claim 两次：第一次 True，第二次 False。"""
        name = 'audio_phone_opus_16000_1_fs160_1754700000.bin'
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', name))
        self.assertFalse(dev_db.claim_synced_file('dev', 'uid', name))

    def test_different_files_do_not_collide(self):
        """不同录制起始时间是不同文件，都要放过去。"""
        a = 'audio_phone_opus_16000_1_fs160_1754700000.bin'
        b = 'audio_phone_opus_16000_1_fs160_1754700060.bin'
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', a))
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', b))

    def test_claim_is_scoped_per_user(self):
        """两个用户各自上传同名文件（SD 卡形态 `audio_{ts}.bin` 不带 device，
        撞名完全可能）—— 不许互相屏蔽，否则一个用户的同步会吃掉另一个的音频。
        """
        name = 'audio_1754700000.bin'
        self.assertTrue(dev_db.claim_synced_file('dev', 'user-a', name))
        self.assertTrue(dev_db.claim_synced_file('dev', 'user-b', name))
        self.assertTrue(dev_db.claim_synced_file('other-dev', 'user-a', name))

    def test_path_prefix_does_not_change_identity(self):
        """带目录前缀的同一个文件仍判为同一个 —— 客户端可能发全路径。"""
        name = 'audio_1754700000.bin'
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', f'/var/mobile/Documents/{name}'))
        self.assertFalse(dev_db.claim_synced_file('dev', 'uid', name))

    def test_release_allows_a_genuine_retry(self):
        """处理失败后释放 claim，文件必须能再被接受。

        这是本组用例里最要紧的一条：不释放的话，claim 过又失败的文件会**永久**
        不可 claim —— app 一直重发、后端一直跳过，那段录音静默永久丢失。
        重复是可恢复的（章节层还有内容去重），丢音频不是。
        """
        name = 'audio_1754700000.bin'
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', name))
        dev_db.release_synced_file_claim('dev', 'uid', name)
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', name), 'release 之后仍然被拒 = 音频永久丢失')

    def test_concurrent_claims_only_one_wins(self):
        """并发 claim 同一个文件：恰好 1 个成功。

        `sync_local_files` 用 `chunk_size=5` 起线程，同一批里出现同名文件是真会发生的
        （app 重发 + 批次边界重叠）。`get()` 后 `set()` 的写法在这里会让多份都通过。
        """
        name = 'audio_1754700000.bin'
        results = []
        lock = threading.Lock()

        def claim():
            ok = dev_db.claim_synced_file('dev', 'uid', name)
            with lock:
                results.append(ok)

        threads = [threading.Thread(target=claim) for _ in range(8)]
        [t.start() for t in threads]
        [t.join() for t in threads]

        self.assertEqual(sum(1 for r in results if r), 1, f'并发下不止一个 claim 成功：{results}')
        self.assertEqual(len(results), 8)

    def test_claim_fails_open_when_firestore_is_down(self):
        """Firestore 挂了要放过去（fail open）—— 丢音频比存两份糟。

        与 `redis_db.acquire_lock` 同一取向：去重是优化，不是数据完整性的守卫。
        """

        class BrokenDb:
            def collection(self, name):
                raise RuntimeError('firestore unreachable')

        dev_db.db = BrokenDb()
        self.assertTrue(dev_db.claim_synced_file('dev', 'uid', 'audio_1754700000.bin'))


class FilenameHandleTests(unittest.TestCase):
    """文件名 → doc id 的映射必须稳定，且不能把非法字符带进 Firestore。"""

    def test_doc_id_is_stable_across_calls(self):
        a = dev_db._synced_file_doc_id('audio_1754700000.bin')
        b = dev_db._synced_file_doc_id('audio_1754700000.bin')
        self.assertEqual(a, b)

    def test_doc_id_is_a_legal_firestore_id(self):
        """Firestore doc id 不许含 '/'、不许是 '.' 或 '..'、有长度上限。

        文件名来自 multipart 的 part name，是客户端可控的 —— 直接当 doc id 用会让
        `../` 之类的输入落到别的路径上，或者超长直接写失败。
        """
        for hostile in ('../../etc/passwd', '.', '..', 'a' * 5000 + '.bin', 'audio/1754700000.bin'):
            with self.subTest(filename=hostile):
                doc_id = dev_db._synced_file_doc_id(hostile)
                self.assertNotIn('/', doc_id)
                self.assertNotIn(doc_id, ('.', '..'))
                self.assertLessEqual(len(doc_id), 64)
                self.assertTrue(doc_id)

    def test_the_two_real_filename_forms_are_distinguished(self):
        """两种真实命名形态（带 device 的缓冲 wal / 不带的 SD 卡分块）不能撞到一起。"""
        buffered = dev_db._synced_file_doc_id('audio_phone_opus_16000_1_fs160_1754700000.bin')
        sdcard = dev_db._synced_file_doc_id('audio_1754700000.bin')
        self.assertNotEqual(buffered, sdcard)


if __name__ == '__main__':
    unittest.main(verbosity=2)
