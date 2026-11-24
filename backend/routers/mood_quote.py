"""情绪页「每日一语」（今日情绪寄语）路由。

与「自己」Tab 的占卜 (routers/fortune.py) 完全独立，不复用其 model/缓存/逻辑。

按需生成流程：先查 Redis → 查 Firestore → 都没有则即时生成、写 Firestore、写 Redis(24h)。

鉴权：沿用 fortune 的 `auth.get_current_user_context`，返回 (developer_id, uid)。
App 端 makeApiCall (app/lib/backend/http/shared.dart) 对所有平台请求自动注入
Authorization=<raw API key> + ?external_user_id=...，与该依赖项使用的
开发者 API key + external_user_id query 完全一致；uid 即 external_user_id，
正好用作 Firestore 路径与缓存键，因此选它而非 discover 的纯 developer_id 模式。
"""

import logging
import re
from datetime import datetime, time, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

import database.developer_data as dev_db
from database.redis_db import get_generic_cache, set_generic_cache
from models.conversation import Conversation
from models.mood_quote import DailyMoodQuote, EMOTION_COLORS
from routers.discover import aggregate_day_emotions
from utils.llm.mood_quote import generate_mood_quote
from utils.notifications import send_notification
from utils.other import endpoints as auth

router = APIRouter()
logger = logging.getLogger(__name__)

_DATE_RE = re.compile(r'\d{4}-\d{2}-\d{2}')
_MAX_TITLES = 20  # 控制 prompt 长度 / 成本 / 隐私
_CACHE_TTL = 86400  # 24h


def _today_in_timezone(tz_name: Optional[str]) -> str:
    """Return today's date string (YYYY-MM-DD) in the user's timezone (UTC fallback)."""
    if tz_name:
        try:
            import pytz

            return datetime.now(pytz.timezone(tz_name)).strftime('%Y-%m-%d')
        except Exception:
            logger.warning('[mood_quote] invalid timezone %r, falling back to UTC', tz_name)
    return datetime.now(timezone.utc).strftime('%Y-%m-%d')


def _local_day_bounds_utc(date_str: str, tz_name: Optional[str]):
    """Return (start_utc, end_utc) datetimes for the local calendar day `date_str`."""
    day = datetime.strptime(date_str, '%Y-%m-%d').date()
    if tz_name:
        try:
            import pytz

            tz = pytz.timezone(tz_name)
            start_local = tz.localize(datetime.combine(day, time.min))
            end_local = tz.localize(datetime.combine(day, time.max))
            return start_local.astimezone(timezone.utc), end_local.astimezone(timezone.utc)
        except Exception:
            logger.warning('[mood_quote] invalid timezone %r, falling back to UTC', tz_name)
    start_utc = datetime.combine(day, time.min).replace(tzinfo=timezone.utc)
    end_utc = datetime.combine(day, time.max).replace(tzinfo=timezone.utc)
    return start_utc, end_utc


def _build_mood_quote(developer_id: str, uid: str, date_str: str, language: Optional[str]) -> DailyMoodQuote:
    """聚合当日情绪 + 对话标题 → 生成寄语 → 填充颜色等字段（不含缓存/持久化）。"""
    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    start_utc, end_utc = _local_day_bounds_utc(date_str, tz_name)

    raw = dev_db.get_conversations(
        developer_id=developer_id,
        external_user_id=uid,
        limit=200,
        offset=0,
        statuses=['completed'],
        start_date=start_utc,
        end_date=end_utc,
        include_discarded=False,
        include_photos=False,
    )

    convos = []
    titles = []
    for c in raw:
        try:
            convo = Conversation(**c) if isinstance(c, dict) else c
        except Exception:
            continue
        convos.append(convo)
        title = (convo.structured.title or '').strip() if convo.structured else ''
        if title:
            # 标题是用户生成内容，会进 LLM prompt：去掉换行、截断长度，
            # 收窄 prompt 注入面（结构化输出已限制 blast radius）。
            titles.append(title.replace('\n', ' ').replace('\r', ' ')[:80])

    emotion_dist = aggregate_day_emotions(convos)
    titles = titles[:_MAX_TITLES]

    # dominant：取计数最高情绪，排除 calm；排除后无有效情绪 → 'calm' + 兜底色。
    non_calm = {e: n for e, n in emotion_dist.items() if e != 'calm' and n > 0}
    if non_calm:
        dominant = max(non_calm.items(), key=lambda kv: kv[1])[0]
        is_fallback = False
    else:
        dominant = 'calm'
        is_fallback = True

    # Use unified language resolution with conversation fallback
    from utils.locales import get_user_effective_language
    if language:
        # Explicit language override from query param
        lang = language
        lang_source = 'explicit'
    else:
        # Convert conversations to dicts for language inference
        conv_dicts = [{'language': c.language} for c in convos if hasattr(c, 'language') and c.language]
        lang, lang_source = get_user_effective_language(developer_id, uid, fallback_conversations=conv_dicts)

    logger.info(f"[mood_quote] {uid[:8]} date={date_str} lang={lang} source={lang_source}")
    llm_out = generate_mood_quote(emotion_dist, titles, dominant, lang)

    colors = EMOTION_COLORS.get(dominant, EMOTION_COLORS['calm'])
    return DailyMoodQuote(
        date=date_str,
        dominant_emotion=dominant,
        emotion_distribution=emotion_dist,
        bg_color=colors['bg_color'],
        text_color=colors['text_color'],
        title=llm_out.title,
        body=llm_out.body,
        language=lang,
        is_fallback=is_fallback,
    )


