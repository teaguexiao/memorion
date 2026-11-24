"""钉住「客户端重复发帧」探测器。

## 为什么需要这个测试

2026-08-17 查清的故障：App 侧 BLE 音频特征上挂了多个监听器，同一个 10ms opus 帧被发给
服务器 6~14 遍（详见 `app/lib/services/devices/live_subscription_registry.dart`）。

⚠️ **那次故障全链路零错误日志。** Opus 帧合法、解码不报错；音频被复印成 10ms 粒度的卡碟
之后 Soniox **合法地**返回 0 段并正常关闭；VAD 也照跑。也就是说除了「收到的音频秒数远
超墙钟秒数」以外，没有任何一处会响 —— 而这个比值以前从没被算过，两周的损耗就这么无声地
过去了。所以探测器本身就是这次修复的一半，它不能被静默删掉或调坏。

用 `ast` 读源码而不是 import：`routers/developer_listen.py` 的 import 链要 GCP 凭证、
Redis、opuslib，在 CI 上跑不起来；而这里要断言的恰恰是「那几行在不在该在的地方」。
"""

import ast
import os
import re
import unittest

ROUTER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'routers', 'developer_listen.py')


def _source() -> str:
    with open(ROUTER, 'r', encoding='utf-8') as f:
        return f.read()


def _alert_factor(source: str) -> float:
    """从源码里读阈值常量，而不是在测试里再抄一遍数字。"""
    match = re.search(r'^DUPLICATE_FRAME_ALERT_FACTOR\s*=\s*([0-9.]+)', source, re.MULTILINE)
    assert match, 'DUPLICATE_FRAME_ALERT_FACTOR 不见了 —— 探测器的阈值必须是个有名字的常量'
    return float(match.group(1))


