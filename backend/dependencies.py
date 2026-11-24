import json
from dataclasses import dataclass
from email.message import Message
from typing import List, Optional

import firebase_admin
from firebase_admin import auth as firebase_auth
from fastapi import Depends, HTTPException, Request, Security
from fastapi.security import APIKeyHeader, HTTPAuthorizationCredentials, HTTPBearer

import database.developers as developers_db
from models.developer import MEMORION_APP_DEVELOPER_ID, Developer


# ******************************************************
# ************* DEVELOPER API AUTH *********************
# ******************************************************

developer_api_key_header = APIKeyHeader(name="Authorization", auto_error=False)
firebase_bearer = HTTPBearer(auto_error=False)

BOUND_KEY_FORBIDDEN_DETAIL = "This API key is not authorized for the requested external_user_id"
BOUND_KEY_SCOPE_DETAIL = (
    "This API key is bound to a single external_user_id and cannot access "
    "developer-scoped endpoints; pass external_user_id equal to the bound user"
)
APP_KEY_NO_KEY_MGMT_DETAIL = (
    "Keys issued under the Memorion App developer account cannot manage API keys"
)


async def _collect_request_external_user_ids(request: Request) -> List[str]:
    """
    Extract external_user_id values from the request inputs:
    query string, top-level JSON body field, or form field.

    Reading the body/form here is safe: Starlette caches request._body /
    request._form, so downstream endpoint parsing reuses the cached value.
    """
    found = request.query_params.getlist("external_user_id")
    content_type = request.headers.get("content-type")
    message = Message()
    if content_type:
        message["content-type"] = content_type

    if message.get_content_type() in ("multipart/form-data", "application/x-www-form-urlencoded"):
        form = await request.form()
        found.extend(str(value) for value in form.getlist("external_user_id"))
    elif not content_type or (
        message.get_content_maintype() == "application"
        and (message.get_content_subtype() == "json" or message.get_content_subtype().endswith("+json"))
    ):
        # Match FastAPI's JSON body selection, including an omitted Content-Type.
        try:
            data = await request.json()
        except (ValueError, UnicodeDecodeError):
            # FastAPI rejects malformed JSON on routes that consume a JSON body.
            data = None
        if isinstance(data, dict) and "external_user_id" in data:
            found.append(str(data["external_user_id"]))

    return found


async def enforce_api_key_user_binding(
    request: Request, bound_external_user_id: Optional[str]
) -> None:
    """
    Enforces a key's bound_external_user_id against the incoming request.

    No-op for unbound keys (bound_external_user_id is None) — all pre-existing
    keys keep full developer scope, behavior unchanged. For bound keys, every
    external_user_id the request references (query/body/form) must equal the
    bound value, and requests that reference none at all (developer-scoped
    endpoints like key management or user listing) are rejected.
    """
    if not bound_external_user_id:
        return

    found = await _collect_request_external_user_ids(request)

    if not found:
        raise HTTPException(status_code=403, detail=BOUND_KEY_SCOPE_DETAIL)

    for value in found:
        if value != bound_external_user_id:
            raise HTTPException(status_code=403, detail=BOUND_KEY_FORBIDDEN_DETAIL)


def _get_developer_key_auth(api_key: Optional[str]) -> dict:
    """Authenticate the raw developer API key shared by both route scopes."""
    if not api_key:
        raise HTTPException(
            status_code=401,
            detail="Missing Authorization header",
        )

    # Reject if Bearer prefix is used (this API uses raw keys)
    if api_key.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Invalid Authorization format. Use raw API key without Bearer prefix",
        )

    auth = developers_db.get_api_key_auth(api_key)
    if not auth:
        raise HTTPException(status_code=401, detail="Invalid API key")

    return auth


async def get_developer_id_from_api_key(
    request: Request,
    api_key: str = Security(developer_api_key_header),
) -> str:
    auth = _get_developer_key_auth(api_key)
    await enforce_api_key_user_binding(request, auth.get("bound_external_user_id"))
    return auth["developer_id"]


def get_developer_id_for_developer_scope(
    api_key: str = Security(developer_api_key_header),
) -> str:
    """Only developer-level credentials may enter tenant-wide routes."""
    auth = _get_developer_key_auth(api_key)
    if auth.get("bound_external_user_id") or auth["developer_id"] == MEMORION_APP_DEVELOPER_ID:
        raise HTTPException(status_code=403, detail="A developer-scope API key is required")
    return auth["developer_id"]


def require_developer_for_external_user(api_key: str, external_user_id: Optional[str]) -> str:
    """
    Validates an API key (query-param style auth used by listen/talk/transcribe
    endpoints) against the requested external_user_id, enforcing user-bound keys.

    Returns the developer_id, or raises HTTPException:
    401 invalid key, 403 bound key targeting a different external_user_id.
    """
    developer_id, error = developers_db.resolve_developer_id_for_external_user(
        api_key, external_user_id
    )
    if error == developers_db.KEY_AUTH_ERROR_FORBIDDEN:
        raise HTTPException(status_code=403, detail=BOUND_KEY_FORBIDDEN_DETAIL)
    if not developer_id:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return developer_id


async def get_developer(
    developer_id: str = Depends(get_developer_id_from_api_key),
) -> Developer:
    return _get_active_developer(developer_id)


