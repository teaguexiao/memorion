"""
Developer API - EIR Event Dispatch System

This module handles dispatching webhook events to developer endpoints.
Includes HMAC signing, retry logic, and delivery tracking.
"""

import asyncio
import hashlib
import hmac
import json
import threading
import time
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional

import requests

import database.developer_eir_webhooks as webhooks_db
from models.developer_eir_webhook import (
    DeveloperEventType,
    DeveloperEvent,
    DeliveryStatus,
    WebhookStatus,
)


# ******************************************************
# ****************** CONSTANTS *************************
# ******************************************************

API_VERSION = "2024-02-04"

# Retry configuration: exponential backoff
RETRY_DELAYS = [5, 10, 20, 40, 80]  # seconds
MAX_RETRIES = 5
WEBHOOK_TIMEOUT = 30  # seconds


# ******************************************************
# ****************** SIGNATURE *************************
# ******************************************************


def generate_signature(secret: str, timestamp: int, payload: str) -> str:
    """
    Generate HMAC-SHA256 signature for webhook payload.

    Args:
        secret: Webhook secret key
        timestamp: Unix timestamp
        payload: JSON payload string

    Returns:
        Hex-encoded HMAC signature
    """
    message = f"{timestamp}.{payload}"
    signature = hmac.new(
        secret.encode("utf-8"),
        message.encode("utf-8"),
        hashlib.sha256
    ).hexdigest()
    return f"sha256={signature}"


def verify_signature(secret: str, timestamp: int, payload: str, signature: str) -> bool:
    """
    Verify HMAC-SHA256 signature from webhook payload.

    Args:
        secret: Webhook secret key
        timestamp: Unix timestamp from header
        payload: Raw payload string
        signature: Signature from header

    Returns:
        True if signature is valid
    """
    expected = generate_signature(secret, timestamp, payload)
    return hmac.compare_digest(expected, signature)


# ******************************************************
# ****************** EVENT CREATION ********************
# ******************************************************


