from collections import Counter
from datetime import date, datetime, time, timedelta, timezone
from typing import Dict, List, Optional, Tuple

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

import database.developer_data as dev_db
from database.redis_db import delete_generic_cache, get_generic_cache, set_generic_cache
from models.conversation import Conversation
from models.pdp import PDP_TRAIT_KEYS, PdpMetric, PdpSnapshot, PdpTrajectoryEntry
from utils.locales import base_language
from utils.other import endpoints as auth

router = APIRouter()
_CACHE_TTL = 86400
_ENGINE_VERSION = 2
_BASELINE_DAYS = 28
_TRAJECTORY_DAYS = 7
_FETCH_DAYS = 42
_MAX_CONVERSATIONS = 1000
# Hard ceiling on how far back /v1/pdp/history will page. PDP is derived
# per-day data, so without a bound the client could page indefinitely.
_MAX_HISTORY_DAYS = 90

_TRAIT_LABELS = {
    'control': {'zh': '控制型', 'en': 'Control'},
    'expression': {'zh': '表现型', 'en': 'Expression'},
    'caution': {'zh': '谨慎型', 'en': 'Caution'},
    'warmth': {'zh': '温和型', 'en': 'Warmth'},
    'balance': {'zh': '均衡型', 'en': 'Balance'},
}

_ANIMAL_LABELS = {
    'tiger': {'zh': '老虎', 'en': 'Tiger'},
    'peacock': {'zh': '孔雀', 'en': 'Peacock'},
    'owl': {'zh': '猫头鹰', 'en': 'Owl'},
    'koala': {'zh': '考拉', 'en': 'Koala'},
    'lizard': {'zh': '变色龙', 'en': 'Lizard'},
}

_EMOTION_LABELS = {
    'happy': {'zh': '开心', 'en': 'happy'},
    'angry': {'zh': '紧绷', 'en': 'tense'},
    'sad': {'zh': '低落', 'en': 'low-key'},
    'surprised': {'zh': '兴奋', 'en': 'energized'},
    'calm': {'zh': '平静', 'en': 'calm'},
}

_CATEGORY_LABELS = {
    'personal': {'zh': '个人生活', 'en': 'personal life'},
    'education': {'zh': '学习成长', 'en': 'learning'},
    'health': {'zh': '健康', 'en': 'health'},
    'finance': {'zh': '财务', 'en': 'finance'},
    'legal': {'zh': '规则边界', 'en': 'boundaries'},
    'philosophy': {'zh': '思考', 'en': 'reflection'},
    'spiritual': {'zh': '精神世界', 'en': 'inner world'},
    'science': {'zh': '科学', 'en': 'science'},
    'entrepreneurship': {'zh': '创业', 'en': 'building'},
    'parenting': {'zh': '育儿', 'en': 'parenting'},
    'romantic': {'zh': '亲密关系', 'en': 'relationships'},
    'travel': {'zh': '出行', 'en': 'travel'},
    'inspiration': {'zh': '灵感', 'en': 'inspiration'},
    'technology': {'zh': '技术', 'en': 'technology'},
    'business': {'zh': '业务推进', 'en': 'business'},
    'social': {'zh': '社交互动', 'en': 'social topics'},
    'work': {'zh': '工作推进', 'en': 'work progress'},
    'sports': {'zh': '运动', 'en': 'sports'},
    'politics': {'zh': '公共议题', 'en': 'public issues'},
    'literature': {'zh': '阅读', 'en': 'reading'},
    'history': {'zh': '历史', 'en': 'history'},
    'architecture': {'zh': '空间设计', 'en': 'space design'},
    'music': {'zh': '音乐', 'en': 'music'},
    'weather': {'zh': '天气', 'en': 'weather'},
    'news': {'zh': '新闻', 'en': 'news'},
    'entertainment': {'zh': '娱乐', 'en': 'entertainment'},
    'psychology': {'zh': '心理', 'en': 'psychology'},
    'real': {'zh': '现实事务', 'en': 'real-life tasks'},
    'design': {'zh': '设计', 'en': 'design'},
    'family': {'zh': '家庭', 'en': 'family'},
    'economics': {'zh': '经济', 'en': 'economics'},
    'environment': {'zh': '环境', 'en': 'environment'},
    'other': {'zh': '日常杂谈', 'en': 'everyday topics'},
}

