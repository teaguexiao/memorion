"""
Developer API - EIR (Emotion Intelligence Recognition) Webhook Models

This module defines data models for the Developer webhook notification system,
including event types, webhook configurations, and delivery records.
"""

from datetime import datetime
from enum import Enum
from typing import Dict, Any, List, Optional

from pydantic import BaseModel, Field, HttpUrl


# ******************************************************
# ****************** EVENT TYPES ***********************
# ******************************************************


class DeveloperEventType(str, Enum):
    """
    Event types that can trigger webhook notifications.

    EIR = Emotion Intelligence Recognition (情绪智能识别)
    """
    # EIR Emotion Recognition events
    eir_emotion_detected = "eir.emotion_detected"

    # Conversation events
    conversation_completed = "conversation.completed"

    # Memory events
    memory_created = "memory.created"

    # Daily summary events
    daily_summary_ready = "daily_summary.ready"

    # Listen session events
    listen_session_completed = "listen_session.completed"


class EIREmotionCategory(str, Enum):
    """
    Emotion categories detected by EIR (Emotion Intelligence Recognition).

    Aligned with the mobile Avatar's five emotions. Developers can subscribe to
    specific categories via webhook filters.
    """
    happy = "happy"             # 开心、积极、愉悦、兴奋
    angry = "angry"             # 愤怒、生气、沮丧、不满
    sad = "sad"                 # 悲伤、低落、失落、难过
    surprised = "surprised"     # 惊讶、震惊、意外
    calm = "calm"               # 平静、放松、专注、中性（默认）


# ******************************************************
# ****************** WEBHOOK STATUS ********************
# ******************************************************


class WebhookStatus(str, Enum):
    """Status of a webhook endpoint."""
    active = "active"           # Webhook is active and receiving events
    disabled = "disabled"       # Manually disabled by developer
    suspended = "suspended"     # Auto-suspended due to consecutive failures


# ******************************************************
# ****************** FILTER MODELS *********************
# ******************************************************


class EIREmotionFilter(BaseModel):
    """Filter configuration for eir.emotion_detected events."""
    eir_emotions: Optional[List[str]] = Field(
        None,
        description=(
            "List of emotion categories to trigger webhook. "
            "Valid values: happy, angry, sad, surprised, calm. "
            "Legacy values from earlier deployments are accepted but will never match "
            "incoming events. If empty/null, all emotions trigger."
        )
    )
    eir_min_confidence: Optional[float] = Field(
        0.0,
        ge=0.0,
        le=1.0,
        description="Minimum confidence score to trigger webhook (0.0 - 1.0)"
    )


class ConversationFilter(BaseModel):
    """Filter configuration for conversation.completed events."""
    min_duration_seconds: Optional[int] = Field(
        0,
        ge=0,
        description="Minimum conversation duration in seconds to trigger webhook"
    )


class WebhookFilters(BaseModel):
    """
    Filter configurations for different event types.

    Allows developers to specify conditions for when webhooks should be triggered.
    """
    eir_emotion_detected: Optional[EIREmotionFilter] = Field(
        None,
        alias="eir.emotion_detected",
        description="Filters for eir.emotion_detected events"
    )
    conversation_completed: Optional[ConversationFilter] = Field(
        None,
        alias="conversation.completed",
        description="Filters for conversation.completed events"
    )

    class Config:
        populate_by_name = True


# ******************************************************
# ****************** WEBHOOK MODELS ********************
# ******************************************************


class WebhookCreate(BaseModel):
    """Request model for creating a new webhook."""
    name: str = Field(
        ...,
        min_length=1,
        max_length=100,
        description="Human-readable name for this webhook"
    )
    url: HttpUrl = Field(
        ...,
        description="HTTPS URL to receive webhook events"
    )
    events: List[DeveloperEventType] = Field(
        ...,
        min_length=1,
        description="List of event types to subscribe to"
    )
    filters: Optional[Dict[str, Any]] = Field(
        None,
        description="Optional filters to control when events are delivered"
    )


class WebhookUpdate(BaseModel):
    """Request model for updating a webhook."""
    name: Optional[str] = Field(
        None,
        min_length=1,
        max_length=100,
        description="New name for this webhook"
    )
    url: Optional[HttpUrl] = Field(
        None,
        description="New URL to receive webhook events"
    )
    events: Optional[List[DeveloperEventType]] = Field(
        None,
        description="New list of event types to subscribe to"
    )
    filters: Optional[Dict[str, Any]] = Field(
        None,
        description="New filters configuration"
    )
    status: Optional[WebhookStatus] = Field(
        None,
        description="New status (active or disabled)"
    )


