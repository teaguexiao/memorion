import uuid
from datetime import datetime
from typing import List, Optional, Tuple

from google.cloud import firestore

import database.redis_db as redis_db
from database._client import db
from models.developer import (
    Developer,
    DeveloperTier,
    ApiKey,
    ApiKeyDB,
    ApiKeyEnvironment,
    ApiKeyCreate,
)
from utils.developer_api_keys import generate_developer_api_key, hash_api_key, parse_api_key


# ******************************************************
# ****************** DEVELOPERS ************************
# ******************************************************


def create_developer(
    email: str,
    name: Optional[str] = None,
    company_name: Optional[str] = None,
    tier: DeveloperTier = DeveloperTier.FREE,
) -> Developer:
    """
    Creates a new developer account.

    Args:
        email: Developer's email address
        name: Developer's name
        company_name: Developer's company name
        tier: Developer tier (FREE, STARTER, PRO, ENTERPRISE)

    Returns:
        The created Developer object
    """
    developer_id = str(uuid.uuid4())
    now = datetime.utcnow()

    developer_data = {
        "id": developer_id,
        "email": email,
        "name": name,
        "company_name": company_name,
        "tier": tier.value,
        "is_active": True,
        "credits_balance": 0.0,
        "created_at": now,
        "updated_at": None,
    }

    db.collection("developer_data").document(developer_id).set(developer_data)

    return Developer(**developer_data)


def get_developer(developer_id: str) -> Optional[Developer]:
    """
    Retrieves a developer by ID.

    Args:
        developer_id: The developer's unique ID

    Returns:
        Developer object or None if not found
    """
    if not developer_id:
        return None

    doc_ref = db.collection("developer_data").document(developer_id)
    doc = doc_ref.get()

    if not doc.exists:
        return None

    data = doc.to_dict()
    return Developer(**data)


def get_developer_by_email(email: str) -> Optional[Developer]:
    """
    Retrieves a developer by email address.

    Args:
        email: The developer's email address

    Returns:
        Developer object or None if not found
    """
    docs = (
        db.collection("developer_data")
        .where("email", "==", email)
        .limit(1)
        .stream()
    )

    for doc in docs:
        data = doc.to_dict()
        return Developer(**data)

    return None


def update_developer(developer_id: str, **kwargs) -> Optional[Developer]:
    """
    Updates a developer's information.

    Args:
        developer_id: The developer's unique ID
        **kwargs: Fields to update

    Returns:
        Updated Developer object or None if not found
    """
    doc_ref = db.collection("developer_data").document(developer_id)
    doc = doc_ref.get()

    if not doc.exists:
        return None

    kwargs["updated_at"] = datetime.utcnow()
    doc_ref.update(kwargs)

    return get_developer(developer_id)


# ******************************************************
# ******************* API KEYS *************************
# ******************************************************


def create_api_key(
    developer_id: str, key_data: ApiKeyCreate
) -> Tuple[str, ApiKey]:
    """
    Creates a new API key for a developer.

    Args:
        developer_id: The developer's unique ID
        key_data: Key creation data (name, environment)

    Returns:
        Tuple of (raw_key, ApiKey) - raw_key is shown only once
    """
    raw_key, hashed_key, key_prefix = generate_developer_api_key(key_data.environment)
    key_id = str(uuid.uuid4())
    now = datetime.utcnow()

    api_key_doc = {
        "id": key_id,
        "developer_id": developer_id,
        "name": key_data.name,
        "hashed_key": hashed_key,
        "key_prefix": key_prefix,
        "environment": key_data.environment.value,
        "is_active": True,
        "created_at": now,
        "last_used_at": None,
        # None => full developer scope (legacy behavior, all pre-existing keys).
        "bound_external_user_id": key_data.bound_external_user_id,
        # Explicit cross-user opt-in for platform jobs; see models/developer.py.
        "allow_any_user": key_data.allow_any_user,
    }

    # Store under developer_data/{developer_id}/api_keys/{key_id}
    db.collection("developer_data").document(developer_id).collection(
        "api_keys"
    ).document(key_id).set(api_key_doc)

    # Also store in global collection for lookup by hashed key
    db.collection("developer_api_keys").document(key_id).set(api_key_doc)

    api_key = ApiKey(
        id=key_id,
        name=key_data.name,
        key_prefix=key_prefix,
        environment=key_data.environment,
        is_active=True,
        created_at=now,
        last_used_at=None,
        bound_external_user_id=key_data.bound_external_user_id,
        allow_any_user=key_data.allow_any_user,
    )

    return raw_key, api_key


