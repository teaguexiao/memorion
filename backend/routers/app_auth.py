"""
Mobile App login token exchange (per-user bound API keys).

Why this exists: the shipped App authenticates every user with ONE developer
API key compiled into the binary. Obfuscation is not encryption, so that key
must be treated as public — and being unbound, it can read or write any user's
data by simply passing a different external_user_id. Phase 0 stopped it from
managing keys; this endpoint is Phase 1, giving each user their own key bound
to their own Firebase uid.

Flow:
    1. App signs the user in with Firebase (existing behavior, unchanged).
    2. App POSTs its Firebase ID token here.
    3. Backend mints a developer API key under the OFFICIAL Memorion App
       developer account with bound_external_user_id = the user's uid.
    4. App stores the key locally and uses it for every subsequent request.

Mirrors routers/cli_auth.py — same official-developer rationale, same binding
enforcement — with one behavioral difference: each exchange first revokes this
user's previous App keys. The CLI shows users their keys and lets them revoke
them; the App has no such UI, so without replace-on-login every reinstall would
leak an unrevocable key and eventually hit the per-user cap.
"""

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

import database.developers as developers_db
from models.developer import (
    MEMORION_APP_DEVELOPER_ID,
    ApiKeyCreate,
    ApiKeyEnvironment,
)
from routers.cli_auth import _verify_firebase_token

logger = logging.getLogger(__name__)

router = APIRouter()

_firebase_bearer = HTTPBearer(auto_error=False)

# Every App key carries this exact name. revoke_bound_api_keys_by_name matches
# on it, so it must stay stable across releases — changing it would orphan the
# keys issued by older builds.
APP_KEY_NAME = "Memorion App"

# Safety net only. Normal operation holds exactly one App key per user because
# each exchange revokes the previous ones; this bounds the damage if revocation
# starts failing (e.g. partial Firestore outage) instead of minting forever.
MAX_APP_KEYS_PER_USER = 10


class AppTokenResponse(BaseModel):
    api_key: str = Field(..., description="Plaintext developer API key. Shown only once.")
    external_user_id: str = Field(
        ..., description="Firebase uid; the key is bound to this and only this user"
    )


@router.post(
    "/v1/auth/app-token",
    response_model=AppTokenResponse,
    tags=["app-auth"],
)
async def exchange_app_token(
    credentials: Optional[HTTPAuthorizationCredentials] = Security(_firebase_bearer),
):
    """
    Exchange a Firebase ID token for a user-bound developer API key.

    Auth: `Authorization: Bearer <firebase_id_token>`.

    The returned key is issued under the official Memorion App developer
    account (where all App data lives) but bound to the caller's Firebase uid:
    any request made with it must carry external_user_id equal to that uid,
    otherwise it is rejected with 403. The plaintext key appears only in this
    response — the App must persist it.

    Calling this again for the same user revokes the keys previously issued to
    them by this endpoint, so the old key stops working immediately. Keys from
    other sources (CLI login) are untouched.
    """
    decoded = _verify_firebase_token(credentials)
    uid = decoded["uid"]

    developer = developers_db.get_developer(MEMORION_APP_DEVELOPER_ID)
    if not developer or not developer.is_active:
        logger.error(
            "[app-auth] official developer account %s missing or inactive",
            MEMORION_APP_DEVELOPER_ID,
        )
        raise HTTPException(status_code=503, detail="Login is temporarily unavailable")

    # Replace, don't accumulate. Deliberately before the cap check so a user
    # whose old keys are revocable can always log in again.
    try:
        revoked = developers_db.revoke_bound_api_keys_by_name(
            developer.id, uid, APP_KEY_NAME
        )
    except Exception:
        # A failed cleanup must not block login — the cap below is the backstop.
        logger.exception("[app-auth] failed to revoke previous App keys for uid %s", uid)
        revoked = 0

    active = developers_db.count_active_bound_api_keys(developer.id, uid)
    if active >= MAX_APP_KEYS_PER_USER:
        logger.error(
            "[app-auth] uid %s holds %d active bound keys, refusing to mint more",
            uid,
            active,
        )
        raise HTTPException(
            status_code=429,
            detail="Too many active API keys for this account. Contact support.",
        )

    raw_key, api_key = developers_db.create_api_key(
        developer.id,
        ApiKeyCreate(
            name=APP_KEY_NAME,
            environment=ApiKeyEnvironment.PROD,
            bound_external_user_id=uid,
        ),
    )
    logger.info(
        "[app-auth] issued bound App key for uid %s (key_id=%s, revoked_previous=%d)",
        uid,
        api_key.id,
        revoked,
    )

    return AppTokenResponse(api_key=raw_key, external_user_id=uid)
