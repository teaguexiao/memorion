"""批量转录管线：缝合 → 整轨 VAD → 并发转录 → 串行落库 → 每条对话只重算一次摘要。

`POST /v1/sync-local-files` 原来的形态是「每个文件一个线程，各自 VAD + 转录 + 写库」。
四个缺陷都源自同一个误解：**把设备切片的文件边界当成了有意义的边界**。它们在只有实时
链路的今天只是偶发脏数据，硬件带存储后会变成每次同步都发生。

| # | 缺陷 | 失败形态 |
|---|---|---|
| ① | 逐文件跑 VAD | 跨 60s 边界的一句话被切两半、分别送去转录（半个词）|
| ② | 5 个线程无锁写同一条 `closest_memory` | read-modify-write 覆盖，最后一个写者赢，其余段静默丢失 |
| ③ | 拼接不去重、不重算摘要 | 重传把同一句话追加第二遍；`structured` 永久描述一条更短的 transcript |
| ④ | `update_conversation_segments_dev` 写裸 list | 长 transcript 撞 Firestore 1MB 上限（生产实测已有 4 条）；对 chunked 对话是静默 no-op |

**为什么这些断言长这样**：几乎每一条都刻意断言「过程」而不是「结果」——
- ② 断言的是「有没有交错」，不是「最后段数对不对」。段数在只有一条 run 的用例里
  即使无锁也是对的，逮不到那个错。
- ③ 断言的是「LLM 被调了几次」，不是「摘要被更新了」。每次合并都重算摘要同样能让
  摘要变新，但会花 N 次 LLM 钱产出 N-1 份废摘要，而且**不安全**：
  `process_conversation_developer` 结尾是整文档 upsert（用它进入时读到的 transcript），
  一次慢的重算会把后来合并进去的段覆盖掉。
- ④ 断言的是「走到了压缩写入函数」，不是「写成功了」。裸写对绝大多数对话同样会成功
  （生产 7926 条里只有 4 条超 1MB），所以结果断言几乎永远是绿的。

不连 Firestore、不连 Soniox。缝合用例真的合成 wav（pydub 走本地 ffmpeg），
因为「按时间排序」这个行为只有在真文件上才能验出来。

Run:
    cd backend && python3 tests/test_sync_batch_pipeline.py
"""

import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")
os.environ.setdefault("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/memorion-service-account.json")

from pydub import AudioSegment  # noqa: E402
from pydub.generators import Sine  # noqa: E402

import routers.sync as sync  # noqa: E402
from models.transcript_segment import TranscriptSegment  # noqa: E402


def seg(text, start, end, speaker='SPEAKER_00'):
    return TranscriptSegment(text=text, start=start, end=end, speaker=speaker, is_user=False)


