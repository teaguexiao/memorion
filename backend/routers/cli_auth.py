"""
CLI browser-login token exchange.

Flow:
    1. User runs `memorion login`; the CLI opens the portal web page.
    2. User signs in with Firebase (Google) in the browser.
    3. The portal calls POST /v1/auth/cli-token with the Firebase ID token.
    4. Backend mints a developer API key under the OFFICIAL Memorion App
       developer account, bound to the user's Firebase uid
       (bound_external_user_id = uid).
    5. The plaintext key is returned exactly once and handed back to the CLI.

Why the official developer: all Memorion App user data lives under
developer_data/{MEMORION_APP_DEVELOPER_ID}/users/{firebase_uid}/..., so a key
issued under any other developer account would see no data. The key is bound
to the user's own uid, and every developer-key auth path enforces the binding
(403 on any other external_user_id), so handing these keys to end users does
not grant horizontal access to other users' data.
"""

import logging
from typing import Optional

import firebase_admin
from firebase_admin import auth as firebase_auth
from fastapi import APIRouter, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

import database.developers as developers_db
from models.developer import (
    MEMORION_APP_DEVELOPER_ID,
    ApiKeyCreate,
    ApiKeyEnvironment,
)

logger = logging.getLogger(__name__)

router = APIRouter()

_firebase_bearer = HTTPBearer(auto_error=False)

# Hard cap on active CLI keys bound to a single user. Prevents scripts from
# minting unlimited keys via repeated `memorion login`.
MAX_CLI_KEYS_PER_USER = 20

DEFAULT_DEVICE_NAME = "Memorion CLI"


# ******************************************************
# ******************** SCHEMAS *************************
# ******************************************************


class CliTokenRequest(BaseModel):
    device_name: Optional[str] = Field(
        default=None,
        max_length=100,
        description="Friendly name for the created API key, e.g. 'CLI (my-macbook)'",
    )


class CliTokenResponse(BaseModel):
    api_key: str = Field(..., description="Plaintext developer API key. Shown only once.")
    external_user_id: str = Field(..., description="Firebase uid; use as external_user_id on Developer API calls")
    developer_id: str
    email: str


# ******************************************************
# ******************* FIREBASE AUTH ********************
# ******************************************************


def _verify_firebase_token(
    credentials: Optional[HTTPAuthorizationCredentials],
) -> dict:
    """
    Validates a Firebase ID token and returns the decoded claims.

    Mirrors dependencies.get_firebase_user_uid (user-facing Firebase project is
    the named "fcm" app), but returns the full decoded token because this
    endpoint also needs the email claim.
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
        logger.warning(
            "[cli-auth] verify_id_token failed: %s: %s (token_len=%d app=%s)",
            type(exc).__name__,
            exc,
            len(credentials.credentials),
            firebase_app.name,
        )
        raise HTTPException(status_code=401, detail="Invalid Firebase token") from exc

    if not decoded.get("uid"):
        raise HTTPException(status_code=401, detail="Firebase token missing uid")
    return decoded


# ******************************************************
# ******************** ENDPOINT ************************
# ******************************************************


@router.post(
    "/v1/auth/cli-token",
    response_model=CliTokenResponse,
    tags=["cli-auth"],
)
async def exchange_cli_token(
    body: Optional[CliTokenRequest] = None,
    credentials: Optional[HTTPAuthorizationCredentials] = Security(_firebase_bearer),
):
    """
    Exchange a Firebase ID token for a user-bound developer API key.

    Auth: `Authorization: Bearer <firebase_id_token>`.

    Semantics: "the user accessing his own data". The key is issued under the
    official Memorion App developer account (where all App data lives) but is
    bound to the user's Firebase uid: any Developer API request made with it
    must use external_user_id equal to that uid, otherwise it is rejected
    with 403.

    The plaintext key appears only in this response and cannot be retrieved
    again. Returns 429 once the user holds too many active CLI keys (revoke
    old ones first).
    """
    decoded = _verify_firebase_token(credentials)
    uid = decoded["uid"]
    email = decoded.get("email") or f"{uid}@users.memorion.me"

    developer = developers_db.get_developer(MEMORION_APP_DEVELOPER_ID)
    if not developer or not developer.is_active:
        logger.error(
            "[cli-auth] official developer account %s missing or inactive",
            MEMORION_APP_DEVELOPER_ID,
        )
        raise HTTPException(status_code=503, detail="CLI login is temporarily unavailable")

    # Cap active keys bound to this uid (NOT total keys of the shared
    # official developer account).
    bound_key_count = developers_db.count_active_bound_api_keys(developer.id, uid)
    if bound_key_count >= MAX_CLI_KEYS_PER_USER:
        raise HTTPException(
            status_code=429,
            detail=(
                f"API key limit reached ({MAX_CLI_KEYS_PER_USER}). "
                "Revoke unused CLI keys, then retry."
            ),
        )

    device_name = (body.device_name.strip() if body and body.device_name else "") or DEFAULT_DEVICE_NAME
    raw_key, api_key = developers_db.create_api_key(
        developer.id,
        ApiKeyCreate(
            name=device_name[:100],
            environment=ApiKeyEnvironment.PROD,
            bound_external_user_id=uid,
        ),
    )
    logger.info(
        "[cli-auth] issued bound CLI key for uid %s (key_id=%s, active_bound=%d)",
        uid,
        api_key.id,
        bound_key_count + 1,
    )

    return CliTokenResponse(
        api_key=raw_key,
        external_user_id=uid,
        developer_id=developer.id,
        email=email,
    )
