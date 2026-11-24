"""
Developer API - Usage endpoints

Provides usage statistics, API logs, and billing information for developer accounts.
"""

from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

import database.developer_data as dev_db
import database.api_logs as api_logs_db
from dependencies import (
    get_developer_for_developer_scope,
    get_developer_id_for_developer_scope,
    get_developer_id_from_api_key,
)
from models.developer import Developer
from models.api_log import (
    APILogEntry,
    DailyUsageSummary,
    MonthlyUsageSummary,
    BillingSummary,
    ResourceUsage,
    APILogListResponse,
    UsageSummaryRangeResponse,
)

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class UserUsageStats(BaseModel):
    external_user_id: str
    memories_count: int
    conversations_count: int
    people_count: int
    facts_count: int
    total_items: int


class AggregateUsageStats(BaseModel):
    user_count: int
    memories_count: int
    conversations_count: int
    people_count: int
    facts_count: int
    total_items: int


class UsageResponse(BaseModel):
    developer_id: str
    tier: str
    is_active: bool
    credits_balance: float
    stats: AggregateUsageStats


class UserInfo(BaseModel):
    id: str
    created_at: datetime
    updated_at: datetime


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.get("/v1/usage", response_model=UsageResponse, tags=["developer-api-usage"])
async def get_usage(
    developer: Developer = Depends(get_developer_for_developer_scope),
):
    """
    Get aggregate usage statistics for the developer account.

    Returns total counts across all users.
    """
    stats = dev_db.get_usage_stats(developer_id=developer.id)

    return UsageResponse(
        developer_id=developer.id,
        tier=developer.tier.value,
        is_active=developer.is_active,
        credits_balance=developer.credits_balance,
        stats=AggregateUsageStats(**stats),
    )


