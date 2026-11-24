"""
Developer API - User Preferences endpoints

All data is tenant-isolated under developer_data/{developer_id}/users/{external_user_id}
"""

import logging
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from dependencies import get_developer_id_from_api_key
from utils.llm.chat import retrieve_context_dates_by_question

router = APIRouter()

logger = logging.getLogger(__name__)


def _resolve_user_timezone(developer_id: str, external_user_id: str) -> str:
    """The user's timezone, preferring the field the chat agent actually reads.

    ⚠️ 用户时区在 Firestore 里有**两个字段**，写入方不同：

    - `time_zone` —— `POST /v1/users/fcm-token` 写的（App 启动时随 FCM token 上报），
      chat agent（`graph.py`）、对话处理、通知都读这个
    - `timezone` —— `PATCH /v1/user/timezone` 写的（用户在设置里手选）

    这里 `time_zone` 优先，是为了让本端点解析出的范围与 chat 里
    `resolve_time_range` 工具解析出的**完全一致**——外部客户端拿到的 start/end
    要能和 chat 的回答对得上，否则同一句"上周"在两条路径下会指向不同区间。
    """
    tz = None
    try:
        tz = dev_db.get_user_time_zone(developer_id, external_user_id)
    except Exception:
        logger.exception("get_user_time_zone failed for %s/%s", developer_id, external_user_id)
    if not tz:
        try:
            tz = dev_db.get_user_timezone(developer_id, external_user_id)
        except Exception:
            logger.exception("get_user_timezone failed for %s/%s", developer_id, external_user_id)
    return tz or "UTC"


def _iso_or_none(value: Optional[datetime]) -> Optional[str]:
    return value.isoformat() if isinstance(value, datetime) else None


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class UserPreferencesResponse(BaseModel):
    """User preferences response model.

    ⚠️ 新增字段必须在这里声明——response_model 会静默滤掉未声明的字段
    （`ActionItem.confirmed` / `MemoryResponse.user_review` 都踩过这个坑：
    Firestore 写对了、API 返回却没有）。
    """
    language: Optional[str] = Field(None, description="User's preferred language code")
    timezone: Optional[str] = Field(None, description="User's preferred timezone (IANA format)")
    recording_categories: Optional[List[str]] = Field(
        None,
        description="Recording content preferences picked during onboarding (O-03), e.g. ['work','family']",
    )


class LanguageUpdate(BaseModel):
    """Language update request model."""
    language: str = Field(..., description="Language code (e.g., 'en', 'zh', 'vi')", min_length=2, max_length=10)


class TimezoneUpdate(BaseModel):
    """Timezone update request model."""
    timezone: str = Field(..., description="IANA timezone string (e.g., 'America/New_York', 'Asia/Shanghai')")


class TimeRangeRequest(BaseModel):
    """Relative-time resolution request."""
    expr: str = Field(
        ...,
        description="Relative time expression, e.g. 'last Wednesday', 'this month', '上周'",
        min_length=1,
        max_length=200,
    )
    timezone: Optional[str] = Field(
        None,
        description="IANA timezone override; defaults to the user's stored timezone",
    )


class TimeRangeResponse(BaseModel):
    """Resolved absolute range. start/end are null when nothing was resolvable."""
    start: Optional[str] = Field(None, description="ISO-8601 range start, or null")
    end: Optional[str] = Field(None, description="ISO-8601 range end, or null")
    timezone: str = Field(..., description="Timezone the expression was resolved in")
    resolved_as: str = Field(..., description="Echo of the input expression")