class Webhook(BaseModel):
    """Webhook configuration stored in database."""
    id: str = Field(..., description="Unique webhook identifier")
    name: str = Field(..., description="Human-readable name")
    url: str = Field(..., description="HTTPS URL to receive events")
    events: List[str] = Field(..., description="Subscribed event types")
    status: WebhookStatus = Field(default=WebhookStatus.active)
    consecutive_failures: int = Field(default=0, description="Number of consecutive delivery failures")
    filters: Optional[Dict[str, Any]] = Field(default=None)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    updated_at: Optional[datetime] = None

    # Note: secret is stored but never returned in API responses


class WebhookResponse(BaseModel):
    """Response model for webhook (excludes secret)."""
    id: str
    name: str
    url: str
    events: List[str]
    status: WebhookStatus
    consecutive_failures: int
    filters: Optional[Dict[str, Any]] = None
    created_at: datetime
    updated_at: Optional[datetime] = None


class WebhookCreatedResponse(WebhookResponse):
    """Response when creating a webhook - includes secret (shown only once)."""
    secret: str = Field(..., description="HMAC signing secret (shown only once)")


# ******************************************************
# ************** WEBHOOK DELIVERY MODELS ***************
# ******************************************************


class DeliveryStatus(str, Enum):
    """Status of a webhook delivery attempt."""
    pending = "pending"
    delivered = "delivered"
    failed = "failed"


class WebhookDelivery(BaseModel):
    """Record of a webhook delivery attempt."""
    id: str = Field(..., description="Unique delivery identifier")
    webhook_id: str = Field(..., description="Associated webhook ID")
    event_type: str = Field(..., description="Type of event delivered")
    external_user_id: str = Field(..., description="External user ID")
    payload: Dict[str, Any] = Field(..., description="Event payload sent")
    status: DeliveryStatus = Field(default=DeliveryStatus.pending)
    attempts: int = Field(default=0, description="Number of delivery attempts")
    last_attempt_at: Optional[datetime] = None
    last_response_code: Optional[int] = None
    last_error: Optional[str] = None
    created_at: datetime = Field(default_factory=datetime.utcnow)


class WebhookDeliveryResponse(BaseModel):
    """Response model for webhook delivery records."""
    id: str
    webhook_id: str
    event_type: str
    external_user_id: str
    status: str
    attempts: int
    last_attempt_at: Optional[datetime] = None
    last_response_code: Optional[int] = None
    last_error: Optional[str] = None
    created_at: datetime


# ******************************************************
# ****************** EVENT MODELS **********************
# ******************************************************


class DeveloperEvent(BaseModel):
    """
    Base model for developer webhook events.

    This is the payload structure sent to developer webhook endpoints.
    """
    id: str = Field(..., description="Unique event identifier (evt_xxx)")
    type: str = Field(..., description="Event type")
    api_version: str = Field(default="2024-02-04", description="API version")
    created_at: datetime = Field(default_factory=datetime.utcnow)
    developer_id: str = Field(..., description="Developer ID")
    external_user_id: str = Field(..., description="External user ID")
    data: Dict[str, Any] = Field(..., description="Event-specific data")


class EIREmotionDetectedData(BaseModel):
    """Data payload for eir.emotion_detected events."""
    conversation_id: str
    eir_primary_emotion: str = Field(..., description="Primary detected emotion")
    eir_confidence: float = Field(..., ge=0.0, le=1.0, description="Detection confidence")
    eir_should_notify: bool = Field(default=False, description="Whether notification is recommended")
    eir_emotion_summary: Optional[str] = Field(None, description="Summary of emotional context")
    eir_suggested_message: Optional[str] = Field(None, description="Suggested response message")


class ConversationCompletedData(BaseModel):
    """Data payload for conversation.completed events."""
    conversation_id: str
    title: str = Field(..., description="Conversation title")
    overview: str = Field(..., description="Conversation overview")
    duration_seconds: float = Field(..., description="Conversation duration")
    category: Optional[str] = None
    action_items_count: int = Field(default=0)


class MemoryCreatedData(BaseModel):
    """Data payload for memory.created events."""
    memory_id: str
    conversation_id: Optional[str] = None
    content: str
    category: Optional[str] = None


class DailySummaryReadyData(BaseModel):
    """Data payload for daily_summary.ready events."""
    summary_id: str
    date: str
    summary: str
    highlights_count: int = Field(default=0)


class ListenSessionCompletedData(BaseModel):
    """Data payload for listen_session.completed events."""
    session_id: str
    duration_seconds: float
    audio_path: Optional[str] = None


# ******************************************************
# ****************** TEST PAYLOAD **********************
# ******************************************************


class WebhookTestRequest(BaseModel):
    """Request model for testing webhook delivery."""
    event_type: Optional[DeveloperEventType] = Field(
        default=DeveloperEventType.eir_emotion_detected,
        description="Event type to simulate"
    )
