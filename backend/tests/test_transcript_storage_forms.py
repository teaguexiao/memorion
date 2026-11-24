"""三种 transcript 存储形态读出来必须一模一样 —— 尤其是生产里跑不到的那种。

存在的理由：章节层的输入只有 `transcript_segments`，而它在 Firestore 里有三种存法
（`developer_data._prepare_conversation_for_read`）：明文 list、内联 zlib 压缩 bytes、
以及压缩后 >500KB 时切进 `transcript_chunks/` 子集合。

**第三种在生产里一次都没出现过**（实测：主用户 368 条压缩 transcript 最大 118KB,
离 500KB 阈值还差 4 倍;全 tenant 查 `transcript_segments_chunked==True` 返回 0 条）。
所以「跑真实数据把解压路径验一遍」这条人工检查项对它是**做不到**的 —— 只能在这里
用测试盯住。它一旦坏掉的失败形态是最难发现的那种：`transcript_segments` 变成 `[]`，
章节层看到「这天没人说话」，不报错、不告警，用户只是少了一段时间线。

顺带钉住一个已经犯过的错：**压缩后的 bytes 长度不是 segment 条数。**
`len(compressed)` 是几万，`len(segments)` 是几十;拿前者当后者会得出「这条会话有
118000 段」这种结论。

不连 Firestore：用假的 doc / collection 对象喂给 `_prepare_conversation_for_read`,
它只需要 `conv_ref.collection('transcript_chunks').stream()` 这一个能力。

Run:
    cd backend && python3 tests/test_transcript_storage_forms.py
"""

import json
import os
import sys
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
# `.env` 里这个变量指向容器路径 `/home/ubuntu/...`,import database 时会去建目录并
# 在 macOS 上直接 OSError。照 test_chat_agent_loop.py 的做法先占位成本地路径。
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

from database.developer_data import _prepare_conversation_for_read  # noqa: E402

SEGMENTS = [
    {'text': f'sentence number {i}', 'start': float(i * 10), 'end': float(i * 10 + 8),
     'speaker_id': i % 2, 'is_user': False, 'person_id': None}
    for i in range(40)
]

# 生产实际用的分片大小（`developer_data.py` set_conversation_segments）。
# 这里刻意用比它小得多的值来强制切出多片，见 `_chunked_doc`。
PROD_CHUNK_SIZE = 750 * 1024


class FakeChunkDoc:
    def __init__(self, data, index, total):
        self._d = {'data': data, 'index': index, 'total_chunks': total}

    def to_dict(self):
        return self._d


class FakeChunksCollection:
    def __init__(self, docs):
        self._docs = docs

    def stream(self):
        # Firestore 不保证 stream 顺序 —— 真实代码靠 index 排序。倒序返回,
        # 这样「忘了排序」会直接变成 zlib 解压失败而不是偶发通过。
        return list(reversed(self._docs))


class FakeConvRef:
    def __init__(self, chunks):
        self._chunks = chunks

    def collection(self, name):
        assert name == 'transcript_chunks', name
        return FakeChunksCollection(self._chunks)


def _compressed_bytes():
    return zlib.compress(json.dumps(SEGMENTS).encode('utf-8'))


def _plain_doc():
    return {'id': 'c1', 'transcript_segments': list(SEGMENTS)}


def _compressed_doc():
    return {'id': 'c1', 'transcript_segments': _compressed_bytes(),
            'transcript_segments_compressed': True, 'transcript_segments_chunked': False}


def _chunked_doc(chunk_size=64):
    """切片存储形态。用很小的 chunk_size 逼出多片,不然 40 段压完只有一片。"""
    blob = _compressed_bytes()
    pieces = [blob[i:i + chunk_size] for i in range(0, len(blob), chunk_size)]
    docs = [FakeChunkDoc(p, i, len(pieces)) for i, p in enumerate(pieces)]
    data = {'id': 'c1', 'transcript_segments': [], 'transcript_segments_compressed': True,
            'transcript_segments_chunked': True, 'transcript_segments_chunk_count': len(pieces)}
    return data, FakeConvRef(docs)


