"""章节边界：只由物理静音决定，永不由时钟算术决定。

这个文件存在的理由是**钉住几个反直觉的决策**，防止将来被「优化」回去：

1. **没有时长硬上限。** 曾计划 45min 强制断开，被实测否决：23 个超长章节里 14 个
   内部最大 gap < 1min（有的是负值=区间重叠），根本没有可信切点；有 gap 的 9 个最大
   也只 3.5–7.2min，**全都小于合并阈值** —— 拿它当切点与合并规则自相矛盾。递归切只让
   265 章变 294 章，p90 一点没动，代价是 37 章在语音中间被截断。用例 3 就是这条的哨兵。

2. **规则挂在 segment 层。** conversation 是传输产物：批量转录的固定切块彼此相接
   （gap 恒为 0）、一个 3 小时长文件整段没有 gap。conversation 级规则在那个形态下
   **静默失效**（算出来全是 0，一整天合成一章）。用例 12 用固定切块形态钉住这点。

3. **实时链路的 conversation 不拆开。** 它的边界本身就来自物理静音（120s flush），
   内部不该存在 8min 静音；真出现只能是数据异常，拆它没收益只有风险。批量转录反过来
   —— 文件边界无意义，内部静音才是唯一真信号。用例 11 / 12 是这组对照。

用标准库 `zoneinfo` 而不是生产依赖的 `pytz`：时区只用来做 `astimezone().date()`，
两者行为一致，而 `pytz` 在本地 venv 常常没装 —— 测试不该因环境缺包变成环境问题。

Run:
    cd backend && python3 tests/test_timeline_chaptering.py
"""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")

from utils.timeline.chaptering import (  # noqa: E402
    DEDUP_TEXT_RATIO,
    GAP_MERGE_MINUTES,
    MIN_CONTAINMENT_CHARS,
    collect_segment_refs,
    dedup_segment_refs,
    filter_convos_for_local_day,
    segment_day_into_chapters,
)

DAY = datetime(2026, 8, 6, 0, 0, tzinfo=timezone.utc)


def at(hour: float) -> datetime:
    """当天 UTC 的某个小时（可带小数）。"""
    return DAY + timedelta(hours=hour)


def convo(
    started_at: datetime,
    segments,
    convo_id=None,
    source='app',
    discarded=False,
    title='untitled',
):
    """一条 conversation。`segments` 是 (start_offset_s, end_offset_s, text) 三元组。

    注意 `started_at` 是**唯一的时间锚点** —— 段的绝对时间由它加 `start` 推导
    （实测 3679/3679 个 segment 都不带绝对 timestamp）。
    """
    return {
        'id': convo_id or f'c-{started_at.isoformat()}-{source}',
        'source': source,
        'discarded': discarded,
        'started_at': started_at,
        'finished_at': started_at + timedelta(seconds=segments[-1][1] if segments else 0),
        'transcript_segments': [
            {'start': s, 'end': e, 'text': t, 'is_user': False, 'person_id': None} for s, e, t in segments
        ],
        'structured': {'title': title, 'overview': '', 'emoji': '🧠'},
    }


def talking(started_at: datetime, minutes: float, source='app', convo_id=None, title='untitled', gap_s=1.0):
    """一条「持续说话」的 conversation：每 10s 一句，句间 gap_s 秒。

    真实数据里 87.4% 的段间隙 < 30s，所以默认 1s 代表正常语流。
    """
    segments = []
    t = 0.0
    step = 10.0
    while t < minutes * 60:
        segments.append((t, min(t + step, minutes * 60), f'sentence at {t:.0f}s'))
        t += step + gap_s
    return convo(started_at, segments, convo_id=convo_id, source=source, title=title)