class StitchTests(unittest.TestCase):
    """缺陷 ①：先按录制时间缝成连续音轨，再整轨跑 VAD。"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def write(self, timestamp, seconds, freq=440):
        """写一个真 wav。用不同频率是为了后面能验出「拼接顺序」。"""
        path = f'{self.tmp}/audio_{timestamp}.wav'
        Sine(freq).to_audio_segment(duration=seconds * 1000).set_frame_rate(16000).set_channels(1).export(
            path, format='wav'
        )
        return path

    def test_contiguous_files_become_one_track(self):
        """核心用例：背靠背的三个 60s 文件缝成一条 180s 音轨。

        这才是修 ① 的意义 —— VAD 只有看到完整音轨才能找到真实静音结构。
        """
        paths = [self.write(1754700000, 60), self.write(1754700060, 60), self.write(1754700120, 60)]
        stitched = sync.stitch_contiguous_files(paths)

        self.assertEqual(len(stitched), 1, f'没缝成一条：{stitched}')
        out_path, start_timestamp = stitched[0]
        self.assertEqual(start_timestamp, 1754700000, '缝合后的锚点必须是最早那个文件的时间')
        self.assertAlmostEqual(AudioSegment.from_wav(out_path).duration_seconds, 180, delta=1)

    def test_stitched_name_varies_with_length_so_the_vad_cache_cannot_collide(self):
        """两条起点相同、长度不同的音轨，缝出来的文件名必须不同。

        `vad_is_empty(cache=True)` 按**文件路径**做 Redis 缓存。部分失败后重传时，
        同一个起点可能从更少的文件重新缝出来（丢了一个 chunk），名字只带起点的话就会
        命中上一条更长音轨的 VAD 结果 —— 而 pydub 切超出末尾的片段是静默 clamp 的，
        症状是切出来的音频被截断或为空，不报错。
        """
        a = self.write(1754700000, 10)
        b = self.write(1754700010, 10)
        long_path, _ = sync.stitch_contiguous_files([a, b])[0]

        # 重传时只剩第一个文件 + 一个更短的后继
        a2 = self.write(1754700000, 10)
        b2 = f'{self.tmp}/audio_1754700010.wav'
        Sine(440).to_audio_segment(duration=3000).set_frame_rate(16000).set_channels(1).export(b2, format='wav')
        short_path, _ = sync.stitch_contiguous_files([a2, b2])[0]

        self.assertNotEqual(
            os.path.basename(long_path), os.path.basename(short_path),
            '起点相同、长度不同的两条音轨缝出了同一个文件名 —— VAD 缓存会串',
        )
        # 锚点仍然读得出来
        self.assertEqual(sync.get_timestamp_from_path(short_path), 1754700000)

    def test_stitched_name_keeps_the_time_anchor_readable(self):
        """缝出来的文件名必须还能被 `get_timestamp_from_path` 解析。

        整条链路的锚点是从文件名读的（`store_segment` → `started_at`）。缝合换了个
        文件名，如果新名字解析不出来，锚点就在这一步丢了 —— 而它不会报错，
        只会让整天的时间线错位。
        """
        paths = [self.write(1754700000, 60), self.write(1754700060, 60)]
        out_path, _ = sync.stitch_contiguous_files(paths)[0]
        self.assertEqual(sync.get_timestamp_from_path(out_path), 1754700000)

    def test_files_are_ordered_by_recording_time_not_arrival_order(self):
        """给的顺序是乱的（app 就是倒序上传的），缝出来必须是正序。

        这条是本文件最重要的用例：按到达顺序缝 = 把音频拼反了。而拼反了**不会报错**,
        转录也照样返回结果 —— 只是内容顺序全错。所以这里比对的是真实波形：
        用两个不同频率的段，验第一秒是先录的那个。
        """
        early = self.write(1754700000, 5, freq=200)
        late = self.write(1754700005, 5, freq=2000)

        # 故意倒序传入
        out_path, start_timestamp = sync.stitch_contiguous_files([late, early])[0]
        self.assertEqual(start_timestamp, 1754700000)

        combined = AudioSegment.from_wav(out_path)
        first_half = combined[:5000]
        second_half = combined[5000:]
        # 低频段的 dBFS 与高频段不同不足以区分，用 max 频率不好取；改用响度之外的
        # 稳定特征：Sine(200) 与 Sine(2000) 的 rms 相同，但零穿越次数差一个数量级。
        self.assertLess(
            _zero_crossings(first_half), _zero_crossings(second_half),
            '缝出来的音轨前半段是后录的那个 —— 按到达顺序拼了，音频被拼反了',
        )

    def test_a_real_gap_splits_the_run(self):
        """真实间隔（设备关机 / 两次独立录音）不许缝在一起。

        缝过去等于凭空造出一段从未存在的连续音频，VAD 会把那段「不存在的静音」
        当成真静音，章节层再据此切分 —— 错误会一路传下去。
        """
        paths = [self.write(1754700000, 60), self.write(1754703600, 60)]  # 相隔 1 小时
        stitched = sync.stitch_contiguous_files(paths)
        self.assertEqual(len(stitched), 2, '跨越 1 小时的两个文件被缝成了一条')
        self.assertEqual([ts for _, ts in stitched], [1754700000, 1754703600])

    def test_small_negative_gap_is_still_contiguous(self):
        """轻微负间隔要当连续处理。

        设备的时间戳是按字节数推算的，双向都带舍入误差。把 -0.4s 当成「不连续」
        会让每个文件都自成一轨，① 就等于没修。
        """
        a = self.write(1754700000, 10)
        # 下一个文件声称从第 9.6 秒开始 —— 早于前一个文件的结尾
        b = f'{self.tmp}/audio_1754700009.wav'
        Sine(440).to_audio_segment(duration=10000).set_frame_rate(16000).set_channels(1).export(b, format='wav')
        stitched = sync.stitch_contiguous_files([a, b])
        self.assertEqual(len(stitched), 1, '1 秒的舍入误差被当成了真实间隔')

    def test_large_overlap_is_not_concatenated(self):
        """大幅重叠（同一段音频被录了两次）必须拆开，不能拼。

        拼起来等于把重复内容翻倍成一条音轨 —— 之后任何去重都救不回来了，因为它已经
        是一份「合法的、内容重复的」录音。拆开则留给章节层的内容去重处理。
        """
        a = self.write(1754700000, 60)
        b = self.write(1754700010, 60)  # 与 a 重叠 50 秒
        stitched = sync.stitch_contiguous_files([a, b])
        self.assertEqual(len(stitched), 2, '重叠 50 秒的两个文件被拼成了一条，重复内容翻倍')

    def test_single_file_is_passed_through_untouched(self):
        """只有一个文件时不该重新编码 —— 原路返回，省一次 ffmpeg。"""
        path = self.write(1754700000, 60)
        stitched = sync.stitch_contiguous_files([path])
        self.assertEqual(stitched, [(path, 1754700000)])
        self.assertTrue(os.path.exists(path), '单文件被删了')

    def test_source_files_are_removed_after_stitching(self):
        """缝完要删源文件 —— 否则同一段音频会被转录两次（源 + 缝合体）。"""
        paths = [self.write(1754700000, 60), self.write(1754700060, 60)]
        sync.stitch_contiguous_files(paths)
        for path in paths:
            self.assertFalse(os.path.exists(path), f'{path} 缝合后没删，音频会被重复转录')

    def test_empty_input(self):
        self.assertEqual(sync.stitch_contiguous_files([]), [])

    def test_unreadable_timestamp_becomes_its_own_run(self):
        """解析不出时间戳的文件自成一轨，不许猜位置插进别人中间。

        插错位置 = 静默拼错音频。自成一轨最坏也只是少缝了一次。
        """
        good = self.write(1754700000, 5)
        bad = f'{self.tmp}/garbage.wav'
        Sine(440).to_audio_segment(duration=5000).set_frame_rate(16000).set_channels(1).export(bad, format='wav')
        stitched = sync.stitch_contiguous_files([good, bad])
        self.assertEqual(len(stitched), 2)
        # 坏文件排在最后，且原样返回（没被缝）
        self.assertEqual(stitched[0][1], 1754700000)
        self.assertIsNone(stitched[1][1])


def _zero_crossings(aseg):
    """数符号变化次数 —— 频率的廉价代理，不引依赖。"""
    samples = aseg.get_array_of_samples()
    return sum(1 for a, b in zip(samples, samples[1:]) if (a >= 0) != (b >= 0))


class VadCutNamingTests(unittest.TestCase):
    """VAD 切出来的片段命名不能撞车。"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def write(self, name, seconds):
        path = f'{self.tmp}/{name}'
        Sine(440).to_audio_segment(duration=seconds * 1000).set_frame_rate(16000).set_channels(1).export(
            path, format='wav'
        )
        return path

    def test_overlapping_runs_do_not_overwrite_each_others_cuts(self):
        """两条重叠的 run 在同一绝对秒切出片段时，两个片段都要留下。

        撞名的后果是**双重静默**：export 覆盖掉先写的那个文件，而 `segmented_paths`
        是 set，重复的 key 又让其中一条彻底消失 —— 音频丢了，没有任何报错。
        这个场景不是假设：`stitch_contiguous_files` 刻意把真实重叠的文件拆成两条 run
        （见上面的 `test_large_overlap_is_not_concatenated`），于是它们必然重叠。
        """
        run_a = self.write('stitched30000_1754700000.wav', 30)
        run_b = self.write('stitched30000_1754700010.wav', 30)

        # 关键是让两条 run 的**绝对**切点撞在一起：A 起点 …000、语音在相对 20–25 秒；
        # B 起点 …010、语音在相对 10–15 秒 —— 两者都是绝对 …020。这不是构造出来的
        # 巧合，重叠的 run 里同一段真实语音必然落在同一个绝对时刻。
        per_run = {
            run_a: [{'start': 20.0, 'end': 25.0}],
            run_b: [{'start': 10.0, 'end': 15.0}],
        }

        segmented = set()
        with mock.patch.object(sync, 'vad_is_empty', side_effect=lambda path, **k: per_run[path]):
            sync.retrieve_vad_segments(run_a, segmented)
            sync.retrieve_vad_segments(run_b, segmented)

        self.assertEqual(len(segmented), 2, f'两条 run 的片段撞名了，只剩 {segmented}')
        # 而且锚点还得读得出来 —— 两个片段的绝对时刻本来就相同，这正是撞名的原因
        by_ts = sorted(sync.get_timestamp_from_path(p) for p in segmented)
        self.assertEqual(by_ts, [1754700020, 1754700020])

    def test_cut_lands_next_to_its_source_not_in_the_filesystem_root(self):
        """裸文件名（无目录）时，切片要写到当前目录，不是根目录。

        `os.path.dirname('a.wav')` 是 `''`，f-string 拼出来就是 `/1754700010.wav`。
        容器里 root 通常可写，所以这个错不会报错，只会把音频写到没人会去读的地方。
        """
        cwd = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, cwd)
        self.write('stitched_1754700000.wav', 30)

        segmented = set()
        with mock.patch.object(sync, 'vad_is_empty', return_value=[{'start': 10.0, 'end': 20.0}]):
            sync.retrieve_vad_segments('stitched_1754700000.wav', segmented)

        self.assertEqual(len(segmented), 1)
        cut = next(iter(segmented))
        self.assertFalse(cut.startswith('/'), f'切片写到了绝对路径 {cut}')
        self.assertTrue(os.path.exists(os.path.join(self.tmp, cut)), f'{cut} 不在源文件旁边')