class PreferencesUpdate(BaseModel):
    """User preferences update request model."""
    language: Optional[str] = Field(None, description="Language code (e.g., 'en', 'zh', 'vi')")
    timezone: Optional[str] = Field(None, description="IANA timezone string")
    recording_categories: Optional[List[str]] = Field(
        None,
        description="Recording content preferences (O-03 tags). Empty list clears the selection.",
    )


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/user/preferences", response_model=UserPreferencesResponse, tags=["developer-api-users"])
async def get_user_preferences(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get all user preferences (language, timezone).
    """
    preferences = dev_db.get_user_preferences(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )
    return preferences


@router.patch("/v1/user/preferences", response_model=UserPreferencesResponse, tags=["developer-api-users"])
async def update_user_preferences(
    update_data: PreferencesUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Update user preferences. Only provided fields will be updated.
    """
    if update_data.language is None and update_data.timezone is None and update_data.recording_categories is None:
        raise HTTPException(
            status_code=400,
            detail="At least one field (language, timezone or recording_categories) must be provided",
        )

    preferences = dev_db.update_user_preferences(
        developer_id=developer_id,
        external_user_id=external_user_id,
        language=update_data.language,
        timezone_str=update_data.timezone,
        recording_categories=update_data.recording_categories,
    )
    return preferences


@router.get("/v1/user/language", tags=["developer-api-users"])
async def get_user_language(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get the user's preferred language.
    """
    language = dev_db.get_user_language(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )
    return {"language": language}


@router.patch("/v1/user/language", response_model=UserPreferencesResponse, tags=["developer-api-users"])
async def set_user_language(
    update_data: LanguageUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Set the user's preferred language.

    Common language codes: 'en' (English), 'zh' (Chinese), 'vi' (Vietnamese),
    'ja' (Japanese), 'ko' (Korean), 'es' (Spanish), 'fr' (French), etc.
    """
    preferences = dev_db.set_user_language(
        developer_id=developer_id,
        external_user_id=external_user_id,
        language=update_data.language,
    )
    return preferences


@router.get("/v1/user/timezone", tags=["developer-api-users"])
async def get_user_timezone(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get the user's preferred timezone.
    """
    timezone = dev_db.get_user_timezone(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )
    return {"timezone": timezone}


@router.patch("/v1/user/timezone", response_model=UserPreferencesResponse, tags=["developer-api-users"])
async def set_user_timezone(
    update_data: TimezoneUpdate,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Set the user's preferred timezone.

    Use IANA timezone strings (e.g., 'America/New_York', 'Asia/Shanghai', 'Europe/London').
    See: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
    """
    preferences = dev_db.set_user_timezone(
        developer_id=developer_id,
        external_user_id=external_user_id,
        timezone_str=update_data.timezone,
    )
    return preferences


@router.post("/v1/user/resolve-time-range", response_model=TimeRangeResponse, tags=["developer-api-users"])
async def resolve_time_range(
    body: TimeRangeRequest,
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Resolve a relative time expression ("last Wednesday", "上周") into an
    absolute ISO-8601 range in the user's timezone.

    Same resolver the chat agent's `resolve_time_range` tool uses, exposed so
    external clients (CLI / MCP) can feed absolute ranges into the search and
    to-do endpoints instead of guessing at the user's timezone themselves.

    Returns `start: null, end: null` when the expression carries no resolvable
    date — that is a normal answer, not an error.
    """
    expr = (body.expr or "").strip()
    if not expr:
        raise HTTPException(status_code=400, detail="expr must not be empty")

    tz = body.timezone or _resolve_user_timezone(developer_id, external_user_id)

    try:
        dates_range = retrieve_context_dates_by_question(expr, tz)
    except Exception:
        logger.exception("resolve_time_range failed for expr=%r", expr)
        dates_range = None

    if dates_range and len(dates_range) >= 2:
        return TimeRangeResponse(
            start=_iso_or_none(dates_range[0]),
            end=_iso_or_none(dates_range[1]),
            timezone=tz,
            resolved_as=expr,
        )
    return TimeRangeResponse(start=None, end=None, timezone=tz, resolved_as=expr)


@router.put("/v1/user/preferences/app", tags=["developer-api-users"])
async def set_preferred_app(
    app_id: str = Query(..., description="App ID to set as preferred"),
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """Set the user's preferred summarization app."""
    dev_db.update_user_preferences(
        developer_id=developer_id,
        external_user_id=external_user_id,
        preferred_app_id=app_id,
    )
    return {"status": "ok"}