class ChapterBoundaryTests(unittest.TestCase):
    def test_short_gap_merges(self):
        """用例 1：gap=13s 的两条合成一章（Phase 0 的真实样本形态）。

        这类边界是 WS 断连兜底的产物，纯粹是网络状态，没有任何语义 —— 合并不丢信息。
        """
        a = talking(at(9), 10, title='TikTok Strategy')
        b = talking(at(9) + timedelta(minutes=10, seconds=13), 10, title='Image to 3D')
        chapters = segment_day_into_chapters([a, b])
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0]['source_conversation_ids'], [a['id'], b['id']])

    def test_gap_threshold_boundary(self):
        """用例 2：7min59s 合并、8min01s 分开 —— 阈值两侧各验一次。"""
        base = talking(at(9), 5)
        for delta_s, expected in ((7 * 60 + 59, 1), (8 * 60 + 1, 2)):
            with self.subTest(gap_seconds=delta_s):
                later = talking(at(9) + timedelta(minutes=5, seconds=delta_s), 5)
                self.assertEqual(len(segment_day_into_chapters([base, later])), expected)

    def test_no_duration_cap(self):
        """用例 3（哨兵）：30 条各 15min、gap 都 1min → 仍是 1 章约 8 小时。

        任何把时长上限加回来的改动都会在这里失败。时长上限是时钟算术，是伪边界。
        """
        convos = []
        cursor = at(9)
        for i in range(30):
            convos.append(talking(cursor, 15, convo_id=f'c{i}'))
            cursor += timedelta(minutes=16)
        chapters = segment_day_into_chapters(convos)
        self.assertEqual(len(chapters), 1, '出现了时长上限或别的非静音断开条件')
        self.assertGreater(chapters[0]['duration_seconds'], 7.5 * 3600)
        self.assertEqual(len(chapters[0]['source_conversation_ids']), 30)

    def test_single_long_conversation_stays_one_chapter(self):
        """用例 4：单条 90min 不被细切 —— 语义细切在 Phase 1 是恒等函数。"""
        chapters = segment_day_into_chapters([talking(at(9), 90)])
        self.assertEqual(len(chapters), 1)

    def test_real_silence_inside_day_splits(self):
        """静音 > 阈值就断开 —— 这是唯一的断开条件，正向验一次。"""
        morning = talking(at(9), 20)
        evening = talking(at(19), 20)
        chapters = segment_day_into_chapters([morning, evening])
        self.assertEqual(len(chapters), 2)
        self.assertLess(chapters[0]['start'], chapters[1]['start'])

    def test_overlapping_blocks_do_not_manufacture_gap(self):
        """区间包含时不能凭空造出 gap（实测 12.4% 的相邻对是重叠的）。

        若按「上一块的 end」而不是「组内最大 end」比较，被包含的短块结束后
        会让后面的内容看起来隔了很久 —— 那个 gap 没有任何听者体验过。
        """
        long_one = talking(at(9), 60, convo_id='long')
        nested = talking(at(9) + timedelta(minutes=5), 5, convo_id='nested')
        tail = talking(at(9) + timedelta(minutes=62), 5, convo_id='tail')
        chapters = segment_day_into_chapters([long_one, nested, tail])
        self.assertEqual(len(chapters), 1)


class DedupTests(unittest.TestCase):
    def test_same_text_same_time_dedups_keeping_realtime(self):
        """用例 5：同一时段 + 同文本 = 两个来源录了同一段话，保留实时那份。

        实时路径带声纹与 person_id，质量高于 sdcard 路径。
        """
        live = convo(at(9), [(0, 10, 'hello world'), (11, 20, 'second line')], convo_id='live', source='app')
        card = convo(at(9), [(0, 10, 'hello world'), (11, 20, 'second line')], convo_id='card', source='sdcard')
        refs, dropped = dedup_segment_refs(collect_segment_refs([live, card]))
        self.assertEqual(len(refs), 2)
        self.assertEqual({r.conversation_id for r in refs}, {'live'})
        self.assertEqual({r.conversation_id for r in dropped}, {'card'})

    def test_different_text_same_time_is_not_dedup(self):
        """用例 6：时间重叠但文本不同 = 真的两个人同时说话，不能去重。"""
        a = convo(at(9), [(0, 10, 'I think we should ship it today')], convo_id='a', source='app')
        b = convo(at(9), [(0, 10, 'the weather is terrible this week')], convo_id='b', source='sdcard')
        refs, dropped = dedup_segment_refs(collect_segment_refs([a, b]))
        self.assertEqual(len(refs), 2)
        self.assertEqual(dropped, [])

    def test_repeated_utterance_within_one_conversation_survives(self):
        """同一条 conversation 内的重复话语是真的说了两遍，不是重复录入。"""
        one = convo(at(9), [(0, 2, '嗯'), (5, 7, '嗯')], convo_id='one', source='app')
        refs, dropped = dedup_segment_refs(collect_segment_refs([one]))
        self.assertEqual(len(refs), 2)
        self.assertEqual(dropped, [])

    def test_dedup_does_not_shrink_speech_time_below_reality(self):
        """去重后 speech_seconds 不应把重叠录音累加成比一天还长的时间。"""
        live = talking(at(9), 10, source='app', convo_id='live')
        card = talking(at(9), 10, source='sdcard', convo_id='card')
        chapters = segment_day_into_chapters([live, card])
        self.assertEqual(len(chapters), 1)
        self.assertLessEqual(chapters[0]['speech_seconds'], chapters[0]['duration_seconds'] + 1)


