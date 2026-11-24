"""
Developer API - EIR Webhook Database Operations

Firestore storage structure:
  developer_data/{developer_id}/webhooks/{webhook_id}
  developer_data/{developer_id}/eir_webhook_deliveries/{delivery_id}
"""

import secrets
import uuid
from datetime import datetime
from typing import List, Optional, Dict, Any

from google.cloud import firestore

from database._client import db
from models.developer_eir_webhook import (
    WebhookStatus,
    DeliveryStatus,
    Webhook,
    WebhookResponse,
    WebhookDelivery,
    WebhookDeliveryResponse,
)


# ******************************************************
# ****************** CONSTANTS *************************
# ******************************************************

MAX_CONSECUTIVE_FAILURES = 5  # Suspend webhook after this many failures
WEBHOOK_SECRET_LENGTH = 32  # Length of HMAC secret in bytes


# ******************************************************
# ****************** WEBHOOKS **************************
# ******************************************************


def generate_webhook_secret() -> str:
    """Generate a secure random secret for webhook HMAC signing."""
    return secrets.token_hex(WEBHOOK_SECRET_LENGTH)


def create_webhook(
    developer_id: str,
    name: str,
    url: str,
    events: List[str],
    filters: Optional[Dict[str, Any]] = None,
) -> tuple[dict, str]:
    """
    Create a new webhook for a developer.

    Args:
        developer_id: The developer's ID
        name: Human-readable name for the webhook
        url: HTTPS URL to receive events
        events: List of event types to subscribe to
        filters: Optional event filters

    Returns:
        Tuple of (webhook_dict, secret) - secret is only returned once
    """
    webhook_id = str(uuid.uuid4())
    secret = generate_webhook_secret()
    now = datetime.utcnow()

    webhook_data = {
        "id": webhook_id,
        "name": name,
        "url": str(url),
        "events": events,
        "status": WebhookStatus.active.value,
        "secret": secret,  # Stored but never exposed via API
        "consecutive_failures": 0,
        "filters": filters,
        "created_at": now,
        "updated_at": None,
    }

    db.collection("developer_data").document(developer_id).collection(
        "webhooks"
    ).document(webhook_id).set(webhook_data)

    # Return webhook data without secret for response
    response_data = {k: v for k, v in webhook_data.items() if k != "secret"}
    return response_data, secret


def get_webhook(developer_id: str, webhook_id: str) -> Optional[dict]:
    """
    Get a webhook by ID.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID

    Returns:
        Webhook dict or None if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    data = doc.to_dict()
    # Remove secret from response
    if "secret" in data:
        del data["secret"]

    return data


def get_webhook_with_secret(developer_id: str, webhook_id: str) -> Optional[dict]:
    """
    Get a webhook by ID including the secret (for internal use only).

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID

    Returns:
        Webhook dict with secret or None if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    return doc.to_dict()


def list_webhooks(developer_id: str) -> List[dict]:
    """
    List all webhooks for a developer.

    Args:
        developer_id: The developer's ID

    Returns:
        List of webhook dicts (without secrets)
    """
    webhooks_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .order_by("created_at", direction=firestore.Query.DESCENDING)
    )

    docs = webhooks_ref.stream()
    webhooks = []
    for doc in docs:
        data = doc.to_dict()
        # Remove secret from response
        if "secret" in data:
            del data["secret"]
        webhooks.append(data)

    return webhooks


def update_webhook(
    developer_id: str,
    webhook_id: str,
    name: Optional[str] = None,
    url: Optional[str] = None,
    events: Optional[List[str]] = None,
    filters: Optional[Dict[str, Any]] = None,
    status: Optional[str] = None,
) -> Optional[dict]:
    """
    Update a webhook.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID
        name: New name (optional)
        url: New URL (optional)
        events: New event list (optional)
        filters: New filters (optional)
        status: New status (optional)

    Returns:
        Updated webhook dict or None if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    updates = {"updated_at": datetime.utcnow()}

    if name is not None:
        updates["name"] = name
    if url is not None:
        updates["url"] = str(url)
    if events is not None:
        updates["events"] = events
    if filters is not None:
        updates["filters"] = filters
    if status is not None:
        updates["status"] = status
        # Reset failures when re-enabling
        if status == WebhookStatus.active.value:
            updates["consecutive_failures"] = 0

    doc_ref.update(updates)

    return get_webhook(developer_id, webhook_id)


def delete_webhook(developer_id: str, webhook_id: str) -> bool:
    """
    Delete a webhook.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID

    Returns:
        True if deleted, False if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return False

    doc_ref.delete()
    return True


def rotate_webhook_secret(developer_id: str, webhook_id: str) -> Optional[str]:
    """
    Rotate (regenerate) a webhook's secret.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID

    Returns:
        New secret or None if webhook not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    new_secret = generate_webhook_secret()
    doc_ref.update({
        "secret": new_secret,
        "updated_at": datetime.utcnow(),
    })

    return new_secret


def increment_webhook_failures(developer_id: str, webhook_id: str) -> int:
    """
    Increment the consecutive failure count for a webhook.
    Suspends the webhook if it exceeds MAX_CONSECUTIVE_FAILURES.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID

    Returns:
        New failure count
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return 0

    data = doc.to_dict()
    new_count = data.get("consecutive_failures", 0) + 1

    updates = {
        "consecutive_failures": new_count,
        "updated_at": datetime.utcnow(),
    }

    # Suspend if exceeded threshold
    if new_count >= MAX_CONSECUTIVE_FAILURES:
        updates["status"] = WebhookStatus.suspended.value

    doc_ref.update(updates)

    return new_count