@router.get('/v1/mood/daily-quote', tags=['mood'], response_model=DailyMoodQuote)
def get_daily_mood_quote(
    date: Optional[str] = Query(None, description="YYYY-MM-DD，默认用户本地时区今天"),
    language: Optional[str] = Query(None, description="覆盖输出语言，默认用户偏好"),
    ctx: tuple = Depends(auth.get_current_user_context),
):
    """获取当日情绪寄语。先查 Redis → 查 Firestore → 都没有则即时生成并持久化。"""
    developer_id, uid = ctx

    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    date_str = (date or '').strip() or _today_in_timezone(tz_name)
    # 同时做格式 + 语义校验：'2024-13-45' 能过正则但不是合法日期，
    # 必须在这里拦掉，否则后续 strptime 会抛 ValueError -> 500。
    if not _DATE_RE.fullmatch(date_str):
        raise HTTPException(status_code=400, detail="date must be in YYYY-MM-DD format")
    try:
        datetime.strptime(date_str, '%Y-%m-%d')
    except ValueError:
        raise HTTPException(status_code=400, detail="date is not a valid calendar date")

    language = language or (dev_db.get_user_language(developer_id, uid) if developer_id else None)
    # 缓存键含语言：同一天换语言（或显式传 ?language=）不应命中旧语言的缓存。
    # 兜底值与 _build_mood_quote 存储的 language（None -> 'en'）保持一致，
    # 否则 None 语言永远命中不了 Firestore 记录、每次重复生成。
    lang_key = (language or 'en').lower()
    cache_path = f'mood_quote:{uid}:{date_str}:{lang_key}'
    cached = get_generic_cache(cache_path)
    if cached:
        return DailyMoodQuote(**cached)

    # Firestore 持久化按 date 去重（不含语言维度）：仅当存储记录语言与请求一致时复用，
    # 否则按当前语言重新生成并覆盖，保证返回语言正确。
    stored = dev_db.get_daily_mood_quote(developer_id, uid, date_str) if developer_id else None
    if stored and (stored.get('language') or '').lower() == lang_key:
        quote = DailyMoodQuote(**stored)
        set_generic_cache(cache_path, quote.dict(), ttl=_CACHE_TTL)
        return quote

    quote = _build_mood_quote(developer_id, uid, date_str, language)

    quote_dict = quote.dict()
    if developer_id:
        dev_db.store_daily_mood_quote(developer_id, uid, date_str, quote_dict)
    set_generic_cache(cache_path, quote_dict, ttl=_CACHE_TTL)
    return quote


@router.get('/v1/mood/daily-quote/history', tags=['mood'])
def get_daily_mood_quote_history(
    limit: int = Query(30, ge=1, le=100, description="返回条数上限"),
    offset: int = Query(0, ge=0, description="跳过条数（分页）"),
    ctx: tuple = Depends(auth.get_current_user_context),
):
    """按日期倒序返回历史每日一语，供二级页「情绪色彩流」展示。"""
    developer_id, uid = ctx
    if not developer_id:
        # ADMIN_KEY 模式下无 developer_id，无法定位 Firestore 路径。
        return {'items': [], 'has_more': False}

    items = dev_db.get_daily_mood_quotes(developer_id, uid, limit=limit, offset=offset)
    return {
        'items': items,
        'has_more': len(items) == limit,
    }