def create_event_payload(
    developer_id: str,
    external_user_id: str,
    event_type: DeveloperEventType,
    data: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Create a standardized event payload.

    Args:
        developer_id: Developer ID
        external_user_id: External user ID
        event_type: Event type
        data: Event-specific data

    Returns:
        Event payload dict
    """
    event_id = f"evt_{event_type.value.replace('.', '_')}_{uuid.uuid4().hex[:12]}"

    return {
        "id": event_id,
        "type": event_type.value,
        "api_version": API_VERSION,
        "created_at": datetime.utcnow().isoformat() + "Z",
        "developer_id": developer_id,
        "external_user_id": external_user_id,
        "data": data,
    }


# ******************************************************
# ****************** FILTERING *************************
# ******************************************************


def should_deliver_event(
    webhook: Dict[str, Any],
    event_type: str,
    payload_data: Dict[str, Any],
) -> bool:
    """
    Check if an event should be delivered based on webhook filters.

    Args:
        webhook: Webhook configuration dict
        event_type: Event type string
        payload_data: The 'data' portion of the event payload

    Returns:
        True if event should be delivered
    """
    filters = webhook.get("filters") or {}

    # Get filter for this specific event type
    event_filter = filters.get(event_type, {})

    if not event_filter:
        # No filter = deliver all events of this type
        return True

    if event_type == DeveloperEventType.eir_emotion_detected.value:
        return _check_eir_emotion_filter(event_filter, payload_data)

    elif event_type == DeveloperEventType.conversation_completed.value:
        return _check_conversation_filter(event_filter, payload_data)

    # No specific filter logic = deliver
    return True


def _check_eir_emotion_filter(
    filter_config: Dict[str, Any],
    payload_data: Dict[str, Any],
) -> bool:
    """Check if EIR emotion event passes the filter."""
    # Check emotion category filter
    allowed_emotions = filter_config.get("eir_emotions")
    if allowed_emotions:
        primary_emotion = payload_data.get("eir_primary_emotion")
        if primary_emotion not in allowed_emotions:
            return False

    # Check minimum confidence filter
    min_confidence = filter_config.get("eir_min_confidence", 0.0)
    confidence = payload_data.get("eir_confidence", 0.0)
    if confidence < min_confidence:
        return False

    return True


def _check_conversation_filter(
    filter_config: Dict[str, Any],
    payload_data: Dict[str, Any],
) -> bool:
    """Check if conversation event passes the filter."""
    # Check minimum duration filter
    min_duration = filter_config.get("min_duration_seconds", 0)
    duration = payload_data.get("duration_seconds", 0)
    if duration < min_duration:
        return False

    return True


# ******************************************************
# ****************** DELIVERY **************************
# ******************************************************


def deliver_webhook(
    webhook_url: str,
    webhook_secret: str,
    payload: Dict[str, Any],
    timeout: int = WEBHOOK_TIMEOUT,
) -> tuple[bool, int, Optional[str]]:
    """
    Deliver a webhook event to the endpoint.

    Args:
        webhook_url: Destination URL
        webhook_secret: HMAC secret for signing
        payload: Event payload
        timeout: Request timeout in seconds

    Returns:
        Tuple of (success, status_code, error_message)
    """
    timestamp = int(time.time())
    payload_json = json.dumps(payload, separators=(",", ":"), default=str)

    signature = generate_signature(webhook_secret, timestamp, payload_json)

    headers = {
        "Content-Type": "application/json",
        "X-Memorion-Signature": signature,
        "X-Memorion-Timestamp": str(timestamp),
        "X-Memorion-Event-Type": payload.get("type", ""),
        "X-Memorion-Event-ID": payload.get("id", ""),
    }

    try:
        response = requests.post(
            webhook_url,
            data=payload_json,
            headers=headers,
            timeout=timeout,
        )

        # 2xx status codes are considered successful
        success = 200 <= response.status_code < 300
        return success, response.status_code, None

    except requests.Timeout:
        return False, 0, "Request timeout"
    except requests.ConnectionError as e:
        return False, 0, f"Connection error: {str(e)}"
    except Exception as e:
        return False, 0, f"Unexpected error: {str(e)}"


def deliver_with_retry(
    developer_id: str,
    webhook: Dict[str, Any],
    payload: Dict[str, Any],
    delivery_id: str,
) -> bool:
    """
    Deliver webhook with retry logic.

    Args:
        developer_id: Developer ID
        webhook: Webhook configuration (with secret)
        payload: Event payload
        delivery_id: Delivery record ID for tracking

    Returns:
        True if delivery succeeded
    """
    webhook_url = webhook["url"]
    webhook_secret = webhook.get("secret", "")
    webhook_id = webhook["id"]

    for attempt, delay in enumerate(RETRY_DELAYS):
        success, status_code, error = deliver_webhook(
            webhook_url, webhook_secret, payload
        )

        if success:
            # Update delivery record as successful
            webhooks_db.update_delivery(
                developer_id,
                delivery_id,
                DeliveryStatus.delivered.value,
                response_code=status_code,
            )
            # Reset failure count on success
            webhooks_db.reset_webhook_failures(developer_id, webhook_id)
            return True

        # Update delivery record with failure
        webhooks_db.update_delivery(
            developer_id,
            delivery_id,
            DeliveryStatus.pending.value,
            response_code=status_code,
            error=error,
        )

        # Check if we should retry
        if attempt < len(RETRY_DELAYS) - 1:
            time.sleep(delay)

    # All retries exhausted
    webhooks_db.update_delivery(
        developer_id,
        delivery_id,
        DeliveryStatus.failed.value,
        error="Max retries exceeded",
    )

    # Increment failure count (may suspend webhook)
    webhooks_db.increment_webhook_failures(developer_id, webhook_id)

    return False


# ******************************************************
# ****************** EVENT EMISSION ********************
# ******************************************************


def emit_developer_event(
    developer_id: str,
    external_user_id: str,
    event_type: DeveloperEventType,
    data: Dict[str, Any],
):
    """
    Emit an event to all subscribed webhooks for a developer.

    This function:
    1. Finds all active webhooks subscribed to the event type
    2. Checks if event passes each webhook's filters
    3. Creates delivery records and dispatches events

    Events are dispatched in a background thread to avoid blocking.

    Args:
        developer_id: Developer ID
        external_user_id: External user ID
        event_type: Event type to emit
        data: Event-specific data
    """
    # Create the event payload
    payload = create_event_payload(developer_id, external_user_id, event_type, data)

    # Get all active webhooks for this event type
    webhooks = webhooks_db.get_active_webhooks_for_event(
        developer_id, event_type.value
    )

    if not webhooks:
        return

    # Dispatch to each webhook in background
    for webhook in webhooks:
        # Check filters
        if not should_deliver_event(webhook, event_type.value, data):
            continue

        # Create delivery record
        delivery = webhooks_db.create_delivery(
            developer_id,
            webhook["id"],
            event_type.value,
            external_user_id,
            payload,
        )

        # Dispatch in background thread
        threading.Thread(
            target=deliver_with_retry,
            args=(developer_id, webhook, payload, delivery["id"]),
            daemon=True,
        ).start()


def emit_developer_event_sync(
    developer_id: str,
    external_user_id: str,
    event_type: DeveloperEventType,
    data: Dict[str, Any],
) -> List[Dict[str, Any]]:
    """
    Emit an event synchronously and return delivery results.

    Useful for testing or when you need to know delivery status.

    Args:
        developer_id: Developer ID
        external_user_id: External user ID
        event_type: Event type to emit
        data: Event-specific data

    Returns:
        List of delivery results with status
    """
    payload = create_event_payload(developer_id, external_user_id, event_type, data)
    webhooks = webhooks_db.get_active_webhooks_for_event(
        developer_id, event_type.value
    )

    results = []

    for webhook in webhooks:
        if not should_deliver_event(webhook, event_type.value, data):
            results.append({
                "webhook_id": webhook["id"],
                "status": "filtered",
                "message": "Event filtered out by webhook configuration",
            })
            continue

        delivery = webhooks_db.create_delivery(
            developer_id,
            webhook["id"],
            event_type.value,
            external_user_id,
            payload,
        )

        success = deliver_with_retry(developer_id, webhook, payload, delivery["id"])

        results.append({
            "webhook_id": webhook["id"],
            "delivery_id": delivery["id"],
            "status": "delivered" if success else "failed",
        })

    return results


# ******************************************************
# ****************** TEST EVENTS ***********************
# ******************************************************


def emit_test_event(
    developer_id: str,
    webhook_id: str,
    event_type: DeveloperEventType = DeveloperEventType.eir_emotion_detected,
) -> Dict[str, Any]:
    """
    Emit a test event to a specific webhook.

    Args:
        developer_id: Developer ID
        webhook_id: Specific webhook ID to test
        event_type: Event type to simulate

    Returns:
        Test result dict
    """
    webhook = webhooks_db.get_webhook_with_secret(developer_id, webhook_id)
    if not webhook:
        return {"success": False, "error": "Webhook not found"}

    # Generate test payload based on event type
    test_data = _generate_test_data(event_type)

    payload = create_event_payload(
        developer_id,
        "test_user_123",
        event_type,
        test_data,
    )

    # Override event ID to indicate test
    payload["id"] = f"evt_test_{uuid.uuid4().hex[:8]}"

    # Create delivery record
    delivery = webhooks_db.create_delivery(
        developer_id,
        webhook_id,
        event_type.value,
        "test_user_123",
        payload,
    )

    # Deliver synchronously for test
    success, status_code, error = deliver_webhook(
        webhook["url"],
        webhook.get("secret", ""),
        payload,
    )

    # Update delivery record
    webhooks_db.update_delivery(
        developer_id,
        delivery["id"],
        DeliveryStatus.delivered.value if success else DeliveryStatus.failed.value,
        response_code=status_code,
        error=error,
    )

    return {
        "success": success,
        "delivery_id": delivery["id"],
        "status_code": status_code,
        "error": error,
        "payload": payload,
    }


def _generate_test_data(event_type: DeveloperEventType) -> Dict[str, Any]:
    """Generate sample test data for an event type."""
    if event_type == DeveloperEventType.eir_emotion_detected:
        return {
            "conversation_id": "test_conv_123",
            "eir_primary_emotion": "sad",
            "eir_confidence": 0.85,
            "eir_should_notify": True,
            "eir_emotion_summary": "This is a test event - user appears to feel down",
            "eir_suggested_message": "Test: I noticed you might be feeling down. Would you like to talk about it?",
        }

    elif event_type == DeveloperEventType.conversation_completed:
        return {
            "conversation_id": "test_conv_123",
            "title": "Test Conversation",
            "overview": "This is a test conversation event",
            "duration_seconds": 300.0,
            "category": "work",
            "action_items_count": 2,
        }

    elif event_type == DeveloperEventType.memory_created:
        return {
            "memory_id": "test_mem_123",
            "conversation_id": "test_conv_123",
            "content": "This is a test memory",
            "category": "insight",
        }

    elif event_type == DeveloperEventType.daily_summary_ready:
        return {
            "summary_id": "test_summary_123",
            "date": datetime.utcnow().strftime("%Y-%m-%d"),
            "summary": "This is a test daily summary",
            "highlights_count": 3,
        }

    elif event_type == DeveloperEventType.listen_session_completed:
        return {
            "session_id": "test_session_123",
            "duration_seconds": 600.0,
            "audio_path": None,
        }

    return {}
