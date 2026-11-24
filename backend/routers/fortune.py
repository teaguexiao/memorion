import re
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

import database.developer_data as dev_db
from database.redis_db import get_generic_cache, set_generic_cache
from utils.llm.fortune import DailyFortune, generate_daily_fortune
from utils.other import endpoints as auth

router = APIRouter()


class DailyFortuneRequest(BaseModel):
    birthday: Optional[str] = None  # 'YYYY-MM-DD'，为空则回退 Firestore birthday
    date: Optional[str] = None  # 'YYYY-MM-DD'，为空则用 UTC 当日
    language: Optional[str] = None


@router.post('/v1/fortune/daily', tags=['v1'], response_model=DailyFortune)
def get_daily_fortune(data: DailyFortuneRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx

    birthday = (data.birthday or '').strip() or (dev_db.get_user_birthday(developer_id, uid) if developer_id else None)
    if not birthday:
        raise HTTPException(status_code=400, detail="birthday required")
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', birthday):
        raise HTTPException(status_code=400, detail="birthday must be in YYYY-MM-DD format")

    date_str = (data.date or '').strip() or datetime.utcnow().strftime('%Y-%m-%d')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', date_str):
        raise HTTPException(status_code=400, detail="date must be in YYYY-MM-DD format")

    cache_path = f'fortune:{uid}:{date_str}'
    cached = get_generic_cache(cache_path)
    if cached:
        return DailyFortune(**cached)

    language = data.language or (dev_db.get_user_language(developer_id, uid) if developer_id else None)
    fortune = generate_daily_fortune(birthday, date_str, output_language=language)

    # 结果只进 Redis（TTL 24h），不写 Firestore —— 满足「不自动保存」。
    set_generic_cache(cache_path, fortune.dict(), ttl=86400)
    return fortune