class AccumulatedPrefixTests(unittest.TestCase):
    """累积前缀式重复：靠**包含关系**抓，靠相似度永远抓不到，靠字数/秒不该去抓。

    形态取自生产真实数据（2026-05-03，5 条会话）：实时链路的 re-flush bug 让同一个
    STT 段在每次 flush 后又被当成新段写进下一条会话，而每次更新都带**整段累积文本**,
    于是同一天出现 5 条各含 1 个段的会话,文本互为严格前缀（74→179→617→684→2101 字）,
    `end` 一路涨到 17012s —— 2101 个字声称占了 4.7 小时。

    伤害不是「某条会话时长不准」,而是**一个坏段把 5 段无关录音粘成 8.66 小时一章**。
    全库 111 条会话带这种段,93 个章节受影响,其中 62 个粘了多条会话。

    采集侧已在 `developer_listen.py` 修（`flushed_segment_ids`）,但存量数据改不了,
    所以章节层必须自己扛住 —— 这两层各测一遍,不能只测一层。

    ⚠️ 曾经在这里还试过第二条路：段的时长与字数差两个数量级就按字数重算。
    **408 用户日 A/B 实测否决**：只开包含去重是 ≥2h 章节 51→49、粘连 38→35，
    加上时长重算反而变成 1424→1432 章（更碎）而 ≥2h 只到 50。见 `chaptering.py`
    里替代 `MIN_CHARS_PER_SECOND` 的那段注释。下面最后一个用例是它的反向哨兵。
    """

    def test_prefix_superset_copies_are_deduped(self):
        """互为严格前缀的拷贝要被判重 —— 相似度永远抓不到它们。

        实测这 5 份拷贝的两两相似度只有 0.068–0.585,而 `startswith` 全部命中。
        这是**包含关系,不是相似关系**,阈值调不出来。
        """
        # 长度取自真实数据：最短那份 74 字，最长 2101 字。
        base = '喂喂喂，1234567。转换，成不成功？不是我现在就是想把它换掉，这是充电宝。关于两项我们就点赞啊。哎呦，这个东西还挺有意思的。'
        longer = base + '我再多说几句话，看看转录还能不能跟上，这段是后面才累积进来的内容。' * 3
        self.assertGreaterEqual(len(base), MIN_CONTAINMENT_CHARS)
        from difflib import SequenceMatcher
        ratio = SequenceMatcher(None, base, longer).ratio()
        self.assertLess(ratio, DEDUP_TEXT_RATIO, '前提没成立：这两份靠相似度就能抓到')

        short = convo(at(9), [(0.0, 90.0, base)], convo_id='short-copy')
        full = convo(at(9) + timedelta(seconds=10), [(0.0, 90.0, longer)], convo_id='full-copy')
        refs, dropped = dedup_segment_refs(collect_segment_refs([short, full]))
        self.assertEqual(len(refs), 1, '前缀超集没被判重')
        self.assertEqual(len(dropped), 1)
        # 保留更完整的那份,否则去重反而截断了句子
        self.assertEqual(refs[0].text, longer)

    def test_short_prefix_utterances_are_not_deduped(self):
        """反向哨兵：短句互为前缀是正常的（「好」是「好的，我明白了」的前缀）。"""
        a = convo(at(9), [(0.0, 2.0, '好')], convo_id='a')
        b = convo(at(9) + timedelta(seconds=5), [(0.0, 3.0, '好的，我明白了')], convo_id='b')
        refs, dropped = dedup_segment_refs(collect_segment_refs([a, b]))
        self.assertEqual(len(refs), 2, '短句前缀被误判成重复')
        self.assertEqual(dropped, [])

    def test_sparse_speech_keeps_its_full_span(self):
        """哨兵：字少时间长的段不许被按字数缩短 —— 稀疏语音是真的。

        「哇。」占 63.8s（0.031 字/秒）是生产真实段，同一区间里还有
        「你这个人你以后去教。」占 262.6s。3644 个超 60s 的段里有 136 个落在
        0.05 字/秒以下，分布上**没有断点**可以把它们和坏段分开 —— 按字数重算
        会静默截短这些真实录音。任何「span 由 text 推导」的改动都会在这里失败。
        """
        for text, span in (('哇。', 63.8), ('你这个人你以后去教。', 262.6)):
            with self.subTest(text=text, span=span):
                c = convo(at(9), [(0.0, span, text)], convo_id='sparse')
                chapters = segment_day_into_chapters([c])
                self.assertAlmostEqual(
                    chapters[0]['duration_seconds'], span, places=1,
                    msg='段的时长被按字数改写了；这条是真实稀疏语音，不是坏数据',
                )