class SerializedWriteTests(unittest.TestCase):
    """缺陷 ②：读-改-写必须串行。"""

    def test_concurrent_stores_do_not_interleave(self):
        """核心用例：并发调 `store_segment`，两次读-改-写不许交错。

        断言「有没有交错」而不是「最终段数对不对」：段数在很多用例里即使无锁也
        正好是对的（比如两条 run 命中不同对话），逮不到那个错。这里让 fake 的
        read 和 write 之间睡一下，把竞态窗口放大到必然发生。
        """
        events = []
        events_lock = threading.Lock()

        def fake_closest(developer_id, uid, start, end):
            with events_lock:
                events.append(('read', threading.current_thread().name))
            time.sleep(0.05)  # 放大窗口
            return {
                'id': 'conv-1',
                'started_at': datetime.fromtimestamp(1754700000, tz=timezone.utc),
                'transcript_segments': [],
            }

        def fake_update(developer_id, uid, conversation_id, segments):
            with events_lock:
                events.append(('write', threading.current_thread().name))
            return True

        with mock.patch.object(sync.dev_db, 'get_closest_conversation_to_timestamps', side_effect=fake_closest), \
             mock.patch.object(sync.dev_db, 'update_conversation_segments_dev', side_effect=fake_update):
            response = {'new_memories': set(), 'updated_memories': set()}
            resummarize_ids = set()
            threads = []
            for i in range(4):
                path = f'syncing/uid/seg1754700000_{1754700000 + i}.wav'
                threads.append(threading.Thread(
                    target=sync.store_segment,
                    args=(path, [seg(f'line {i}', 0.0, 4.0)], 'en', 'uid', response),
                    kwargs={'developer_id': 'dev', 'resummarize_ids': resummarize_ids},
                    name=f'w{i}',
                ))
            for t in threads:
                t.start()
            for t in threads:
                t.join()

        # 每个线程的 read 后面紧跟着它自己的 write
        self.assertEqual(len(events), 8, f'事件数不对：{events}')
        for i in range(0, 8, 2):
            read_kind, read_thread = events[i]
            write_kind, write_thread = events[i + 1]
            self.assertEqual((read_kind, write_kind), ('read', 'write'), f'读写交错了：{events}')
            self.assertEqual(read_thread, write_thread, f'另一个线程插进了读写之间：{events}')

    def test_concurrent_creates_do_not_both_create(self):
        """两条 run 都没找到对话时，不许各建一条。

        这正是实时链路上已经修过的「一段录音出两条对话」，批量路径同一个形状。
        所以 check-and-create 整个在锁里，包括那次 LLM。
        """
        created = []
        created_lock = threading.Lock()
        store = {}

        def fake_closest(developer_id, uid, start, end):
            # 只要已经建过一条，就把它当成 closest（模拟 ±2min 窗口命中）
            return store.get('conv')

        def fake_process(uid, language, create_memory, developer_id=None):
            with created_lock:
                created.append(create_memory)
            # 睡在「记下已创建」和「让它可被查到」之间 —— 这正是真实的竞态窗口:
            # `process_conversation` 要跑几秒 LLM 才写库，那期间别的线程查不到它。
            # 睡在别处（比如 fake_closest 里）测的是另一回事，无锁也能过。
            time.sleep(0.1)
            store['conv'] = {
                'id': 'conv-1',
                'started_at': create_memory.started_at,
                'transcript_segments': [s.dict() for s in create_memory.transcript_segments],
            }
            return mock.Mock(id='conv-1')

        with mock.patch.object(sync.dev_db, 'get_closest_conversation_to_timestamps', side_effect=fake_closest), \
             mock.patch.object(sync.dev_db, 'update_conversation_segments_dev', return_value=True), \
             mock.patch.object(sync, 'process_conversation', side_effect=fake_process):
            response = {'new_memories': set(), 'updated_memories': set()}
            resummarize_ids = set()
            threads = [
                threading.Thread(
                    target=sync.store_segment,
                    args=(f'syncing/uid/seg1754700000_{1754700000 + i}.wav', [seg('hi', 0.0, 4.0)], 'en', 'uid', response),
                    kwargs={'developer_id': 'dev', 'resummarize_ids': resummarize_ids},
                )
                for i in range(3)
            ]
            for t in threads:
                t.start()
            for t in threads:
                t.join()

        self.assertEqual(len(created), 1, f'建了 {len(created)} 条对话 —— check-and-create 不是原子的')


