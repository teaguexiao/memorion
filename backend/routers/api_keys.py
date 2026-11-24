from typing import List

from fastapi import APIRouter, Depends, HTTPException

import database.developers as developers_db
from dependencies import get_developer, get_developer_for_key_management
from models.developer import (
    ApiKey,
    ApiKeyCreate,
    ApiKeyCreated,
    Developer,
)

router = APIRouter()


# Key management is gated by get_developer_for_key_management, which rejects
# inactive developers and the official Memorion App account (whose key ships
# inside the mobile app). See that dependency for the full rationale.


@router.get("/v1/keys", response_model=List[ApiKey], tags=["developer-api"])
async def list_api_keys(
    developer: Developer = Depends(get_developer_for_key_management),
):
    """
    List all API keys for the authenticated developer.

    Returns a list of API keys with metadata (id, name, prefix, environment, etc.).
    The actual key values are not returned for security reasons.
    """
    return developers_db.get_api_keys_for_developer(developer.id)


@router.post("/v1/keys", response_model=ApiKeyCreated, tags=["developer-api"])
async def create_api_key(
    key_data: ApiKeyCreate,
    developer: Developer = Depends(get_developer_for_key_management),
):
    """
    Create a new API key for the authenticated developer.

    The raw API key is returned in the response and will only be shown once.
    Store it securely as it cannot be retrieved again.

    Request body:
    - name: A friendly name for the key (required)
    - environment: "dev" or "prod" (defaults to "dev")
    """
    if not key_data.name or len(key_data.name.strip()) == 0:
        raise HTTPException(status_code=422, detail="Key name cannot be empty")

    raw_key, api_key = developers_db.create_api_key(
        developer.id,
        ApiKeyCreate(name=key_data.name.strip(), environment=key_data.environment)
    )

    return ApiKeyCreated(**api_key.model_dump(), key=raw_key)


@router.get("/v1/keys/{key_id}", response_model=ApiKey, tags=["developer-api"])
async def get_api_key(
    key_id: str,
    developer: Developer = Depends(get_developer_for_key_management),
):
    """
    Get details of a specific API key.

    The actual key value is not returned for security reasons.
    Only the key prefix (e.g., memorion_dev_prod_abc1...xyz9) is shown.
    """
    api_key = developers_db.get_api_key(developer.id, key_id)
    if not api_key:
        raise HTTPException(status_code=404, detail="API key not found")
    return api_key


@router.delete("/v1/keys/{key_id}", status_code=204, tags=["developer-api"])
async def revoke_api_key(
    key_id: str,
    developer: Developer = Depends(get_developer_for_key_management),
):
    """
    Revoke (delete) an API key.

    This action is irreversible. Once revoked, the key can no longer be used
    for authentication.
    """
    success = developers_db.revoke_api_key(developer.id, key_id)
    if not success:
        raise HTTPException(status_code=404, detail="API key not found")
    return


@router.post("/v1/keys/{key_id}/rotate", response_model=ApiKeyCreated, tags=["developer-api"])
async def rotate_api_key(
    key_id: str,
    developer: Developer = Depends(get_developer_for_key_management),
):
    """
    Rotate an API key.

    This creates a new key with the same name and environment, and immediately
    invalidates the old key. The new raw key is returned and will only be shown once.

    Use this to periodically refresh keys or if a key may have been compromised.
    """
    result = developers_db.rotate_api_key(developer.id, key_id)
    if not result:
        raise HTTPException(status_code=404, detail="API key not found")

    new_raw_key, new_api_key, old_key_id = result
    return ApiKeyCreated(**new_api_key.model_dump(), key=new_raw_key)


# ******************************************************
# ************* DEVELOPER PROFILE **********************
# ******************************************************


@router.get("/v1/developers/me", response_model=Developer, tags=["developer-api"])
async def get_current_developer(
    developer: Developer = Depends(get_developer),
):
    """
    Get the authenticated developer's profile.

    Returns the developer's account information including:
    - id: Unique developer ID
    - email: Developer's email address
    - name: Developer's name
    - company_name: Developer's company
    - tier: Subscription tier (free, starter, pro, enterprise)
    - is_active: Account status
    - credits_balance: Available API credits
    """
    return developer