_TRAIT_TO_ANIMAL = {
    'control': 'tiger',
    'expression': 'peacock',
    'caution': 'owl',
    'warmth': 'koala',
    'balance': 'lizard',
}

_TIE_BREAK = {
    'balance': 0,
    'warmth': 1,
    'caution': 2,
    'expression': 3,
    'control': 4,
}

_CATEGORY_WEIGHTS = {
    'work': {'control': 2.6, 'balance': 0.6},
    'business': {'control': 2.5, 'expression': 0.8},
    'entrepreneurship': {'control': 2.4, 'expression': 0.9},
    'finance': {'control': 1.8, 'caution': 2.1},
    'legal': {'control': 1.1, 'caution': 2.5},
    'technology': {'control': 1.2, 'caution': 1.8},
    'economics': {'control': 1.4, 'caution': 1.8},
    'politics': {'control': 1.6, 'expression': 0.8},
    'real': {'control': 1.4, 'balance': 1.1},
    'personal': {'warmth': 1.8, 'balance': 1.1},
    'family': {'warmth': 2.4, 'balance': 0.8},
    'parenting': {'warmth': 2.0, 'caution': 1.1},
    'romantic': {'warmth': 1.8, 'expression': 1.2},
    'social': {'expression': 1.9, 'warmth': 1.0},
    'entertainment': {'expression': 1.7, 'balance': 0.8},
    'music': {'expression': 1.8, 'warmth': 0.9},
    'inspiration': {'expression': 1.5, 'balance': 1.1},
    'travel': {'expression': 1.1, 'balance': 1.6},
    'design': {'expression': 1.2, 'balance': 1.4},
    'psychology': {'caution': 1.0, 'balance': 1.7},
    'philosophy': {'balance': 2.0, 'caution': 0.8},
    'spiritual': {'warmth': 1.2, 'balance': 1.7},
    'education': {'caution': 1.8, 'balance': 0.9},
    'science': {'caution': 2.0, 'balance': 0.8},
    'health': {'caution': 1.5, 'warmth': 1.4},
    'history': {'caution': 1.3, 'balance': 1.0},
    'architecture': {'caution': 1.0, 'balance': 1.3},
    'environment': {'balance': 1.8, 'warmth': 0.8},
    'literature': {'expression': 1.0, 'balance': 1.2},
    'news': {'caution': 1.1, 'expression': 0.8},
    'weather': {'balance': 1.0, 'warmth': 0.7},
    'sports': {'control': 1.0, 'expression': 1.0},
    'other': {'balance': 1.0},
}

_EMOTION_WEIGHTS = {
    'happy': {'expression': 1.4, 'warmth': 1.2},
    'angry': {'control': 1.5, 'caution': 0.7},
    'sad': {'caution': 1.1, 'warmth': 1.4},
    'surprised': {'expression': 1.6, 'balance': 0.8},
    'calm': {'balance': 1.4, 'warmth': 1.0},
}

_TRAIT_EFFECTS = {
    'control': {
        'zh': '推进和定夺感',
        'en': 'decisiveness and momentum',
        'advice_zh': '先收束目标，再把下一步定出来',
        'advice_en': 'close the loop and name the next move clearly',
    },
    'expression': {
        'zh': '表达和带动氛围的倾向',
        'en': 'expressiveness and social pull',
        'advice_zh': '把想法说满一点，会更容易带动别人',
        'advice_en': 'say the idea out loud so others can build on it',
    },
    'caution': {
        'zh': '观察和校准细节的倾向',
        'en': 'care with details and boundaries',
        'advice_zh': '先补足证据，再做最后判断',
        'advice_en': 'gather the missing facts before making the final call',
    },
    'warmth': {
        'zh': '照顾关系和留空间的倾向',
        'en': 'care for people and emotional space',
        'advice_zh': '先接住对方的感受，再推进结论',
        'advice_en': 'acknowledge how people feel before pushing the conclusion',
    },
    'balance': {
        'zh': '调和节奏和切换视角的能力',
        'en': 'balance and adaptability',
        'advice_zh': '给自己一点缓冲，会更容易保持稳定输出',
        'advice_en': 'leave a little slack so the pace stays sustainable',
    },
}


