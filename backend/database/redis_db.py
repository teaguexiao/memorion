import base64
import json
import os
from typing import List, Union, Optional

import redis

r = redis.Redis(
    host=os.getenv('REDIS_DB_HOST'),
    port=int(os.getenv('REDIS_DB_PORT')) if os.getenv('REDIS_DB_PORT') is not None else 6379,
    username='default',
    password=os.getenv('REDIS_DB_PASSWORD'),
    health_check_interval=30,
)


def try_catch_decorator(func):
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception as e:
            print(f'Error calling {func.__name__}', e)
            return None

    return wrapper


@try_catch_decorator
def get_generic_cache(path: str):
    key = base64.b64encode(f'{path}'.encode('utf-8'))
    key = key.decode('utf-8')

    data = r.get(f'cache:{key}')
    return json.loads(data) if data else None


@try_catch_decorator
def set_generic_cache(path: str, data: Union[dict, list], ttl: int = None):
    key = base64.b64encode(f'{path}'.encode('utf-8'))
    key = key.decode('utf-8')

    r.set(f'cache:{key}', json.dumps(data, default=str))
    if ttl:
        r.expire(f'cache:{key}', ttl)


@try_catch_decorator
def delete_generic_cache(path: str):
    key = base64.b64encode(f'{path}'.encode('utf-8'))
    key = key.decode('utf-8')
    r.delete(f'cache:{key}')


# ******************************************************
# ********************* APP BY ID **********************
# ******************************************************


def set_app_cache_by_id(app_id: str, app: dict):
    r.set(f'apps:{app_id}', json.dumps(app, default=str), ex=60 * 10)  # 10 minutes cached


def get_app_cache_by_id(app_id: str) -> dict | None:
    app = r.get(f'apps:{app_id}')
    app = json.loads(app) if app else None
    return app


def delete_app_cache_by_id(app_id: str):
    r.delete(f'apps:{app_id}')


# ******************************************************
# ********************** PERSONA ***********************
# ******************************************************


def is_username_taken(username: str) -> bool:
    """Check if username is taken by checking if it exists in the username:uid mapping"""
    value = r.exists(f'username:{username}:uid')
    if value == 0:
        return False
    return True


def get_uid_by_username(username: str) -> str | None:
    """Get the UID that owns this username"""
    uid = r.get(f'username:{username}:uid')
    return uid.decode() if uid else None


def get_usernames_by_uid(uid: str) -> List[str]:
    """Get all usernames owned by a UID"""
    usernames = r.smembers(f'uid:{uid}:usernames')
    return [u.decode() for u in usernames] if usernames else []


def delete_username(username: str):
    """Delete username and remove it from owner's set"""
    # Get current owner
    uid = get_uid_by_username(username)
    if uid:
        # Remove from owner's set
        r.srem(f'uid:{uid}:usernames', username)
        # Delete username:uid mapping
        r.delete(f'username:{username}:uid')


def save_username(username: str, uid: str):
    """Save username and add to owner's set"""
    # Save username:uid mapping
    r.set(f'username:{username}:uid', uid)
    # Add to owner's set of usernames
    r.sadd(f'uid:{uid}:usernames', username)


# ******************************************************
# *********************** APPS *************************
# ******************************************************


def set_app_usage_count_cache(app_id: str, count: int):
    r.set(f'apps:{app_id}:usage_count', count, ex=60 * 15)  # 15 minutes


def get_app_usage_count_cache(app_id: str) -> int | None:
    count = r.get(f'apps:{app_id}:usage_count')
    if not count:
        return None
    return eval(count)


def set_app_money_made_amount_cache(app_id: str, amount: float):
    r.set(f'apps:{app_id}:money_made', amount, ex=60 * 15)  # 15 minutes


def get_app_money_made_amount_cache(app_id: str) -> float | None:
    amount = r.get(f'apps:{app_id}:money_made')
    if not amount:
        return None
    return eval(amount)