def get_api_keys_for_developer(developer_id: str) -> List[ApiKey]:
    """
    Retrieves all API keys for a developer.

    Args:
        developer_id: The developer's unique ID

    Returns:
        List of ApiKey objects (without hashed_key)
    """
    keys_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_keys")
        .order_by("created_at", direction=firestore.Query.DESCENDING)
    )

    docs = keys_ref.stream()
    keys = []
    for doc in docs:
        data = doc.to_dict()
        keys.append(
            ApiKey(
                id=data["id"],
                name=data["name"],
                key_prefix=data["key_prefix"],
                environment=ApiKeyEnvironment(data["environment"]),
                is_active=data.get("is_active", True),
                created_at=data["created_at"],
                last_used_at=data.get("last_used_at"),
                bound_external_user_id=data.get("bound_external_user_id"),
                allow_any_user=bool(data.get("allow_any_user")),
            )
        )
    return keys


def count_active_bound_api_keys(developer_id: str, external_user_id: str) -> int:
    """
    Counts active API keys under a developer that are bound to a specific
    external_user_id (used to cap per-user CLI keys, not per-developer keys).
    """
    keys_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_keys")
        .where("bound_external_user_id", "==", external_user_id)
        .where("is_active", "==", True)
    )
    return sum(1 for _ in keys_ref.stream())


def revoke_bound_api_keys_by_name(
    developer_id: str, external_user_id: str, name: str
) -> int:
    """
    Revokes every active key under `developer_id` that is bound to
    `external_user_id` AND carries exactly `name`.

    Used by the App login token exchange: each device re-login mints a fresh
    key, and without this the per-user key cap would be exhausted by
    reinstalls (each one leaks a key nobody can ever revoke, since end users
    have no key-management UI). Scoping by name means CLI keys and any other
    key kind bound to the same uid are left alone.

    Returns the number of keys revoked.
    """
    keys_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_keys")
        .where("bound_external_user_id", "==", external_user_id)
        .where("is_active", "==", True)
        .where("name", "==", name)
    )

    revoked = 0
    for doc in list(keys_ref.stream()):
        # Use the doc id, not data["id"]: a doc missing the mirrored `id`
        # field would raise and abort the whole loop, leaving the user's
        # other keys active and walking them into the per-user cap.
        try:
            if revoke_api_key(developer_id, doc.id):
                revoked += 1
        except Exception:
            print(f"revoke_bound_api_keys_by_name: failed to revoke {doc.id}")
    return revoked


def get_api_key(developer_id: str, key_id: str) -> Optional[ApiKey]:
    """
    Retrieves a specific API key.

    Args:
        developer_id: The developer's unique ID
        key_id: The key's unique ID

    Returns:
        ApiKey object or None if not found
    """
    doc_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_keys")
        .document(key_id)
    )
    doc = doc_ref.get()

    if not doc.exists:
        return None

    data = doc.to_dict()

    # Verify ownership
    if data.get("developer_id") != developer_id:
        return None

    return ApiKey(
        id=data["id"],
        name=data["name"],
        key_prefix=data["key_prefix"],
        environment=ApiKeyEnvironment(data["environment"]),
        is_active=data.get("is_active", True),
        created_at=data["created_at"],
        last_used_at=data.get("last_used_at"),
        bound_external_user_id=data.get("bound_external_user_id"),
        allow_any_user=bool(data.get("allow_any_user")),
    )


def revoke_api_key(developer_id: str, key_id: str) -> bool:
    """
    Revokes (deletes) an API key.

    Args:
        developer_id: The developer's unique ID
        key_id: The key's unique ID

    Returns:
        True if key was revoked, False if not found
    """
    # Get the key first to get the hashed key for cache invalidation
    key_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_keys")
        .document(key_id)
    )
    key_doc = key_ref.get()

    if not key_doc.exists:
        return False

    key_data = key_doc.to_dict()

    # Verify ownership
    if key_data.get("developer_id") != developer_id:
        return False

    hashed_key = key_data.get("hashed_key")

    # Delete from cache
    if hashed_key:
        redis_db.delete_cached_developer_api_key(hashed_key)

    # Delete from developer's subcollection
    key_ref.delete()

    # Delete from global collection
    db.collection("developer_api_keys").document(key_id).delete()

    return True


