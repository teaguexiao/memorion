"""
Billing metrics extraction utilities.

This module provides functions to extract billing-related information
from API requests and responses.
"""

import re
from typing import Any, Dict, Optional, Tuple

from starlette.requests import Request

from models.api_log import EndpointGroup, ResourceType


# Endpoint path to group mapping (exact matches)
ENDPOINT_GROUP_EXACT_MAP: Dict[str, EndpointGroup] = {
    "/v1/keys": EndpointGroup.KEYS,
    "/v1/profile": EndpointGroup.USAGE,
}

# Endpoint path prefix to group mapping
ENDPOINT_GROUP_PREFIX_MAP: Dict[str, EndpointGroup] = {
    "/v1/memories": EndpointGroup.MEMORIES,
    "/v1/conversations": EndpointGroup.CONVERSATIONS,
    "/v1/people": EndpointGroup.PEOPLE,
    "/v1/facts": EndpointGroup.FACTS,
    "/v1/chat": EndpointGroup.CHAT,
    "/v1/listen": EndpointGroup.LISTEN,
    "/v1/transcribe": EndpointGroup.TRANSCRIBE,
    "/v1/images": EndpointGroup.IMAGES,
    "/v1/speech-profile": EndpointGroup.SPEECH_PROFILE,
    "/v1/daily-summary": EndpointGroup.DAILY_SUMMARY,
    "/v1/usage": EndpointGroup.USAGE,
    "/v1/keys": EndpointGroup.KEYS,
    "/v1/webhooks": EndpointGroup.WEBHOOKS,
}

# Default resource types for endpoint groups
DEFAULT_RESOURCE_TYPES: Dict[EndpointGroup, ResourceType] = {
    EndpointGroup.LISTEN: ResourceType.STT_REALTIME_MINUTES,
    EndpointGroup.TRANSCRIBE: ResourceType.STT_BATCH_MINUTES,
    EndpointGroup.CHAT: ResourceType.LLM_STANDARD_TOKENS,
    EndpointGroup.IMAGES: ResourceType.STORAGE_BYTES,
}


def get_endpoint_group(path: str) -> EndpointGroup:
    """
    Determine the endpoint group from a request path.

    This function supports:
    1. Exact match lookup
    2. Prefix-based matching
    3. Dynamic extraction from path structure
    4. Default fallback to OTHER

    Args:
        path: The request URL path (e.g., "/v1/memories/123")

    Returns:
        The EndpointGroup for the path
    """
    # Normalize path
    path = path.rstrip("/")

    # 1. Check exact match
    if path in ENDPOINT_GROUP_EXACT_MAP:
        return ENDPOINT_GROUP_EXACT_MAP[path]

    # 2. Check prefix match
    for prefix, group in ENDPOINT_GROUP_PREFIX_MAP.items():
        if path.startswith(prefix):
            return group

    # 3. Try to extract from path structure
    # Pattern: /v1/{resource}/...
    match = re.match(r"^/v1/([a-z][a-z0-9_-]*)", path)
    if match:
        resource = match.group(1).replace("-", "_")
        try:
            return EndpointGroup(resource)
        except ValueError:
            pass

    # 4. Default fallback
    return EndpointGroup.OTHER


def get_default_resource_type(endpoint_group: EndpointGroup) -> ResourceType:
    """
    Get the default resource type for an endpoint group.

    Args:
        endpoint_group: The endpoint group

    Returns:
        The default ResourceType for billing
    """
    return DEFAULT_RESOURCE_TYPES.get(endpoint_group, ResourceType.API_REQUESTS)


def extract_external_user_id(request: Request) -> Optional[str]:
    """
    Extract the external_user_id from various sources in a request.

    Priority:
    1. Query parameter: external_user_id
    2. Path parameter: user_id or external_user_id
    3. Request body (for POST/PUT): external_user_id

    Args:
        request: The Starlette/FastAPI request object

    Returns:
        The external_user_id if found, None otherwise
    """
    # 1. Check query params
    external_user_id = request.query_params.get("external_user_id")
    if external_user_id:
        return external_user_id

    # 2. Check path params (from route matching)
    path_params = getattr(request, "path_params", {})
    for param_name in ["external_user_id", "user_id"]:
        if param_name in path_params:
            return path_params[param_name]

    # 3. Body parsing is handled separately in middleware
    # to avoid consuming the request body stream

    return None


def extract_query_params_safe(request: Request) -> Dict[str, Any]:
    """
    Extract query parameters, sanitizing sensitive values.

    Args:
        request: The Starlette/FastAPI request object

    Returns:
        Dictionary of sanitized query parameters
    """
    # List of parameter names that should be masked
    sensitive_params = {"password", "token", "secret", "key", "api_key", "authorization"}

    params = {}
    for key, value in request.query_params.items():
        if key.lower() in sensitive_params:
            params[key] = "[REDACTED]"
        else:
            params[key] = value

    return params


def calculate_cost_estimate(resource_type: str, billable_units: float) -> float:
    """
    Calculate estimated cost based on resource type and units.

    These are placeholder prices that should be configured based on
    actual pricing tiers.

    Args:
        resource_type: The resource type
        billable_units: Number of billable units

    Returns:
        Estimated cost in USD
    """
    # Pricing table (USD per unit)
    # These should be moved to configuration
    PRICING = {
        ResourceType.STT_REALTIME_MINUTES.value: 0.006,  # $0.006/minute
        ResourceType.STT_BATCH_MINUTES.value: 0.004,  # $0.004/minute
        ResourceType.LLM_MINI_TOKENS.value: 0.0001,  # $0.0001/1K tokens
        ResourceType.LLM_STANDARD_TOKENS.value: 0.001,  # $0.001/1K tokens
        ResourceType.LLM_PRO_TOKENS.value: 0.01,  # $0.01/1K tokens
        ResourceType.VLM_REQUESTS.value: 0.002,  # $0.002/request
        ResourceType.STORAGE_BYTES.value: 0.0001,  # $0.0001/MB
        ResourceType.SPEAKER_ID_REQUESTS.value: 0.001,  # $0.001/request
        ResourceType.API_REQUESTS.value: 0.0,  # Free for basic requests
    }

    unit_price = PRICING.get(resource_type, 0.0)
    return round(billable_units * unit_price, 6)


def parse_error_detail(response_body: bytes, status_code: int) -> Optional[str]:
    """
    Extract error detail from response body for error responses.

    Args:
        response_body: The response body bytes
        status_code: The HTTP status code

    Returns:
        Error detail string if available, None otherwise
    """
    if status_code < 400:
        return None

    try:
        import json

        body = json.loads(response_body.decode("utf-8"))

        # Try common error response formats
        if isinstance(body, dict):
            return body.get("detail") or body.get("message") or body.get("error")
    except Exception:
        pass

    return None
