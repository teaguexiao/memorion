"""
Internal EIR Webhook Receiver

This module provides an internal endpoint that receives EIR webhook events
and adds emotional care messages to the user's chat session.

The endpoint acts as an internal webhook consumer, receiving events from
the EIR webhook system and processing them to provide emotional support.
"""

import os
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

import database.developer_data as dev_db
from models.chat import Message, MessageSender, MessageType
from utils.developer_eir_events import verify_signature
from utils.llm.eir_care_message import generate_eir_care_message


router = APIRouter()


# ******************************************************
# ****************** CONFIGURATION ********************
# ******************************************************

# Internal webhook secret - must match the secret used when registering
# the internal webhook via the EIR webhooks API
INTERNAL_EIR_WEBHOOK_SECRET = os.environ.get("INTERNAL_EIR_WEBHOOK_SECRET", "")

# Signature verification tolerance (5 minutes)
SIGNATURE_TOLERANCE_SECONDS = 300


# ******************************************************
# ****************** RESPONSE MODELS ******************
# ******************************************************


class InternalWebhookResponse(BaseModel):
    """Response from internal webhook processing."""
    status: str
    message_id: Optional[str] = None
    session_id: Optional[str] = None


# ******************************************************
# ****************** WEBHOOK ENDPOINT *****************
# ******************************************************


@router.post(
    "/v1/internal/eir-webhook",
    response_model=InternalWebhookResponse,
    tags=["internal"],
)
async def receive_eir_webhook(request: Request):
    """
    Internal endpoint to receive EIR webhook events.

    This endpoint:
    1. Verifies the HMAC signature from the webhook system
    2. Processes `eir.emotion_detected` events
    3. Generates care messages using LLM
    4. Writes messages to the user's EIR care chat session

    Headers expected:
    - X-Memorion-Signature: HMAC-SHA256 signature
    - X-Memorion-Timestamp: Unix timestamp
    - X-Memorion-Event-Type: Event type string

    This is an internal endpoint not exposed to external developers.
    """
    if not INTERNAL_EIR_WEBHOOK_SECRET:
        raise HTTPException(status_code=503, detail="Webhook is unavailable")

    # Get headers
    signature = request.headers.get("X-Memorion-Signature", "")
    timestamp_str = request.headers.get("X-Memorion-Timestamp", "")
    event_type = request.headers.get("X-Memorion-Event-Type", "")

    # Validate required headers
    if not signature or not timestamp_str:
        raise HTTPException(
            status_code=400,
            detail="Missing required headers (X-Memorion-Signature, X-Memorion-Timestamp)"
        )

    # Parse timestamp
    try:
        timestamp = int(timestamp_str)
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid timestamp format")

    # Check timestamp is within tolerance (prevent replay attacks)
    current_time = int(time.time())
    if abs(current_time - timestamp) > SIGNATURE_TOLERANCE_SECONDS:
        raise HTTPException(status_code=400, detail="Timestamp out of range")

    # Get raw body for signature verification
    body = await request.body()
    payload_str = body.decode("utf-8")

    if not verify_signature(INTERNAL_EIR_WEBHOOK_SECRET, timestamp, payload_str, signature):
        raise HTTPException(status_code=401, detail="Invalid signature")

    # Parse payload
    try:
        import json
        payload = json.loads(payload_str)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON payload")

    # Extract event data
    event_type_from_body = payload.get("type", "")
    developer_id = payload.get("developer_id", "")
    external_user_id = payload.get("external_user_id", "")
    data = payload.get("data", {})

    # Only handle eir.emotion_detected events
    if event_type_from_body != "eir.emotion_detected":
        return InternalWebhookResponse(
            status="ignored",
            message_id=None,
            session_id=None,
        )

    # Validate required fields
    if not developer_id or not external_user_id:
        raise HTTPException(
            status_code=400,
            detail="Missing developer_id or external_user_id in payload"
        )

    # Process the emotion event
    result = await _process_emotion_event(developer_id, external_user_id, data)

    return InternalWebhookResponse(
        status="ok",
        message_id=result.get("message_id"),
        session_id=result.get("session_id"),
    )


# ******************************************************
# ****************** EVENT PROCESSING *****************
# ******************************************************


async def _process_emotion_event(
    developer_id: str,
    external_user_id: str,
    data: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Process an EIR emotion detected event.

    Args:
        developer_id: Developer ID
        external_user_id: External user ID
        data: Event data containing emotion info

    Returns:
        Dict with message_id and session_id
    """
    # Extract emotion data
    conversation_id = data.get("conversation_id", "")
    emotion = data.get("eir_primary_emotion", "unknown")
    emotion_summary = data.get("eir_emotion_summary", "")
    suggested_message = data.get("eir_suggested_message", "")

    # Get conversation transcript for context
    transcript = ""
    if conversation_id:
        conversation = dev_db.get_conversation(
            developer_id, external_user_id, conversation_id
        )
        if conversation:
            segments = conversation.get("transcript_segments", [])
            transcript = " ".join(
                seg.get("text", "") for seg in segments if seg.get("text")
            )

    # Generate care message using LLM
    # If we have a suggested message from the emotion detection, we still
    # generate a fresh one based on the full context for personalization.
    # Pass user.language so the care message respects the user's preference
    # rather than relying on transcript heuristics.
    user_language = dev_db.get_user_language(developer_id, external_user_id)
    care_message = generate_eir_care_message(
        emotion=emotion,
        emotion_summary=emotion_summary,
        transcript=transcript,
        output_language=user_language,
    )

    # Write the care message into the user's v2 chat, which is the only chat the
    # app actually reads. Use the default chat session:
    # reuse the default (app_id=None) session so care messages land in the same
    # thread the user chats in, rather than a separate EIR-only session.
    chat_session = dev_db.get_v2_chat_session(developer_id, external_user_id, app_id=None)
    if not chat_session:
        chat_session = dev_db.create_v2_new_chat_session(
            developer_id, external_user_id, app_id=None, title="Chat"
        )
    session_id = chat_session["id"]

    message_id = str(uuid.uuid4())
    ai_message = Message(
        id=message_id,
        text=care_message,
        created_at=datetime.now(timezone.utc),
        sender=MessageSender.ai,
        app_id=None,
        from_external_integration=False,
        type=MessageType.text,
        memories_id=[conversation_id] if conversation_id else [],
        chat_session_id=session_id,
    )
    dev_db.add_v2_message(developer_id, external_user_id, ai_message.dict())
    dev_db.add_v2_message_to_chat_session(developer_id, external_user_id, session_id, message_id)

    print(f"EIR care message added: developer={developer_id}, user={external_user_id}, "
          f"emotion={emotion}, session={session_id}")

    return {
        "message_id": message_id,
        "session_id": session_id,
    }