class GeneratePdpSnapshotRequest(BaseModel):
    date: Optional[str] = None
    language: Optional[str] = None
    force_regenerate: bool = False



def _today_in_timezone(tz_name: Optional[str]) -> str:
    if tz_name:
        try:
            import pytz

            return datetime.now(pytz.timezone(tz_name)).strftime('%Y-%m-%d')
        except Exception:
            pass
    return datetime.now(timezone.utc).strftime('%Y-%m-%d')



def _local_day_bounds_utc(date_str: str, tz_name: Optional[str]):
    day = datetime.strptime(date_str, '%Y-%m-%d').date()
    if tz_name:
        try:
            import pytz

            tz = pytz.timezone(tz_name)
            start_local = tz.localize(datetime.combine(day, time.min))
            end_local = tz.localize(datetime.combine(day, time.max))
            return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)
        except Exception:
            pass
    start_utc = datetime.combine(day, time.min).replace(tzinfo=timezone.utc)
    end_utc = datetime.combine(day, time.max).replace(tzinfo=timezone.utc)
    return start_utc, end_utc



def _language_for(developer_id: Optional[str], uid: str, language: Optional[str]) -> str:
    if language:
        return language.lower()
    if developer_id:
        return (dev_db.get_user_language(developer_id, uid) or 'en').lower()
    return 'en'



def _cache_key(uid: str, date_str: str, lang: str) -> str:
    return f'pdp:v{_ENGINE_VERSION}:{uid}:{date_str}:{lang}'


def invalidate_pdp_cache(developer_id: str, uid: str, date_str: str) -> None:
    """Invalidate cached PDP snapshot so the next request triggers a fresh build."""
    for lang in ('zh', 'en'):
        delete_generic_cache(_cache_key(uid, date_str, lang))
    if developer_id:
        dev_db.delete_daily_pdp_snapshot(developer_id, uid, date_str)


def _text(lang: str, zh: str, en: str) -> str:
    return zh if base_language(lang) == 'zh' else en



def _trait_text(key: str, lang: str) -> str:
    return _TRAIT_LABELS[key]['zh' if base_language(lang) == 'zh' else 'en']



def _animal_text(key: str, lang: str) -> str:
    return _ANIMAL_LABELS[key]['zh' if base_language(lang) == 'zh' else 'en']



def _emotion_text(key: str, lang: str) -> str:
    return _EMOTION_LABELS.get(key, _EMOTION_LABELS['calm'])['zh' if base_language(lang) == 'zh' else 'en']



def _category_text(key: str, lang: str) -> str:
    item = _CATEGORY_LABELS.get(key, _CATEGORY_LABELS['other'])
    return item['zh' if base_language(lang) == 'zh' else 'en']



def _empty_bundle() -> Dict:
    return {
        'traits': {key: 0.0 for key in PDP_TRAIT_KEYS},
        'conversation_count': 0,
        'action_items': 0,
        'events': 0,
        'categories': Counter(),
        'emotions': Counter(),
    }



def _add_weights(target: Dict[str, float], weights: Dict[str, float], scale: float = 1.0) -> None:
    for key, value in weights.items():
        target[key] += value * scale



