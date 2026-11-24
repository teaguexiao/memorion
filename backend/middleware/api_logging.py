"""
API Logging Middleware for Developer API.

This middleware captures all requests to the Developer API (/v1/*)
and logs them asynchronously for billing and analytics purposes.
"""

import logging
import time
import uuid
from datetime import datetime
from typing import Callable, Optional, Tuple

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp

from models.api_log import APILogEntry, ResourceType
from utils.logging.context import BillingContext, ensure_billing_context
from utils.logging.billing_extractor import (
    get_endpoint_group,
    get_default_resource_type,
    extract_external_user_id,
    extract_query_params_safe,
    calculate_cost_estimate,
    parse_error_detail,
)
from utils.logging.log_writer import get_log_writer

logger = logging.getLogger(__name__)


class APILoggingMiddleware(BaseHTTPMiddleware):
    """
    Middleware that logs all Developer API requests.

    Features:
    - Captures request metadata (method, path, query params, body size)
    - Captures response metadata (status code, response time, body size)
    - Extracts billing context set by route handlers
    - Writes logs asynchronously via LogBatchWriter
    """

    def __init__(self, app: ASGIApp, api_prefix: str = "/v1/"):
        """
        Initialize the middleware.

        Args:
            app: The ASGI application
            api_prefix: URL prefix for Developer API (default: /v1/)
        """
        super().__init__(app)
        self.api_prefix = api_prefix

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        """
        Process a request and log it.

        Args:
            request: The incoming request
            call_next: The next middleware/handler in the chain

        Returns:
            The response from the handler
        """
        # Sharing uses Firebase/share bearers, not developer API keys. Do not
        # feed these credentials or public requests into billing analytics.
        from middleware.share_privacy import is_share_path
        if is_share_path(request.url.path):
            return await call_next(request)

        # Skip non-Developer API requests
        if not request.url.path.startswith(self.api_prefix):
            return await call_next(request)

        # Skip WebSocket upgrade requests (handled separately)
        if request.headers.get("upgrade", "").lower() == "websocket":
            return await call_next(request)

        # Initialize request context
        request_id = str(uuid.uuid4())
        start_time = time.perf_counter()

        # Ensure billing context exists
        billing_context = ensure_billing_context(request)

        # Extract initial request metadata
        api_key_id, developer_id = await self._extract_api_key_metadata(request)
        external_user_id = extract_external_user_id(request)

        # Store in billing context for route handlers
        billing_context.api_key_id = api_key_id
        billing_context.developer_id = developer_id
        if external_user_id:
            billing_context.external_user_id = external_user_id

        # Get request body size (if available)
        request_body_size = 0
        content_length = request.headers.get("content-length")
        if content_length:
            try:
                request_body_size = int(content_length)
            except ValueError:
                pass

        # Process the request
        response = await call_next(request)

        # Calculate response time
        response_time_ms = int((time.perf_counter() - start_time) * 1000)

        # Get response body size
        response_body_size = 0
        response_content_length = response.headers.get("content-length")
        if response_content_length:
            try:
                response_body_size = int(response_content_length)
            except ValueError:
                pass

        # Extract endpoint group
        endpoint_group = get_endpoint_group(request.url.path)

        # Get billing info from context (may have been updated by route handler)
        billing_context = ensure_billing_context(request)

        # Determine resource type and billable units
        resource_type = billing_context.resource_type
        billable_units = billing_context.billable_units

        # Use defaults if not set by handler
        if resource_type is None:
            resource_type = get_default_resource_type(endpoint_group).value
            billable_units = 1.0  # Default to 1 request

        # Get external_user_id from context (may have been updated)
        if billing_context.external_user_id:
            external_user_id = billing_context.external_user_id

        # Calculate cost estimate
        cost_estimate = calculate_cost_estimate(resource_type, billable_units)

        # Extract error detail if applicable
        error_detail = None
        if response.status_code >= 400:
            # Note: We can't easily read the response body in middleware
            # Error detail can be set explicitly via billing_context.metadata
            error_detail = billing_context.metadata.get("error_detail")

        # Skip logging if we couldn't identify the developer
        if not developer_id:
            logger.warning(
                f"Skipping log for {request.method} {request.url.path}: "
                "Could not extract developer_id"
            )
            return response

        # Build log entry
        log_entry = APILogEntry(
            request_id=request_id,
            timestamp=datetime.utcnow(),
            method=request.method,
            endpoint=request.url.path,
            endpoint_group=endpoint_group.value,
            query_params=extract_query_params_safe(request),
            request_body_size=request_body_size,
            api_key_id=api_key_id or "unknown",
            developer_id=developer_id,
            external_user_id=external_user_id,
            status_code=response.status_code,
            response_time_ms=response_time_ms,
            response_body_size=response_body_size,
            error_detail=error_detail,
            resource_type=resource_type,
            billable_units=billable_units,
            cost_estimate=cost_estimate,
            client_ip=self._get_client_ip(request),
            user_agent=request.headers.get("user-agent"),
            region=None,  # Could be set based on deployment region
        )

        # Write log asynchronously
        log_writer = get_log_writer()
        if log_writer:
            try:
                # Use create_task to avoid blocking the response
                import asyncio
                asyncio.create_task(log_writer.add(log_entry))
            except Exception as e:
                logger.error(f"Failed to queue log entry: {e}")
        else:
            logger.warning("Log writer not initialized, skipping log")

        return response

    async def _extract_api_key_metadata(
        self, request: Request
    ) -> Tuple[Optional[str], Optional[str]]:
        """
        Extract API key ID and developer ID from the request.

        This checks the cache first, then queries the database if needed.

        Args:
            request: The incoming request

        Returns:
            Tuple of (api_key_id, developer_id)
        """
        auth_header = request.headers.get("Authorization")
        if not auth_header:
            return None, None

        # Skip Bearer prefix (Developer API uses raw keys)
        if auth_header.startswith("Bearer "):
            return None, None

        try:
            import database.developers as developers_db
            from utils.developer_api_keys import parse_api_key, hash_api_key
            import database.redis_db as redis_db

            # Parse the API key
            parsed = parse_api_key(auth_header)
            if not parsed:
                return None, None

            prefix, environment, secret_part = parsed
            hashed_key = hash_api_key(secret_part)

            # Check cache first
            developer_id = redis_db.get_cached_developer_api_key(hashed_key)
            if developer_id:
                # We have developer_id from cache, but need api_key_id
                # For now, use hash prefix as key identifier
                return hashed_key[:12], developer_id

            # Query database
            from database._client import db

            keys_ref = (
                db.collection("developer_api_keys")
                .where("hashed_key", "==", hashed_key)
                .where("is_active", "==", True)
                .limit(1)
            )
            docs = list(keys_ref.stream())

            if not docs:
                return None, None

            key_data = docs[0].to_dict()
            api_key_id = key_data.get("id")
            developer_id = key_data.get("developer_id")

            return api_key_id, developer_id

        except Exception as e:
            logger.error(f"Error extracting API key metadata: {e}")
            return None, None

    def _get_client_ip(self, request: Request) -> Optional[str]:
        """
        Extract the client IP address from the request.

        Handles common proxy headers.

        Args:
            request: The incoming request

        Returns:
            Client IP address or None
        """
        # Check common proxy headers
        forwarded_for = request.headers.get("X-Forwarded-For")
        if forwarded_for:
            # Take the first IP in the chain
            return forwarded_for.split(",")[0].strip()

        real_ip = request.headers.get("X-Real-IP")
        if real_ip:
            return real_ip

        # Fall back to direct client IP
        if request.client:
            return request.client.host

        return None
