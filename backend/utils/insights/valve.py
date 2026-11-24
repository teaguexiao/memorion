"""释放阀（Release Valve）——决定"什么时候推"的确定性代码。

这一层刻意不含 LLM。整套洞察引擎的分工是：
  - 智能端（提名者/怀疑者）负责"有什么可说"，完全放开，不设话题枚举
  - 时机端（本模块）负责"多久打扰一次"，纯规则，产品完全掌控

这样放开话题不会导致轰炸，节流也不会限制模型的想象力。

关键取舍：**只设上限，不设下限。** 没有"每周至少一张"的配额——配额会
逼引擎凑数，凑数就是幻觉的开始。真值得说的事本来就稀少（用创始人 60 天
真实语料实测：9 条提名 → 3 条通过 → 排成 3 张卡）。
"""

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

# 两张卡之间的最小间隔——用户的注意力预算，与"能说什么"无关
MIN_DAYS_BETWEEN_CARDS = 5

# 低于此置信度的提名永不出卡（怀疑者审后分数）
MIN_CONFIDENCE_TO_RELEASE = 60

# 低于此 worth 的提名即便为真也不值得打扰
MIN_WORTH_TO_RELEASE = 45

# 冷启动兜底：陪伴天数 ≤ 此值且账本空时，允许发一张脚手架卡
COLD_START_DAYS = 7

# 货龄折旧的地平线，单位天。取值等于引擎的观察窗口（`WINDOW_DAYS = 60`）不是巧合，
# 而就是判据：一张卡依据的是它被提名那一刻的 60 天窗口，货龄到 60 天时那个窗口与
# 当前窗口**零重叠** —— 它描述的时期已经整段滑出视野，不该再占卡位。
STALENESS_HORIZON_DAYS = 60


def _as_dt(value: Any) -> Optional[datetime]:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value)
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None


def last_release_at(ledger: List[Dict[str, Any]]) -> Optional[datetime]:
    """账本里最近一次真正推给用户的时间。"""
    stamps = [
        _as_dt(row.get('released_at'))
        for row in ledger
        if row.get('status') == 'released'
    ]
    stamps = [s for s in stamps if s]
    return max(stamps) if stamps else None


def in_fatigue_window(ledger: List[Dict[str, Any]], now: Optional[datetime] = None) -> bool:
    """距上次推送是否还没过疲劳窗口。"""
    last = last_release_at(ledger)
    if not last:
        return False
    now = now or datetime.now(timezone.utc)
    return (now - last) < timedelta(days=MIN_DAYS_BETWEEN_CARDS)


def is_duplicate(topic_key: str, known_topics: Dict[str, str]) -> bool:
    """这条是不是账本里已经出现过的话题。

    比对**全部历史**（含 rejected/material），不只是 released——否则被毙掉
    的提名每轮都会重新冒出来，引擎永不收敛。
    """
    return bool(topic_key) and topic_key in known_topics


def eligible(nomination: Dict[str, Any]) -> bool:
    """单条提名是否够格进入排期。

    ⚠️ **没有 depth 的条目一律不许释放（2026-08-20）。** 卡片详情页的主体是深读段——
    没有它，用户点开看到的是一句话正文加一段原话清单，读起来像统计报表而不是洞察。
    2026-08-19 生产上真发生了：`tech-discussion-frequency`（`created_at=08-02`，
    body 32 字、depth 无）被推了出去，而同一批新提名的三条 depth 都是 400~445 字。

    根因不是排序算错：按 `worth × freshness` 重放，新卡 68 分本该压过老货的
    75×0.724=54.3。是 `pick_next` 跑的时候池子里**还没有**本轮的新提名（那一路
    nominate 退化返回 0 条，或两个 run 并发各读了同一份 ledger 快照）。也就是说
    「靠新鲜度折扣让新卡自然胜出」这条路挡不住它——折扣只在两者同时在池子里时才起
    作用，而空壳老货恰恰是在池子里只剩它自己的时候被选中的。所以判据必须是**硬门槛**：
    depth 是卡片的必要成分，缺了就不是一张能发的卡，跟它得几分、多新无关。

    ⚠️ 这条不会误挡冷启动脚手架卡：那张卡刻意 `depth=None`（此刻还没攒够录音，
    硬写一段就是编的），但它不走 `pick_next`，是 `chosen is None` 之后才兜底造出来的。

    存量副作用是刻意的：某账号 16 条 mature 里 8 条无 depth（含 worth 最高的两条），
    加了这道门它们就永久出局，卡位让给带 depth 的新卡。它们不该被"补一段 depth 救回
    来"——那一层要基于提名时那个 60 天窗口的原话来写，窗口早滑走了。
    """
    if not (nomination.get('depth') or '').strip():
        return False
    return (
        nomination.get('confidence', 0) >= MIN_CONFIDENCE_TO_RELEASE
        and nomination.get('worth', 0) >= MIN_WORTH_TO_RELEASE
    )