class MergeDedupTests(unittest.TestCase):
    """缺陷 ③ 的前半：拼接要去重、要 rebase 到已有锚点。"""

    def make_existing(self, anchor_ts=1754700000, segments=None):
        return {
            'id': 'conv-1',
            'started_at': datetime.fromtimestamp(anchor_ts, tz=timezone.utc),
            'transcript_segments': segments if segments is not None else [],
        }

    def merge(self, existing, incoming, timestamp):
        written = {}

        def fake_update(developer_id, uid, conversation_id, segments):
            written['segments'] = segments
            return True

        response = {'new_memories': set(), 'updated_memories': set()}
        resummarize_ids = set()
        with mock.patch.object(sync.dev_db, 'update_conversation_segments_dev', side_effect=fake_update):
            sync._merge_into_existing('dev', 'uid', existing, incoming, timestamp, response, resummarize_ids)
        return written.get('segments'), response, resummarize_ids

    def test_segments_are_rebased_onto_the_existing_anchor(self):
        """新段的 start/end 要换算到已有对话的时间轴上。

        不换算就是把「相对本 run 的偏移」直接当成「相对对话开头的偏移」——
        一条 10 分钟后录的段会显示在第 0 秒。段的绝对时间是章节层的地基
        （`started_at + segment.start`），所以这个错会一路传到时间线。
        """
        existing = self.make_existing(anchor_ts=1754700000)
        # 这条 run 从对话开始后 300 秒起录，段本身在 run 内的 10–14 秒
        segments, _, _ = self.merge(existing, [seg('later', 10.0, 14.0)], 1754700300)
        self.assertEqual(len(segments), 1)
        self.assertAlmostEqual(segments[0]['start'], 310.0)
        self.assertAlmostEqual(segments[0]['end'], 314.0, msg='时长在 rebase 中被改变了')

    def test_retransmit_adds_nothing(self):
        """核心用例：同一段音频再转录一次，一条都不许追加。

        原来的代码无条件 concat，所以任何重传或重叠采集都让同一句话进去第二遍。
        断言 `update` 完全没被调用，而不是「段数没变」—— 后者在「追加后又排序去重」
        之类的实现里也成立。
        """
        existing = self.make_existing(segments=[
            {'text': 'hello there', 'start': 0.0, 'end': 4.0, 'speaker': 'SPEAKER_00', 'is_user': False},
        ])
        segments, response, resummarize_ids = self.merge(existing, [seg('hello there', 0.0, 4.0)], 1754700000)
        self.assertIsNone(segments, '重复的段被写进去了')
        self.assertEqual(response['updated_memories'], set(), '什么都没变却标记了 updated')
        self.assertEqual(resummarize_ids, set(), '什么都没变却要重算摘要 —— 白花一次 LLM')

    def test_genuinely_new_segments_are_appended_and_sorted(self):
        """真的新内容要进去，并按时间排好。"""
        existing = self.make_existing(segments=[
            {'text': 'first', 'start': 0.0, 'end': 4.0, 'speaker': 'SPEAKER_00', 'is_user': False},
            {'text': 'third', 'start': 20.0, 'end': 24.0, 'speaker': 'SPEAKER_00', 'is_user': False},
        ])
        segments, response, resummarize_ids = self.merge(existing, [seg('second', 0.0, 4.0)], 1754700010)
        self.assertEqual([s['text'] for s in segments], ['first', 'second', 'third'])
        self.assertEqual(response['updated_memories'], {'conv-1'})
        self.assertEqual(resummarize_ids, {'conv-1'})

    def test_partial_overlap_keeps_only_the_new_part(self):
        """一半重复一半新：只进新的那一半。

        这是重传的真实形态 —— app 的批次边界重叠，每批都带着上批的尾巴。
        """
        existing = self.make_existing(segments=[
            {'text': 'aaa', 'start': 0.0, 'end': 4.0, 'speaker': 'SPEAKER_00', 'is_user': False},
            {'text': 'bbb', 'start': 4.0, 'end': 8.0, 'speaker': 'SPEAKER_00', 'is_user': False},
        ])
        segments, _, _ = self.merge(
            existing, [seg('bbb', 4.0, 8.0), seg('ccc', 8.0, 12.0)], 1754700000
        )
        self.assertEqual([s['text'] for s in segments], ['aaa', 'bbb', 'ccc'])

    def test_same_text_at_a_different_time_is_kept(self):
        """同样的话在不同时刻说了两次，两条都要留。

        去重的判据必须同时看时间和文本。只看文本会吃掉「嗯」「对」「好的」这类
        高频短句 —— 一段真实对话里它们出现几十次。
        """
        existing = self.make_existing(segments=[
            {'text': 'okay', 'start': 0.0, 'end': 1.0, 'speaker': 'SPEAKER_00', 'is_user': False},
        ])
        segments, _, _ = self.merge(existing, [seg('okay', 0.0, 1.0)], 1754700100)
        self.assertEqual(len(segments), 2, '不同时刻的同一句话被当成重复吃掉了')

    def test_rounding_noise_still_counts_as_duplicate(self):
        """浮点噪声不能骗过去重。

        同一段音频重新转录出来的时间戳可能差 0.02 秒。判据取 1 位小数，
        既容得下这点噪声，又远小于任何真实的重复间隔。
        """
        existing = self.make_existing(segments=[
            {'text': 'hello there', 'start': 4.0, 'end': 8.0, 'speaker': 'SPEAKER_00', 'is_user': False},
        ])
        segments, _, _ = self.merge(existing, [seg('hello there', 4.02, 8.02)], 1754700000)
        self.assertIsNone(segments, '0.02 秒的浮点噪声让重复段漏了进去')

    def test_whitespace_only_difference_counts_as_duplicate(self):
        """首尾空白不算差异 —— STT 的空白不稳定，落库时也会被 normalize 掉。"""
        existing = self.make_existing(segments=[
            {'text': 'hello there', 'start': 0.0, 'end': 4.0, 'speaker': 'SPEAKER_00', 'is_user': False},
        ])
        segments, _, _ = self.merge(existing, [seg('  hello there ', 0.0, 4.0)], 1754700000)
        self.assertIsNone(segments, '只差首尾空白的段被当成新内容了')