def set_app_usage_history_cache(app_id: str, usage: List[dict]):
    r.set(f'apps:{app_id}:usage', json.dumps(usage, default=str), ex=60 * 10)  # 10 minutes


def get_app_usage_history_cache(app_id: str) -> List[dict]:
    usage = r.get(f'apps:{app_id}:usage')
    if usage is None:
        return []
    usage = json.loads(usage)
    if not usage:
        return []
    return usage


def get_app_money_made_cache(app_id: str) -> dict:
    money = r.get(f'apps:{app_id}:money')
    if money is None:
        return {}
    money = json.loads(money)
    if not money:
        return {}
    return money


def set_app_money_made_cache(app_id: str, money: dict):
    r.set(f'apps:{app_id}:money', json.dumps(money, default=str), ex=60 * 10)  # 10 minutes


def set_app_review_cache(app_id: str, uid: str, data: dict):
    reviews = r.get(f'plugins:{app_id}:reviews')
    if not reviews:
        reviews = {}
    else:
        reviews = eval(reviews)
    reviews[uid] = data
    r.set(f'plugins:{app_id}:reviews', str(reviews))


def get_specific_user_review(app_id: str, uid: str) -> dict:
    reviews = r.get(f'plugins:{app_id}:reviews')
    if not reviews:
        return {}
    reviews = eval(reviews)
    return reviews.get(uid, {})


def migrate_user_apps_reviews(prev_uid: str, new_uid: str):
    for key in r.scan_iter(f'plugins:*:reviews'):
        app_id = key.decode().split(':')[1]
        reviews = r.get(key)
        if not reviews:
            continue
        reviews = eval(reviews)
        if prev_uid in reviews:
            reviews[new_uid] = reviews.pop(prev_uid)
            reviews[new_uid]['uid'] = new_uid
            r.set(f'plugins:{app_id}:reviews', str(reviews))


def set_user_paid_app(app_id: str, uid: str, ttl: int):
    r.set(f'users:{uid}:paid_apps:{app_id}', app_id, ex=ttl)


def get_user_paid_app(app_id: str, uid: str) -> str:
    val = r.get(f'users:{uid}:paid_apps:{app_id}')
    if not val:
        return None
    return val.decode()


def enable_app(uid: str, app_id: str):
    r.sadd(f'users:{uid}:enabled_plugins', app_id)


def disable_app(uid: str, app_id: str):
    r.srem(f'users:{uid}:enabled_plugins', app_id)


def get_enabled_apps(uid: str):
    val = r.smembers(f'users:{uid}:enabled_plugins')
    if not val:
        return []
    return [x.decode() for x in val]


def get_app_reviews(app_id: str) -> dict:
    reviews = r.get(f'plugins:{app_id}:reviews')
    if not reviews:
        return {}
    return eval(reviews)


def get_apps_reviews(app_ids: list) -> dict:
    if not app_ids:
        return {}

    keys = [f'plugins:{app_id}:reviews' for app_id in app_ids]
    reviews = r.mget(keys)
    if reviews is None:
        return {}
    return {app_id: eval(review) if review else {} for app_id, review in zip(app_ids, reviews)}


def set_app_installs_count(app_id: str, count: int):
    r.set(f'plugins:{app_id}:installs', count)


def increase_app_installs_count(app_id: str):
    r.incr(f'plugins:{app_id}:installs')


def decrease_app_installs_count(app_id: str):
    r.decr(f'plugins:{app_id}:installs')


def get_app_installs_count(app_id: str) -> int:
    count = r.get(f'plugins:{app_id}:installs')
    if not count:
        return 0
    return int(count)


def get_apps_installs_count(app_ids: list) -> dict:
    if not app_ids:
        return {}

    keys = [f'plugins:{app_id}:installs' for app_id in app_ids]
    counts = r.mget(keys)
    if counts is None:
        return {}
    return {app_id: int(count) if count else 0 for app_id, count in zip(app_ids, counts)}


def set_user_has_soniox_speech_profile(uid: str):
    r.set(f'users:{uid}:has_soniox_speech_profile', '1')


