"""洞察引擎的「确定性事实层」——不经 LLM 的真实统计。

为什么单独一层：提名者是 LLM，它擅长发现"有意思的事"，但不擅长数数。
把节律/计数/时段分布这类可精确计算的东西先算好、以事实清单的形式喂给它，
可以做到两件事：
  1. 卡片里的数字永远是对的（不会出现"你周五说了最多的话"但其实是周二）
  2. 提名者省下算术精力，专注在"这意味着什么"上

媒体音过滤：设备会录到电视/播客/有声书/电梯播报。这些内容在
transcript 里可能被错标成用户本人（is_user=true），如果进了洞察层，
引擎会拿着小说台词当"你的原话"下结论。所以本层在统计与取证前先剔除
被判定为媒体的对话。判定沿用对话处理管线已经写进 title/overview 的
「媒体录音 / Media Recording」标记（不新增 LLM 调用）。
"""

import logging
from collections import Counter, OrderedDict
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

WEEKDAY_ZH = ['周一', '周二', '周三', '周四', '周五', '周六', '周日']

# 对话处理管线在判定为媒体内容时写进 title/overview 的标记
_MEDIA_MARKERS = (
    '媒体录音',
    'Media Recording',
    '媒体播放',
    '并非用户参与',
    '并非真实对话',
    '不是用户参与的真实对话',
)

# 少于这个字数的 is_user 片段不作为原话证据（"嗯""对""好的"撑不起一张卡）
_MIN_QUOTE_CHARS = 12


def is_media_conversation(conv: Dict[str, Any]) -> bool:
    """这段录音是不是电视/播客/有声书之类的媒体内容。"""
    structured = conv.get('structured') or {}
    blob = ' '.join(
        str(x or '')
        for x in (structured.get('title'), structured.get('overview'), conv.get('title'), conv.get('overview'))
    )
    return any(marker in blob for marker in _MEDIA_MARKERS)


def _local_dt(conv: Dict[str, Any], tz) -> Optional[datetime]:
    created = conv.get('created_at')
    if isinstance(created, str):
        try:
            created = datetime.fromisoformat(created)
        except ValueError:
            return None
    if not isinstance(created, datetime):
        return None
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    return created.astimezone(tz) if tz else created


def _resolve_tz(tz_name: Optional[str]):
    """Resolve a tz name, preferring stdlib zoneinfo over pytz.

    Falling back to UTC silently would be dangerous here: every time-of-day
    claim ("你晚上不谈事") is computed in local time, so a silent UTC fallback
    would produce confidently-wrong cards. zoneinfo is stdlib (3.9+) and always
    available, so the fallback now only triggers on a genuinely unknown tz.
    """
    if not tz_name:
        return timezone.utc

    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(tz_name)
    except Exception:
        pass

    try:
        import pytz

        return pytz.timezone(tz_name)
    except Exception:
        logger.warning('[insights] unknown timezone %r, falling back to UTC', tz_name)
        return timezone.utc


def build_fact_sheet(
    conversations: List[Dict[str, Any]],
    tz_name: Optional[str],
) -> Dict[str, Any]:
    """把一批对话压成一份"确定无疑"的统计清单。

    Returns a dict of precomputed, verifiable stats. Everything here is
    arithmetic — no inference, no LLM.
    """
    tz = _resolve_tz(tz_name)

    real: List[Tuple[datetime, Dict[str, Any]]] = []
    media_count = 0
    for conv in conversations:
        dt = _local_dt(conv, tz)
        if dt is None:
            continue
        if is_media_conversation(conv):
            media_count += 1
            continue
        real.append((dt, conv))

    real.sort(key=lambda x: x[0])

    if not real:
        return {
            'conversation_count': 0,
            'media_excluded': media_count,
            'days_with_data': 0,
            'weekday_counts': {},
            'hour_counts': {},
            'category_counts': {},
            'emotion_counts': {},
            'late_night_count': 0,
            'action_item_count': 0,
            'window_start': None,
            'window_end': None,
        }

    weekday = Counter(WEEKDAY_ZH[dt.weekday()] for dt, _ in real)
    hours = Counter(dt.hour for dt, _ in real)
    days = {dt.date().isoformat() for dt, _ in real}

    categories = Counter()
    emotions = Counter()
    action_items = 0
    for _, conv in real:
        structured = conv.get('structured') or {}
        if structured.get('category'):
            categories[structured['category']] += 1
        emotion = conv.get('eir_emotion') or structured.get('emotion')
        if emotion:
            emotions[str(emotion).lower()] += 1
        action_items += len(structured.get('action_items') or [])

    # 深夜 = 本地 21:00 之后或 06:00 之前
    late = [(dt, c) for dt, c in real if dt.hour >= 21 or dt.hour < 6]

    return {
        'conversation_count': len(real),
        'media_excluded': media_count,
        'days_with_data': len(days),
        'weekday_counts': dict(weekday),
        'hour_counts': {str(h): n for h, n in sorted(hours.items())},
        'category_counts': dict(categories.most_common(10)),
        'emotion_counts': dict(emotions),
        'late_night_count': len(late),
        'action_item_count': action_items,
        'window_start': real[0][0].date().isoformat(),
        'window_end': real[-1][0].date().isoformat(),
    }