def get_developer_for_developer_scope(
    developer_id: str = Depends(get_developer_id_for_developer_scope),
) -> Developer:
    return _get_active_developer(developer_id)


def _get_active_developer(developer_id: str) -> Developer:
    developer = developers_db.get_developer(developer_id)
    if not developer:
        raise HTTPException(status_code=401, detail="Developer not found")
    if not developer.is_active:
        raise HTTPException(status_code=403, detail="Developer account is inactive")
    return developer


async def get_developer_for_key_management(
    developer: Developer = Depends(get_developer),
    api_key: str = Security(developer_api_key_header),
) -> Developer:
    """
    Auth for the API-key management endpoints (/v1/keys*).

    Two restrictions on top of get_developer:

    1. Inactive developers are rejected — inherited from get_developer, which
       these endpoints previously bypassed by depending on
       get_developer_id_from_api_key directly (a deactivated developer could
       still list/create/revoke/rotate keys).

    2. Keys belonging to the official Memorion App developer account are
       rejected outright. That account's key is embedded in the shipped mobile
       app (obfuscated, therefore extractable), so anyone with a copy of the
       app could otherwise mint new keys for the account or revoke the key the
       whole user base authenticates with. The App never calls these endpoints,
       so this costs it nothing.

       Note this is a privilege-escalation fix, not the horizontal-access fix:
       the embedded key can still read/write any user's data by passing an
       arbitrary external_user_id. That requires per-user bound keys in the app.
    """
    if developer.id == MEMORION_APP_DEVELOPER_ID:
        raise HTTPException(status_code=403, detail=APP_KEY_NO_KEY_MGMT_DETAIL)
    get_developer_id_for_developer_scope(api_key)
    return developer


async def get_firebase_user_uid(
    credentials: Optional[HTTPAuthorizationCredentials] = Security(firebase_bearer),
) -> str:
    """
    Validates a Firebase ID token and returns the authenticated user UID.

    The Memorion app signs users into the user-facing Firebase project, which is
    initialized as the named "fcm" app in backend/main.py. Fall back to the
    default Firebase app if that named app is unavailable.
    """
    if credentials is None or not credentials.credentials:
        raise HTTPException(status_code=401, detail="Missing Bearer token")

    try:
        firebase_app = firebase_admin.get_app("fcm")
    except ValueError:
        firebase_app = firebase_admin.get_app()

    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials, app=firebase_app)
    except Exception as exc:
        # Server-side log captures the underlying reason (expired, wrong
        # project, signature invalid, missing kid, ...) — without this every
        # cause collapses into an opaque 401 and no one can tell what's
        # actually wrong. Client response stays generic to avoid leaking
        # backend Firebase project / key configuration to attackers probing
        # the endpoint.
        import logging
        logging.getLogger(__name__).warning(
            "[firebase-auth] verify_id_token failed: %s: %s "
            "(token_len=%d app=%s)",
            type(exc).__name__,
            exc,
            len(credentials.credentials),
            firebase_app.name,
        )
        raise HTTPException(status_code=401, detail="Invalid Firebase token") from exc

    uid = decoded.get("uid")
    if not uid:
        raise HTTPException(status_code=401, detail="Firebase token missing uid")
    return uid


# ******************************************************
# ********** API KEY METADATA FOR LOGGING **************
# ******************************************************


@dataclass
class ApiKeyMetadata:
    """Metadata about the authenticated API key."""

    api_key_id: str
    developer_id: str
    environment: str


async def get_api_key_metadata(
    request: Request,
    api_key: str = Security(developer_api_key_header),
) -> ApiKeyMetadata:
    """
    Validates a developer API key and returns full metadata.

    This dependency is useful when you need both the developer_id
    and api_key_id for logging purposes.

    Args:
        request: The FastAPI request object
        api_key: The API key from Authorization header

    Returns:
        ApiKeyMetadata with api_key_id, developer_id, and environment
    """
    from utils.developer_api_keys import parse_api_key, hash_api_key

    if not api_key:
        raise HTTPException(
            status_code=401,
            detail="Missing Authorization header",
        )

    if api_key.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Invalid Authorization format. Use raw API key without Bearer prefix",
        )

    # Parse the API key (for the environment component)
    parsed = parse_api_key(api_key)
    if not parsed:
        raise HTTPException(status_code=401, detail="Invalid API key format")

    prefix, environment, secret_part = parsed
    hashed_key = hash_api_key(secret_part)

    auth = developers_db.get_api_key_auth(api_key)
    if not auth:
        raise HTTPException(status_code=401, detail="Invalid API key")

    await enforce_api_key_user_binding(request, auth.get("bound_external_user_id"))

    developer_id = auth["developer_id"]
    api_key_id: Optional[str] = auth.get("api_key_id") or hashed_key[:12]

    # Store metadata in request state for middleware access
    if hasattr(request, "state"):
        from utils.logging.context import ensure_billing_context

        billing_context = ensure_billing_context(request)
        billing_context.api_key_id = api_key_id
        billing_context.developer_id = developer_id

    return ApiKeyMetadata(
        api_key_id=api_key_id or hashed_key[:12],
        developer_id=developer_id,
        environment=environment,
    )