def get_user_has_soniox_speech_profile(uid: str) -> bool:
    return r.exists(f'users:{uid}:has_soniox_speech_profile')


def remove_user_soniox_speech_profile(uid: str):
    r.delete(f'users:{uid}:has_soniox_speech_profile')


def cache_user_name(uid: str, name: str, ttl: int = 60 * 60 * 24 * 7):
    r.set(f'users:{uid}:name', name)
    r.expire(f'users:{uid}:name', ttl)


def get_cached_user_name(uid: str) -> str:
    name = r.get(f'users:{uid}:name')
    if not name:
        return 'User'
    return name.decode()


# TODO: cache memories if speed improves dramatically
def cache_memories(uid: str, memories: List[dict]):
    r.set(f'users:{uid}:facts', str(memories))
    r.expire(f'users:{uid}:facts', 60 * 60)  # 1 hour, most people chat during a few minutes


def get_cached_memories(uid: str) -> List[dict]:
    memories = r.get(f'users:{uid}:facts')
    if not memories:
        return []
    return eval(memories)


def cache_signed_url(blob_path: str, signed_url: str, ttl: int = 60 * 60):
    r.set(f'urls:{blob_path}', signed_url)
    r.expire(f'urls:{blob_path}', ttl - 1)


def get_cached_signed_url(blob_path: str) -> str:
    signed_url = r.get(f'urls:{blob_path}')
    if not signed_url:
        return ''
    return signed_url.decode()


def cache_user_geolocation(uid: str, geolocation: dict):
    r.set(f'users:{uid}:geolocation', str(geolocation))
    r.expire(f'users:{uid}:geolocation', 60 * 30)  # FIXME: too much?


def get_cached_user_geolocation(uid: str):
    geolocation = r.get(f'users:{uid}:geolocation')
    if not geolocation:
        return None
    return eval(geolocation)


def set_in_progress_conversation_id(uid: str, conversation_id: str, ttl: int = 150):
    r.set(f'users:{uid}:in_progress_memory_id', conversation_id)
    r.expire(f'users:{uid}:in_progress_memory_id', ttl)


def remove_in_progress_conversation_id(uid: str):
    r.delete(f'users:{uid}:in_progress_memory_id')


def get_in_progress_conversation_id(uid: str) -> str:
    conversation_id = r.get(f'users:{uid}:in_progress_memory_id')
    if not conversation_id:
        return ''
    return conversation_id.decode()


def set_user_webhook_db(uid: str, wtype: str, url: str):
    r.set(f'users:{uid}:developer:webhook:{wtype}', url)


def disable_user_webhook_db(uid: str, wtype: str):
    r.set(f'users:{uid}:developer:webhook_status:{wtype}', str(False).lower())


def enable_user_webhook_db(uid: str, wtype: str):
    r.set(f'users:{uid}:developer:webhook_status:{wtype}', str(True).lower())


def user_webhook_status_db(uid: str, wtype: str):
    status = r.get(f'users:{uid}:developer:webhook_status:{wtype}')
    if status is None:
        return None
    return status.decode() == str(True).lower()


def get_user_webhook_db(uid: str, wtype: str) -> str:
    url = r.get(f'users:{uid}:developer:webhook:{wtype}')
    if not url:
        return ''
    return url.decode()


def save_migrated_retrieval_conversation_id(conversation_id: str):
    r.sadd('migrated_retrieval_memory_ids', conversation_id)
    r.expire('migrated_retrieval_memory_ids', 60 * 60 * 24 * 7)


def set_proactive_noti_sent_at(uid: str, app_id: str, ts: int, ttl: int = 30):
    r.set(f'{uid}:{app_id}:proactive_noti_sent_at', ts, ex=ttl)


def get_proactive_noti_sent_at(uid: str, app_id: str):
    val = r.get(f'{uid}:{app_id}:proactive_noti_sent_at')
    if not val:
        return None
    return int(val)