class ResummarizeTests(unittest.TestCase):
    """缺陷 ③ 的后半：合并完要重算摘要，但每条对话只算一次。"""

    def test_one_llm_call_per_conversation_not_per_merge(self):
        """核心用例：一批 5 条 run 都并进同一条对话 → 只重算 1 次摘要。

        断言调用次数而不是「摘要变新了」：每次合并都重算同样能让摘要变新，
        但代价是 5 次 LLM 产出 4 份废摘要，而且**不安全** ——
        `process_conversation_developer` 结尾是整文档 upsert（用它进入时读到的
        transcript），一次慢的重算会把之后合并进去的段覆盖回去。
        """
        calls = []
        existing = {
            'id': 'conv-1',
            'started_at': datetime.fromtimestamp(1754700000, tz=timezone.utc),
            'transcript_segments': [],
        }

        def fake_closest(developer_id, uid, start, end):
            return dict(existing)

        def fake_update(developer_id, uid, conversation_id, segments):
            existing['transcript_segments'] = segments
            return True

        with mock.patch.object(sync.dev_db, 'get_closest_conversation_to_timestamps', side_effect=fake_closest), \
             mock.patch.object(sync.dev_db, 'update_conversation_segments_dev', side_effect=fake_update), \
             mock.patch.object(sync.dev_db, 'get_conversation', return_value={
                 'id': 'conv-1',
                 'started_at': datetime.fromtimestamp(1754700000, tz=timezone.utc),
                 'finished_at': datetime.fromtimestamp(1754700300, tz=timezone.utc),
                 'created_at': datetime.fromtimestamp(1754700300, tz=timezone.utc),
                 'transcript_segments': [],
                 'structured': {'title': 't', 'overview': 'o'},
                 'source': 'sdcard',
                 'language': 'en',
             }), \
             mock.patch.object(sync, 'process_conversation_developer',
                               side_effect=lambda *a, **k: calls.append(a)):
            response = {'new_memories': set(), 'updated_memories': set()}
            resummarize_ids = set()
            for i in range(5):
                sync.store_segment(
                    f'syncing/uid/seg1754700000_{1754700000 + i * 10}.wav',
                    [seg(f'line {i}', 0.0, 4.0)], 'en', 'uid', response,
                    developer_id='dev', resummarize_ids=resummarize_ids,
                )
            self.assertEqual(len(calls), 0, '合并过程中就调了 LLM —— 应该推迟到全部合并完')
            self.assertEqual(resummarize_ids, {'conv-1'})

            sync.resummarize_merged_conversations('dev', 'uid', resummarize_ids, 'en')

        self.assertEqual(len(calls), 1, f'重算了 {len(calls)} 次摘要')

    def test_resummary_uses_force_process(self):
        """重算必须 `force_process=True`，跳过 discard 判定。

        对话已经存在、用户已经能看到它了。让 discard 判定在生命周期中途认定它
        「该丢弃」，等于把用户已见的内容删掉。
        """
        captured = {}

        with mock.patch.object(sync.dev_db, 'get_conversation', return_value={
            'id': 'conv-1',
            'started_at': datetime.fromtimestamp(1754700000, tz=timezone.utc),
            'finished_at': datetime.fromtimestamp(1754700300, tz=timezone.utc),
            'created_at': datetime.fromtimestamp(1754700300, tz=timezone.utc),
            'transcript_segments': [],
            'structured': {'title': 't', 'overview': 'o'},
            'source': 'sdcard',
        }), mock.patch.object(sync, 'process_conversation_developer',
                              side_effect=lambda *a, **k: captured.update(k)):
            sync.resummarize_merged_conversations('dev', 'uid', {'conv-1'}, 'en')

        self.assertTrue(captured.get('force_process'), '没传 force_process —— 重算可能把对话判成 discarded')

    def test_a_failed_resummary_does_not_lose_segments(self):
        """重算抛异常时不许把整个请求带崩。

        段已经落库了。重算失败的后果只是「摘要陈旧」—— 也就是修复前的状态。
        让它冒出去反而会触发端点的 `except`，把 claim 全释放掉，于是同一批音频
        被重传、重新转录、重复计费。
        """
        with mock.patch.object(sync.dev_db, 'get_conversation', side_effect=RuntimeError('firestore down')):
            sync.resummarize_merged_conversations('dev', 'uid', {'conv-1', 'conv-2'}, 'en')  # 不该抛

    def test_missing_conversation_is_skipped(self):
        """对话在重算前被删掉了（用户手动删）→ 静默跳过，不抛。"""
        with mock.patch.object(sync.dev_db, 'get_conversation', return_value=None), \
             mock.patch.object(sync, 'process_conversation_developer') as spy:
            sync.resummarize_merged_conversations('dev', 'uid', {'conv-1'}, 'en')
            spy.assert_not_called()

    def test_source_is_coerced_not_crashed_on(self):
        """存量数据里的未知 source 不许让重算崩掉。

        `Conversation(**doc)` 对未知 source 会 ValidationError。批量路径的默认
        `sdcard` 是安全的猜测（这条路径只处理批量音频），而崩掉意味着这条对话的
        摘要永远修不了。
        """
        self.assertEqual(sync._coerce_source('sdcard').value, 'sdcard')
        self.assertEqual(sync._coerce_source('app').value, 'app')
        self.assertEqual(sync._coerce_source('nonsense-from-2024').value, 'sdcard')
        self.assertEqual(sync._coerce_source(None).value, 'sdcard')


