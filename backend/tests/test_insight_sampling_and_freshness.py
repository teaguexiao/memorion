"""证据采样与货龄折旧：两条都是「同预算下别丢掉有用的东西」。

判据不是拍的，来自 2026-08-19 对四个重度用户账本的回溯：把**历史卡片真实引用过的
原话**当成金标，量各种采样策略在同预算下能保住多少。结论：

    纯时间均匀   8/38      ← digest 原来用的就是这个
    长度70+均匀30  21/38    ← quotes 原来用的
    纯按长度     23/38
    按天分配+天内长度 27/38  ← 现在用的

而货龄折旧的判据是「卡片依据的窗口与当前窗口的重叠比例」，不是调出来的衰减率。
"""

import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BACKEND_DIR)

from utils.insights import facts as facts_mod  # noqa: E402
from utils.insights import valve as valve_mod  # noqa: E402

NOW = datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc)


def _q(date: str, text: str, time: str = '10:00') -> dict:
    return {'text': text, 'date': date, 'time': time, 'conversation_id': f'c-{date}-{len(text)}'}


def _d(date: str, n: int) -> dict:
    return {'date': date, 'time': '10:00', 'title': f't{n}', 'overview': 'o', 'conversation_id': f'c{date}-{n}'}


class TestQuoteThinning(unittest.TestCase):
    def test_every_day_keeps_a_representative(self):
        """话最多的那天不许吃掉全部名额 —— 跨日期的复现是提名 prompt 立论的基础。"""
        quotes = [_q('2026-08-01', 'x' * (200 - i)) for i in range(100)]      # 话很多的一天
        quotes += [_q(f'2026-08-{d:02d}', 'y' * 30) for d in range(2, 12)]    # 另外 10 天各 1 条
        picked = facts_mod._thin_quotes(quotes, 20)
        self.assertLessEqual(len(picked), 20)
        days = {q['date'] for q in picked}
        self.assertEqual(
            len(days), 11,
            f'只保住了 {len(days)} 天 —— 长句全在 08-01，纯按长度会把日期塌缩掉',
        )

    def test_within_a_day_longer_quotes_win(self):
        """长句是强信号：全池长度中位 24 字符，被真实引用过的中位 89。"""
        quotes = [_q('2026-08-01', 'a' * 200), _q('2026-08-01', 'b' * 12)]
        quotes += [_q(f'2026-08-{d:02d}', 'c' * 50) for d in range(2, 20)]
        picked = facts_mod._thin_quotes(quotes, 19)
        day1 = [q['text'] for q in picked if q['date'] == '2026-08-01']
        self.assertIn('a' * 200, day1)
        self.assertNotIn('b' * 12, day1, '同一天里短句不该顶掉长句')

    def test_under_budget_is_returned_untouched(self):
        quotes = [_q('2026-08-01', 'a' * 20), _q('2026-08-02', 'b' * 20)]
        self.assertEqual(facts_mod._thin_quotes(list(quotes), 10), quotes)

    def test_budget_is_never_exceeded_even_with_more_days_than_budget(self):
        """天数比预算还多时 per_day=1 仍会超预算 —— 必须再截一刀。"""
        quotes = [_q(f'2026-0{7 if d <= 31 else 8}-{((d - 1) % 31) + 1:02d}', 'a' * (10 + d)) for d in range(1, 50)]
        picked = facts_mod._thin_quotes(quotes, 5)
        self.assertLessEqual(len(picked), 5)

    def test_result_is_in_time_order(self):
        quotes = [_q('2026-08-03', 'a' * 99), _q('2026-08-01', 'b' * 50), _q('2026-08-02', 'c' * 70)]
        picked = facts_mod._thin_quotes(quotes, 2)
        self.assertEqual([q['date'] for q in picked], sorted(q['date'] for q in picked))


