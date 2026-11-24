from datetime import datetime, timezone
from typing import List, Optional, Tuple

from fastapi import APIRouter, Depends

import database.developer_data as dev_db
from models.home_updates import HomeModuleUpdate, HomeModuleUpdatesResponse
from utils.locales import base_language
from utils.other import endpoints as auth

router = APIRouter()



def _lang(developer_id: str, uid: str) -> str:
    return base_language(dev_db.get_user_language(developer_id, uid) or 'en')



def _text(lang: str, zh: str, en: str) -> str:
    return zh if lang == 'zh' else en



def _as_datetime(value) -> datetime:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(timezone.utc)
        except Exception:
            return datetime.now(timezone.utc)
    return datetime.now(timezone.utc)



def _animal_name(animal_key: str, lang: str) -> str:
    if animal_key == 'peacock':
        return _text(lang, '孔雀', 'Peacock')
    if animal_key == 'owl':
        return _text(lang, '猫头鹰', 'Owl')
    if animal_key == 'koala':
        return _text(lang, '考拉', 'Koala')
    if animal_key == 'lizard':
        return _text(lang, '变色龙', 'Lizard')
    return _text(lang, '老虎', 'Tiger')



def _build_mood_update(developer_id: str, uid: str, lang: str) -> Optional[HomeModuleUpdate]:
    quote = dev_db.get_daily_mood_quotes(developer_id, uid, limit=1, offset=0)
    if quote:
        latest = quote[0]
        detail = latest.get('title') or latest.get('body', '').replace('\n', ' ')
        return HomeModuleUpdate(
            module='mood',
            detail=(detail or _text(lang, '今日寄语已更新', 'Mood line updated'))[:80],
            updated_at=_as_datetime(latest.get('created_at') or latest.get('updated_at')),
        )

    convo = dev_db.get_latest_eir_conversation(developer_id, uid)
    if convo:
        emotion = (convo.get('eir_emotion') or 'calm').lower()
        return HomeModuleUpdate(
            module='mood',
            detail=_text(lang, f'最新情绪信号：{emotion}', f'Latest emotion signal: {emotion}'),
            updated_at=_as_datetime(convo.get('eir_updated_at') or convo.get('updated_at') or convo.get('created_at')),
        )
    return None



def _build_self_update(developer_id: str, uid: str, lang: str) -> HomeModuleUpdate:
    pdp_items = dev_db.get_daily_pdp_snapshots(developer_id, uid, limit=1, offset=0)
    if pdp_items:
        latest = pdp_items[0]
        animal = _animal_name((latest.get('hero_animal_key') or 'tiger').lower(), lang)
        return HomeModuleUpdate(
            module='self',
            detail=_text(lang, f'今日人格卡已刷新，更偏向{animal}', f'Today\'s personality card leans more {animal}'),
            updated_at=_as_datetime(latest.get('updated_at') or latest.get('date')),
        )

    birthday = dev_db.get_user_birthday(developer_id, uid)
    if birthday:
        return HomeModuleUpdate(
            module='self',
            detail=_text(lang, '生日信息已就绪，可查看今日一测', 'Birthday info is ready for today\'s reading'),
            updated_at=datetime.now(timezone.utc),
        )
    return HomeModuleUpdate(
        module='self',
        detail=_text(lang, '补充生日信息后即可解锁今日一测', 'Add birthday info to unlock your daily reading'),
        updated_at=datetime.now(timezone.utc),
    )



def _build_memory_update(developer_id: str, uid: str, lang: str) -> Optional[HomeModuleUpdate]:
    summaries = dev_db.list_daily_summaries(developer_id, uid, limit=1, offset=0)
    if summaries:
        latest = summaries[0]
        detail = latest.get('summary_text') or _text(lang, '一条每日日一刻已经准备好了。', 'A daily moment is ready.')
        detail = detail.replace('\n', ' ').strip()
        return HomeModuleUpdate(
            module='memory',
            detail=detail[:80],
            updated_at=_as_datetime(latest.get('updated_at') or latest.get('created_at')),
        )

    convos = dev_db.get_conversations(
        developer_id=developer_id,
        external_user_id=uid,
        limit=1,
        offset=0,
        include_discarded=False,
        statuses=['completed'],
    )
    if convos:
        latest = convos[0]
        title = ((latest.get('structured') or {}).get('title') if isinstance(latest, dict) else None) or _text(
            lang,
            '最近一段对话已经存好',
            'Recent conversation saved',
        )
        return HomeModuleUpdate(
            module='memory',
            detail=str(title)[:80],
            updated_at=_as_datetime(latest.get('updated_at') or latest.get('created_at')),
        )
    return None


@router.get('/v1/home/updates', tags=['home'], response_model=HomeModuleUpdatesResponse)
def get_home_module_updates(ctx: Tuple[str, str] = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    lang = _lang(developer_id, uid)
    items: List[HomeModuleUpdate] = []
    mood = _build_mood_update(developer_id, uid, lang)
    if mood:
        items.append(mood)
    items.append(_build_self_update(developer_id, uid, lang))
    memory = _build_memory_update(developer_id, uid, lang)
    if memory:
        items.append(memory)
    return HomeModuleUpdatesResponse(items=items)