def _bundle_from_conversations(conversations: List[Conversation]) -> Dict:
    bundle = _empty_bundle()
    for convo in conversations:
        category = convo.structured.category.value if convo.structured and convo.structured.category else 'other'
        emotion = (convo.eir_emotion or (convo.structured.emotion if convo.structured else None) or 'calm').lower()
        action_items = len(convo.structured.action_items) if convo.structured else 0
        events = len(convo.structured.events) if convo.structured else 0

        bundle['conversation_count'] += 1
        bundle['action_items'] += action_items
        bundle['events'] += events
        bundle['categories'][category] += 1
        bundle['emotions'][emotion] += 1

        _add_weights(bundle['traits'], _CATEGORY_WEIGHTS.get(category, _CATEGORY_WEIGHTS['other']))
        _add_weights(bundle['traits'], _EMOTION_WEIGHTS.get(emotion, {}))
        if action_items:
            bundle['traits']['control'] += min(action_items, 4) * 0.75
            bundle['traits']['caution'] += min(action_items, 4) * 0.35
        if events:
            bundle['traits']['control'] += min(events, 3) * 0.25
            bundle['traits']['balance'] += min(events, 3) * 0.45

    if bundle['conversation_count']:
        bundle['traits']['balance'] += min(len(bundle['categories']), 6) * 0.55
        if bundle['emotions'].get('calm', 0):
            bundle['traits']['warmth'] += min(bundle['emotions']['calm'], 3) * 0.2
    return bundle



def _apply_quote_signal(bundle: Dict, quote: Optional[Dict]) -> Dict:
    if not quote:
        return bundle
    dominant = str(quote.get('dominant_emotion') or 'calm').lower()
    dist = quote.get('emotion_distribution') or {}
    if isinstance(dist, dict):
        for emotion, count in dist.items():
            try:
                numeric = max(float(count), 0.0)
            except Exception:
                numeric = 0.0
            if numeric <= 0:
                continue
            bundle['emotions'][str(emotion).lower()] += int(numeric)
            _add_weights(bundle['traits'], _EMOTION_WEIGHTS.get(str(emotion).lower(), {}), scale=min(numeric, 3.0) * 0.35)
    elif dominant:
        _add_weights(bundle['traits'], _EMOTION_WEIGHTS.get(dominant, {}), scale=0.45)
        bundle['emotions'][dominant] += 1
    return bundle



def _local_date_str(dt: datetime, tz_name: Optional[str]) -> str:
    if tz_name:
        try:
            import pytz

            return dt.astimezone(pytz.timezone(tz_name)).strftime('%Y-%m-%d')
        except Exception:
            pass
    return dt.astimezone(timezone.utc).strftime('%Y-%m-%d')



def _fetch_recent_conversations(developer_id: str, uid: str, start_utc: datetime, end_utc: datetime) -> List[Conversation]:
    raw = dev_db.get_conversations(
        developer_id=developer_id,
        external_user_id=uid,
        limit=_MAX_CONVERSATIONS,
        offset=0,
        statuses=['completed'],
        start_date=start_utc,
        end_date=end_utc,
        include_discarded=False,
        include_photos=False,
        include_transcript_segments=False,
    )
    conversations: List[Conversation] = []
    for item in raw:
        try:
            conversations.append(Conversation(**item) if isinstance(item, dict) else item)
        except Exception:
            continue
    return conversations



def _ordered_traits(scores: Dict[str, int]) -> List[str]:
    return sorted(PDP_TRAIT_KEYS, key=lambda key: (-scores.get(key, 0), _TIE_BREAK[key]))



def _scores_from_bundle(bundle: Dict) -> Dict[str, int]:
    total = sum(max(value, 0.0) for value in bundle['traits'].values())
    if total <= 0:
        return {key: 50 for key in PDP_TRAIT_KEYS}

    scores: Dict[str, int] = {}
    for key in PDP_TRAIT_KEYS:
        share = bundle['traits'][key] / total
        scores[key] = int(round(max(32, min(84, 55 + (share - 0.2) * 125))))
    return scores