def freshness_factor(row: Dict[str, Any], now: Optional[datetime] = None) -> float:
    """卡片依据的窗口与当前窗口的重叠比例，∈ [0, 1]。

    `1 - 货龄 / STALENESS_HORIZON_DAYS`。这不是一个调出来的衰减率，而是重叠比例本身：
    货龄 0 天 ⇒ 完全重叠 ⇒ 1.0；货龄 30 天 ⇒ 半个窗口已滑出 ⇒ 0.5；货龄 60 天 ⇒ 0。
    """
    created = _as_dt(row.get('created_at'))
    if not created:
        return 1.0
    now = now or datetime.now(timezone.utc)
    age_days = (now - created).total_seconds() / 86400
    if age_days <= 0:
        return 1.0
    return max(0.0, 1.0 - age_days / STALENESS_HORIZON_DAYS)


def pick_next(
    mature: List[Dict[str, Any]],
    ledger: List[Dict[str, Any]],
    known_topics: Dict[str, str],
    now: Optional[datetime] = None,
) -> Optional[Dict[str, Any]]:
    """从成熟池里挑出"现在该推的那一张"，没有就返回 None。

    多个候选竞争同一个卡位时由 **worth × 新鲜度** 决胜（其次 confidence）——高价值的
    先出，剩下的留在账本里等下一个窗口，不会丢。

    ⚠️ **必须给 worth 打货龄折扣，否则高分老货会永久压住新卡。** 提名约 3 条/天而释放
    被疲劳窗口卡在 0.2 张/天，池子只涨不消，于是纯按 worth 排序的结果是「总在发上个月
    的发现」。池中高分老卡积压时，折扣使较新的候选有机会释放。

    ⚠️ **折扣只参与排序，不参与 `eligible` 门槛。** 门槛回答的是「这条洞察本身够不够格
    打扰用户」，那跟它在池子里躺了多久无关；把折扣塞进门槛会让积压的卡集体跌破 45 分、
    于是池子明明有货却发不出，触发 `nothing_worth_saying` 或脚手架卡。
    唯一的硬淘汰是新鲜度为 0（货龄 ≥ 60 天，依据的窗口已整段滑出）—— 实测当前四个用户
    的 34~23 条候选里被淘汰 0 条，所以这条线不会在正常情况下减少可发的卡。
    """
    if in_fatigue_window(ledger, now=now):
        return None

    pool = [
        n for n in mature
        if eligible(n)
        and not is_duplicate(n.get('topic_key', ''), known_topics)
        and freshness_factor(n, now=now) > 0
    ]
    if not pool:
        return None

    pool.sort(
        key=lambda n: (n.get('worth', 0) * freshness_factor(n, now=now), n.get('confidence', 0)),
        reverse=True,
    )
    return pool[0]


def should_use_scaffold(
    companion_days_count: int,
    ledger: List[Dict[str, Any]],
    has_mature_candidate: bool,
) -> bool:
    """冷启动地板：前几天没攒出真洞察时，才用时间脚手架兜底。

    一旦有真正够格的洞察，它立刻顶替脚手架——时间维度只是"啥都没攒够
    时的下限"，不是独立机制。
    """
    if has_mature_candidate:
        return False
    if companion_days_count > COLD_START_DAYS:
        return False
    return not any(row.get('status') == 'released' for row in ledger)