def reset_webhook_failures(developer_id: str, webhook_id: str):
    """
    Reset the consecutive failure count for a webhook.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .document(webhook_id)
    )

    doc_ref.update({
        "consecutive_failures": 0,
        "updated_at": datetime.utcnow(),
    })


def get_active_webhooks_for_event(
    developer_id: str,
    event_type: str,
) -> List[dict]:
    """
    Get all active webhooks subscribed to a specific event type.

    Args:
        developer_id: The developer's ID
        event_type: The event type to filter by

    Returns:
        List of active webhook dicts (with secrets for delivery)
    """
    webhooks_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("webhooks")
        .where("status", "==", WebhookStatus.active.value)
    )

    docs = webhooks_ref.stream()
    matching_webhooks = []

    for doc in docs:
        data = doc.to_dict()
        # Check if webhook is subscribed to this event type
        if event_type in data.get("events", []):
            matching_webhooks.append(data)

    return matching_webhooks


# ******************************************************
# ************** WEBHOOK DELIVERIES ********************
# ******************************************************


def create_delivery(
    developer_id: str,
    webhook_id: str,
    event_type: str,
    external_user_id: str,
    payload: Dict[str, Any],
) -> dict:
    """
    Create a delivery record for tracking webhook delivery attempts.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID
        event_type: The event type being delivered
        external_user_id: The external user ID
        payload: The event payload

    Returns:
        Created delivery dict
    """
    delivery_id = str(uuid.uuid4())
    now = datetime.utcnow()

    delivery_data = {
        "id": delivery_id,
        "webhook_id": webhook_id,
        "event_type": event_type,
        "external_user_id": external_user_id,
        "payload": payload,
        "status": DeliveryStatus.pending.value,
        "attempts": 0,
        "last_attempt_at": None,
        "last_response_code": None,
        "last_error": None,
        "created_at": now,
    }

    db.collection("developer_data").document(developer_id).collection(
        "eir_webhook_deliveries"
    ).document(delivery_id).set(delivery_data)

    return delivery_data


def update_delivery(
    developer_id: str,
    delivery_id: str,
    status: str,
    response_code: Optional[int] = None,
    error: Optional[str] = None,
) -> Optional[dict]:
    """
    Update a delivery record after an attempt.

    Args:
        developer_id: The developer's ID
        delivery_id: The delivery's ID
        status: New status
        response_code: HTTP response code (optional)
        error: Error message (optional)

    Returns:
        Updated delivery dict or None if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("eir_webhook_deliveries")
        .document(delivery_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    data = doc.to_dict()
    attempts = data.get("attempts", 0) + 1

    updates = {
        "status": status,
        "attempts": attempts,
        "last_attempt_at": datetime.utcnow(),
    }

    if response_code is not None:
        updates["last_response_code"] = response_code
    if error is not None:
        updates["last_error"] = error

    doc_ref.update(updates)

    data.update(updates)
    return data


def get_delivery(developer_id: str, delivery_id: str) -> Optional[dict]:
    """
    Get a delivery record by ID.

    Args:
        developer_id: The developer's ID
        delivery_id: The delivery's ID

    Returns:
        Delivery dict or None if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("eir_webhook_deliveries")
        .document(delivery_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    return doc.to_dict()


def list_deliveries(
    developer_id: str,
    webhook_id: str,
    limit: int = 50,
    offset: int = 0,
) -> List[dict]:
    """
    List delivery records for a webhook.

    Args:
        developer_id: The developer's ID
        webhook_id: The webhook's ID
        limit: Maximum records to return
        offset: Number of records to skip

    Returns:
        List of delivery dicts
    """
    # Requires composite index: webhook_id (ASC) + created_at (DESC)
    deliveries_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("eir_webhook_deliveries")
        .where("webhook_id", "==", webhook_id)
        .order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit + offset)
    )

    docs = list(deliveries_ref.stream())

    # Apply offset
    docs = docs[offset:offset + limit]

    return [doc.to_dict() for doc in docs]


def get_pending_deliveries(developer_id: str, limit: int = 100) -> List[dict]:
    """
    Get pending deliveries for retry processing.

    Args:
        developer_id: The developer's ID
        limit: Maximum records to return

    Returns:
        List of pending delivery dicts
    """
    deliveries_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("eir_webhook_deliveries")
        .where("status", "==", DeliveryStatus.pending.value)
        .order_by("created_at")
        .limit(limit)
    )

    docs = deliveries_ref.stream()
    return [doc.to_dict() for doc in docs]


def delete_old_deliveries(developer_id: str, days: int = 7) -> int:
    """
    Delete delivery records older than specified days.

    Args:
        developer_id: The developer's ID
        days: Delete records older than this many days

    Returns:
        Number of records deleted
    """
    from datetime import timedelta

    cutoff = datetime.utcnow() - timedelta(days=days)

    deliveries_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("eir_webhook_deliveries")
        .where("created_at", "<", cutoff)
        .limit(500)  # Batch delete limit
    )

    docs = list(deliveries_ref.stream())
    count = 0

    for doc in docs:
        doc.reference.delete()
        count += 1

    return count