class StorageFormEquivalenceTests(unittest.TestCase):
    def test_plain_form(self):
        out = _prepare_conversation_for_read(_plain_doc())
        self.assertEqual(out['transcript_segments'], SEGMENTS)

    def test_inline_compressed_form(self):
        out = _prepare_conversation_for_read(_compressed_doc())
        self.assertEqual(out['transcript_segments'], SEGMENTS)

    def test_chunked_form_reassembles_in_index_order(self):
        """切片形态：多片按 index 重组后与明文完全相同。

        `FakeChunksCollection.stream()` 故意倒序返回 —— 少了按 index 排序这一步,
        zlib 会直接解压失败,段数静默变 0。
        """
        data, conv_ref = _chunked_doc()
        self.assertGreater(data['transcript_segments_chunk_count'], 1, '没切出多片,这个用例就白测了')
        out = _prepare_conversation_for_read(data, conv_ref=conv_ref)
        self.assertEqual(out['transcript_segments'], SEGMENTS)

    def test_all_three_forms_agree(self):
        """三种存法读出来必须逐字段相同 —— 章节层不该知道 transcript 存在哪。"""
        chunk_data, conv_ref = _chunked_doc()
        plain = _prepare_conversation_for_read(_plain_doc())['transcript_segments']
        inline = _prepare_conversation_for_read(_compressed_doc())['transcript_segments']
        chunked = _prepare_conversation_for_read(chunk_data, conv_ref=conv_ref)['transcript_segments']
        self.assertEqual(plain, inline)
        self.assertEqual(plain, chunked)


class SilentFailureTests(unittest.TestCase):
    def test_compressed_byte_length_is_not_segment_count(self):
        """压缩 bytes 的长度 ≠ segment 条数（本代码库混淆过这两者）。"""
        blob = _compressed_bytes()
        self.assertGreater(len(blob), len(SEGMENTS) * 10)
        out = _prepare_conversation_for_read(_compressed_doc())
        self.assertEqual(len(out['transcript_segments']), len(SEGMENTS))

    def test_chunked_without_conv_ref_yields_empty_not_bytes(self):
        """拿不到 conv_ref 时必须是空 list,不能把 bytes 漏成 segment 列表。

        `get_conversations` 总会传 conv_ref,但别的调用点不一定 —— 漏成 bytes
        会让下游 `seg.get('text')` 在字符串上崩,比空列表更难查。
        """
        data, _ = _chunked_doc()
        out = _prepare_conversation_for_read(data, conv_ref=None)
        self.assertEqual(out['transcript_segments'], [])

    def test_corrupt_chunks_degrade_to_empty(self):
        """分片损坏 → 空 list,不抛异常整天算不出来。"""
        docs = [FakeChunkDoc(b'not-zlib-data', 0, 1)]
        data = {'id': 'c1', 'transcript_segments': [], 'transcript_segments_chunked': True}
        out = _prepare_conversation_for_read(data, conv_ref=FakeConvRef(docs))
        self.assertEqual(out['transcript_segments'], [])

    def test_internal_flags_are_stripped(self):
        """压缩/分片标记不进 API 响应 —— 也是对照脚本只能读原始文档的原因。"""
        chunk_data, conv_ref = _chunked_doc()
        out = _prepare_conversation_for_read(chunk_data, conv_ref=conv_ref)
        for flag in ('transcript_segments_compressed', 'transcript_segments_chunked',
                     'transcript_segments_chunk_count'):
            self.assertNotIn(flag, out)

    def test_include_transcript_segments_false_is_empty(self):
        """取数层拿它省流量（对照脚本扫活跃天用的就是这条路径）。"""
        out = _prepare_conversation_for_read(_compressed_doc(), include_transcript_segments=False)
        self.assertEqual(out['transcript_segments'], [])


class ChapteringOnEachFormTests(unittest.TestCase):
    """把三种形态分别喂进章节层，断言算出来的边界完全一样。

    这一层才是真正想保护的东西：解压路径坏掉时，`chaptering` 不会报错，
    它只会算出「今天没人说话」。
    """

    def test_chapters_identical_across_storage_forms(self):
        from datetime import datetime, timezone

        from utils.timeline.chaptering import segment_day_into_chapters

        started = datetime(2026, 8, 6, 9, 0, tzinfo=timezone.utc)
        chunk_data, conv_ref = _chunked_doc()

        results = []
        for data, ref in ((_plain_doc(), None), (_compressed_doc(), None), (chunk_data, conv_ref)):
            prepared = _prepare_conversation_for_read(data, conv_ref=ref)
            prepared.update({'id': 'c1', 'source': 'app', 'started_at': started, 'discarded': False})
            results.append(segment_day_into_chapters([prepared]))

        self.assertEqual(len(results[0]), 1)
        self.assertEqual(len(results[0][0]['segment_refs']), len(SEGMENTS))
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0], results[2])


if __name__ == '__main__':
    unittest.main(verbosity=2)