class TestDigestThinning(unittest.TestCase):
    def test_a_busy_day_does_not_starve_the_quiet_ones(self):
        """原来是按下标均匀取，对话按时间排序 ⇒ 话多的那天吃掉名额、话少的天整天消失。"""
        items = [_d('2026-08-01', n) for n in range(100)]
        items += [_d(f'2026-08-{d:02d}', 0) for d in range(2, 12)]
        picked = facts_mod._thin_digest(items, 20)
        self.assertLessEqual(len(picked), 20)
        self.assertEqual(len({it['date'] for it in picked}), 11)

    def test_under_budget_untouched(self):
        items = [_d('2026-08-01', 1), _d('2026-08-02', 2)]
        self.assertEqual(facts_mod._thin_digest(list(items), 10), items)


class TestFreshnessFactor(unittest.TestCase):
    def test_factor_is_the_window_overlap_ratio(self):
        """不是调出来的衰减率，就是重叠比例本身。"""
        h = valve_mod.STALENESS_HORIZON_DAYS
        for age, expected in ((0, 1.0), (h / 2, 0.5), (h, 0.0), (h * 2, 0.0)):
            row = {'created_at': NOW - timedelta(days=age)}
            self.assertAlmostEqual(valve_mod.freshness_factor(row, now=NOW), expected, places=6)

    def test_horizon_matches_the_observation_window(self):
        """地平线等于引擎的观察窗口不是巧合，而是判据本身 —— 一起改或都不改。"""
        with open(os.path.join(BACKEND_DIR, 'modal/memorion_insight_engine.py'), encoding='utf-8') as f:
            src = f.read()
        self.assertIn(
            f'WINDOW_DAYS = {valve_mod.STALENESS_HORIZON_DAYS}', src,
            'STALENESS_HORIZON_DAYS 与 cron 的 WINDOW_DAYS 脱钩了 —— '
            '折旧的语义（窗口重叠比例）就不成立了',
        )

    def test_missing_created_at_is_treated_as_fresh(self):
        """读不到货龄就不打折：宁可让一张卡多留一轮，也不要因为字段缺失把它静默淘汰。"""
        self.assertEqual(valve_mod.freshness_factor({}, now=NOW), 1.0)


class TestPickNextPrefersFresh(unittest.TestCase):
    @staticmethod
    def _card(topic, worth, age_days, conf=80, depth='深读段正文。'):
        return {
            'topic_key': topic,
            'worth': worth,
            'confidence': conf,
            'status': 'mature',
            'depth': depth,
            'created_at': NOW - timedelta(days=age_days),
        }

    def test_high_worth_old_card_no_longer_blocks_a_fresh_one(self):
        """回归用例：池里 22 天前 worth 90 的那条压着后面所有卡。"""
        old = self._card('old', 90, 22)
        fresh = self._card('fresh', 78, 1)
        picked = valve_mod.pick_next([old, fresh], ledger=[], known_topics={}, now=NOW)
        self.assertEqual(picked['topic_key'], 'fresh')

    def test_it_does_not_chase_novelty_when_the_pool_is_already_fresh(self):
        """两条都很新时，worth 仍然说话 —— 折旧只是打折，不是反转排序。"""
        strong = self._card('strong', 90, 3)
        weak = self._card('weak', 60, 1)
        picked = valve_mod.pick_next([strong, weak], ledger=[], known_topics={}, now=NOW)
        self.assertEqual(picked['topic_key'], 'strong')

    def test_discount_does_not_gate_eligibility(self):
        """折扣只排序、不参与门槛：否则积压的卡集体跌破 45 分，池里有货却发不出。"""
        # worth 50、货龄 30 天 ⇒ 折后 25，远低于 MIN_WORTH_TO_RELEASE(45)
        aging = self._card('aging', 50, 30)
        self.assertLess(
            aging['worth'] * valve_mod.freshness_factor(aging, now=NOW),
            valve_mod.MIN_WORTH_TO_RELEASE,
        )
        picked = valve_mod.pick_next([aging], ledger=[], known_topics={}, now=NOW)
        self.assertIsNotNone(picked, '折扣渗进门槛了 —— 这条卡本身够格，只是躺久了')
        self.assertEqual(picked['topic_key'], 'aging')

    def test_zero_freshness_is_the_only_hard_drop(self):
        """货龄 ≥ 地平线：依据的窗口已整段滑出视野，不该再占卡位。"""
        expired = self._card('expired', 100, valve_mod.STALENESS_HORIZON_DAYS + 1)
        self.assertIsNone(valve_mod.pick_next([expired], ledger=[], known_topics={}, now=NOW))

    def test_fatigue_window_still_short_circuits(self):
        ledger = [{'status': 'released', 'released_at': NOW - timedelta(days=1)}]
        self.assertIsNone(
            valve_mod.pick_next([self._card('x', 90, 0)], ledger=ledger, known_topics={}, now=NOW)
        )


