"""人物列表只返回样本**条数**，不逐人列 GCS（2026-08-12）。

现场是「手机端人物页下载不了」。`GET /v1/people?include_speech_samples=true` 会对每个
person 各做一次 GCS 列举 + 逐 blob 签名 URL：833 人的账号上单页实测 **15.65s**（不带
样本 2.38s），后端 limit 上限 500 所以全量要两页 ≈ 27s。App 的 `makeApiCall` 不设超时，
但 iOS 一锁屏/切后台就挂起网络，于是这 27 秒里任何打断都让整次拉取失败——而失败的
结果曾被当成真相写进本地缓存，人物列表就永久空了（App 侧见
`app/test/people_cache_wipe_test.dart`）。

列表界面每行要的只是「N 段样本」这个数字，URL 一条都用不到。所以：
`get_developer_people_speech_sample_counts` 对 `people_profiles/` **整体列举一次**，按
路径第一段归组。

为什么不在 Firestore 上养一个计数字段：那要在上传 / 删单个样本 / 删整个人 / 声纹撤销
四条写路径上同步维护，漏一条就静默偏，还得给存量补一次。前缀列举永远是准的。

这里钉三件事，都是「看着对、其实静默错」的形态：

1. **归组必须按第一段路径**。用 `basename` 或最后一段会把所有人的样本算到一起／算成 0。
2. **`revoked_samples/` 是 `people_profiles/` 的兄弟**，不是子目录。撤销掉的样本必须不
   计数，而这只在两者是兄弟关系时自动成立（当初 quarantine 没放成子目录就是为了它）。
3. **只数 `{person_id}/xxx.wav`**：前缀自身那条伪目录 blob 和更深的层级都不算。GCS 的
   "目录" 是 0 字节对象，把它算进去会让每个人凭空多一段样本。

Run:
    cd backend && python3 tests/test_people_sample_counts.py
"""

import asyncio
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("BUCKET_SPEECH_PROFILES", "test-speech-profiles")

import utils.other.storage as storage  # noqa: E402

DEV = "dev1"
UID = "user1"
PEOPLE = f"developers/{DEV}/users/{UID}/people_profiles/"
REVOKED = f"developers/{DEV}/users/{UID}/revoked_samples/"
SAMPLES = f"developers/{DEV}/users/{UID}/samples/"


class FakeBlob:
    def __init__(self, name):
        self.name = name


class FakeBucket:
    def __init__(self):
        self.names = []
        self.list_calls = []

    def add(self, name):
        self.names.append(name)

    def list_blobs(self, prefix=""):
        # 真实 GCS 的 prefix 语义：对完整对象名做普通字符串前缀匹配。
        self.list_calls.append(prefix)
        return [FakeBlob(n) for n in sorted(self.names) if n.startswith(prefix)]


class FakeClient:
    def __init__(self, bucket):
        self._bucket = bucket

    def bucket(self, _name):
        return self._bucket


class CountsTestCase(unittest.TestCase):
    def setUp(self):
        self.bucket = FakeBucket()
        self._orig = storage.storage_client
        storage.storage_client = FakeClient(self.bucket)

    def tearDown(self):
        storage.storage_client = self._orig

    def counts(self):
        return storage.get_developer_people_speech_sample_counts(
            developer_id=DEV, external_user_id=UID
        )


class GroupingIsByPersonId(CountsTestCase):
    def test_counts_group_by_the_first_path_segment(self):
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")
        self.bucket.add(f"{PEOPLE}alice/bbb22222.wav")
        self.bucket.add(f"{PEOPLE}bob/ccc33333.wav")

        self.assertEqual(self.counts(), {"alice": 2, "bob": 1})

    def test_people_with_no_samples_are_simply_absent(self):
        """调用方用 `counts.get(pid, 0)`——缺席就是 0，不需要预先知道有哪些人。"""
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")

        self.assertEqual(self.counts().get("bob", 0), 0)

    def test_one_listing_for_the_whole_user(self):
        """省下来的 13 秒全在这一条上：per-person 列举是人数次往返。"""
        for i in range(50):
            self.bucket.add(f"{PEOPLE}p{i}/aaa{i:05d}.wav")

        self.counts()

        self.assertEqual(self.bucket.list_calls, [PEOPLE])