class CompressedWriteTests(unittest.TestCase):
    """缺陷 ④：合并后的 segments 必须走压缩写入。"""

    def test_update_delegates_to_the_compressing_writer(self):
        """`update_conversation_segments_dev` 必须转发给
        `set_conversation_transcript_segments`。

        断言的是「走到了压缩写入函数」而不是「写成功了」—— 裸写对 7926 条生产对话里
        的 7922 条同样会成功，结果断言几乎永远是绿的。

        裸写的两种坏法：
        1. 长 transcript 撞 Firestore 1MB 文档上限而报错。压缩本来就是它能存下的唯一
           原因。生产实测已有 4 条超限（最大 3.1MB / 1810 段）—— 那几条对话根本编辑不了。
        2. 对 chunked 对话是**静默 no-op**：`_prepare_conversation_for_read` 先看
           `transcript_segments_chunked`，该标记还在，读出来就还是子集合的旧内容。
           生产目前 0 条 chunked 恰恰是缺陷本身造成的 —— 只有走压缩路径才会变成 chunked。
        """
        import database.developer_data as dev_db

        with mock.patch.object(dev_db, 'set_conversation_transcript_segments', return_value=True) as spy:
            result = dev_db.update_conversation_segments_dev('dev', 'uid', 'conv-1', [{'text': 'x'}])

        self.assertTrue(result)
        spy.assert_called_once()
        self.assertEqual(spy.call_args.kwargs['conversation_id'], 'conv-1')

    def test_no_raw_transcript_segments_write_remains(self):
        """哨兵：函数体里不许再出现直接 update `transcript_segments` 的写法。

        写成源码断言是因为「改回裸写」不会让任何行为测试变红 —— 生产没有 chunked
        对话，短 transcript 也不撞上限。只有源码能钉住它。
        """
        import inspect

        import database.developer_data as dev_db

        src = inspect.getsource(dev_db.update_conversation_segments_dev)
        self.assertIn('set_conversation_transcript_segments', src)
        self.assertNotIn('"transcript_segments":', src, '又出现了直接写 transcript_segments 的裸写')