class DuplicateAudioFrameDetectorTest(unittest.TestCase):
    def setUp(self):
        self.source = _source()
        self.tree = ast.parse(self.source)

    def test_threshold_separates_healthy_from_broken_sessions(self):
        """阈值必须落在实测的健康值与故障值之间。

        实测样本（同一个账号）：健康会话 0.87 / 0.90 / 1.40 倍，故障会话 6.1 ~ 14.8 倍。
        ⚠️ **别把阈值往 1.0 推。** 1.40 那个是真实的健康会话 —— 墙钟从 `datetime.utcnow()`
        算起，而客户端可能在建连之前就已经缓了一小段音频，比值天然能超过 1。
        """
        factor = _alert_factor(self.source)

        healthy = [0.87, 0.90, 1.40]
        broken = [6.1, 9.2, 14.8]

        for value in healthy:
            self.assertLessEqual(
                value, factor, f'健康会话 {value}x 会误报 —— 阈值 {factor} 太低'
            )
        for value in broken:
            self.assertGreater(
                value, factor, f'故障会话 {value}x 报不出来 —— 阈值 {factor} 太高'
            )

    def test_detector_lives_in_the_websocket_finally_block(self):
        """探测器必须在 WS handler 的 finally 里。

        判据是「会话正常结束和异常断开都要算」：重复发帧的会话多半是被客户端掐断的，
        放在正常返回路径上等于对最需要它的那些会话失明。
        """
        # 找到包含探测器的那个函数
        target = None
        for node in ast.walk(self.tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                segment = ast.get_source_segment(self.source, node) or ''
                if 'DUPLICATE AUDIO FRAMES' in segment:
                    target = node
                    break
        self.assertIsNotNone(target, '源码里找不到重复帧探测器（DUPLICATE AUDIO FRAMES）')

        finally_bodies = [
            ast.get_source_segment(self.source, stmt) or ''
            for stmt in ast.walk(target)
            if isinstance(stmt, ast.Try)
            for stmt in stmt.finalbody
        ]
        self.assertTrue(
            any('DUPLICATE AUDIO FRAMES' in body for body in finally_bodies),
            '探测器必须在 finally 里 —— 重复发帧的会话大多是被客户端掐断的',
        )

    def test_detector_uses_pcm_byte_rate_not_a_hardcoded_number(self):
        """音频秒数必须按 `sample_rate * 2` 算（16-bit 单声道）。

        写死 32000 的话，8kHz 的会话（`sample_rate` 是可选 Query 参数，允许 8000）
        会被算成一半的秒数 —— 真有重复也报不出来。
        """
        detector = self.source[self.source.index('DUPLICATE AUDIO FRAMES') - 1500:self.source.index('DUPLICATE AUDIO FRAMES')]
        self.assertIn(
            'sample_rate * 2',
            detector,
            '音频秒数要按 sample_rate * 2 算，别写死 32000（8kHz 会话会漏报）',
        )

    def test_detector_skips_short_sessions(self):
        """短会话必须跳过，否则日志会被淹。

        几秒的会话里，「建连前缓的那点音频」占比很大，比值随便就上 2 倍。真正值得看的
        是长会话 —— 故障样本全都是几分钟到半小时。
        """
        idx = self.source.index('DUPLICATE AUDIO FRAMES')
        preamble = self.source[idx - 1500:idx]
        self.assertRegex(
            preamble,
            r'duration\s*>\s*\d+',
            '探测器要有会话时长下限，否则短会话会刷满日志',
        )


class RealtimeFactorPersistenceTest(unittest.TestCase):
    """钉住「这个比值必须落库」。

    ⚠️ **事后没有任何办法重算它。** 裁剪后的 wav 除以墙钟得到的是另一个数、而且会放行
    （实测 22fc3b65 原始 5.73×、裁后只剩 1.10×）；而三个「从音频本身判断」的候选判据
    2026-08-17 全部被健康对照组否掉 —— 相邻帧相关度、逐字节全等帧占比、100Hz 梳状谱
    强度（健康 max 53.1 vs 膨胀 min 50.4，没有缝）。所以只有会话结束那一刻算得准。
    """

    def setUp(self):
        self.source = _source()
        with open(os.path.join(os.path.dirname(ROUTER), '..', 'database', 'developer_data.py'), encoding='utf-8') as f:
            self.data_layer = f.read()

    def test_every_session_update_in_the_finally_carries_the_factor(self):
        """收尾的**每一个** `update_listen_session` 都要带上比值。

        ⚠️ 判据是「所有调用点」而不是「至少有一个」。收尾有两条路：主更新，以及它抛异常
        时那条「只写 status」的兜底。而会写不下去的恰恰是段落最多、最异常的那些会话 ——
        只给主路径加上，比值就在最需要它的场合缺失，而且缺得**静默**（字段不存在 ⇒
        重建脚本的门禁放行 ⇒ 又为一段死音频付一次转写钱）。
        """
        tree = ast.parse(self.source)
        target = None
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if 'DUPLICATE AUDIO FRAMES' in (ast.get_source_segment(self.source, node) or ''):
                    target = node
                    break
        self.assertIsNotNone(target, '源码里找不到重复帧探测器所在的函数')

        calls = [
            call
            for stmt in ast.walk(target) if isinstance(stmt, ast.Try)
            for fin in stmt.finalbody
            for call in ast.walk(fin)
            if isinstance(call, ast.Call)
            and getattr(call.func, 'attr', None) == 'update_listen_session'
        ]
        self.assertGreaterEqual(len(calls), 2, 'finally 里应该有主更新 + 只写 status 的兜底两处')
        for call in calls:
            self.assertIn(
                'audio_realtime_factor',
                [kw.arg for kw in call.keywords],
                f'第 {call.lineno} 行的 update_listen_session 没带 audio_realtime_factor',
            )

    def test_data_layer_actually_writes_the_field(self):
        """签名收了参数但没写进 update_data 是本仓库反复踩的「两个各自正确的函数没接起来」。"""
        self.assertIn('audio_realtime_factor: float = None', self.data_layer)
        self.assertRegex(
            self.data_layer,
            r'update_data\[["\']audio_realtime_factor["\']\]\s*=',
            'update_listen_session 收了 audio_realtime_factor 却没写进 update_data',
        )

    def test_factor_is_computed_before_vad_trimming(self):
        """比值必须在 VAD 裁剪**之前**算。

        裁完再算会放行：22fc3b65 原始 608s / 墙钟 106s = 5.73×，裁后只剩 117s ⇒ 1.10×，
        低于任何合理阈值。而这个顺序错了是**静默**的 —— 依然会写一个数进库，只是那个数
        没有分辨力。
        """
        factor_at = self.source.index('realtime_factor = audio_seconds / duration')
        trim_at = self.source.index('vad_trim_silence_bytes(')
        self.assertLess(
            factor_at,
            trim_at,
            'realtime_factor 必须在 vad_trim_silence_bytes 之前算，否则算的是裁剪后的时长',
        )


class RescueScriptInflationGuardTest(unittest.TestCase):
    """钉住「不给不可恢复的音频付转写费」。

    2026-08-17 实测 98d76dff（8.75×）：原始片段 0 段、能量门控后 0 段、stride 7/8/9 各
    相位抽帧后仍是 0 段；而同一天同样切法的健康会话 d06206d2（1.38×）出了 36 个字 ——
    对照组证明管线没问题，是那批音频里真的没有语音（有状态的 opus 解码器把它毁成了嗡鸣）。
    """

    def setUp(self):
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            'scripts', 'rescue_orphaned_listen_sessions.py')
        with open(path, encoding='utf-8') as f:
            self.source = f.read()

    def test_threshold_matches_the_detector(self):
        """门禁阈值不能低于健康会话的实测上限，否则会把能救的也跳过。"""
        match = re.search(r'^_MAX_REALTIME_FACTOR\s*=\s*([0-9.]+)', self.source, re.MULTILINE)
        self.assertIsNotNone(match, '_MAX_REALTIME_FACTOR 不见了')
        threshold = float(match.group(1))
        for healthy in (0.87, 0.90, 1.40):
            self.assertLessEqual(healthy, threshold, f'健康会话 {healthy}x 会被跳过 —— 阈值太低')
        for broken in (5.48, 8.75):
            self.assertGreater(broken, threshold, f'膨胀会话 {broken}x 还是会被转写 —— 阈值太高')

    def test_guard_runs_before_paying_for_transcription(self):
        guard_at = self.source.index('_MAX_REALTIME_FACTOR and not args.force_inflated')
        pay_at = self.source.index('soniox_transcribe_file(\n')
        self.assertLess(guard_at, pay_at, '门禁必须排在 soniox_transcribe_file 之前，否则钱已经花了')

    def test_missing_field_does_not_block_legacy_sessions(self):
        """2026-08-17 之前的会话没有这个字段，门禁必须放行 —— 否则连 --ids 点名都救不回来。"""
        self.assertIn('factor is not None and factor >', self.source,
                      '缺字段时必须放行（存量会话全都没有这个字段）')


if __name__ == '__main__':
    unittest.main()