# ──────────────────────────────────────────────────────────────────────────
# Cron 专用：定时生成 + 推送（每天用户本地 20:00 由 Modal cron 调用）
# ──────────────────────────────────────────────────────────────────────────

# 推送标题按语言本地化；body 用 LLM 寄语 title（短、适合通知栏）。
_PUSH_TITLE = {
    'zh': '今日情绪寄语',
    'en': 'Your daily line',
}


def _localized_push_title(language: Optional[str]) -> str:
    try:
        from utils.locales import base_language

        base = base_language(language or 'en')
    except Exception:
        base = (language or 'en').lower().split('-')[0]
    return _PUSH_TITLE.get(base, _PUSH_TITLE['en'])


class GenerateMoodQuoteRequest(BaseModel):
    date: Optional[str] = None  # 'YYYY-MM-DD'，为空则用用户本地时区今天
    language: Optional[str] = None
    push: bool = True  # 是否在生成后发送 FCM 推送
    force_regenerate: bool = False  # True 则忽略缓存/已存记录，强制重算


@router.post('/v1/mood/daily-quote/generate', tags=['mood'])
def generate_and_push_daily_mood_quote(
    data: GenerateMoodQuoteRequest,
    ctx: tuple = Depends(auth.get_current_user_context),
):
    """定时生成当日情绪寄语并落库，按需推送。供 Modal cron（ADMIN/开发者 key）调用。

    推送策略：仅当寄语含真实情绪信号（is_fallback=False）时才推送，
    避免给当天无活跃数据的用户发兜底文案造成打扰。兜底文案仍会生成+落库，
    保证卡片不空窗、历史连续。
    """
    developer_id, uid = ctx

    tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
    date_str = (data.date or '').strip() or _today_in_timezone(tz_name)
    if not _DATE_RE.fullmatch(date_str):
        raise HTTPException(status_code=400, detail="date must be in YYYY-MM-DD format")
    try:
        datetime.strptime(date_str, '%Y-%m-%d')
    except ValueError:
        raise HTTPException(status_code=400, detail="date is not a valid calendar date")

    language = data.language or (dev_db.get_user_language(developer_id, uid) if developer_id else None)
    lang_key = (language or 'en').lower()
    cache_path = f'mood_quote:{uid}:{date_str}:{lang_key}'

    quote: Optional[DailyMoodQuote] = None
    if not data.force_regenerate:
        # 复用已生成结果（Redis → Firestore），避免 cron 重复调 LLM。
        cached = get_generic_cache(cache_path)
        if cached:
            quote = DailyMoodQuote(**cached)
        else:
            stored = dev_db.get_daily_mood_quote(developer_id, uid, date_str) if developer_id else None
            if stored and (stored.get('language') or '').lower() == lang_key:
                quote = DailyMoodQuote(**stored)

    if quote is None:
        quote = _build_mood_quote(developer_id, uid, date_str, language)
        quote_dict = quote.dict()
        if developer_id:
            dev_db.store_daily_mood_quote(developer_id, uid, date_str, quote_dict)
        set_generic_cache(cache_path, quote_dict, ttl=_CACHE_TTL)

    pushed = False
    lang_source = 'explicit' if data.language else 'inferred'  # Track if language was explicitly requested
    if data.push and not quote.is_fallback:
        fcm_token = dev_db.get_user_fcm_token(developer_id, uid) if developer_id else None
        if fcm_token:
            title = _localized_push_title(language)
            body = quote.title or quote.body.replace('\n', ' ')
            pushed = send_notification(
                fcm_token,
                title,
                body,
                data={
                    'type': 'mood_quote',
                    'notification_type': 'mood_quote',
                    'navigate_to': '/mood',
                    'date': date_str,
                },
            )
            logger.info(
                '[mood_quote] %s date=%s lang=%s (source=%s) emotion=%s sent=%s',
                uid[:8], date_str, quote.language, lang_source, quote.dominant_emotion, 'ok' if pushed else 'fail'
            )
        else:
            logger.info('[mood_quote] %s date=%s lang=%s no FCM token, skip push', uid[:8], date_str, quote.language)
    elif data.push and quote.is_fallback:
        logger.info(
            '[mood_quote] %s date=%s lang=%s is_fallback=True, skip push',
            uid[:8], date_str, quote.language
        )

    return {
        'date': date_str,
        'dominant_emotion': quote.dominant_emotion,
        'is_fallback': quote.is_fallback,
        'pushed': pushed,
    }
