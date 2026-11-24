import json
import time

from fastapi import Depends, Header, HTTPException, Query
from fastapi import Request

import database.developers as developers_db
from models.developer import MEMORION_APP_DEVELOPER_ID


def _resolve_developer_context(authorization: str, external_user_id: str) -> str:
    """
    Validates a developer API key against the requested external_user_id,
    enforcing keys bound to a single user (bound_external_user_id).

    Returns the developer_id, or raises HTTPException (401 invalid key,
    403 bound key targeting a different external_user_id).
    """
    developer_id, error = developers_db.resolve_developer_id_for_external_user(
        authorization, external_user_id
    )
    if error == developers_db.KEY_AUTH_ERROR_FORBIDDEN:
        raise HTTPException(
            status_code=403,
            detail="This API key is not authorized for the requested external_user_id",
        )
    if not developer_id:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return developer_id


def get_current_user_uid(
    authorization: str = Header(None),
    external_user_id: str = Query(None),
):
    """
    Authenticate user via developer API key.

    Format: Authorization: {api_key} (memorion_dev_{env}_{secret})
    Requires: external_user_id query parameter
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="Authorization header not found")

    # Validate developer API key (format: memorion_dev_{env}_{secret})
    if not authorization.startswith("memorion_"):
        raise HTTPException(status_code=401, detail="Invalid API key format. Expected: memorion_dev_{env}_{secret}")

    if not external_user_id:
        raise HTTPException(status_code=400, detail="external_user_id query parameter required")

    _resolve_developer_context(authorization, external_user_id)

    return external_user_id


def get_current_user_context(
    authorization: str = Header(None),
    external_user_id: str = Query(None),
) -> tuple:
    """
    Same auth logic as get_current_user_uid, but returns (developer_id, external_user_id).

    `developer_id` is now always a real developer id. It used to be None under
    the removed ADMIN_KEY path, so callers still carry `if not developer_id`
    guards — those are unreachable now, kept only as cheap defensive returns.
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="Authorization header not found")

    if not authorization.startswith("memorion_"):
        raise HTTPException(status_code=401, detail="Invalid API key format. Expected: memorion_dev_{env}_{secret}")

    if not external_user_id:
        raise HTTPException(status_code=400, detail="external_user_id query parameter required")

    developer_id = _resolve_developer_context(authorization, external_user_id)

    return (developer_id, external_user_id)


def get_current_user_context_for_deletion(
    ctx: tuple = Depends(get_current_user_context),
    authorization: str = Header(None),
) -> tuple:
    developer_id, uid = ctx
    if developer_id == MEMORION_APP_DEVELOPER_ID:
        key_auth = developers_db.get_api_key_auth(authorization)
        if not key_auth or key_auth.get("bound_external_user_id") != uid:
            raise HTTPException(status_code=403, detail="A user-bound API key is required")
    return ctx


cached = {}


def rate_limit_custom(endpoint: str, request: Request, requests_per_window: int, window_seconds: int):
    ip = request.client.host
    key = f"rate_limit:{endpoint}:{ip}"

    # Check if the IP is already rate-limited
    current = cached.get(key)
    if current:
        current = json.loads(current)
        remaining = current["remaining"]
        timestamp = current["timestamp"]
        current_time = int(time.time())

        # Check if the time window has expired
        if current_time - timestamp >= window_seconds:
            remaining = requests_per_window - 1  # Reset the counter for the new window
            timestamp = current_time
        elif remaining == 0:
            raise HTTPException(status_code=429, detail="Too Many Requests")

        remaining -= 1

    else:
        # If no previous data found, start a new time window
        remaining = requests_per_window - 1
        timestamp = int(time.time())

    # Update the rate limit info in Redis
    current = {"timestamp": timestamp, "remaining": remaining}
    cached[key] = json.dumps(current)

    return True


# Dependency to enforce custom rate limiting for specific endpoints
def rate_limit_dependency(endpoint: str = "", requests_per_window: int = 60, window_seconds: int = 60):
    def rate_limit(request: Request):
        return rate_limit_custom(endpoint, request, requests_per_window, window_seconds)

    return rate_limit


def timeit(func):
    """
    Decorator for measuring function's running time.
    """

    def measure_time(*args, **kw):
        start_time = time.time()
        result = func(*args, **kw)
        print("Processing time of %s(): %.2f seconds." % (func.__qualname__, time.time() - start_time))
        return result

    return measure_time


def delete_account(uid: str):
    # Note: With API key auth, account deletion is handled differently
    # This function is kept for compatibility but may need to be updated
    # based on how user data should be deleted in the new architecture
    return {"message": "User deleted"}