class TranscribePoolTests(unittest.TestCase):
    """并发转录：滑动池而不是固定批次。"""

    def test_all_paths_are_transcribed_exactly_once(self):
        seen = []
        lock = threading.Lock()

        def fake_transcribe(path, transcripts):
            with lock:
                seen.append(path)
            transcripts[path] = ([seg('x', 0.0, 1.0)], 'en')

        paths = [f'syncing/uid/seg0_{1754700000 + i}.wav' for i in range(23)]
        with mock.patch.object(sync, 'transcribe_segment', side_effect=fake_transcribe):
            transcripts = {}
            sync.transcribe_all(paths, transcripts)

        self.assertEqual(sorted(seen), sorted(paths))
        self.assertEqual(len(transcripts), 23)

    def test_concurrency_is_capped(self):
        """并发数不许超过 `TRANSCRIBE_CONCURRENCY` —— Soniox 是按账号限流的。"""
        in_flight = {'now': 0, 'peak': 0}
        lock = threading.Lock()

        def fake_transcribe(path, transcripts):
            with lock:
                in_flight['now'] += 1
                in_flight['peak'] = max(in_flight['peak'], in_flight['now'])
            time.sleep(0.02)
            with lock:
                in_flight['now'] -= 1

        with mock.patch.object(sync, 'transcribe_segment', side_effect=fake_transcribe):
            sync.transcribe_all([f'p{i}' for i in range(30)], {})

        self.assertLessEqual(in_flight['peak'], sync.TRANSCRIBE_CONCURRENCY,
                             f"并发峰值 {in_flight['peak']} 超过了上限")

    def test_a_slow_call_does_not_stall_the_pool(self):
        """一个慢请求不许挡住整池。

        这正是原来 `chunk_threads` 的病：每批 join 完才开下一批，所以每轮的成本
        是那一批里最慢的那个。480 个文件 = 96 轮，一个慢的 Soniox 调用让 4 个
        worker 干等。滑动池下慢请求只占一个槽。
        """
        done = []
        lock = threading.Lock()

        def fake_transcribe(path, transcripts):
            time.sleep(0.5 if path == 'slow' else 0.01)
            with lock:
                done.append(path)

        paths = ['slow'] + [f'fast{i}' for i in range(12)]
        with mock.patch.object(sync, 'transcribe_segment', side_effect=fake_transcribe):
            start = time.monotonic()
            sync.transcribe_all(paths, {})
            elapsed = time.monotonic() - start

        # 固定批次的话：'slow' 在第一批 → 第一批要 0.5s，再加两轮 ≈ 0.52s。
        # 滑动池：其余 12 个在 4 个空闲 worker 上并行跑完，总时长 ≈ max(0.5, ...) ≈ 0.5s。
        # 差异不够稳到能计时断言，所以这里只断言「慢的那个没有阻塞快的完成」。
        self.assertEqual(done[-1], 'slow', f'快请求被慢请求挡在后面了：{done}')
        self.assertLess(elapsed, 1.5)

    def test_a_failed_transcription_does_not_kill_the_batch(self):
        """一条 run 转录失败，其余照常。

        `transcribe_segment` 自己吞异常。让它冒出来会触发端点的 `except`、释放整批
        claim，于是 479 个已经转录好的文件被重传、重新计费。
        """
        with mock.patch.object(sync, 'soniox_transcribe_file',
                              side_effect=lambda p: (_ for _ in ()).throw(RuntimeError('soniox 500'))):
            transcripts = {}
            sync.transcribe_all(['a', 'b'], transcripts)
        self.assertEqual(transcripts, {})

    def test_empty_input(self):
        sync.transcribe_all([], {})  # 不该起线程、不该抛


