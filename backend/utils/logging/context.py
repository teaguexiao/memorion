"""
Request context management for billing and logging.

This module provides a way to pass billing information from route handlers
to the logging middleware without modifying function signatures.
"""

from dataclasses import dataclass, field
from typing import Any, Dict, Optional

from starlette.requests import Request

from models.api_log import ResourceType


@dataclass
class BillingContext:
    """
    Context object for storing billing information during request processing.

    Route handlers can update this context to provide specific billing metrics
    that will be captured by the logging middleware.
    """

    resource_type: Optional[str] = None
    billable_units: float = 0.0
    external_user_id: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    # API key metadata (set by middleware)
    api_key_id: Optional[str] = None
    developer_id: Optional[str] = None

    def set_stt_usage(self, duration_seconds: float, is_realtime: bool = True) -> None:
        """Set STT usage metrics."""
        if is_realtime:
            self.resource_type = ResourceType.STT_REALTIME_MINUTES.value
        else:
            self.resource_type = ResourceType.STT_BATCH_MINUTES.value
        self.billable_units = duration_seconds / 60.0  # Convert to minutes

    def set_llm_usage(self, token_count: int, model_tier: str = "standard") -> None:
        """Set LLM usage metrics."""
        tier_map = {
            "mini": ResourceType.LLM_MINI_TOKENS.value,
            "standard": ResourceType.LLM_STANDARD_TOKENS.value,
            "pro": ResourceType.LLM_PRO_TOKENS.value,
        }
        self.resource_type = tier_map.get(model_tier, ResourceType.LLM_STANDARD_TOKENS.value)
        self.billable_units = token_count / 1000.0  # Convert to thousands

    def set_storage_usage(self, size_bytes: int) -> None:
        """Set storage usage metrics."""
        self.resource_type = ResourceType.STORAGE_BYTES.value
        self.billable_units = size_bytes / (1024 * 1024)  # Convert to MB

    def set_vlm_usage(self, request_count: int = 1) -> None:
        """Set Vision LLM usage metrics."""
        self.resource_type = ResourceType.VLM_REQUESTS.value
        self.billable_units = float(request_count)

    def set_speaker_id_usage(self, request_count: int = 1) -> None:
        """Set speaker identification usage metrics."""
        self.resource_type = ResourceType.SPEAKER_ID_REQUESTS.value
        self.billable_units = float(request_count)


def get_billing_context(request: Request) -> Optional[BillingContext]:
    """
    Get the billing context from a request.

    Args:
        request: The Starlette/FastAPI request object

    Returns:
        BillingContext if set, None otherwise
    """
    return getattr(request.state, "billing_context", None)


def set_billing_context(request: Request, context: BillingContext) -> None:
    """
    Set the billing context on a request.

    Args:
        request: The Starlette/FastAPI request object
        context: The BillingContext to attach
    """
    request.state.billing_context = context


def ensure_billing_context(request: Request) -> BillingContext:
    """
    Ensure a billing context exists on the request, creating one if needed.

    Args:
        request: The Starlette/FastAPI request object

    Returns:
        The existing or newly created BillingContext
    """
    context = get_billing_context(request)
    if context is None:
        context = BillingContext()
        set_billing_context(request, context)
    return context