def _delta_scores(day_bundle: Dict, baseline_bundle: Dict) -> Dict[str, int]:
    day_total = sum(max(value, 0.0) for value in day_bundle['traits'].values())
    baseline_total = sum(max(value, 0.0) for value in baseline_bundle['traits'].values())
    if day_total <= 0 or baseline_total <= 0:
        return {key: 0 for key in PDP_TRAIT_KEYS}

    deltas: Dict[str, int] = {}
    for key in PDP_TRAIT_KEYS:
        day_share = day_bundle['traits'][key] / day_total
        baseline_share = baseline_bundle['traits'][key] / baseline_total
        deltas[key] = int(round(max(-18, min(18, (day_share - baseline_share) * 85))))
    return deltas



def _effective_scores(scores: Dict[str, int], deltas: Dict[str, int]) -> Dict[str, int]:
    return {key: max(0, min(100, scores[key] + deltas.get(key, 0))) for key in PDP_TRAIT_KEYS}



def _add_bundle(target: Dict, source: Dict) -> None:
    for key in PDP_TRAIT_KEYS:
        target['traits'][key] += source['traits'][key]
    target['conversation_count'] += source['conversation_count']
    target['action_items'] += source['action_items']
    target['events'] += source['events']
    target['categories'].update(source['categories'])
    target['emotions'].update(source['emotions'])



def _aggregate_window(day_bundles: Dict[str, Dict], start_day: date, end_day: date) -> Dict:
    bundle = _empty_bundle()
    cursor = start_day
    while cursor <= end_day:
        key = cursor.strftime('%Y-%m-%d')
        if key in day_bundles:
            _add_bundle(bundle, day_bundles[key])
        cursor += timedelta(days=1)
    return bundle



def _daily_quote_for(developer_id: Optional[str], uid: str, date_str: str) -> Optional[Dict]:
    if not developer_id:
        return None
    try:
        return dev_db.get_daily_mood_quote(developer_id, uid, date_str)
    except Exception:
        return None



def _top_counter_key(counter: Counter) -> Optional[str]:
    if not counter:
        return None
    return counter.most_common(1)[0][0]



def _hero_summary(hero_trait: str, hero_delta: int, today_count: int, lang: str) -> str:
    animal = _animal_text(_TRAIT_TO_ANIMAL[hero_trait], lang)
    effect = _TRAIT_EFFECTS[hero_trait]['zh' if base_language(lang) == 'zh' else 'en']
    if base_language(lang) == 'zh':
        if today_count <= 0:
            return f'今天的画像还在积累中，整体更接近{animal}的稳定底色。'
        if hero_delta >= 8:
            return f'今天你更像一只{animal}，{effect}比平时更明显。'
        if hero_delta <= -8:
            return f'今天你从高推进切回收束状态，{animal}的锋利感先放缓了一点。'
        return f'今天你更靠近{animal}，{effect}正慢慢往前排。'
    if today_count <= 0:
        return f'Today is still building signal, so your card stays closer to a steady {animal} baseline.'
    if hero_delta >= 8:
        return f'Today you read more like a {animal}, with {effect} showing up more clearly than usual.'
    if hero_delta <= -8:
        return f'Today softens the sharper {animal} edge a little, even if it still shapes your baseline.'
    return f'Today leans a little more {animal}, with {effect} moving closer to the front.'



def _trajectory_line(today_animal: str, yesterday_animal: str, lang: str) -> str:
    today_label = _animal_text(today_animal, lang)
    yesterday_label = _animal_text(yesterday_animal, lang)
    if base_language(lang) == 'zh':
        if today_animal == yesterday_animal:
            return f'和昨天相比，主导风格仍然是{today_label}。'
        return f'和昨天相比，今天从{yesterday_label}切到了{today_label}。'
    if today_animal == yesterday_animal:
        return f'Compared with yesterday, {today_label} still leads the day.'
    return f'Compared with yesterday, the lead shifts from {yesterday_label} to {today_label}.'