def collect_user_quotes(
    conversations: List[Dict[str, Any]],
    tz_name: Optional[str],
    max_quotes: int = 320,
    min_chars: int = _MIN_QUOTE_CHARS,
) -> List[Dict[str, Any]]:
    """抽取可作为证据的用户原话（已剔除媒体对话）。

    只取 is_user=true 的片段。声纹准确率提升后这一层会自然变干净；
    在此之前媒体过滤 + 最小长度是两道粗筛。
    """
    tz = _resolve_tz(tz_name)
    quotes: List[Dict[str, Any]] = []

    for conv in conversations:
        if is_media_conversation(conv):
            continue
        dt = _local_dt(conv, tz)
        if dt is None:
            continue
        for seg in conv.get('transcript_segments') or []:
            if not seg.get('is_user'):
                continue
            text = (seg.get('text') or '').strip()
            if len(text) < min_chars:
                continue
            quotes.append({
                'text': text[:400],
                'date': dt.date().isoformat(),
                'weekday': WEEKDAY_ZH[dt.weekday()],
                'time': dt.strftime('%H:%M'),
                'conversation_id': conv.get('id'),
                'category': (conv.get('structured') or {}).get('category'),
            })

    return _thin_quotes(quotes, max_quotes)


def _thin_quotes(quotes: List[Dict[str, Any]], max_quotes: int) -> List[Dict[str, Any]]:
    """把原话裁到预算内：先按天分配名额，天内按长度取。

    两条经验都是实测出来的，方向相反、必须同时满足：

    **长句是强信号，纯时间均匀采样会毁掉证据。** 早先用均匀采样，把创始人语料里
    那句「肯定不能打录音卡、录音笔这种……」——唯一一条能支撑"产品执念"卡片的原话
    ——正好采样掉了。2026-08-19 量化了这件事：全池长度中位 24 字符，而**被历史卡片
    真实引用过**的原话中位 89 字符。同预算 320 下纯时间均匀只保住 8/38 条被引用过的
    原话，纯按长度是 23/38。

    **但纯按长度会让日期塌缩。** 提名 prompt 要靠「跨不同日期的复现」立论，全局按
    长度取会把名额堆在话最多的那几天。所以改成按天分配名额、天内按长度取：同样
    320 预算下保住 **27/38**，比原来的「长度 70% + 均匀 30%」（21/38）高 29%，而
    字符数几乎不变（38k vs 37k）。

    `max_quotes` 和 `_MIN_QUOTE_CHARS` 影响引用证据的保留率。
    """
    if len(quotes) <= max_quotes:
        return quotes

    by_day: 'OrderedDict[str, List[Dict[str, Any]]]' = OrderedDict()
    for q in quotes:
        by_day.setdefault(q.get('date') or '', []).append(q)

    per_day = max(1, max_quotes // len(by_day))
    picked: List[Dict[str, Any]] = []
    for items in by_day.values():
        picked.extend(sorted(items, key=lambda q: len(q.get('text') or ''), reverse=True)[:per_day])

    # 名额没用完（天数少、或某天条数不够）→ 从剩下的里按长度补
    if len(picked) < max_quotes:
        picked_ids = {id(q) for q in picked}
        rest = sorted(
            (q for q in quotes if id(q) not in picked_ids),
            key=lambda q: len(q.get('text') or ''),
            reverse=True,
        )
        picked.extend(rest[:max_quotes - len(picked)])
    elif len(picked) > max_quotes:
        # 天数比预算还多时 per_day=1 仍会超，按长度截
        picked = sorted(picked, key=lambda q: len(q.get('text') or ''), reverse=True)[:max_quotes]

    # 回到时间顺序，便于模型看出跨日期的复现
    picked.sort(key=lambda q: (q.get('date') or '', q.get('time') or ''))
    return picked


def collect_conversation_digest(
    conversations: List[Dict[str, Any]],
    tz_name: Optional[str],
    max_items: int = 160,
) -> List[Dict[str, Any]]:
    """对话摘要清单（标题+概述截断），给提名者提供"发生了什么"的骨架。"""
    tz = _resolve_tz(tz_name)
    items: List[Dict[str, Any]] = []
    for conv in conversations:
        if is_media_conversation(conv):
            continue
        dt = _local_dt(conv, tz)
        if dt is None:
            continue
        structured = conv.get('structured') or {}
        title = (structured.get('title') or '').strip()
        if not title:
            continue
        items.append({
            'date': dt.date().isoformat(),
            'weekday': WEEKDAY_ZH[dt.weekday()],
            'time': dt.strftime('%H:%M'),
            'title': title[:80],
            'overview': (structured.get('overview') or '').strip()[:220],
            'category': structured.get('category'),
            'conversation_id': conv.get('id'),
        })

    return _thin_digest(items, max_items)


def _thin_digest(items: List[Dict[str, Any]], max_items: int) -> List[Dict[str, Any]]:
    """按天分配名额，而不是全局按索引均匀取。

    原来是 `items[int(i * step)]`，即按下标均匀 —— 对话按时间排序，所以话多的那天
    会吃掉大量名额，话少的天可能整天被跳过。改成按天分配后，被历史卡片引用过的对话
    覆盖率从 75% 升到 80%（`max_items=160`，四个重度用户合计 55 条引用）。

    提升不像 `_thin_quotes` 那么显著（那边是 +29%），因为 digest 每条长度相近、没有
    「长句更有信息量」这种可利用的信号；这里图的只是日期不塌缩。同样**别下调
    `max_items` 省 token**：160 时覆盖率已经只有 80%，降到 80 会掉到 55%。
    """
    if len(items) <= max_items:
        return items

    by_day: 'OrderedDict[str, List[Dict[str, Any]]]' = OrderedDict()
    for it in items:
        by_day.setdefault(it.get('date') or '', []).append(it)

    per_day = max(1, max_items // len(by_day))
    picked: List[Dict[str, Any]] = []
    for day_items in by_day.values():
        picked.extend(day_items[:per_day])

    if len(picked) < max_items:
        picked_ids = {id(it) for it in picked}
        rest = [it for it in items if id(it) not in picked_ids]
        spread = max_items - len(picked)
        if rest and spread > 0:
            step = len(rest) / spread
            picked.extend(rest[int(i * step)] for i in range(spread))
    elif len(picked) > max_items:
        step = len(picked) / max_items
        picked = [picked[int(i * step)] for i in range(max_items)]

    picked.sort(key=lambda it: (it.get('date') or '', it.get('time') or ''))
    return picked


def companion_days(first_conversation_at: Optional[datetime], now: Optional[datetime] = None) -> int:
    """陪伴天数：以第一段对话为起点（比注册时间更接近"关系的开始"）。"""
    if not first_conversation_at:
        return 0
    if isinstance(first_conversation_at, str):
        try:
            first_conversation_at = datetime.fromisoformat(first_conversation_at)
        except ValueError:
            return 0
    if first_conversation_at.tzinfo is None:
        first_conversation_at = first_conversation_at.replace(tzinfo=timezone.utc)
    now = now or datetime.now(timezone.utc)
    return max(0, (now - first_conversation_at).days)


def has_enough_data(fact_sheet: Dict[str, Any]) -> bool:
    """数据充分性闸门——不够就不生成，绝不发空卡。

    门槛故意定得低（3 天有数据 + 8 段真实对话）：它拦的是"装了但几乎没戴"
    的空洞卡，不是拦轻度用户。
    """
    return fact_sheet.get('days_with_data', 0) >= 3 and fact_sheet.get('conversation_count', 0) >= 8


def default_window(days: int = 60) -> Tuple[datetime, datetime]:
    """洞察引擎默认观察窗口（UTC 起止）。"""
    end = datetime.now(timezone.utc)
    return end - timedelta(days=days), end