def get_proactive_noti_sent_at_ttl(uid: str, app_id: str):
    return r.ttl(f'{uid}:{app_id}:proactive_noti_sent_at')


def set_user_preferred_app(uid: str, app_id: str):
    """Stores the user's preferred app ID."""
    key = f'user:{uid}:preferred_app'
    r.set(key, app_id)


def get_user_preferred_app(uid: str) -> Optional[str]:
    """Retrieves the user's preferred app ID, if set."""
    key = f'user:{uid}:preferred_app'
    app_id = r.get(key)
    return app_id.decode() if app_id else None


@try_catch_decorator
def set_user_data_protection_level(uid: str, level: str):
    """Caches the user's data protection level."""
    key = f'user:{uid}:data_protection_level'
    r.set(key, level)


@try_catch_decorator
def get_user_data_protection_level(uid: str) -> Optional[str]:
    """Retrieves the user's cached data protection level."""
    key = f'user:{uid}:data_protection_level'
    level = r.get(key)
    return level.decode() if level else None


# ******************************************************
# ******************* MCP API KEYS *********************
# ******************************************************


@try_catch_decorator
def cache_mcp_api_key(hashed_key: str, user_id: str, ttl: int = 3600):
    """Caches the user_id for a given hashed MCP API key."""
    r.set(f'mcp_api_key:{hashed_key}', user_id, ex=ttl)


@try_catch_decorator
def get_cached_mcp_api_key_user_id(hashed_key: str) -> Optional[str]:
    """Retrieves the user_id for a given hashed MCP API key from cache."""
    user_id = r.get(f'mcp_api_key:{hashed_key}')
    return user_id.decode() if user_id else None


@try_catch_decorator
def delete_cached_mcp_api_key(hashed_key: str):
    """Deletes a cached MCP API key."""
    r.delete(f'mcp_api_key:{hashed_key}')


# ******************************************************
# **************** DATA MIGRATION STATUS ***************
# ******************************************************


def set_migration_status(uid: str, status: str, processed: int = None, total: int = None, error: str = None):
    key = f"migration_status:{uid}"
    data = {"status": status}
    if processed is not None:
        data["processed"] = processed
    if total is not None:
        data["total"] = total
    if error is not None:
        data["error"] = error

    r.set(key, json.dumps(data), ex=3600)  # Expire after 1 hour


def get_migration_status(uid: str) -> dict:
    key = f"migration_status:{uid}"
    data = r.get(key)
    if data:
        status_data = json.loads(data)
        # If complete or failed, keep the status for a short time so the UI can fetch it.
        if status_data.get('status') in ['complete', 'failed']:
            r.expire(key, 60)  # Keep it for 1 minute
        return status_data
    return {"status": "idle"}


def clear_migration_status(uid: str):
    key = f"migration_status:{uid}"
    r.delete(key)


# ******************************************************
# ************* DEVELOPER API KEYS *********************
# ******************************************************


@try_catch_decorator
def cache_developer_api_key(hashed_key: str, developer_id: str, ttl: int = 3600):
    """Caches the developer_id for a given hashed developer API key."""
    r.set(f'developer_api_key:{hashed_key}', developer_id, ex=ttl)


@try_catch_decorator
def get_cached_developer_api_key(hashed_key: str) -> Optional[str]:
    """Retrieves the developer_id for a given hashed developer API key from cache."""
    developer_id = r.get(f'developer_api_key:{hashed_key}')
    return developer_id.decode() if developer_id else None


@try_catch_decorator
def cache_developer_api_key_auth(hashed_key: str, auth: dict, ttl: int = 3600):
    """
    Caches full key auth info (developer_id, bound_external_user_id, api_key_id)
    as JSON under a NEW redis key namespace (developer_api_key_auth:).

    The legacy plain-string entry (developer_api_key: -> developer_id) is kept
    in sync too, so code that only needs the developer_id (api_logging
    middleware) and still-running old instances during a rolling deploy keep
    working unchanged.
    """
    r.set(f'developer_api_key_auth:{hashed_key}', json.dumps(auth), ex=ttl)
    developer_id = auth.get('developer_id')
    if developer_id:
        r.set(f'developer_api_key:{hashed_key}', developer_id, ex=ttl)