def _build_insights(
    *,
    lang: str,
    hero_trait: str,
    secondary_trait: str,
    today_bundle: Dict,
    trajectory: List[PdpTrajectoryEntry],
) -> List[str]:
    top_category = _top_counter_key(today_bundle['categories'])
    top_emotion = _top_counter_key(today_bundle['emotions'])

    if today_bundle['conversation_count'] > 0 and top_category:
        line_one = _text(
            lang,
            f'今天的主信号来自{_category_text(top_category, lang)}，一共记录了 {today_bundle["conversation_count"]} 段对话。',
            f'Today\'s strongest signal comes from {_category_text(top_category, lang)}, across {today_bundle["conversation_count"]} conversations.',
        )
    else:
        line_one = _text(
            lang,
            '今天新增对话不多，这张卡更多沿用了近 4 周的长期基线。',
            'There is not much fresh data today, so this card leans more on your 4-week baseline.',
        )

    if today_bundle['action_items'] > 0:
        line_two = _text(
            lang,
            f'今天提到了 {today_bundle["action_items"]} 个待办，让{_trait_text(hero_trait, lang)}更容易冲到前面。',
            f'{today_bundle["action_items"]} action items showed up today, which pushes {_trait_text(hero_trait, lang)} closer to the front.',
        )
    elif top_emotion:
        line_two = _text(
            lang,
            f'情绪上更偏{_emotion_text(top_emotion, lang)}，因此{_trait_text(secondary_trait, lang)}也在陪跑。',
            f'The day feels more {_emotion_text(top_emotion, lang)}, so {_trait_text(secondary_trait, lang)} stays active in the background.',
        )
    else:
        line_two = _text(
            lang,
            f'次强特征是{_trait_text(secondary_trait, lang)}，适合{_TRAIT_EFFECTS[secondary_trait]["advice_zh" if base_language(lang) == "zh" else "advice_en"]}。',
            f'The secondary signal is {_trait_text(secondary_trait, lang)}, so it helps to {_TRAIT_EFFECTS[secondary_trait]["advice_en"]}.',
        )

    today_animal = trajectory[-1].animal_key if trajectory else _TRAIT_TO_ANIMAL[hero_trait]
    yesterday_animal = trajectory[-2].animal_key if len(trajectory) > 1 else today_animal
    line_three = _trajectory_line(today_animal, yesterday_animal, lang)

    return [line_one, line_two, line_three]