class NoiseIsNotCounted(CountsTestCase):
    def test_revoked_samples_are_not_counted(self):
        """撤销掉的样本不能再算进条数——它们已经不在识别的读路径里了。"""
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")
        self.bucket.add(f"{REVOKED}alice/bbb22222.wav")

        self.assertEqual(self.counts(), {"alice": 1})
        # 兄弟关系是上面那条自动成立的原因；放成 people_profiles/{pid}/revoked/ 就白撤了。
        self.assertFalse(REVOKED.startswith(PEOPLE))

    def test_the_users_own_profile_prefix_is_not_counted(self):
        """`samples/` 是佩戴者本人的声纹，跟 people 的条数无关。"""
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")
        self.bucket.add(f"{SAMPLES}own11111.wav")

        self.assertEqual(self.counts(), {"alice": 1})

    def test_pseudo_directory_blob_is_not_counted(self):
        """GCS 的「目录」是 0 字节对象，数进去每人凭空多一段。"""
        self.bucket.add(PEOPLE)
        self.bucket.add(f"{PEOPLE}alice/")
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")

        self.assertEqual(self.counts(), {"alice": 1})

    def test_non_wav_objects_are_not_counted(self):
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")
        self.bucket.add(f"{PEOPLE}alice/notes.json")

        self.assertEqual(self.counts(), {"alice": 1})


class SinglePersonCount(CountsTestCase):
    """详情端点用的那一个人的条数。不签 URL，所以比 `len(get_..._samples())` 便宜。"""

    def count_one(self, person_id):
        return storage.get_developer_person_speech_sample_count(
            developer_id=DEV, external_user_id=UID, person_id=person_id
        )

    def test_counts_only_that_person(self):
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")
        self.bucket.add(f"{PEOPLE}alice/bbb22222.wav")
        self.bucket.add(f"{PEOPLE}bob/ccc33333.wav")

        self.assertEqual(self.count_one("alice"), 2)
        self.assertEqual(self.count_one("bob"), 1)
        self.assertEqual(self.count_one("carol"), 0)

    def test_pseudo_directory_blob_is_not_counted(self):
        self.bucket.add(f"{PEOPLE}alice/")
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")

        self.assertEqual(self.count_one("alice"), 1)

    def test_prefix_is_person_scoped_not_a_name_prefix_match(self):
        """`alice` 不能把 `alice2` 的样本一起数进来——prefix 以 `/` 结尾就是为了这个。"""
        self.bucket.add(f"{PEOPLE}alice/aaa11111.wav")
        self.bucket.add(f"{PEOPLE}alice2/bbb22222.wav")

        self.assertEqual(self.count_one("alice"), 1)


class ListEndpointPicksOneListingPath(unittest.TestCase):
    """`list_people` 的两条列举路径**互斥**，绝不能同时跑。

    ⚠️ 这条是为**老客户端**存在的，所以「新版 App 已经不带样本了」不是删掉它的理由：
    2.0.2 及以前的 `getAllPeople` 默认 `include_speech_samples=true`，而那正是本来
    最慢的一条路（833 人 15.65s）。给它再加一次整体前缀列举只会更慢 —— 一个只在
    「还没发新版」这段窗口里出现、且方向和整轮优化相反的退步。

    带样本时条数直接 `len()` 已经列回来的那份，不另外算。
    """

    def setUp(self):
        import routers.developer_people as people_router

        self.router = people_router
        self.bulk_calls = []
        self.per_person_calls = []
        self._patches = [
            mock.patch.object(people_router.dev_db, "get_people",
                              return_value=[{"id": "alice", "name": "Alice"}]),
            mock.patch.object(people_router, "get_developer_people_speech_sample_counts",
                              side_effect=self._bulk),
            mock.patch.object(people_router, "get_developer_person_speech_samples",
                              side_effect=self._per_person),
        ]
        for p in self._patches:
            p.start()
        self.addCleanup(lambda: [p.stop() for p in self._patches])

    def _bulk(self, **kwargs):
        self.bulk_calls.append(kwargs)
        return {"alice": 7}

    def _per_person(self, **kwargs):
        self.per_person_calls.append(kwargs)
        return ["url1", "url2"]

    def call(self, include_speech_samples):
        return asyncio.run(self.router.list_people(
            external_user_id=UID,
            limit=100,
            offset=0,
            include_speech_samples=include_speech_samples,
            # 直接调函数时 FastAPI 不参与，缺省值会是 Query 对象本身（真值），所以显式传。
            include_mentions=False,
            developer_id=DEV,
        ))

    def test_without_samples_only_the_bulk_listing_runs(self):
        result = self.call(False)

        self.assertEqual(len(self.bulk_calls), 1)
        self.assertEqual(self.per_person_calls, [], "列表页一条 URL 都用不到，签名就是白花的 13 秒")
        self.assertEqual(result[0]["speech_samples"], [])
        self.assertEqual(result[0]["speech_samples_count"], 7)

    def test_with_samples_the_bulk_listing_is_skipped(self):
        result = self.call(True)

        self.assertEqual(self.bulk_calls, [],
                         "已经逐人列过了，再整体列一遍等于给最慢的那条路又加一次往返")
        self.assertEqual(len(self.per_person_calls), 1)
        self.assertEqual(result[0]["speech_samples"], ["url1", "url2"])
        self.assertEqual(result[0]["speech_samples_count"], 2, "带样本时条数就是刚拿到的那份的长度")


if __name__ == "__main__":
    unittest.main(verbosity=2)