class DayAttributionTests(unittest.TestCase):
    def test_cross_midnight_belongs_to_start_day(self):
        """用例 7：23:40 起、00:20 结束 → 整条归到开始那天。"""
        tz = timezone.utc
        overnight = talking(datetime(2026, 8, 6, 23, 40, tzinfo=timezone.utc), 40)
        self.assertEqual(len(filter_convos_for_local_day([overnight], tz, DAY.date())), 1)
        self.assertEqual(len(filter_convos_for_local_day([overnight], tz, DAY.date() + timedelta(days=1))), 0)

    def test_local_timezone_decides_the_day(self):
        """用例 8：UTC+8 用户的本地 00:30 会话归本地日，不是 UTC 日。

        UTC 时间是前一天 16:30 —— 按 UTC 分组会把它算到前一天，用户看到的是「昨天」
        多出一段凌晨的内容。
        """
        tz = ZoneInfo('Asia/Shanghai')
        local_early = talking(datetime(2026, 8, 6, 16, 30, tzinfo=timezone.utc), 20)
        self.assertEqual(len(filter_convos_for_local_day([local_early], tz, DAY.date() + timedelta(days=1))), 1)
        self.assertEqual(len(filter_convos_for_local_day([local_early], tz, DAY.date())), 0)


class RobustnessTests(unittest.TestCase):
    def test_idempotent_across_repeated_runs(self):
        """用例 9：同一天算 10 次结果完全一致 —— Phase 2 的幂等覆写依赖这条。"""
        convos = [talking(at(9), 10, convo_id='a'), talking(at(11), 10, convo_id='b')]
        first = segment_day_into_chapters(convos)
        for _ in range(9):
            self.assertEqual(segment_day_into_chapters(convos), first)

    def test_order_of_input_does_not_matter(self):
        """输入顺序无关 —— Firestore 的 get_all 会打乱顺序（chat 侧踩过这个坑）。"""
        convos = [talking(at(9), 10, convo_id='a'), talking(at(11), 10, convo_id='b'), talking(at(15), 5, convo_id='c')]
        self.assertEqual(segment_day_into_chapters(convos), segment_day_into_chapters(list(reversed(convos))))

    def test_empty_and_discarded_inputs(self):
        """用例 10：空输入 / 全 discarded → 返回 []，不抛异常。"""
        self.assertEqual(segment_day_into_chapters([]), [])
        self.assertEqual(segment_day_into_chapters([talking(at(9), 5) | {'discarded': True}]), [])

    def test_conversation_without_transcript_is_not_lost(self):
        """没有 transcript 的会话仍要出现在章节里 —— 用户今天能在首页看到它。

        但它只占一个瞬间，不能拿 started_at→finished_at 去声明一段时长，
        否则一条空会话能把两个无关章节粘起来。
        """
        empty = convo(at(9), [], convo_id='empty')
        chapters = segment_day_into_chapters([empty])
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0]['source_conversation_ids'], ['empty'])
        self.assertEqual(chapters[0]['segment_refs'], [])

    def test_fully_deduped_conversation_does_not_return_as_empty_chapter(self):
        """整条被判重复的会话不许借「没有 transcript」的兜底路径复活成空白卡。

        这是「两个各自正确的函数接起来是错的」的实例，实测才发现：去重对 94 对
        逐字重复全部命中（一个不漏），但其中 3 对**仍然出 2 章**，第二章 0 段、
        0 秒语音 —— 用户本来不该看见的那条重复，变成了一张空白卡片。

        原因是 `build_blocks` 看到的只是「这条会话名下没有段」，而这有两种成因：
        从来没有可用 transcript（该给占位块，见上一个用例），以及**它的每一段都被
        去重丢掉了**（该整条消失）。两者在函数入口处长得一模一样，所以要把
        `dedup_segment_refs` 丢弃的那份显式传进去才能分开。

        用例形态取自真实数据：两条 `source=app` 会话，段文本逐字相同、时间重叠。
        """
        text = 'exactly the same sentence recorded twice'
        keeper = convo(at(9), [(0.0, 6.0, text)], convo_id='keeper')
        # 晚 8s 落库的同一句话；重叠且文本相同 → 必然判重。
        dupe = convo(at(9) + timedelta(seconds=8), [(0.0, 6.0, text)], convo_id='dupe')

        refs, dropped = dedup_segment_refs(collect_segment_refs([keeper, dupe]))
        self.assertEqual(len(refs), 1, '前提没成立：这两条本该被判为重复')
        self.assertEqual(len(dropped), 1)

        chapters = segment_day_into_chapters([keeper, dupe])
        self.assertEqual(len(chapters), 1, f'重复的那条复活成了空白章节：{chapters}')
        self.assertEqual(chapters[0]['source_conversation_ids'], ['keeper'])
        # 没有任何一章可以是 0 段 —— 那正是空白卡的形状。
        for chapter in chapters:
            self.assertTrue(chapter['segment_refs'])

    def test_partially_deduped_conversation_survives(self):
        """只有部分段被判重复时，会话必须留下 —— 别把去重做成整条丢弃。"""
        shared = 'the overlapping sentence'
        keeper = convo(at(9), [(0.0, 6.0, shared)], convo_id='keeper')
        partial = convo(
            at(9) + timedelta(seconds=8),
            [(0.0, 6.0, shared), (30.0, 40.0, 'a sentence only this one has')],
            convo_id='partial',
        )
        chapters = segment_day_into_chapters([keeper, partial])
        self.assertEqual(len(chapters), 1)
        self.assertIn('partial', chapters[0]['source_conversation_ids'])
        self.assertEqual(len(chapters[0]['segment_refs']), 2)

    def test_malformed_segments_are_skipped_not_fatal(self):
        """脏 segment（缺 start、text 为空、类型不对）跳过即可，不能让整天算不出来。"""
        dirty = {
            'id': 'dirty',
            'source': 'app',
            'started_at': at(9),
            'transcript_segments': [
                {'start': 0, 'end': 5, 'text': 'good line'},
                {'start': 'oops', 'end': 5, 'text': 'bad start'},
                {'start': 10, 'end': 15, 'text': '   '},
                'not-a-dict',
                {'start': 20, 'text': 'missing end'},
            ],
        }
        chapters = segment_day_into_chapters([dirty])
        self.assertEqual(len(chapters), 1)
        self.assertEqual(len(chapters[0]['segment_refs']), 2)