class EndpointPhaseOrderTests(unittest.TestCase):
    """端点的三段式接线：缝合 → 串行 VAD → 并发转录 → 串行落库 → 一次重算。"""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        cwd = os.getcwd()
        os.chdir(self.tmp)
        self.addCleanup(os.chdir, cwd)

    def test_stores_run_in_recording_order(self):
        """落库顺序必须是录制时间序，不是 set 的迭代顺序。

        `segmented_paths` 是 set，迭代顺序在 Python 里由 hash 决定 —— 也就是随机。
        谁先落库谁就成为 `closest_memory` 的锚点，所以随机顺序意味着**同一批音频
        每次同步都可能产出不同的对话边界**。这个不确定性本身就是 bug，即使每次结果
        都「看起来合理」。
        """
        import io

        class FakeUpload:
            def __init__(self, filename):
                self.filename = filename
                self.file = io.BytesIO(b'\x00' * 16)

        stored = []
        # 故意让文件名的 hash 顺序和时间顺序不同
        timestamps = [1754700300, 1754700000, 1754700150, 1754700450]

        with mock.patch.object(sync.dev_db, 'claim_synced_file', return_value=True), \
             mock.patch.object(sync.dev_db, 'release_synced_file_claim'), \
             mock.patch.object(sync, 'decode_files_to_wav', side_effect=lambda paths: list(paths)), \
             mock.patch.object(sync, 'stitch_contiguous_files',
                               side_effect=lambda paths: [(p, sync.get_timestamp_from_path(p)) for p in paths]), \
             mock.patch.object(sync, 'retrieve_vad_segments', side_effect=lambda path, out: out.add(path)), \
             mock.patch.object(sync, 'transcribe_segment',
                               side_effect=lambda p, t: t.__setitem__(p, ([seg('x', 0.0, 1.0)], 'en'))), \
             mock.patch.object(sync, 'store_segment',
                               side_effect=lambda path, *a, **k: stored.append(sync.get_timestamp_from_path(path))):
            sync.sync_local_files(
                files=[FakeUpload(f'audio_{ts}.bin') for ts in timestamps],
                ctx=('dev', 'uid'),
            )

        self.assertEqual(stored, sorted(timestamps), f'落库顺序不是录制时间序：{stored}')

    def test_intermediate_files_are_cleaned_up_on_success(self):
        """解码 wav / 缝合音轨 / VAD 切片，跑完一个都不许留。

        ECS 任务的临时盘是固定大小的，而容器长期存活 —— 泄漏会跨请求累积，直到写盘
        开始失败，而报错会出现在**恰好那一刻在跑的另一个请求**里，跟真正的原因毫无
        关系。缝合让这件事变严重了：它在原有的解码 wav 之外，又多出每条 run 一份
        拼接副本 + 每段语音一个切片。
        """
        import io

        class FakeUpload:
            def __init__(self, filename):
                self.filename = filename
                self.file = io.BytesIO(b'\x00' * 16)

        def fake_decode(paths):
            outs = []
            for p in paths:
                out = p.replace('.bin', '.wav')
                Sine(440).to_audio_segment(duration=2000).set_frame_rate(16000).set_channels(1).export(
                    out, format='wav'
                )
                os.remove(p)
                outs.append(out)
            return outs

        with mock.patch.object(sync.dev_db, 'claim_synced_file', return_value=True), \
             mock.patch.object(sync.dev_db, 'release_synced_file_claim'), \
             mock.patch.object(sync, 'decode_files_to_wav', side_effect=fake_decode), \
             mock.patch.object(sync, 'vad_is_empty', return_value=[{'start': 0.0, 'end': 2.0}]), \
             mock.patch.object(sync, 'transcribe_segment', side_effect=lambda p, t: None):
            sync.sync_local_files(
                files=[FakeUpload('audio_1754700000.bin'), FakeUpload('audio_1754700002.bin')],
                ctx=('dev', 'uid'),
            )

        leftovers = []
        for root, _dirs, files in os.walk(self.tmp):
            leftovers.extend(os.path.join(root, f) for f in files)
        self.assertEqual(leftovers, [], f'跑完还剩下临时文件：{leftovers}')

    def test_intermediate_files_are_cleaned_up_on_failure_too(self):
        """失败路径同样要清 —— 否则一次崩溃就永久占着盘。

        清理放在 `finally` 而不是成功分支：失败时删这些文件是安全的，因为用户在意的
        音频要么已经进了 Firestore，要么还在设备上等重传（claim 已经释放）。
        """
        import io

        class FakeUpload:
            def __init__(self, filename):
                self.filename = filename
                self.file = io.BytesIO(b'\x00' * 16)

        def fake_decode(paths):
            outs = []
            for p in paths:
                out = p.replace('.bin', '.wav')
                Sine(440).to_audio_segment(duration=2000).set_frame_rate(16000).set_channels(1).export(
                    out, format='wav'
                )
                os.remove(p)
                outs.append(out)
            return outs

        with mock.patch.object(sync.dev_db, 'claim_synced_file', return_value=True), \
             mock.patch.object(sync.dev_db, 'release_synced_file_claim'), \
             mock.patch.object(sync, 'decode_files_to_wav', side_effect=fake_decode), \
             mock.patch.object(sync, 'vad_is_empty', side_effect=RuntimeError('silero blew up')):
            with self.assertRaises(RuntimeError):
                sync.sync_local_files(
                    files=[FakeUpload('audio_1754700000.bin')], ctx=('dev', 'uid'),
                )

        leftovers = []
        for root, _dirs, files in os.walk(self.tmp):
            leftovers.extend(os.path.join(root, f) for f in files)
        self.assertEqual(leftovers, [], f'失败后还剩下临时文件：{leftovers}')

    def test_vad_runs_on_stitched_runs_not_on_raw_files(self):
        """VAD 的输入必须是缝合后的音轨。

        这是缺陷 ① 的接线断言：`stitch_contiguous_files` 写得再对，如果 VAD 还是
        喂原始文件，跨边界的句子照样被切两半。两个各自正确的函数没接起来。
        """
        import io

        class FakeUpload:
            def __init__(self, filename):
                self.filename = filename
                self.file = io.BytesIO(b'\x00' * 16)

        vad_inputs = []

        with mock.patch.object(sync.dev_db, 'claim_synced_file', return_value=True), \
             mock.patch.object(sync.dev_db, 'release_synced_file_claim'), \
             mock.patch.object(sync, 'decode_files_to_wav', side_effect=lambda paths: list(paths)), \
             mock.patch.object(sync, 'stitch_contiguous_files',
                               return_value=[('syncing/uid/stitched_1754700000.wav', 1754700000)]), \
             mock.patch.object(sync, 'retrieve_vad_segments',
                               side_effect=lambda path, out: (vad_inputs.append(path), out.add(path))), \
             mock.patch.object(sync, 'transcribe_segment', side_effect=lambda p, t: None):
            sync.sync_local_files(
                files=[FakeUpload('audio_1754700000.bin'), FakeUpload('audio_1754700060.bin')],
                ctx=('dev', 'uid'),
            )

        self.assertEqual(vad_inputs, ['syncing/uid/stitched_1754700000.wav'],
                         f'VAD 拿到的不是缝合后的音轨：{vad_inputs}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