def rotate_api_key(
    developer_id: str, key_id: str
) -> Optional[Tuple[str, ApiKey, str]]:
    """
    Rotates an API key (creates new key, invalidates old).

    Args:
        developer_id: The developer's unique ID
        key_id: The key's unique ID to rotate

    Returns:
        Tuple of (new_raw_key, new_ApiKey, old_key_id) or None if not found
    """
    # Get the existing key
    key_ref = (
        db.collection("developer_data")
        .document(developer_id)
        .collection("api_keys")
        .document(key_id)
    )
    key_doc = key_ref.get()

    if not key_doc.exists:
        return None

    key_data = key_doc.to_dict()

    # Verify ownership
    if key_data.get("developer_id") != developer_id:
        return None

    old_hashed_key = key_data.get("hashed_key")
    old_key_id = key_id

    # Create new key with same name, environment and user binding.
    #
    # ⚠️ `allow_any_user` must be carried over too. Dropping it here would
    # silently demote the platform cron key to an ordinary unbound key on
    # rotation, and once §9.5 阶段 3 rejects unbound keys the daily summary /
    # daily quote / insights crons would start 403-ing with nothing in the diff
    # to explain why.
    key_create = ApiKeyCreate(
        name=key_data["name"],
        environment=ApiKeyEnvironment(key_data["environment"]),
        bound_external_user_id=key_data.get("bound_external_user_id"),
        allow_any_user=bool(key_data.get("allow_any_user")),
    )
    new_raw_key, new_api_key = create_api_key(developer_id, key_create)

    # Invalidate old key cache
    if old_hashed_key:
        redis_db.delete_cached_developer_api_key(old_hashed_key)

    # Delete old key from developer's subcollection
    key_ref.delete()

    # Delete old key from global collection
    db.collection("developer_api_keys").document(old_key_id).delete()

    return new_raw_key, new_api_key, old_key_id


# Error codes returned by resolve_developer_id_for_external_user.
KEY_AUTH_ERROR_INVALID = "invalid_key"
KEY_AUTH_ERROR_FORBIDDEN = "external_user_id_forbidden"


def get_api_key_auth(api_key: str) -> Optional[dict]:
    """
    Verifies an API key and returns its full auth info:
        {"developer_id": str, "bound_external_user_id": Optional[str], "api_key_id": str}

    Returns None if the key is invalid or inactive.

    IMPORTANT: binding decisions are only made from the new-format redis cache
    (developer_api_key_auth:) or from Firestore. The legacy plain-string cache
    (developer_api_key:) is intentionally NOT consulted here because it lacks
    binding info — trusting it could let a bound key be treated as unbound.
    """
    parsed = parse_api_key(api_key)
    if not parsed:
        return None

    _prefix, _environment, secret_part = parsed
    hashed_key = hash_api_key(secret_part)

    # Check the new-format cache first.
    cached = redis_db.get_cached_developer_api_key_auth(hashed_key)
    if cached:
        return cached

    # Cache miss: query database
    keys_ref = (
        db.collection("developer_api_keys")
        .where("hashed_key", "==", hashed_key)
        .where("is_active", "==", True)
        .limit(1)
    )
    docs = list(keys_ref.stream())

    if not docs:
        return None

    key_doc = docs[0]
    key_data = key_doc.to_dict()
    developer_id = key_data.get("developer_id")

    if not developer_id:
        return None

    auth = {
        "developer_id": developer_id,
        "bound_external_user_id": key_data.get("bound_external_user_id"),
        "api_key_id": key_data.get("id"),
        # Platform-job escape hatch for §9.5 阶段 3. Must ride along in the
        # cached dict, not be re-read from Firestore at enforcement time —
        # otherwise every cron request pays an extra read and the flag can
        # disagree with the developer_id it was cached alongside.
        "allow_any_user": bool(key_data.get("allow_any_user")),
    }

    # Cache the key (writes both the new-format entry and, for backward
    # compatibility with older instances / logging middleware, the legacy one).
    redis_db.cache_developer_api_key_auth(hashed_key, auth)

    # Update last_used_at
    now = datetime.utcnow()
    key_doc.reference.update({"last_used_at": now})

    # Also update in developer's subcollection
    db.collection("developer_data").document(developer_id).collection(
        "api_keys"
    ).document(key_data["id"]).update({"last_used_at": now})

    return auth


def get_developer_id_by_api_key(api_key: str) -> Optional[str]:
    """
    Verifies an API key and returns the associated developer ID.
    Uses cache for performance.

    NOTE: this performs NO user-binding enforcement. Callers that act on an
    external_user_id must use resolve_developer_id_for_external_user (or the
    FastAPI dependencies in dependencies.py / utils/other/endpoints.py).

    Args:
        api_key: The raw API key

    Returns:
        Developer ID or None if invalid
    """
    auth = get_api_key_auth(api_key)
    return auth.get("developer_id") if auth else None


def resolve_developer_id_for_external_user(
    api_key: str, external_user_id: Optional[str]
) -> Tuple[Optional[str], Optional[str]]:
    """
    Verifies an API key against a requested external_user_id, enforcing the
    key's bound_external_user_id (if any).

    Returns:
        (developer_id, None) on success
        (None, KEY_AUTH_ERROR_INVALID) if the key is invalid/inactive
        (None, KEY_AUTH_ERROR_FORBIDDEN) if the key is bound to a different
            external_user_id (or the request supplied none at all)
    """
    auth = get_api_key_auth(api_key)
    if not auth:
        return None, KEY_AUTH_ERROR_INVALID

    bound = auth.get("bound_external_user_id")
    if bound and external_user_id != bound:
        return None, KEY_AUTH_ERROR_FORBIDDEN

    return auth["developer_id"], None