def _build_snapshot(developer_id: Optional[str], uid: str, date_str: str, language: str) -> PdpSnapshot:
    lang = 'zh' if base_language(language) == 'zh' else 'en'
    if not developer_id:
        neutral_scores = {key: 50 for key in PDP_TRAIT_KEYS}
        order = _ordered_traits(neutral_scores)
        trajectory = [
            PdpTrajectoryEntry(
                date=(datetime.strptime(date_str, '%Y-%m-%d').date() - timedelta(days=6 - index)).strftime('%Y-%m-%d'),
                animal_key='lizard',
            )
            for index in range(_TRAJECTORY_DAYS)
        ]
        return PdpSnapshot(
            date=date_str,
            language=language,
            engine_version=_ENGINE_VERSION,
            primary_animal_key=_TRAIT_TO_ANIMAL[order[0]],
            secondary_animal_key=_TRAIT_TO_ANIMAL[order[1]],
            primary_trait_key=order[0],
            secondary_trait_key=order[1],
            hero_animal_key='lizard',
            hero_summary=_hero_summary('balance', 0, 0, lang),
            insight_lines=_build_insights(
                lang=lang,
                hero_trait='balance',
                secondary_trait='warmth',
                today_bundle=_empty_bundle(),
                trajectory=trajectory,
            ),
            metrics=[PdpMetric(key=key, score=neutral_scores[key], delta=0) for key in PDP_TRAIT_KEYS],
            trajectory=trajectory,
        )

    tz_name = dev_db.get_user_timezone(developer_id, uid)
    target_day = datetime.strptime(date_str, '%Y-%m-%d').date()
    fetch_start, _ = _local_day_bounds_utc((target_day - timedelta(days=_FETCH_DAYS - 1)).strftime('%Y-%m-%d'), tz_name)
    _, fetch_end = _local_day_bounds_utc(date_str, tz_name)
    conversations = _fetch_recent_conversations(developer_id, uid, fetch_start, fetch_end)

    day_bundles: Dict[str, Dict] = {}
    for convo in conversations:
        day_key = _local_date_str(convo.created_at, tz_name)
        day_bundles.setdefault(day_key, _empty_bundle())
        _add_bundle(day_bundles[day_key], _bundle_from_conversations([convo]))

    # Blend today's quote emotion back into the day bundle so days with only
    # light signal still produce a non-flat hero card.
    day_bundles.setdefault(date_str, _empty_bundle())
    _apply_quote_signal(day_bundles[date_str], _daily_quote_for(developer_id, uid, date_str))

    baseline_start = target_day - timedelta(days=_BASELINE_DAYS - 1)
    baseline_bundle = _aggregate_window(day_bundles, baseline_start, target_day)
    baseline_scores = _scores_from_bundle(baseline_bundle)
    today_bundle = day_bundles.get(date_str, _empty_bundle())
    deltas = _delta_scores(today_bundle, baseline_bundle)
    effective_today = _effective_scores(baseline_scores, deltas)

    baseline_order = _ordered_traits(baseline_scores)
    today_order = _ordered_traits(effective_today)
    primary_trait = baseline_order[0]
    secondary_trait = baseline_order[1]
    hero_trait = today_order[0]

    trajectory: List[PdpTrajectoryEntry] = []
    for offset in range(_TRAJECTORY_DAYS - 1, -1, -1):
        day = target_day - timedelta(days=offset)
        day_key = day.strftime('%Y-%m-%d')
        day_bundle = day_bundles.get(day_key, _empty_bundle())
        window_bundle = _aggregate_window(day_bundles, day - timedelta(days=_BASELINE_DAYS - 1), day)
        day_scores = _scores_from_bundle(window_bundle)
        day_deltas = _delta_scores(day_bundle, window_bundle)
        effective_scores = _effective_scores(day_scores, day_deltas)
        trajectory_trait = _ordered_traits(effective_scores)[0]
        trajectory.append(PdpTrajectoryEntry(date=day_key, animal_key=_TRAIT_TO_ANIMAL[trajectory_trait]))

    metrics = [
        PdpMetric(key=key, score=baseline_scores[key], delta=deltas.get(key, 0))
        for key in PDP_TRAIT_KEYS
    ]

    return PdpSnapshot(
        date=date_str,
        language=language,
        engine_version=_ENGINE_VERSION,
        primary_animal_key=_TRAIT_TO_ANIMAL[primary_trait],
        secondary_animal_key=_TRAIT_TO_ANIMAL[secondary_trait],
        primary_trait_key=primary_trait,
        secondary_trait_key=secondary_trait,
        hero_animal_key=_TRAIT_TO_ANIMAL[hero_trait],
        hero_summary=_hero_summary(
            hero_trait,
            deltas.get(hero_trait, 0),
            today_bundle['conversation_count'],
            lang,
        ),
        insight_lines=_build_insights(
            lang=lang,
            hero_trait=hero_trait,
            secondary_trait=secondary_trait,
            today_bundle=today_bundle,
            trajectory=trajectory,
        ),
        metrics=metrics,
        trajectory=trajectory,
    )