class SplitPolicyTests(unittest.TestCase):
    """拆不拆一条 conversation，由 source 决定 —— 这是本方案最容易被误改的一处。"""

    def test_realtime_conversation_is_never_split(self):
        """用例 11：实时链路内部即使有 30min 静音也不拆。

        它的边界已经来自 120s flush，内部不该有这种静音；真出现是数据异常
        （锚点错、段偏移错），按异常数据切分只会造出更错的边界。
        """
        weird = convo(at(9), [(0, 10, 'first half'), (1800, 1810, 'much later')], convo_id='live', source='app')
        chapters = segment_day_into_chapters([weird])
        self.assertEqual(len(chapters), 1)
        self.assertEqual(chapters[0]['source_conversation_ids'], ['live'])

    def test_batch_conversation_splits_on_internal_silence(self):
        """用例 12：批量转录的长文件按段级静音拆开 —— 文件边界无意义，静音才是真信号。

        这正是 conversation 级规则会静默失效的形态：一个 3 小时上传整段没有 gap。
        """
        long_file = convo(
            at(9),
            [(0, 600, 'morning talk'), (600 + 40 * 60, 600 + 40 * 60 + 600, 'afternoon talk')],
            convo_id='upload',
            source='audio_upload',
        )
        chapters = segment_day_into_chapters([long_file])
        self.assertEqual(len(chapters), 2)
        self.assertEqual([c['source_conversation_ids'] for c in chapters], [['upload'], ['upload']])

    def test_fixed_size_chunks_merge_then_split_on_real_silence(self):
        """固定切块形态：块间 gap 恒为 0，真实静音全在块内部。

        conversation 级规则在这里会把一整天合成一章；段级规则按块内静音正确切成两章。
        """
        chunks = []
        cursor = at(9)
        for i in range(6):
            # 前 3 块连续说话；第 4 块中间有 20min 真静音
            if i == 3:
                segs = [(0, 10, f'chunk{i} head'), (20 * 60 + 10, 20 * 60 + 20, f'chunk{i} tail')]
            else:
                segs = [(0, 30, f'chunk{i} a'), (31, 60, f'chunk{i} b')]
            chunks.append(convo(cursor, segs, convo_id=f'chunk{i}', source='sdcard'))
            cursor += timedelta(seconds=60)
        chapters = segment_day_into_chapters(chunks)
        self.assertEqual(len(chapters), 2)

    def test_unknown_source_is_treated_as_atomic(self):
        """未知 source 按不可拆处理（fail closed）—— 宁可少切，不可凭空造边界。"""
        weird = convo(at(9), [(0, 10, 'a'), (3600, 3610, 'b')], convo_id='x', source='some_future_source')
        self.assertEqual(len(segment_day_into_chapters([weird])), 1)


