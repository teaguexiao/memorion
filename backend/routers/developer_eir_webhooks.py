"""
Developer API - EIR Webhook Management Endpoints

Provides endpoints for developers to manage webhook subscriptions
for receiving event notifications (emotions, conversations, etc.)
"""

from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

import database.developer_eir_webhooks as webhooks_db
from dependencies import get_developer_id_for_developer_scope
from models.developer_eir_webhook import (
    DeveloperEventType,
    WebhookCreate,
    WebhookUpdate,
    WebhookResponse,
    WebhookCreatedResponse,
    WebhookDeliveryResponse,
    WebhookStatus,
    WebhookTestRequest,
)
from utils.developer_eir_events import emit_test_event


router = APIRouter()


# ******************************************************
# ****************** RESPONSE MODELS *******************
# ******************************************************


class SecretRotatedResponse(BaseModel):
    """Response after rotating webhook secret."""
    id: str
    secret: str = Field(..., description="New HMAC signing secret (shown only once)")


class TestWebhookResponse(BaseModel):
    """Response from webhook test."""
    success: bool
    delivery_id: Optional[str] = None
    status_code: Optional[int] = None
    error: Optional[str] = None


# ******************************************************
# ****************** WEBHOOK CRUD **********************
# ******************************************************


@router.post(
    "/v1/eir/webhooks",
    response_model=WebhookCreatedResponse,
    status_code=201,
    tags=["developer-api-eir-webhooks"],
)
async def create_webhook(
    webhook_data: WebhookCreate,
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Create a new EIR webhook endpoint.

    The response includes a `secret` field that is used to sign webhook
    payloads. **This secret is only shown once** - store it securely.

    ## Event Types
    - `eir.emotion_detected` - Emotion Intelligence Recognition detected an emotion
    - `conversation.completed` - A conversation was processed
    - `memory.created` - A new memory was created
    - `daily_summary.ready` - Daily summary is available
    - `listen_session.completed` - Audio listen session ended

    ## Filters
    You can specify filters to control which events trigger webhooks:

    ```json
    {
      "filters": {
        "eir.emotion_detected": {
          "eir_emotions": ["angry", "sad", "surprised"],
          "eir_min_confidence": 0.7
        },
        "conversation.completed": {
          "min_duration_seconds": 60
        }
      }
    }
    ```
    """
    # Validate URL - HTTPS required except for localhost/127.0.0.1
    url_str = str(webhook_data.url)
    is_localhost = "localhost" in url_str or "127.0.0.1" in url_str
    if not url_str.startswith("https://") and not is_localhost:
        raise HTTPException(
            status_code=400,
            detail="Webhook URL must use HTTPS (HTTP allowed only for localhost)"
        )

    # Convert event types to strings
    events = [e.value for e in webhook_data.events]

    webhook, secret = webhooks_db.create_webhook(
        developer_id=developer_id,
        name=webhook_data.name,
        url=url_str,
        events=events,
        filters=webhook_data.filters,
    )

    return WebhookCreatedResponse(
        **webhook,
        secret=secret,
    )


@router.get(
    "/v1/eir/webhooks",
    response_model=List[WebhookResponse],
    tags=["developer-api-eir-webhooks"],
)
async def list_webhooks(
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    List all EIR webhooks for the developer.

    Returns webhook configurations without secrets.
    """
    webhooks = webhooks_db.list_webhooks(developer_id)
    return [WebhookResponse(**w) for w in webhooks]


@router.get(
    "/v1/eir/webhooks/{webhook_id}",
    response_model=WebhookResponse,
    tags=["developer-api-eir-webhooks"],
)
async def get_webhook(
    webhook_id: str,
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Get a specific EIR webhook by ID.

    Returns webhook configuration without the secret.
    """
    webhook = webhooks_db.get_webhook(developer_id, webhook_id)

    if not webhook:
        raise HTTPException(status_code=404, detail="Webhook not found")

    return WebhookResponse(**webhook)


@router.patch(
    "/v1/eir/webhooks/{webhook_id}",
    response_model=WebhookResponse,
    tags=["developer-api-eir-webhooks"],
)
async def update_webhook(
    webhook_id: str,
    update_data: WebhookUpdate,
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Update an EIR webhook configuration.

    You can update:
    - `name` - Human-readable name
    - `url` - Destination URL (must be HTTPS)
    - `events` - List of subscribed event types
    - `filters` - Event filter configuration
    - `status` - Set to `active` or `disabled`

    Note: Setting status to `active` will reset the failure counter and
    re-enable a suspended webhook.
    """
    # Validate URL if provided - HTTPS required except for localhost/127.0.0.1
    if update_data.url:
        url_str = str(update_data.url)
        is_localhost = "localhost" in url_str or "127.0.0.1" in url_str
        if not url_str.startswith("https://") and not is_localhost:
            raise HTTPException(
                status_code=400,
                detail="Webhook URL must use HTTPS (HTTP allowed only for localhost)"
            )
    else:
        url_str = None

    # Convert event types to strings if provided
    events = None
    if update_data.events:
        events = [e.value for e in update_data.events]

    # Convert status to string if provided
    status = None
    if update_data.status:
        # Only allow active or disabled via API (not suspended)
        if update_data.status == WebhookStatus.suspended:
            raise HTTPException(
                status_code=400,
                detail="Cannot manually set status to suspended"
            )
        status = update_data.status.value

    webhook = webhooks_db.update_webhook(
        developer_id=developer_id,
        webhook_id=webhook_id,
        name=update_data.name,
        url=url_str,
        events=events,
        filters=update_data.filters,
        status=status,
    )

    if not webhook:
        raise HTTPException(status_code=404, detail="Webhook not found")

    return WebhookResponse(**webhook)


@router.delete(
    "/v1/eir/webhooks/{webhook_id}",
    status_code=204,
    tags=["developer-api-eir-webhooks"],
)
async def delete_webhook(
    webhook_id: str,
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Delete an EIR webhook.

    This will stop all event deliveries to this endpoint.
    Delivery history is retained for reference.
    """
    success = webhooks_db.delete_webhook(developer_id, webhook_id)

    if not success:
        raise HTTPException(status_code=404, detail="Webhook not found")

    return


# ******************************************************
# ****************** SECRET ROTATION *******************
# ******************************************************


@router.post(
    "/v1/eir/webhooks/{webhook_id}/rotate-secret",
    response_model=SecretRotatedResponse,
    tags=["developer-api-eir-webhooks"],
)
async def rotate_webhook_secret(
    webhook_id: str,
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Rotate (regenerate) the webhook signing secret.

    The new secret is returned in the response. **This is the only time
    the new secret will be shown** - store it securely.

    After rotation:
    1. Update your server to use the new secret
    2. Events will be signed with the new secret immediately
    3. The old secret is invalidated
    """
    # Check webhook exists
    webhook = webhooks_db.get_webhook(developer_id, webhook_id)
    if not webhook:
        raise HTTPException(status_code=404, detail="Webhook not found")

    new_secret = webhooks_db.rotate_webhook_secret(developer_id, webhook_id)

    if not new_secret:
        raise HTTPException(status_code=500, detail="Failed to rotate secret")

    return SecretRotatedResponse(
        id=webhook_id,
        secret=new_secret,
    )


# ******************************************************
# ****************** TESTING ***************************
# ******************************************************


@router.post(
    "/v1/eir/webhooks/{webhook_id}/test",
    response_model=TestWebhookResponse,
    tags=["developer-api-eir-webhooks"],
)
async def test_webhook(
    webhook_id: str,
    test_data: Optional[WebhookTestRequest] = None,
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    Send a test event to the webhook.

    This sends a sample event with test data to verify your endpoint
    is correctly configured and can receive events.

    The event will have:
    - `external_user_id`: "test_user_123"
    - `data`: Sample data for the event type
    - Event ID prefixed with `evt_test_`

    You can optionally specify which event type to test.
    """
    # Check webhook exists
    webhook = webhooks_db.get_webhook(developer_id, webhook_id)
    if not webhook:
        raise HTTPException(status_code=404, detail="Webhook not found")

    # Check webhook is active
    if webhook.get("status") != WebhookStatus.active.value:
        raise HTTPException(
            status_code=400,
            detail=f"Webhook is {webhook.get('status')} - must be active to test"
        )

    event_type = DeveloperEventType.eir_emotion_detected
    if test_data and test_data.event_type:
        event_type = test_data.event_type

    result = emit_test_event(developer_id, webhook_id, event_type)

    return TestWebhookResponse(
        success=result.get("success", False),
        delivery_id=result.get("delivery_id"),
        status_code=result.get("status_code"),
        error=result.get("error"),
    )


# ******************************************************
# ****************** DELIVERIES ************************
# ******************************************************


@router.get(
    "/v1/eir/webhooks/{webhook_id}/deliveries",
    response_model=List[WebhookDeliveryResponse],
    tags=["developer-api-eir-webhooks"],
)
async def list_webhook_deliveries(
    webhook_id: str,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    developer_id: str = Depends(get_developer_id_for_developer_scope),
):
    """
    List delivery records for a webhook.

    Shows recent delivery attempts including:
    - Status (pending, delivered, failed)
    - Number of attempts
    - Last response code
    - Error messages

    Delivery records are retained for 7 days.
    """
    # Check webhook exists
    webhook = webhooks_db.get_webhook(developer_id, webhook_id)
    if not webhook:
        raise HTTPException(status_code=404, detail="Webhook not found")

    deliveries = webhooks_db.list_deliveries(
        developer_id,
        webhook_id,
        limit=limit,
        offset=offset,
    )

    return [WebhookDeliveryResponse(**d) for d in deliveries]


# ******************************************************
# ****************** EVENT TYPES INFO ******************
# ******************************************************


@router.get(
    "/v1/eir/event-types",
    tags=["developer-api-eir-webhooks"],
)
async def list_event_types():
    """
    List all available webhook event types.

    Returns information about each event type and its data structure.
    """
    return {
        "event_types": [
            {
                "type": DeveloperEventType.eir_emotion_detected.value,
                "description": "Emotion Intelligence Recognition detected an emotion in a conversation",
                "data_fields": {
                    "conversation_id": "string - Conversation ID",
                    "eir_primary_emotion": "string - Detected emotion category",
                    "eir_confidence": "float - Detection confidence (0.0-1.0)",
                    "eir_should_notify": "boolean - Whether notification is recommended",
                    "eir_emotion_summary": "string - Summary of emotional context",
                    "eir_suggested_message": "string - Suggested response message",
                },
                "filterable_by": ["eir_emotions", "eir_min_confidence"],
            },
            {
                "type": DeveloperEventType.conversation_completed.value,
                "description": "A conversation was successfully processed",
                "data_fields": {
                    "conversation_id": "string - Conversation ID",
                    "title": "string - Conversation title",
                    "overview": "string - Conversation summary",
                    "duration_seconds": "float - Duration in seconds",
                    "category": "string - Conversation category",
                    "action_items_count": "int - Number of action items",
                },
                "filterable_by": ["min_duration_seconds"],
            },
            {
                "type": DeveloperEventType.memory_created.value,
                "description": "A new memory was created from a conversation",
                "data_fields": {
                    "memory_id": "string - Memory ID",
                    "conversation_id": "string - Source conversation ID",
                    "content": "string - Memory content",
                    "category": "string - Memory category",
                },
                "filterable_by": [],
            },
            {
                "type": DeveloperEventType.daily_summary_ready.value,
                "description": "Daily summary is available for a user",
                "data_fields": {
                    "summary_id": "string - Summary ID",
                    "date": "string - Date (YYYY-MM-DD)",
                    "summary": "string - Summary content",
                    "highlights_count": "int - Number of highlights",
                },
                "filterable_by": [],
            },
            {
                "type": DeveloperEventType.listen_session_completed.value,
                "description": "An audio listen session ended",
                "data_fields": {
                    "session_id": "string - Session ID",
                    "duration_seconds": "float - Duration in seconds",
                    "audio_path": "string - Path to audio file (if saved)",
                },
                "filterable_by": [],
            },
        ]
    }