@router.get("/v1/usage/user", response_model=UserUsageStats, tags=["developer-api-usage"])
async def get_user_usage(
    external_user_id: str = Query(..., description="External user identifier"),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """
    Get usage statistics for a specific user.
    """
    stats = dev_db.get_usage_stats(
        developer_id=developer_id,
        external_user_id=external_user_id,
    )

    return UserUsageStats(**stats)


@router.get("/v1/users", response_model=List[UserInfo], tags=["developer-api-usage"])
async def list_users(
    limit: int = Query(default=100, ge=1, le=500, description="Maximum users to return"),
    offset: int = Query(default=0, ge=0, description="Number of users to skip"),
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    List all external users that have data stored.
    """
    users = dev_db.get_users_list(
        developer_id=developer_id,
        limit=limit,
        offset=offset,
    )

    return users


# ******************************************************
# *************** API LOGS ENDPOINTS *******************
# ******************************************************


@router.get("/v1/usage/logs", response_model=APILogListResponse, tags=["developer-api-usage"])
async def list_api_logs(
    start_date: str = Query(..., description="Start date (YYYY-MM-DD)"),
    end_date: Optional[str] = Query(None, description="End date (YYYY-MM-DD), defaults to start_date"),
    external_user_id: Optional[str] = Query(None, description="Filter by external user ID"),
    endpoint_group: Optional[str] = Query(None, description="Filter by endpoint group (memories, chat, etc.)"),
    resource_type: Optional[str] = Query(None, description="Filter by resource type"),
    status_code: Optional[int] = Query(None, description="Filter by HTTP status code"),
    min_response_time_ms: Optional[int] = Query(None, description="Filter by minimum response time"),
    limit: int = Query(default=100, ge=1, le=500, description="Maximum results to return"),
    offset: int = Query(default=0, ge=0, description="Offset for pagination"),
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Query API request logs with filtering.

    Returns individual log entries for debugging and analysis.
    For aggregate statistics, use /v1/usage/summary.

    **Note**: Log queries are limited to 7 days per request for performance.
    """
    # Validate date format
    try:
        datetime.strptime(start_date, "%Y-%m-%d")
        if end_date:
            datetime.strptime(end_date, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="Invalid date format. Use YYYY-MM-DD",
        )

    # Limit date range to 7 days
    if end_date:
        start_dt = datetime.strptime(start_date, "%Y-%m-%d")
        end_dt = datetime.strptime(end_date, "%Y-%m-%d")
        if (end_dt - start_dt).days > 7:
            raise HTTPException(
                status_code=400,
                detail="Date range cannot exceed 7 days. Use /v1/usage/summary for longer periods.",
            )

    logs, total_count = api_logs_db.get_logs(
        developer_id=developer_id,
        start_date=start_date,
        end_date=end_date,
        external_user_id=external_user_id,
        endpoint_group=endpoint_group,
        resource_type=resource_type,
        status_code=status_code,
        min_response_time_ms=min_response_time_ms,
        limit=limit,
        offset=offset,
    )

    return APILogListResponse(
        logs=logs,
        total_count=total_count,
        has_more=(offset + len(logs)) < total_count,
    )


@router.get("/v1/usage/summary", response_model=DailyUsageSummary, tags=["developer-api-usage"])
async def get_usage_summary(
    date: str = Query(..., description="Date (YYYY-MM-DD)"),
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Get aggregated usage summary for a specific date.

    Returns pre-computed totals and breakdowns by endpoint, resource type, etc.
    """
    # Validate date format
    try:
        datetime.strptime(date, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="Invalid date format. Use YYYY-MM-DD",
        )

    summary = api_logs_db.get_daily_summary(developer_id, date)

    if not summary:
        # Return empty summary for dates with no data
        return DailyUsageSummary(
            date=date,
            developer_id=developer_id,
            total_requests=0,
            total_errors=0,
            total_cost=0.0,
        )

    return summary


@router.get("/v1/usage/summary/range", response_model=UsageSummaryRangeResponse, tags=["developer-api-usage"])
async def get_usage_summary_range(
    start_date: str = Query(..., description="Start date (YYYY-MM-DD)"),
    end_date: str = Query(..., description="End date (YYYY-MM-DD)"),
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Get usage summaries for a date range.

    Maximum range: 90 days.
    """
    # Validate date format
    try:
        start_dt = datetime.strptime(start_date, "%Y-%m-%d")
        end_dt = datetime.strptime(end_date, "%Y-%m-%d")
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="Invalid date format. Use YYYY-MM-DD",
        )

    # Limit date range to 90 days
    if (end_dt - start_dt).days > 90:
        raise HTTPException(
            status_code=400,
            detail="Date range cannot exceed 90 days.",
        )

    summaries = api_logs_db.get_daily_summaries_range(
        developer_id=developer_id,
        start_date=start_date,
        end_date=end_date,
    )

    # Calculate totals
    total_requests = sum(s.total_requests for s in summaries)
    total_cost = sum(s.total_cost for s in summaries)

    return UsageSummaryRangeResponse(
        summaries=summaries,
        period_start=start_date,
        period_end=end_date,
        total_requests=total_requests,
        total_cost=total_cost,
    )


@router.get("/v1/usage/billing", response_model=BillingSummary, tags=["developer-api-usage"])
async def get_billing_summary(
    month: str = Query(..., description="Month (YYYY-MM)"),
    developer: Developer = Depends(get_developer_for_developer_scope),
):
    """
    Get billing summary for a specific month.

    Returns breakdown by resource type with cost estimates.
    """
    # Validate month format
    try:
        datetime.strptime(month + "-01", "%Y-%m-%d")
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="Invalid month format. Use YYYY-MM",
        )

    # Try to get existing monthly summary
    summary = api_logs_db.get_monthly_summary(developer.id, month)

    if not summary:
        # Compute from daily summaries
        summary = api_logs_db.compute_monthly_summary(developer.id, month)

    # Build resource breakdown
    resources = []

    # Unit labels and pricing (should be moved to config)
    UNIT_LABELS = {
        "stt_realtime_minutes": "minutes",
        "stt_batch_minutes": "minutes",
        "llm_mini_tokens": "1K tokens",
        "llm_standard_tokens": "1K tokens",
        "llm_pro_tokens": "1K tokens",
        "vlm_requests": "requests",
        "storage_bytes": "MB",
        "speaker_id_requests": "requests",
        "api_requests": "requests",
    }

    UNIT_PRICES = {
        "stt_realtime_minutes": 0.006,
        "stt_batch_minutes": 0.004,
        "llm_mini_tokens": 0.0001,
        "llm_standard_tokens": 0.001,
        "llm_pro_tokens": 0.01,
        "vlm_requests": 0.002,
        "storage_bytes": 0.0001,
        "speaker_id_requests": 0.001,
        "api_requests": 0.0,
    }

    for rt, units in summary.by_resource_type.items():
        unit_price = UNIT_PRICES.get(rt, 0.0)
        resources.append(
            ResourceUsage(
                resource_type=rt,
                units=units,
                unit_label=UNIT_LABELS.get(rt, "units"),
                unit_price=unit_price,
                total_cost=round(units * unit_price, 6),
            )
        )

    # Calculate period dates
    year, month_num = map(int, month.split("-"))
    import calendar

    last_day = calendar.monthrange(year, month_num)[1]
    period_start = datetime(year, month_num, 1)
    period_end = datetime(year, month_num, last_day, 23, 59, 59)

    return BillingSummary(
        developer_id=developer.id,
        period_type="monthly",
        period_start=period_start,
        period_end=period_end,
        resources=resources,
        total_requests=summary.total_requests,
        total_cost=summary.total_cost,
        credits_used=min(developer.credits_balance, summary.total_cost),
        credits_remaining=max(0, developer.credits_balance - summary.total_cost),
    )