@try_catch_decorator
def get_cached_developer_api_key_auth(hashed_key: str) -> Optional[dict]:
    """
    Retrieves the cached key auth dict, or None on miss / unparseable value.

    Legacy plain-string entries live under a different redis key namespace, so
    they can never be misread here; a key cached only in the legacy format is
    simply a miss for this function (callers fall back to Firestore, safe).
    """
    raw = r.get(f'developer_api_key_auth:{hashed_key}')
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(data, dict) or not data.get('developer_id'):
        return None
    # Entries cached before `allow_any_user` existed have no such field, and
    # they stay in redis for up to the full TTL after a deploy. Normalize the
    # shape here so consumers can't accidentally read a missing field as
    # "permitted" — absent must mean False (the stricter side), never None.
    data['allow_any_user'] = bool(data.get('allow_any_user'))
    return data


@try_catch_decorator
def delete_cached_developer_api_key(hashed_key: str):
    """Deletes a cached developer API key (both legacy and auth formats)."""
    r.delete(f'developer_api_key:{hashed_key}')
    r.delete(f'developer_api_key_auth:{hashed_key}')


# ======================================================================
# Distributed lock (SET NX EX) — used to make expensive, non-idempotent
# operations mutually exclusive across processes/tasks. See
# routers/developer_conversations.py::process_conversation for the
# conversation-dedup use case (guards against the TOCTOU race where two
# concurrent POST /process requests for the same session both pass the
# Firestore dedup check and each create a conversation + run the LLM).
# ======================================================================


def acquire_lock(lock_key: str, ttl_seconds: int = 60) -> bool:
    """Try to acquire a distributed lock.

    Returns True if the lock was acquired, False if it is already held.

    IMPORTANT — fail-open semantics: if Redis is unreachable we return True
    (treat the lock as acquired) so a Redis outage never blocks the primary
    business flow. The Firestore dedup markers remain as a second line of
    defence for the non-concurrent case; the only thing lost during an outage
    is protection against the exact-simultaneous race.
    """
    try:
        # nx=True: only set if absent -> atomic acquire. ex: auto-expire so a
        # crashed holder never deadlocks the key.
        acquired = r.set(f'lock:{lock_key}', '1', nx=True, ex=ttl_seconds)
        return bool(acquired)
    except Exception as e:
        print(f'[LOCK] acquire_lock failed for {lock_key}, failing open: {e}')
        return True


def release_lock(lock_key: str) -> None:
    """Release a distributed lock acquired via acquire_lock. Best-effort."""
    try:
        r.delete(f'lock:{lock_key}')
    except Exception as e:
        print(f'[LOCK] release_lock failed for {lock_key}: {e}')


def acquire_owned_lock(lock_key: str, owner: str, ttl_seconds: int = 60) -> bool:
    """Fail closed for derived-data writers; preserve the existing lock namespace."""
    return bool(r.set(f'lock:{lock_key}', owner, nx=True, ex=ttl_seconds))


def renew_owned_lock(lock_key: str, owner: str, ttl_seconds: int = 60) -> bool:
    return bool(r.eval('''
        if redis.call('get', KEYS[1]) == ARGV[1] then
            return redis.call('expire', KEYS[1], ARGV[2])
        end
        return 0
    ''', 1, f'lock:{lock_key}', owner, ttl_seconds))


def release_owned_lock(lock_key: str, owner: str) -> None:
    try:
        r.eval('''
            if redis.call('get', KEYS[1]) == ARGV[1] then
                return redis.call('del', KEYS[1])
            end
            return 0
        ''', 1, f'lock:{lock_key}', owner)
    except Exception as error:
        print(f'[LOCK] release_owned_lock failed for {lock_key}: {error}')