def _load_snapshot(
    developer_id: Optional[str],
    uid: str,
    date_str: str,
    language: str,
    *,
    force_regenerate: bool = False,
    read_only: bool = False,
) -> Optional[PdpSnapshot]:
    """Load a daily PDP snapshot.

    With ``read_only=True`` only the cache and the stored snapshot are consulted;
    a miss returns ``None`` instead of running the expensive ``_build_snapshot``.
    The history endpoint uses this so a cold cache can't fan out into dozens of
    synchronous rebuilds (each fetching up to 1000 conversations) and blow the
    request timeout.
    """
    cache_key = _cache_key(uid, date_str, language)
    if not force_regenerate:
        cached = get_generic_cache(cache_key)
        if cached and int(cached.get('engine_version') or 0) >= _ENGINE_VERSION:
            return PdpSnapshot(**cached)

    stored = dev_db.get_daily_pdp_snapshot(developer_id, uid, date_str) if developer_id and not force_regenerate else None
    if stored and (stored.get('language') or '').lower() == language.lower() and int(stored.get('engine_version') or 0) >= _ENGINE_VERSION:
        snapshot = PdpSnapshot(**stored)
        set_generic_cache(cache_key, snapshot.model_dump(mode='json'), ttl=_CACHE_TTL)
        return snapshot

    if read_only:
        return None

    snapshot = _build_snapshot(developer_id, uid, date_str, language)
    if developer_id:
        dev_db.store_daily_pdp_snapshot(developer_id, uid, date_str, snapshot.model_dump(mode='json'))
    set_generic_cache(cache_key, snapshot.model_dump(mode='json'), ttl=_CACHE_TTL)
    return snapshot


@router.get('/v1/pdp/latest', tags=['self'], response_model=PdpSnapshot)
def get_latest_pdp_snapshot(
    date: str | None = Query(None, description='YYYY-MM-DD; defaults to today in user timezone'),
    language: str | None = Query(None, description='Optional language override'),
    ctx: Tuple[str, str] = Depends(auth.get_current_user_context),
):
    developer_id, uid = ctx
    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    date_str = (date or '').strip() or _today_in_timezone(tz_name)
    try:
        datetime.strptime(date_str, '%Y-%m-%d')
    except ValueError:
        raise HTTPException(status_code=400, detail='date must be in YYYY-MM-DD format')
    lang = _language_for(developer_id, uid, language)
    return _load_snapshot(developer_id, uid, date_str, lang)


@router.post('/v1/pdp/daily', tags=['self'], response_model=PdpSnapshot)
def generate_daily_pdp_snapshot(
    data: GeneratePdpSnapshotRequest,
    ctx: Tuple[str, str] = Depends(auth.get_current_user_context),
):
    developer_id, uid = ctx
    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    date_str = (data.date or '').strip() or _today_in_timezone(tz_name)
    try:
        datetime.strptime(date_str, '%Y-%m-%d')
    except ValueError:
        raise HTTPException(status_code=400, detail='date must be in YYYY-MM-DD format')
    lang = _language_for(developer_id, uid, data.language)
    return _load_snapshot(developer_id, uid, date_str, lang, force_regenerate=data.force_regenerate)


@router.get('/v1/pdp/history', tags=['self'])
def get_pdp_history(
    limit: int = Query(10, ge=1, le=30),
    offset: int = Query(0, ge=0),
    language: str | None = Query(None),
    ctx: Tuple[str, str] = Depends(auth.get_current_user_context),
):
    developer_id, uid = ctx
    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    lang = _language_for(developer_id, uid, language)
    today = datetime.strptime(_today_in_timezone(tz_name), '%Y-%m-%d').date()

    # Clamp the requested window to the history ceiling so the client can't page
    # indefinitely. _load_snapshot is cache-backed (generic cache + stored
    # snapshot), so a warm cache makes this loop cheap; only a cold cache pays
    # the per-day _build_snapshot cost.
    start_index = offset
    end_index = min(offset + limit, _MAX_HISTORY_DAYS)

    # read_only: only return snapshots already generated (by /latest or the
    # daily job). Days without a stored snapshot are skipped rather than rebuilt
    # synchronously, keeping this endpoint cheap even on a cold cache.
    snapshots = []
    for index in range(start_index, end_index):
        day = (today - timedelta(days=index)).strftime('%Y-%m-%d')
        snapshot = _load_snapshot(developer_id, uid, day, lang, read_only=True)
        if snapshot is not None:
            snapshots.append(snapshot.model_dump(mode='json'))

    return {
        'items': snapshots,
        'has_more': end_index < _MAX_HISTORY_DAYS,
    }