class VoiceRunsTests(unittest.TestCase):
    """`voice_runs` 必须是**不相交、递增**的语音区间序列，且与 speech_seconds 同源。

    形态取自生产真实数据（2026-08-05，用户 mcaK…，18:21–19:45 那一章）：三条会话
    声称占用同一段真实时间 —— 一条 84min 的 + `closest_memory` 拼接产生的 9.5min
    副本 + 内容真不同的 6.5min 饭桌录音，后两条完整**嵌套**在第一条里面。

    ⚠️ 不能用 block 的 span 直出这个字段：block 会嵌套，那一章直出就是三条相加
    99.8min，装在一个 83.7min 的章节里。任何把它们加起来的消费方（时间轴条、
    未佩戴空档计算、页头小时数）都会报出比章节本身还长的语音时间。而且这种错**不会
    自己暴露**：三个数字各自都像合理值。
    """

    def _chapter(self):
        # 长会话 + 完整嵌套其中的两条短会话。文本各不相同，所以不该被内容去重挡掉
        # （这正是生产那一章的情况：只有一条是真副本，另一条是真内容）。
        long = convo(at(9), [(0, 600, 'the long recording, first half'), (3600, 4200, 'the long recording, later')], convo_id='long')
        inner_a = convo(at(9) + timedelta(minutes=2), [(0, 120, 'a different thing said meanwhile')], convo_id='inner-a')
        inner_b = convo(at(9) + timedelta(minutes=62), [(0, 60, 'dinner table chatter, unrelated')], convo_id='inner-b')
        chapters = segment_day_into_chapters([long, inner_a, inner_b])
        self.assertEqual(len(chapters), 1, '这三条互相重叠，必须是一章')
        return chapters[0]

    def test_runs_are_disjoint_and_ascending(self):
        runs = self._chapter()['voice_runs']
        for prev, nxt in zip(runs, runs[1:]):
            self.assertLessEqual(prev['end'], nxt['start'], f'区间重叠: {prev} 与 {nxt}')
            self.assertLess(prev['start'], nxt['start'])

    def test_runs_sum_to_speech_seconds(self):
        """两个字段必须逐秒一致——不一致就说明其中一个把重叠算了两遍。"""
        chapter = self._chapter()
        summed = sum((r['end'] - r['start']).total_seconds() for r in chapter['voice_runs'])
        self.assertAlmostEqual(summed, chapter['speech_seconds'], places=3)

    def test_runs_never_exceed_the_chapter_span(self):
        chapter = self._chapter()
        summed = sum((r['end'] - r['start']).total_seconds() for r in chapter['voice_runs'])
        self.assertLessEqual(summed, chapter['duration_seconds'] + 1)

    def test_content_less_conversation_contributes_no_run(self):
        """没有 transcript 的会话在时间轴上不占区间（它证明不了自己占了时间）。"""
        real = talking(at(9), 5, convo_id='real')
        blank = convo(at(9) + timedelta(minutes=1), [], convo_id='blank')
        chapter = segment_day_into_chapters([real, blank])[0]
        self.assertTrue(all((r['end'] - r['start']).total_seconds() > 0 for r in chapter['voice_runs']))
        self.assertIn('blank', chapter['source_conversation_ids'], '空会话仍要留在溯源里，不能悄悄丢')


class ThresholdConstantTests(unittest.TestCase):
    def test_threshold_sits_in_the_measured_vacuum_band(self):
        """阈值必须落在实测的真空带 1–10min 内。

        87.4% 的段间隙 < 30s，下一堆质量在小时级，中间 1–10min 只有 43 个间隙。
        落在带内意味着取值不敏感；落到带外（比如 30s 或 30min）就变成敏感参数了。
        """
        self.assertGreaterEqual(GAP_MERGE_MINUTES, 1)
        self.assertLessEqual(GAP_MERGE_MINUTES, 10)


if __name__ == '__main__':
    unittest.main(verbosity=2)