class TestDepthIsRequiredToRelease(unittest.TestCase):
    """没有深读段的条目不许出卡（2026-08-19 生产事故的不变式）。

    ⚠️ 这几条断言刻意不经 `pick_next` 的排序：那次事故里排序是**对的**（新卡 68 分本该
    压过老货折后 54.3 分），失效的是「池子里当时只有老货」。所以门槛必须在单条条目上
    成立，而不是靠竞争胜出。
    """

    _card = staticmethod(TestPickNextPrefersFresh._card)

    def test_no_depth_is_not_eligible_however_high_it_scores(self):
        # 生产原型：worth 75 / confidence 75 / body 32 字 / depth 无
        shell = self._card('tech-discussion-frequency', 75, 17, conf=75, depth=None)
        self.assertFalse(valve_mod.eligible(shell))

    def test_blank_depth_counts_as_missing(self):
        """空串和纯空白都要挡住——模型偶尔回一个 '\\n' 而不是 null。"""
        for blank in ('', '   ', '\n\n'):
            self.assertFalse(valve_mod.eligible(self._card('t', 90, 0, depth=blank)), repr(blank))

    def test_a_lone_shell_card_cannot_be_released_even_with_nothing_to_compete(self):
        """这才是事故的真实形态：池子里只剩空壳老货，它没有对手也照样出不去。"""
        shell = self._card('shell', 75, 17, conf=75, depth=None)
        self.assertIsNone(valve_mod.pick_next([shell], ledger=[], known_topics={}, now=NOW))

    def test_a_fresh_card_with_depth_still_gets_through(self):
        """别把门关到把好卡也挡了。"""
        good = self._card('acknowledgment-before-probe', 68, 0, conf=75)
        picked = valve_mod.pick_next([good], ledger=[], known_topics={}, now=NOW)
        self.assertEqual(picked['topic_key'], 'acknowledgment-before-probe')

    def test_shell_card_loses_to_a_lower_scoring_card_with_depth(self):
        """存量 8 条空壳里 worth 最高的两条是 70，比带 depth 的新卡分高。

        空壳这里刻意也取货龄 1 天：只有这样新鲜度折扣才帮不上忙（70×0.98 > 58×0.98），
        胜负必须由 depth 门禁决定，否则这条断言测的是排序、不是门禁。
        """
        shell = self._card('weekday-work-concentration', 70, 1, depth=None)
        good = self._card('anyway-pragmatic-anchor', 58, 1, conf=68)
        picked = valve_mod.pick_next([shell, good], ledger=[], known_topics={}, now=NOW)
        self.assertEqual(picked['topic_key'], 'anyway-pragmatic-anchor')

    def test_cold_start_scaffold_is_not_collateral_damage(self):
        """脚手架卡刻意 depth=None，但它不走 pick_next —— 这条门禁碰不到它。"""
        with open(os.path.join(BACKEND_DIR, 'utils/insights/engine.py'), encoding='utf-8') as f:
            src = f.read()
        scaffold_at = src.index('**_SCAFFOLD')
        pick_at = src.index('valve_mod.pick_next(')
        self.assertLess(
            pick_at, scaffold_at,
            '脚手架卡被挪到 pick_next 之前了 —— 那它就会撞上 depth 门禁，'
            '冷启动用户从此一张卡都收不到',
        )


if __name__ == '__main__':
    unittest.main()
