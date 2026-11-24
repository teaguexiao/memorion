"""
API Log models for Developer API request tracking and billing.
"""

from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class ResourceType(str, Enum):
    """Resource types for billing purposes."""

    # STT (Speech-to-Text)
    STT_REALTIME_MINUTES = "stt_realtime_minutes"  # Real-time STT via WebSocket
    STT_BATCH_MINUTES = "stt_batch_minutes"  # Batch transcription

    # LLM (Large Language Model)
    LLM_MINI_TOKENS = "llm_mini_tokens"  # Mini model (fast, lightweight)
    LLM_STANDARD_TOKENS = "llm_standard_tokens"  # Standard model (default)
    LLM_PRO_TOKENS = "llm_pro_tokens"  # Pro model (complex reasoning)

    # Vision
    VLM_REQUESTS = "vlm_requests"  # Vision Language Model requests

    # Storage
    STORAGE_BYTES = "storage_bytes"  # Image/audio storage

    # Speaker Identification
    SPEAKER_ID_REQUESTS = "speaker_id_requests"  # Speaker identification

    # General
    API_REQUESTS = "api_requests"  # Default for general API calls


class EndpointGroup(str, Enum):
    """Endpoint groups for categorization."""

    MEMORIES = "memories"
    CONVERSATIONS = "conversations"
    PEOPLE = "people"
    FACTS = "facts"
    CHAT = "chat"
    LISTEN = "listen"
    TRANSCRIBE = "transcribe"
    IMAGES = "images"
    SPEECH_PROFILE = "speech_profile"
    DAILY_SUMMARY = "daily_summary"
    USAGE = "usage"
    KEYS = "keys"
    WEBHOOKS = "webhooks"
    OTHER = "other"


class APILogEntry(BaseModel):
    """Single API request log entry."""

    request_id: str = Field(..., description="Unique request identifier (UUID)")
    timestamp: datetime = Field(default_factory=datetime.utcnow)

    # Request info
    method: str = Field(..., description="HTTP method (GET/POST/PATCH/DELETE/WEBSOCKET)")
    endpoint: str = Field(..., description="API endpoint path")
    endpoint_group: str = Field(
        default=EndpointGroup.OTHER.value, description="Endpoint group for categorization"
    )
    query_params: Dict[str, Any] = Field(
        default_factory=dict, description="Query parameters (sanitized)"
    )
    request_body_size: int = Field(default=0, description="Request body size in bytes")

    # Authentication
    api_key_id: str = Field(..., description="API Key ID (not the full key)")
    developer_id: str = Field(..., description="Developer ID")
    external_user_id: Optional[str] = Field(
        default=None, description="External user ID if applicable"
    )

    # Response info
    status_code: int = Field(..., description="HTTP status code")
    response_time_ms: int = Field(..., description="Response time in milliseconds")
    response_body_size: int = Field(default=0, description="Response body size in bytes")
    error_detail: Optional[str] = Field(
        default=None, description="Error detail if status >= 400"
    )

    # Billing
    resource_type: str = Field(
        default=ResourceType.API_REQUESTS.value, description="Resource type for billing"
    )
    billable_units: float = Field(default=1.0, description="Number of billable units")
    cost_estimate: float = Field(default=0.0, description="Estimated cost in USD")

    # Metadata
    client_ip: Optional[str] = Field(default=None, description="Client IP address")
    user_agent: Optional[str] = Field(default=None, description="User agent string")
    region: Optional[str] = Field(default=None, description="Service region")

    class Config:
        use_enum_values = True


class DailyUsageSummary(BaseModel):
    """Aggregated daily usage summary for a developer."""

    date: str = Field(..., description="Date in YYYY-MM-DD format")
    developer_id: str = Field(..., description="Developer ID")

    total_requests: int = Field(default=0, description="Total API requests")
    total_errors: int = Field(default=0, description="Total error responses (4xx/5xx)")
    total_cost: float = Field(default=0.0, description="Total estimated cost in USD")

    by_endpoint_group: Dict[str, int] = Field(
        default_factory=dict, description="Request count by endpoint group"
    )
    by_resource_type: Dict[str, float] = Field(
        default_factory=dict, description="Billable units by resource type"
    )
    by_status_code: Dict[str, int] = Field(
        default_factory=dict, description="Request count by status code"
    )
    by_external_user: Dict[str, int] = Field(
        default_factory=dict, description="Request count by external user ID"
    )

    updated_at: datetime = Field(default_factory=datetime.utcnow)


class MonthlyUsageSummary(BaseModel):
    """Aggregated monthly usage summary for a developer."""

    month: str = Field(..., description="Month in YYYY-MM format")
    developer_id: str = Field(..., description="Developer ID")

    total_requests: int = Field(default=0)
    total_errors: int = Field(default=0)
    total_cost: float = Field(default=0.0)

    by_endpoint_group: Dict[str, int] = Field(default_factory=dict)
    by_resource_type: Dict[str, float] = Field(default_factory=dict)

    updated_at: datetime = Field(default_factory=datetime.utcnow)


class ResourceUsage(BaseModel):
    """Usage breakdown for a specific resource type."""

    resource_type: str = Field(..., description="Resource type")
    units: float = Field(..., description="Total units consumed")
    unit_label: str = Field(..., description="Human-readable unit label")
    unit_price: float = Field(default=0.0, description="Price per unit in USD")
    total_cost: float = Field(default=0.0, description="Total cost in USD")


class BillingSummary(BaseModel):
    """Billing summary for a specific period."""

    developer_id: str
    period_type: str = Field(..., description="Period type: 'daily' or 'monthly'")
    period_start: datetime
    period_end: datetime

    resources: List[ResourceUsage] = Field(default_factory=list)
    total_requests: int = Field(default=0)
    total_cost: float = Field(default=0.0)

    credits_used: float = Field(default=0.0, description="Credits used from balance")
    credits_remaining: float = Field(default=0.0, description="Remaining credit balance")


# Query/Response models for API endpoints


class APILogQuery(BaseModel):
    """Query parameters for listing API logs."""

    start_date: str = Field(..., description="Start date (YYYY-MM-DD)")
    end_date: Optional[str] = Field(None, description="End date (YYYY-MM-DD)")
    external_user_id: Optional[str] = Field(None, description="Filter by external user ID")
    endpoint_group: Optional[str] = Field(None, description="Filter by endpoint group")
    resource_type: Optional[str] = Field(None, description="Filter by resource type")
    status_code: Optional[int] = Field(None, description="Filter by status code")
    min_response_time_ms: Optional[int] = Field(
        None, description="Filter by minimum response time"
    )
    limit: int = Field(default=100, ge=1, le=500, description="Maximum results to return")
    offset: int = Field(default=0, ge=0, description="Offset for pagination")


class APILogListResponse(BaseModel):
    """Response for listing API logs."""

    logs: List[APILogEntry]
    total_count: int
    has_more: bool


class UsageSummaryRangeResponse(BaseModel):
    """Response for usage summary over a date range."""

    summaries: List[DailyUsageSummary]
    period_start: str
    period_end: str
    total_requests: int
    total_cost: float
