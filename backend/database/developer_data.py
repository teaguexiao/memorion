"""
Tenant-isolated database operations for Developer API.

Data is stored under: developer_data/{developer_id}/users/{external_user_id}/...

This ensures complete isolation between developers' data.
"""

import copy
import json
import uuid
import zlib
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Dict, Any, Tuple

from google.api_core.exceptions import AlreadyExists
from google.cloud import firestore
from google.cloud.firestore_v1 import FieldFilter

from ._client import db, document_id_from_seed
from database.user_usage import ensure_subscription_usage_counter_started_at
from models.user_usage import subscription_counter_covers_month
from models.users import PlanType, Subscription, SubscriptionStatus


# Upper bound on how many ranked ids semantic conversation search resolves in one
# call. It exists to bound the Firestore batch-get and the response size, not to
# page the results — `total_pages` is computed over the whole ranked list, so
# capping this caps how deep a client can paginate. Well above any real user's
# conversation count (largest today: ~5.2k, of which ~3.3k are indexed).
SEMANTIC_SEARCH_MAX_RANKED = 500


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************


def _get_user_ref(developer_id: str, external_user_id: str):
    """Get reference to a user document under developer's data."""
    return (
        db.collection("developer_data")
        .document(developer_id)
        .collection("users")
        .document(external_user_id)
    )


def _ensure_user_exists(developer_id: str, external_user_id: str):
    """Ensure user document exists, create if not."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()
    if not user_doc.exists:
        user_ref.set({
            "id": external_user_id,
            "created_at": datetime.now(timezone.utc),
            "updated_at": datetime.now(timezone.utc),
        })


def get_user_doc(developer_id: str, external_user_id: str) -> Optional[Dict[str, Any]]:
    """Get the user document."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()
    if not user_doc.exists:
        return None
    return user_doc.to_dict()


def ensure_founding_trial(
    developer_id: str,
    external_user_id: str,
    trial_payload: Dict[str, Any],
    *,
    legacy_cutoff: Optional[datetime] = None,
    legacy_payload: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Create the initial entitlement exactly once.

    Historical accounts created on or before ``legacy_cutoff`` receive the
    supplied permanent Legacy entitlement. Newer accounts receive the founding
    trial. Every existing entitlement is preserved.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    transaction = db.transaction()

    @firestore.transactional
    def _ensure(transaction):
        snapshot = user_ref.get(transaction=transaction)
        data = snapshot.to_dict() if snapshot.exists else {}
        if data.get('entitlement'):
            return data

        now = datetime.now(timezone.utc)
        created_at = data.get('created_at')
        if isinstance(created_at, datetime) and created_at.tzinfo is None:
            created_at = created_at.replace(tzinfo=timezone.utc)
        is_historical = (
            legacy_cutoff is not None
            and legacy_payload is not None
            and isinstance(created_at, datetime)
            and created_at <= legacy_cutoff
        )
        payload = {
            'id': external_user_id,
            'entitlement': legacy_payload if is_historical else trial_payload,
            'updated_at': now,
        }
        if not snapshot.exists:
            payload['created_at'] = now
        transaction.set(user_ref, payload, merge=True)
        data.update(payload)
        return data

    return _ensure(transaction)


def activate_apple_subscription(
    developer_id: str,
    external_user_id: str,
    entitlement: Dict[str, Any],
) -> Dict[str, Any]:
    """Persist a verified Apple subscription and bind its chain to one account."""
    original_transaction_id = entitlement.get('original_transaction_id')
    if not original_transaction_id:
        raise ValueError('Verified Apple transaction is missing original_transaction_id')

    user_ref = _get_user_ref(developer_id, external_user_id)
    owner_ref = db.collection('apple_subscription_owners').document(str(original_transaction_id))
    transaction = db.transaction()

    @firestore.transactional
    def _activate(transaction):
        owner = owner_ref.get(transaction=transaction)
        owner_data = owner.to_dict() if owner.exists else {}
        if owner_data and (
            owner_data.get('developer_id') != developer_id
            or owner_data.get('external_user_id') != external_user_id
        ):
            raise ValueError('This Apple subscription is already linked to another account')

        now = datetime.now(timezone.utc)
        transaction.set(
            owner_ref,
            {
                'developer_id': developer_id,
                'external_user_id': external_user_id,
                'product_id': entitlement.get('product_id'),
                'updated_at': now,
            },
            merge=True,
        )
        transaction.set(
            user_ref,
            {
                'id': external_user_id,
                'entitlement': {**entitlement, 'updated_at': now},
                'subscription': {
                    'plan': PlanType.unlimited.value,
                    'status': SubscriptionStatus.active.value,
                    'current_period_end': int(entitlement['expires_at'].timestamp()),
                    'updated_at': now,
                },
                'updated_at': now,
            },
            merge=True,
        )
        return {**entitlement, 'updated_at': now}

    return _activate(transaction)


def update_apple_subscription_from_notification(
    original_transaction_id: str,
    entitlement: Dict[str, Any],
) -> bool:
    """Apply a verified Apple server notification to the account that owns it."""
    owner_ref = db.collection('apple_subscription_owners').document(str(original_transaction_id))
    owner = owner_ref.get()
    if not owner.exists:
        # The user has not linked this purchase in the app yet. Apple retries
        # notifications, and a later restore/purchase will establish ownership.
        return False

    owner_data = owner.to_dict() or {}
    developer_id = owner_data.get('developer_id')
    external_user_id = owner_data.get('external_user_id')
    if not developer_id or not external_user_id:
        return False

    now = datetime.now(timezone.utc)
    expires_at = entitlement.get('expires_at')
    has_active_access = (
        entitlement.get('status') in {'active', 'billing_retry', 'grace_period'}
        and isinstance(expires_at, datetime)
        and expires_at > now
    )
    plan = PlanType.unlimited.value if has_active_access else PlanType.basic.value
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.set(
        {
            'entitlement': {**entitlement, 'updated_at': now},
            'subscription': {
                'plan': plan,
                'status': SubscriptionStatus.active.value,
                'current_period_end': int(entitlement['expires_at'].timestamp()),
                'updated_at': now,
            },
            'updated_at': now,
        },
        merge=True,
    )
    owner_ref.set(
        {
            'product_id': entitlement.get('product_id'),
            'last_notification_uuid': entitlement.get('notification_uuid'),
            'updated_at': now,
        },
        merge=True,
    )
    return True


# ******************************************************
# ****************** USER PREFERENCES ******************
# ******************************************************


def get_user_preferences(
    developer_id: str,
    external_user_id: str,
) -> Dict[str, Any]:
    """
    Get user preferences (language, timezone, etc.).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID

    Returns:
        User preferences dict
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()

    if not user_doc.exists:
        return {
            "language": None,
            "timezone": None,
            "recording_categories": None,
        }

    data = user_doc.to_dict()
    return {
        "language": data.get("language"),
        "timezone": data.get("timezone"),
        "recording_categories": data.get("recording_categories"),
    }


def get_user_language(
    developer_id: str,
    external_user_id: str,
) -> Optional[str]:
    """
    Get the user's preferred language.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID

    Returns:
        Language code or None if not set
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()

    if user_doc.exists:
        return user_doc.to_dict().get("language")
    return None


def set_user_language(
    developer_id: str,
    external_user_id: str,
    language: str,
) -> Dict[str, Any]:
    """
    Set the user's preferred language.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        language: Language code (e.g., 'en', 'zh', 'vi')

    Returns:
        Updated user preferences
    """
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.update({
        "language": language,
        "updated_at": datetime.now(timezone.utc),
    })
    return get_user_preferences(developer_id, external_user_id)


def get_user_timezone(
    developer_id: str,
    external_user_id: str,
) -> Optional[str]:
    """
    Get the user's preferred timezone.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID

    Returns:
        Timezone string or None if not set
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()

    if user_doc.exists:
        return user_doc.to_dict().get("timezone")
    return None


def get_user_effective_timezone(
    developer_id: str,
    external_user_id: str,
) -> Optional[str]:
    """The timezone that defines the user's local day: `timezone`, else `time_zone`.

    Two fields coexist on the user document. `timezone` is the preference the App sets
    (`PUT /v1/user/timezone`); `time_zone` is what the device reports with its FCM token
    (`set_user_time_zone`). Either can be missing (2026-10-27: 30 users had only
    `time_zone`, 12 only `timezone`, 9 had both disagreeing). Reading one field alone
    put the first group's day on UTC, and the daily-summary cron, which discovered users by
    `time_zone` only, never reached the second group at all.
    """
    user_doc = _get_user_ref(developer_id, external_user_id).get()
    if not user_doc.exists:
        return None
    data = user_doc.to_dict() or {}
    return data.get("timezone") or data.get("time_zone")


def set_user_timezone(
    developer_id: str,
    external_user_id: str,
    timezone_str: str,
) -> Dict[str, Any]:
    """
    Set the user's preferred timezone.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        timezone_str: IANA timezone string (e.g., 'America/New_York', 'Asia/Shanghai')

    Returns:
        Updated user preferences
    """
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.update({
        "timezone": timezone_str,
        "updated_at": datetime.now(timezone.utc),
    })
    return get_user_preferences(developer_id, external_user_id)


def update_user_preferences(
    developer_id: str,
    external_user_id: str,
    language: Optional[str] = None,
    timezone_str: Optional[str] = None,
    preferred_app_id: Optional[str] = None,
    recording_categories: Optional[List[str]] = None,
) -> Dict[str, Any]:
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)

    update_data = {"updated_at": datetime.now(timezone.utc)}
    if language is not None:
        update_data["language"] = language
    if timezone_str is not None:
        update_data["timezone"] = timezone_str
    if preferred_app_id is not None:
        update_data["preferred_app_id"] = preferred_app_id
    if recording_categories is not None:
        update_data["recording_categories"] = recording_categories

    if len(update_data) > 1:
        user_ref.update(update_data)

    return get_user_preferences(developer_id, external_user_id)


# 通知偏好默认值——必须与 App 端 SharedPreferencesUtil 的默认保持一致
# (app/lib/backend/preferences.dart)。老用户没有这条记录时按默认放行，
# 避免新增偏好同步接口反而让存量用户收不到推送。
NOTIFICATION_PREFERENCES_DEFAULTS = {
    "daily_moment": True,
    "task_reminder": True,
    "pause_reminder": True,
    "milestone": True,
    "quiet_hours_enabled": False,
    # ⚠️ 起点别设成 22:00：_in_quiet_hours 的跨午夜分支是 now >= start，而每日一刻
    # 恰好在本地 22:00 整点推 → 一开静默时段就永久收不到它。23:00 留出这一小时。
    "quiet_hours_start_minutes": 23 * 60,
    "quiet_hours_end_minutes": 8 * 60,
}


def get_notification_preferences_detailed(
    developer_id: str,
    external_user_id: str,
) -> Tuple[Dict[str, Any], List[str]]:
    """返回 (补齐默认后的偏好, 用户真正存过的 key 列表)。

    ⚠️ **第二个返回值不能省，也没法从第一个反推。** 读出去的偏好总是全字段（缺的按
    默认补齐），所以「用户显式设成 True」和「用户从没设过、默认是 True」在值上完全
    一样。App 回读时若无脑覆盖本地，就把**服务端此刻的默认值固化成了用户设置** ——
    此后两边再改默认值对这批用户永久无效，而且看起来完全正常（值合法、行为「正常」）。
    156 个用户里只有 2 个写过这条记录，绝大多数人都会踩到。
    """
    prefs = dict(NOTIFICATION_PREFERENCES_DEFAULTS)
    if not developer_id:
        return prefs, []

    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()
    stored_keys: List[str] = []
    if user_doc.exists:
        stored = (user_doc.to_dict() or {}).get("notification_preferences") or {}
        for key in prefs:
            if key in stored and stored[key] is not None:
                prefs[key] = stored[key]
                stored_keys.append(key)
    return prefs, stored_keys


def get_notification_preferences(
    developer_id: str,
    external_user_id: str,
) -> Dict[str, Any]:
    """读取用户通知偏好，缺字段按默认补齐（默认放行）。

    服务端推送闸门用这个（只关心最终值）。要区分「用户设过」与「补的默认值」时用
    `get_notification_preferences_detailed`。
    """
    prefs, _ = get_notification_preferences_detailed(developer_id, external_user_id)
    return prefs


def set_notification_preferences(
    developer_id: str,
    external_user_id: str,
    preferences: Dict[str, Any],
) -> Dict[str, Any]:
    """合并写入用户通知偏好（只更新传入的已知字段）。

    ⚠️ **落库的 map 必须只含「用户存过的 + 本次传入的」字段，绝不能拿
    `get_notification_preferences()` 当基线。** 那个函数补齐了默认值，整份写回等于把
    服务端**此刻**的默认值固化成用户设置：用户动一个开关，七个字段全落库，
    `stored_keys` 立刻退化成全集，回读那层「只覆盖用户设过的字段」的防护随即失效。
    App 侧改成增量上报（2026-08-12）只解决了上行那一半，这里不改就等于没改 ——
    又一例「两个函数各自都对、接起来才错」。存量踩中的两个用户见
    `scripts/unpin_notification_quiet_hours.py`。

    返回值仍是补齐默认后的全字段（POST 响应契约），与落库内容刻意不同。
    """
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)

    # prefs[key] 对 stored_keys 里的 key 就是存储原值（没被默认值覆盖过），
    # 所以这里不必再读一次文档。
    prefs, stored_keys = get_notification_preferences_detailed(developer_id, external_user_id)
    to_store = {key: prefs[key] for key in stored_keys}
    for key in NOTIFICATION_PREFERENCES_DEFAULTS:
        if key in preferences and preferences[key] is not None:
            to_store[key] = preferences[key]

    user_ref.update({
        "notification_preferences": to_store,
        "updated_at": datetime.now(timezone.utc),
    })

    current = dict(NOTIFICATION_PREFERENCES_DEFAULTS)
    current.update(to_store)
    return current


def _normalize_transcript_segments(segments: Any) -> Any:
    """Normalize transcript segment dicts (in place) for both reads and writes.

    - speaker_id: historical documents stored a string label (e.g.
      'SPEAKER_01') while the Developer API contract documents an integer.
      Coerce on every read/write so responses always match the docs without
      needing a data migration.
    - text: strip leading/trailing whitespace that STT providers emit
      (e.g. Soniox tokens include leading spaces).

    No-op for already-clean data.
    """
    from models.transcript_segment import coerce_speaker_id

    if not isinstance(segments, list):
        return segments
    for seg in segments:
        if not isinstance(seg, dict):
            continue
        sid = seg.get('speaker_id')
        if sid is not None and not isinstance(sid, int):
            seg['speaker_id'] = coerce_speaker_id(sid)
        text = seg.get('text')
        if isinstance(text, str) and text != text.strip():
            seg['text'] = text.strip()
    return segments


def _prepare_conversation_for_read(
    conversation_data: Optional[Dict[str, Any]],
    conv_ref=None,
    include_transcript_segments: bool = True,
) -> Optional[Dict[str, Any]]:
    """
    Prepare conversation data for reading by decompressing transcript_segments if needed
    and ensuring required fields have default values.
    If transcript was stored in chunks (subcollection), conv_ref is needed to read them.
    """
    if not conversation_data:
        return None

    data = copy.deepcopy(conversation_data)

    if include_transcript_segments:
        # Handle chunked transcript_segments (stored in subcollection)
        if data.get('transcript_segments_chunked') and conv_ref:
            try:
                chunks_ref = conv_ref.collection("transcript_chunks")
                chunk_docs = sorted(chunks_ref.stream(), key=lambda d: d.to_dict().get("index", 0))
                compressed_segments = b"".join(d.to_dict()["data"] for d in chunk_docs)
                decompressed_json = zlib.decompress(compressed_segments).decode('utf-8')
                data['transcript_segments'] = json.loads(decompressed_json)
            except Exception as e:
                print(f"Error reading chunked conversation transcript_segments: {e}")
                data['transcript_segments'] = []
        # Handle inline compressed transcript_segments
        elif data.get('transcript_segments_compressed'):
            if 'transcript_segments' in data and isinstance(data['transcript_segments'], bytes):
                try:
                    decompressed_json = zlib.decompress(data['transcript_segments']).decode('utf-8')
                    data['transcript_segments'] = json.loads(decompressed_json)
                except (json.JSONDecodeError, TypeError, zlib.error) as e:
                    print(f"Error decompressing transcript_segments: {e}")
                    data['transcript_segments'] = []
    else:
        data['transcript_segments'] = []

    # Ensure transcript_segments is a list
    if 'transcript_segments' not in data or not isinstance(data.get('transcript_segments'), list):
        data['transcript_segments'] = []

    # Normalize legacy string speaker_id ('SPEAKER_01') to int for API responses
    _normalize_transcript_segments(data['transcript_segments'])

    # Ensure metadata field exists (required by response model)
    if 'metadata' not in data:
        data['metadata'] = {}

    # Early durable-upload jobs omitted the API's required update timestamp.
    # Use a stable recorded time on reads, preserving any existing edit time.
    if data.get('updated_at') is None:
        data['updated_at'] = data.get('created_at')

    # Remove internal compression/chunking flags from response
    data.pop('transcript_segments_compressed', None)
    data.pop('transcript_segments_chunked', None)
    data.pop('transcript_segments_chunk_count', None)

    return data


def _prepare_listen_session_for_read(session_data: Optional[Dict[str, Any]], session_ref=None) -> Optional[Dict[str, Any]]:
    """
    Prepare listen session data for reading by decompressing transcript_segments if needed.
    If transcript was stored in chunks (subcollection), session_ref is needed to read them.
    """
    if not session_data:
        return None

    data = copy.deepcopy(session_data)

    # Handle chunked transcript_segments (stored in subcollection)
    if data.get('transcript_segments_chunked') and session_ref:
        try:
            chunks_ref = session_ref.collection("transcript_chunks")
            chunk_docs = sorted(chunks_ref.stream(), key=lambda d: d.to_dict().get("index", 0))
            compressed_segments = b"".join(d.to_dict()["data"] for d in chunk_docs)
            decompressed_json = zlib.decompress(compressed_segments).decode('utf-8')
            data['transcript_segments'] = json.loads(decompressed_json)
        except Exception as e:
            print(f"Error reading chunked listen session transcript_segments: {e}")
            data['transcript_segments'] = []
    # Handle inline compressed transcript_segments
    elif data.get('transcript_segments_compressed'):
        if 'transcript_segments' in data and isinstance(data['transcript_segments'], bytes):
            try:
                decompressed_json = zlib.decompress(data['transcript_segments']).decode('utf-8')
                data['transcript_segments'] = json.loads(decompressed_json)
            except (json.JSONDecodeError, TypeError, zlib.error) as e:
                print(f"Error decompressing listen session transcript_segments: {e}")
                data['transcript_segments'] = []

    # Ensure transcript_segments is a list
    if 'transcript_segments' not in data or not isinstance(data.get('transcript_segments'), list):
        data['transcript_segments'] = []

    # Remove internal compression/chunking flags from response
    data.pop('transcript_segments_compressed', None)
    data.pop('transcript_segments_chunked', None)
    data.pop('transcript_segments_chunk_count', None)

    return data


# ******************************************************
# ****************** MEMORIES **************************
# ******************************************************


def create_memory(
    developer_id: str,
    external_user_id: str,
    content: str,
    category: str = "interesting",
    tags: List[str] = None,
    metadata: Dict[str, Any] = None,
    visibility: str = "private",
    manually_added: bool = False,
) -> Dict[str, Any]:
    """
    Create a memory for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        content: Memory content
        category: Memory category
        tags: List of tags
        metadata: Additional metadata
        visibility: Memory visibility (private or public)
        manually_added: True when the user wrote this fact themselves

    Returns:
        The created memory document
    """
    _ensure_user_exists(developer_id, external_user_id)

    memory_id = document_id_from_seed(f"{developer_id}:{external_user_id}:{content}:{datetime.now().isoformat()}")
    now = datetime.now(timezone.utc)

    memory_data = {
        "id": memory_id,
        "content": content,
        "category": category,
        "tags": tags or [],
        "metadata": metadata or {},
        "visibility": visibility,
        # 用户自己写的事实无需再审阅，直接算已确认（对齐 MemoryDB.from_memory）。
        "reviewed": manually_added,
        "user_review": True if manually_added else None,
        "manually_added": manually_added,
        "deleted": False,
        "created_at": now,
        "updated_at": now,
    }

    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_ref.set(memory_data)

    return memory_data


def _is_confirmed_fact(data: Dict[str, Any]) -> bool:
    """已确认事实 = 用户手动写的，或 LLM 提取后用户点过「没错」（user_review==True）。

    老数据（迁移前）manually_added/user_review 都缺失——迁移脚本会把它们补成
    已确认；这里对缺字段的判定保持"未确认"，配合迁移脚本一起才不会误伤存量。
    """
    return bool(data.get("manually_added")) or data.get("user_review") is True


def _is_pending_fact(data: Dict[str, Any]) -> bool:
    """待确认事实 = LLM 提取、还没被用户裁决过。

    user_review is False 是「不对」的否决 tombstone——它不再是待确认（不再问），
    但也不进正式列表；只留着让提取去重认得它。
    """
    return (
        not data.get("manually_added")
        and not data.get("reviewed")
        and data.get("user_review") is None
    )


def get_memories(
    developer_id: str,
    external_user_id: str,
    limit: int = 100,
    offset: int = 0,
    categories: List[str] = None,
    tags: List[str] = None,
    include_deleted: bool = False,
    status: str = "confirmed",
) -> List[Dict[str, Any]]:
    """
    Get memories for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum number of memories to return
        offset: Number of memories to skip
        categories: Filter by categories
        tags: Filter by tags (any match)
        include_deleted: Include soft-deleted memories (deleted=True)
        status: Which review状态 to return —
            "confirmed"（默认）只回已确认（手动加 or 点过「没错」）——「它记住的事实」列表用；
            "pending" 只回待确认（LLM 提取、还没裁决）——待确认气泡卡用；
            "all" 不按 review 状态过滤（否决态仍不含，见下）。

    Returns:
        List of memory documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memories_ref = user_ref.collection("memories")

    # Apply filters
    if categories:
        memories_ref = memories_ref.where(filter=FieldFilter("category", "in", categories))

    memories_ref = memories_ref.order_by("created_at", direction=firestore.Query.DESCENDING)

    # 分页在代码层做，不能直接 .limit(limit).offset(offset)。
    #
    # 要丢掉两类文档，而两类都没法用 Firestore where 表达：
    #  1. 软删除（deleted=True）——deleted 字段是后加的，老文档根本没有这个 key，
    #     缺字段的文档不匹配任何 == 过滤，用 where 会把它们全部漏掉；
    #  2. 没有 content 的文档——历史上有条写入路径把整条对话写进了 memories 集合
    #     （带 transcript_segments/structured），它们不是事实，不能出现在列表里。
    # 如果先 limit 再过滤，一页 100 条会变成「100 条原始文档里的少数幸存者」——
    # 复筛之后 98% 的文档都是软删的，那样一页只剩个把条，翻页也永远翻不完。
    fetch_limit = offset + limit
    kept: List[Dict[str, Any]] = []
    for doc in memories_ref.stream():
        data = doc.to_dict() or {}
        if not include_deleted and data.get("deleted"):
            continue
        if not (data.get("content") or "").strip():
            continue
        # 按 review 状态过滤（默认只回已确认；否决 tombstone 两种状态都不返回）。
        if status == "confirmed" and not _is_confirmed_fact(data):
            continue
        if status == "pending" and not _is_pending_fact(data):
            continue
        if status == "all" and data.get("user_review") is False:
            # 「不对」的否决态既不属于正式列表，也不该在"全部"里冒出来。
            continue
        # Filter by tags here too (Firestore can't combine array-contains-any well)
        if tags and not any(t in data.get("tags", []) for t in tags):
            continue
        kept.append(data)
        if len(kept) >= fetch_limit:
            break

    return kept[offset:]


def get_memory(
    developer_id: str,
    external_user_id: str,
    memory_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a single memory by ID.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        memory_id: The memory's ID

    Returns:
        Memory document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_doc = memory_ref.get()

    if not memory_doc.exists:
        return None

    return memory_doc.to_dict()


def update_memory(
    developer_id: str,
    external_user_id: str,
    memory_id: str,
    content: str = None,
    category: str = None,
    tags: List[str] = None,
    metadata: Dict[str, Any] = None,
    visibility: str = None,
    reviewed: bool = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a memory.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        memory_id: The memory's ID
        content: New content (optional)
        category: New category (optional)
        tags: New tags (optional)
        metadata: New metadata (optional, merged with existing)
        visibility: New visibility (optional)
        reviewed: New reviewed status (optional)

    Returns:
        Updated memory document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_doc = memory_ref.get()

    if not memory_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if content is not None:
        update_data["content"] = content
    if category is not None:
        update_data["category"] = category
    if tags is not None:
        update_data["tags"] = tags
    if metadata is not None:
        existing_data = memory_doc.to_dict()
        existing_metadata = existing_data.get("metadata", {})
        existing_metadata.update(metadata)
        update_data["metadata"] = existing_metadata
    if visibility is not None:
        update_data["visibility"] = visibility
    if reviewed is not None:
        update_data["reviewed"] = reviewed

    memory_ref.update(update_data)

    return memory_ref.get().to_dict()


def delete_memory(
    developer_id: str,
    external_user_id: str,
    memory_id: str,
) -> bool:
    """
    Delete a memory.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        memory_id: The memory's ID

    Returns:
        True if deleted, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_doc = memory_ref.get()

    if not memory_doc.exists:
        return False

    memory_ref.delete()
    return True


# 判重取代旧事实时写的 reason。跟 rescreen 用的那个分开，这样两批软删可以各自回滚
# （`scripts/dedupe_memories.py --restore` 只翻这一种）。
MEMORY_SUPERSEDED_REASON = 'superseded_by_newer_fact'


def soft_delete_memories(
    developer_id: str,
    external_user_id: str,
    memory_ids: List[str],
    reason: str = MEMORY_SUPERSEDED_REASON,
) -> int:
    """软删一批事实，返回真正改动的条数。

    软删而不是 `delete_memory` 的硬删：判重错了要能整批翻回来，而读路径
    （`get_all_memories` / `get_memories` / discover 的计数）都已经按 `deleted` 过滤。
    幂等——已经软删的会被跳过，所以重复处理同一条对话不会累计。
    """
    if not memory_ids:
        return 0
    user_ref = _get_user_ref(developer_id, external_user_id)
    changed = 0
    for memory_id in dict.fromkeys(memory_ids):
        try:
            ref = user_ref.collection('memories').document(memory_id)
            snap = ref.get()
            if not snap.exists or (snap.to_dict() or {}).get('deleted'):
                continue
            ref.update(
                {
                    'deleted': True,
                    'deleted_reason': reason,
                    'deleted_at': datetime.now(timezone.utc),
                }
            )
            changed += 1
        except Exception as e:
            print(f'soft_delete_memories: failed on {memory_id}: {e}')
    return changed


def search_memories(
    developer_id: str,
    external_user_id: str,
    query: str,
    limit: int = 10,
) -> List[Dict[str, Any]]:
    """
    Search memories by content (literal, case-insensitive substring match).

    Deliberately not semantic: unlike conversations, memories have no vector
    index — they are short one-line facts, and only the first 500 are scanned.
    Callers that need meaning-based retrieval should search conversations
    instead (`search_conversations`, which is semantic).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        query: Search query
        limit: Maximum number of results

    Returns:
        List of matching memory documents
    """
    # Simple implementation: get all memories and filter in memory
    # For production, use vector search or full-text search service
    all_memories = get_memories(developer_id, external_user_id, limit=500)

    query_lower = query.lower()
    matching = [
        m for m in all_memories
        if query_lower in m.get("content", "").lower()
    ]

    return matching[:limit]


def delete_all_memories(
    developer_id: str,
    external_user_id: str,
) -> int:
    """
    Delete all memories for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID

    Returns:
        Number of memories deleted
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memories_ref = user_ref.collection("memories")

    deleted_count = 0
    for doc in memories_ref.stream():
        doc.reference.delete()
        deleted_count += 1

    return deleted_count


def update_memory_visibility(
    developer_id: str,
    external_user_id: str,
    memory_id: str,
    visibility: str,
) -> bool:
    """
    Update a memory's visibility.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        memory_id: The memory's ID
        visibility: New visibility (private or public)

    Returns:
        True if updated, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_doc = memory_ref.get()

    if not memory_doc.exists:
        return False

    memory_ref.update({
        "visibility": visibility,
        "updated_at": datetime.now(timezone.utc),
    })

    return True


def review_memory(
    developer_id: str,
    external_user_id: str,
    memory_id: str,
    value: bool,
) -> bool:
    """
    Review a memory (mark as reviewed).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        memory_id: The memory's ID
        value: Review value (True or False)

    Returns:
        True if updated, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_doc = memory_ref.get()

    if not memory_doc.exists:
        return False

    # value 既是「已审阅」也是「用户裁决」：True=「没错」（进正式列表），
    # False=「不对」（否决 tombstone，不进列表、也不再问，但留着供提取去重）。
    # 无论哪种，reviewed 都置 True——这条已经被用户处理过了。
    memory_ref.update({
        "reviewed": True,
        "user_review": value,
        "updated_at": datetime.now(timezone.utc),
    })

    return True


def edit_memory_content(
    developer_id: str,
    external_user_id: str,
    memory_id: str,
    content: str,
) -> bool:
    """
    Edit a memory's content directly.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        memory_id: The memory's ID
        content: New content

    Returns:
        True if updated, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    memory_ref = user_ref.collection("memories").document(memory_id)
    memory_doc = memory_ref.get()

    if not memory_doc.exists:
        return False

    memory_ref.update({
        "content": content,
        "updated_at": datetime.now(timezone.utc),
    })

    return True


# ******************************************************
# **************** CONVERSATIONS ***********************
# ******************************************************


def create_conversation(
    developer_id: str,
    external_user_id: str,
    started_at: datetime = None,
    finished_at: datetime = None,
    language: str = None,
    source: str = "api",
    metadata: Dict[str, Any] = None,
) -> Dict[str, Any]:
    """
    Create a new conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        started_at: When the conversation started
        finished_at: When the conversation ended
        language: Language code
        source: Source of the conversation
        metadata: Additional metadata

    Returns:
        The created conversation document
    """
    _ensure_user_exists(developer_id, external_user_id)

    conversation_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    conversation_data = {
        "id": conversation_id,
        "created_at": now,
        # `or now` is correct *here* and nowhere else. This creates an
        # `in_progress` conversation, i.e. recording is beginning at this
        # instant, so "now" is the recording time rather than a guess at it.
        # Contrast `audio_upload.py`, where the audio already exists and was
        # recorded earlier — defaulting there would relocate the recording to
        # the upload moment, so it raises 400 instead
        # (`_require_recording_started_at`). Don't unify the two.
        "started_at": started_at or now,
        "finished_at": finished_at,
        "language": language,
        "source": source,
        "status": "in_progress",
        "transcript_segments": [],
        "structured": {
            "title": "",
            "overview": "",
            "emoji": "",
            "category": "other",
            "action_items": [],
            "events": [],
            "emotion": "calm",
        },
        "metadata": metadata or {},
        "discarded": False,
        "updated_at": now,
    }

    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_ref.set(conversation_data)

    return conversation_data


def get_conversations(
    developer_id: str,
    external_user_id: str,
    limit: int = 100,
    offset: int = 0,
    statuses: List[str] = None,
    start_date: datetime = None,
    end_date: datetime = None,
    categories: List[str] = None,
    include_photos: bool = True,
    include_discarded: bool = False,
    include_transcript_segments: bool = True,
) -> List[Dict[str, Any]]:
    """
    Get conversations for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum number of conversations to return
        offset: Number of conversations to skip
        statuses: Filter by status
        start_date: Filter by start date
        end_date: Filter by end date
        categories: Filter by category
        include_photos: Whether to include photos subcollection (default True)
        include_discarded: Whether to include discarded conversations (default False)

    Returns:
        List of conversation documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_collection_ref = user_ref.collection("conversations")

    # Apply filters
    query = conv_collection_ref
    if statuses:
        query = query.where(filter=FieldFilter("status", "in", statuses))
    if start_date:
        query = query.where(filter=FieldFilter("created_at", ">=", start_date))
    if end_date:
        query = query.where(filter=FieldFilter("created_at", "<=", end_date))
    if categories:
        query = query.where(filter=FieldFilter("structured.category", "in", categories))
    # 🚨 丢弃过滤必须打在**查询里**，不能等取回来再筛。`limit` 作用在过滤之前，所以
    # 内存过滤会让返回条数变成 `limit - 这一窗口里被丢弃的条数` —— 丢弃率越高，调用方
    # 拿到的越少，而它无从分辨「只剩这么多」和「被吃掉了」。
    #
    # 2026-08-21 的表现：首页请求 50 条只拿回 21 条，只够铺开今天和昨天两天，再往前
    # 一条都看不到（那天丢弃率 57%，25/44）。它还锁死了分页：App 用
    # `conversations.length % 50 != 0` 判断「还有更多」，21 % 50 ≠ 0 ⇒ 永久 return。
    # 两边各自都说得通，接起来就是「首页永远只有第一页」。
    #
    # ⚠️ 下推的前提是每个文档都**有**这个字段：Firestore 里缺字段的文档不匹配任何针对
    # 该字段的过滤条件，而这些文档此前正是靠 `.get("discarded", False)` 的默认值才可见的。
    # 全库当时有 525 条（6.4%）缺它，已由 `scripts/backfill_conversation_discarded_flag.py`
    # 补齐。**别在没跑那个脚本的环境里启用这一行**，否则它们会静默消失。
    #
    # ⚠️ 另一个前提是**复合索引**：等值过滤 + 另一字段排序/范围，Firestore 一定要索引，
    # 缺了就是 `FAILED_PRECONDITION: The query requires an index`，即 500 而不是降级。
    # 换 Firestore 项目 / 新环境时这两个都要先建（`gcloud firestore indexes composite
    # create --collection-group=conversations ...`）：
    #   · discarded ASC + created_at DESC                              ← 基础，含日期区间那几个调用点
    #   · structured.category ASC + discarded ASC + created_at DESC    ← `?categories=` 走这个
    # 只带 `statuses` 的组合复用既有索引，不必新建（已实测）。
    if not include_discarded:
        query = query.where(filter=FieldFilter("discarded", "==", False))

    # Sort and paginate
    query = (
        query.order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    conversations = []
    for doc in query.stream():
        conv = _prepare_conversation_for_read(
            doc.to_dict(),
            conv_ref=doc.reference,
            include_transcript_segments=include_transcript_segments,
        )
        if conv and include_photos:
            # Load photos from subcollection
            photos_ref = doc.reference.collection("photos")
            conv["photos"] = [photo_doc.to_dict() for photo_doc in photos_ref.stream()]
        elif conv:
            conv["photos"] = []
        if conv:
            # 丢弃过滤已经在查询里做掉了（见上）。这里留一道兜底断言式的跳过：真要有
            # 文档漏过来，宁可少一条也不要把已丢弃的对话摆到首页上。正常路径永不命中。
            if not include_discarded and conv.get("discarded", False):
                continue
            conversations.append(conv)

    return conversations


def get_conversations_by_recording_time(
    developer_id: str,
    external_user_id: str,
    start_date: datetime = None,
    end_date: datetime = None,
    limit: int = 500,
    include_transcript_segments: bool = True,
) -> List[Dict[str, Any]]:
    """Read a bounded recording-time window, including discarded conversations.

    Offline recorders can upload weeks after recording. A created_at window,
    however wide, cannot reliably find those recordings on their original day.
    Query and sort on the single started_at field; no new composite index or
    photo subcollection reads are needed. Callers apply their discard policy.
    The ordinary conversations list keeps its existing created_at semantics.
    """
    if start_date is None and end_date is None:
        raise ValueError("A recording-time bound is required")
    if limit <= 0:
        return []
    query = _get_user_ref(developer_id, external_user_id).collection("conversations")
    if start_date is not None:
        query = query.where(filter=FieldFilter("started_at", ">=", start_date))
    if end_date is not None:
        query = query.where(filter=FieldFilter("started_at", "<=", end_date))
    query = query.order_by("started_at", direction=firestore.Query.DESCENDING).limit(limit)
    conversations = []
    for doc in query.stream():
        conv = _prepare_conversation_for_read(
            doc.to_dict(),
            conv_ref=doc.reference,
            include_transcript_segments=include_transcript_segments,
        )
        if conv:
            conv["photos"] = []
            conversations.append(conv)
    return conversations


def get_conversation(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    include_photos: bool = True,
) -> Optional[Dict[str, Any]]:
    """
    Get a single conversation by ID.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        include_photos: Whether to include photos subcollection (default True)

    Returns:
        Conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv = _prepare_conversation_for_read(conv_doc.to_dict(), conv_ref=conv_ref)
    if conv and include_photos:
        # Load photos from subcollection
        photos_ref = conv_ref.collection("photos")
        conv["photos"] = [photo_doc.to_dict() for photo_doc in photos_ref.stream()]
    elif conv:
        conv["photos"] = []

    return conv


def update_conversation(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    title: str = None,
    overview: str = None,
    status: str = None,
    metadata: Dict[str, Any] = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        title: New title (optional)
        overview: New overview (optional)
        status: New status (optional)
        metadata: New metadata (optional, merged)

    Returns:
        Updated conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if title is not None:
        update_data["structured.title"] = title
    if overview is not None:
        update_data["structured.overview"] = overview
    if status is not None:
        update_data["status"] = status
    if metadata is not None:
        existing_data = conv_doc.to_dict()
        existing_metadata = existing_data.get("metadata", {})
        existing_metadata.update(metadata)
        update_data["metadata"] = existing_metadata

    conv_ref.update(update_data)

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


def search_conversations(
    developer_id: str,
    external_user_id: str,
    query: str,
    page: int = 1,
    per_page: int = 10,
    include_discarded: bool = True,
    start_date: datetime = None,
    end_date: datetime = None,
) -> Dict[str, Any]:
    """
    Search conversations by meaning, over the same Pinecone index the chat
    agent's `memory_search` tool uses.

    Ranking is semantic, so a query only has to describe what the user is
    looking for — it does not have to reuse their words. The previous
    implementation streamed every conversation and required *all* query terms to
    appear literally in title+overview, which made ordinary phrasings ("AI
    progress", "what did I decide about pricing") return nothing at all while
    reading the whole collection to do it.

    Falls back to the old substring scan when the semantic path cannot answer at
    all — embedding failure, or a user with no vectors yet (mock/imported data).
    Note this is a fallback on *unavailability*, not on result count: a non-empty
    semantic result is returned as-is even if the literal matcher would have
    found more.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        query: Search query text
        page: Page number (1-indexed)
        per_page: Results per page
        include_discarded: Include discarded conversations
        start_date: Filter by start date
        end_date: Filter by end date

    Returns:
        Search results with pagination info
    """
    semantic = _search_conversations_semantic(
        developer_id=developer_id,
        external_user_id=external_user_id,
        query=query,
        page=page,
        per_page=per_page,
        include_discarded=include_discarded,
        start_date=start_date,
        end_date=end_date,
    )
    if semantic is not None:
        return semantic

    return _search_conversations_substring(
        developer_id=developer_id,
        external_user_id=external_user_id,
        query=query,
        page=page,
        per_page=per_page,
        include_discarded=include_discarded,
        start_date=start_date,
        end_date=end_date,
    )


def _search_conversations_semantic(
    developer_id: str,
    external_user_id: str,
    query: str,
    page: int,
    per_page: int,
    include_discarded: bool = True,
    start_date: datetime = None,
    end_date: datetime = None,
) -> Optional[Dict[str, Any]]:
    """Rank conversations by embedding similarity.

    Returns None (not an empty result) when the semantic path cannot answer, so
    the caller can fall back instead of reporting "no matches".

    Relevance ranking is only meaningful as one ordered list, so the full ranked
    id list is resolved once and the page is sliced out of it — paging walks down
    that list instead of issuing an independent query per page. `total_pages` is
    therefore computed over the whole ranked set, not over one page's worth.
    """
    if not query or not query.strip():
        return None

    # Imported lazily: vector_db builds a Pinecone client at import time, and
    # developer_data is imported by paths with no Pinecone config.
    try:
        from database.vector_db import query_vectors_by_metadata
        from utils.llm.embeddings import generate_embedding_query
    except Exception as e:
        print(f"search_conversations: semantic path unavailable ({e}), using substring scan")
        return None

    try:
        vector = generate_embedding_query(query).values
    except Exception as e:
        print(f"search_conversations: embedding failed ({e}), using substring scan")
        return None

    # Ask for the whole ranked list, not just this page: `total_pages` has to
    # describe every match, otherwise a client paginating by it stops early and
    # can never reach deeper results. `query_vectors_by_metadata` already reads
    # the user's full namespace, so a large limit costs nothing extra there.
    try:
        ids = query_vectors_by_metadata(
            external_user_id,
            vector,
            dates_filter=[start_date, end_date],
            people=[],
            topics=[],
            entities=[],
            dates=[],
            limit=SEMANTIC_SEARCH_MAX_RANKED,
        )
    except Exception as e:
        print(f"search_conversations: vector query failed ({e}), using substring scan")
        return None

    if not ids:
        return None

    ranked = _load_conversations_ranked(
        developer_id, external_user_id, ids, include_discarded=include_discarded
    )
    if not ranked:
        return None

    total_items = len(ranked)
    start_idx = (max(1, page) - 1) * per_page
    return {
        "items": ranked[start_idx:start_idx + per_page],
        "total_pages": (total_items + per_page - 1) // per_page if total_items else 0,
        "current_page": page,
        "per_page": per_page,
    }


def _load_conversations_ranked(
    developer_id: str,
    external_user_id: str,
    conversation_ids: list,
    include_discarded: bool = True,
) -> List[Dict[str, Any]]:
    """Resolve ids to conversations, preserving the order they were given in.

    Like `get_conversations_by_ids`, but honours `include_discarded` — that
    function always drops discarded conversations, which is right for the chat
    agent but would silently ignore this endpoint's `include_discarded=True`.
    Ids with no surviving document (deleted since indexing) are skipped.
    """
    if not conversation_ids:
        return []
    user_ref = _get_user_ref(developer_id, external_user_id)
    conversations_ref = user_ref.collection('conversations')
    docs = db.get_all([conversations_ref.document(str(cid)) for cid in conversation_ids])

    by_id = {}
    for doc in docs:
        if not doc.exists:
            continue
        data = _prepare_conversation_for_read(
            doc.to_dict(), conv_ref=conversations_ref.document(doc.id)
        )
        if not data:
            continue
        if not include_discarded and data.get('discarded'):
            continue
        by_id[doc.id] = data

    return [by_id[str(cid)] for cid in conversation_ids if str(cid) in by_id]


def _search_conversations_substring(
    developer_id: str,
    external_user_id: str,
    query: str,
    page: int = 1,
    per_page: int = 10,
    include_discarded: bool = True,
    start_date: datetime = None,
    end_date: datetime = None,
) -> Dict[str, Any]:
    """Literal fallback: stream conversations and match all query terms.

    Kept as the safety net for users whose conversations are not in the vector
    index (mock/imported data) and for embedding outages.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_collection_ref = user_ref.collection("conversations")

    # Build base query with filters
    base_query = conv_collection_ref
    if not include_discarded:
        base_query = base_query.where(filter=FieldFilter("status", "!=", "discarded"))
    if start_date:
        base_query = base_query.where(filter=FieldFilter("created_at", ">=", start_date))
    if end_date:
        base_query = base_query.where(filter=FieldFilter("created_at", "<=", end_date))

    # Order by created_at descending
    base_query = base_query.order_by("created_at", direction=firestore.Query.DESCENDING)

    # Normalize query for case-insensitive search
    query_lower = query.lower().strip()
    query_terms = query_lower.split()

    # Fetch and filter conversations
    matching_conversations = []
    for doc in base_query.stream():
        conv = _prepare_conversation_for_read(doc.to_dict(), conv_ref=doc.reference)
        if not conv:
            continue

        # Get searchable text from structured data
        structured = conv.get("structured", {})
        title = (structured.get("title") or "").lower()
        overview = (structured.get("overview") or "").lower()
        searchable_text = f"{title} {overview}"

        # Check if all query terms match
        if all(term in searchable_text for term in query_terms):
            matching_conversations.append(conv)

    # Calculate pagination
    total_items = len(matching_conversations)
    total_pages = (total_items + per_page - 1) // per_page if total_items > 0 else 0
    start_idx = (page - 1) * per_page
    end_idx = start_idx + per_page

    # Slice results for current page
    page_items = matching_conversations[start_idx:end_idx]

    return {
        "items": page_items,
        "total_pages": total_pages,
        "current_page": page,
        "per_page": per_page,
    }


def delete_conversation(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
) -> bool:
    """
    Delete a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID

    Returns:
        True if deleted, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return False

    conv_ref.delete()
    # Resolution checks source existence, so deletion already invalidates the
    # capability. Cleanup failure must not prevent deleting the conversation.
    try:
        from utils.sharing.store import ShareStore
        ShareStore(db).delete_source(developer_id, external_user_id, conversation_id)
    except Exception:
        import logging
        logging.getLogger(__name__).warning('share_source_cleanup_failed')

    # Drop the embedding too. Leaving it behind makes the vector a zombie:
    # semantic search still returns its id, `get_conversations_by_ids` finds
    # nothing in Firestore, and the chat agent reports "no matching memories"
    # even though the index reported hits. Best-effort — a failure here must
    # not turn a successful delete into an error.
    # Imported here, not at module scope: vector_db builds a Pinecone client on
    # import, and developer_data is imported by paths that have no Pinecone
    # config at all.
    try:
        from database.vector_db import delete_vector

        delete_vector(external_user_id, conversation_id)
    except Exception as e:
        print(f"delete_conversation: failed to delete vector for {conversation_id}: {e}")

    return True


def add_transcript_segment(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    text: str,
    speaker_id: int = 0,
    start: float = 0.0,
    end: float = 0.0,
    is_user: bool = False,
    person_id: str = None,
) -> Optional[Dict[str, Any]]:
    """
    Add a transcript segment to a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        text: Segment text
        speaker_id: Speaker identifier
        start: Start time in seconds
        end: End time in seconds
        is_user: Whether this is the user speaking
        person_id: Person identifier

    Returns:
        The added segment or None if conversation not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    from models.transcript_segment import coerce_speaker_id

    segment = {
        "id": str(uuid.uuid4()),
        "text": text.strip() if isinstance(text, str) else text,
        "speaker_id": coerce_speaker_id(speaker_id),
        "start": start,
        "end": end,
        "is_user": is_user,
        "person_id": person_id,
    }

    conv_ref.update({
        "transcript_segments": firestore.ArrayUnion([segment]),
        "updated_at": datetime.now(timezone.utc),
    })

    return segment


def set_conversation_transcript_segments(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    segments: List[Dict[str, Any]],
) -> bool:
    """
    Bulk-write transcript segments to a conversation with compression and optional
    chunking to avoid Firestore's 1MB document size limit.

    This replaces the one-by-one add_transcript_segment approach for bulk writes.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return False

    # Normalize before persisting: speaker_id must be an int (API contract)
    # and text should not carry STT leading/trailing whitespace.
    _normalize_transcript_segments(segments)

    segments_json = json.dumps(segments)
    compressed_segments = zlib.compress(segments_json.encode('utf-8'))

    update_data = {"updated_at": datetime.now(timezone.utc)}

    max_inline_bytes = 500 * 1024  # 500KB threshold for inline storage
    if len(compressed_segments) > max_inline_bytes:
        chunk_size = 750 * 1024
        chunks = [compressed_segments[i:i + chunk_size] for i in range(0, len(compressed_segments), chunk_size)]
        chunks_ref = conv_ref.collection("transcript_chunks")
        for old_chunk in chunks_ref.stream():
            old_chunk.reference.delete()
        for idx, chunk in enumerate(chunks):
            chunks_ref.document(f"chunk_{idx:04d}").set({
                "data": chunk,
                "index": idx,
                "total_chunks": len(chunks),
            })
        update_data["transcript_segments_chunked"] = True
        update_data["transcript_segments_chunk_count"] = len(chunks)
        update_data["transcript_segments_compressed"] = True
        update_data["transcript_segments"] = []
        print(f"[set_conversation_segments] Stored {len(compressed_segments)} bytes in {len(chunks)} chunks for conversation {conversation_id}")
    else:
        update_data["transcript_segments"] = compressed_segments
        update_data["transcript_segments_compressed"] = True
        update_data["transcript_segments_chunked"] = False

    conv_ref.update(update_data)
    return True


def finish_conversation(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    title: str = None,
    overview: str = None,
    category: str = None,
    action_items: List[Dict[str, Any]] = None,
    emoji: str = None,
    discarded: bool = False,
    emotion: str = None,
    finished_at: datetime = None,
    first_person_observation: str = None,
    highlights: List[str] = None,
) -> Optional[Dict[str, Any]]:
    """
    Mark a conversation as finished and update structured data.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        title: Conversation title
        overview: Conversation overview/summary
        category: Conversation category
        action_items: List of action items
        finished_at: Actual conversation end time. When omitted, defaults to now
            (correct for the manual /finish endpoint). Callers that know the real
            end time — e.g. process pipelines that derive it from transcript span —
            should pass it explicitly so it reflects the true conversation length.

    Returns:
        Updated conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    now = datetime.now(timezone.utc)
    update_data = {
        "status": "completed",
        "finished_at": finished_at or now,
        "discarded": discarded,
        "updated_at": now,
    }

    if title is not None:
        update_data["structured.title"] = title
    if overview is not None:
        update_data["structured.overview"] = overview
    if category is not None:
        update_data["structured.category"] = category
    if action_items is not None:
        update_data["structured.action_items"] = action_items
    if emoji is not None:
        update_data["structured.emoji"] = emoji
    if emotion is not None:
        update_data["structured.emotion"] = emotion
    if first_person_observation is not None:
        update_data["structured.first_person_observation"] = first_person_observation
    if highlights is not None:
        update_data["structured.highlights"] = highlights

    conv_ref.update(update_data)

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


# ******************************************************
# **************** ACTION ITEMS ************************
# ******************************************************


def get_action_items(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
) -> Optional[List[Dict[str, Any]]]:
    """
    Get action items for a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID

    Returns:
        List of action items or None if conversation not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_data = conv_doc.to_dict()
    structured = conv_data.get("structured", {})
    return structured.get("action_items", [])


_ACTION_ITEM_FIELD_PATHS = ["structured.action_items", "structured.action_items_revoked"]

# How fresh a revocation has to be for `restore_revoked_action_items` to undo it.
# The only legitimate restore is "two voiceprint threads on the same processing run
# reached different conclusions", and those land seconds apart (2026-08-19: 56s).
# Anything older is a different generation of the conversation — see that function's
# docstring for the two ways a stale archive otherwise leaks back in.
REVOKED_RESTORE_MAX_AGE = timedelta(minutes=10)


def _revoked_recently_enough(archived: List[Dict[str, Any]], max_age: timedelta) -> bool:
    """Whether the newest `revoked_at` in the archive is within `max_age`.

    Missing/unparseable timestamps count as **too old**: entries archived before the
    soft delete shipped (2026-08-24) have no `revoked_at` at all, and reviving those
    blind is exactly what the freshness guard exists to prevent.
    """
    if max_age == timedelta.max:
        return True
    newest = None
    for it in archived:
        ts = it.get("revoked_at") if isinstance(it, dict) else None
        if not isinstance(ts, datetime):
            continue
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        if newest is None or ts > newest:
            newest = ts
    if newest is None:
        return False
    return (datetime.now(timezone.utc) - newest) <= max_age


def clear_action_items(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
) -> int:
    """Revoke every action item on a conversation. Returns how many were revoked.

    Used by the post-voiceprint gate: action items are now written on the request
    path (when `is_user` is still uniformly False) and only revoked once speaker
    identification proves the wearer barely spoke.

    Deliberately not `finish_conversation(action_items=[])` — that one also
    rewrites `status` and, worse, defaults `discarded` to False, so using it to
    edit one field would silently un-discard the conversation.

    ⚠️ **Soft delete: the items move to `structured.action_items_revoked`, they are
    not thrown away.** This used to be a hard delete, and that cost real to-dos
    twice over:

    * 2026-08-19, conversation 829f0366 — the gate revoked 2 items at 08:59:35 on
      175 uniformly-False segments; 56 seconds later the listen path's own
      voiceprint thread found the wearer had spoken 88/175 segments (52% of words)
      and restored the conversation. Nothing could restore the to-dos.
    * 2026-08-24, conversation 56313829 — revoked 46 seconds after the items were
      written and *already handed to the app*. The app's cached copy became a
      ghost card that no button could dismiss, because every PATCH/DELETE against
      it 404'd. See `restore_revoked_action_items`.

    The revoked copies live in a **sibling field, not a flag on the items**, on
    purpose: `action_items` is read in a dozen places (discover, pdp, insights,
    the chat agent's `todo_list`, the prompt serializers) and several of them
    address items positionally by index. A `revoked` flag left in the array would
    have to be honoured by every one of those readers — and each miss would
    silently resurrect a revoked to-do, or shift `item_idx` out from under the
    clients that address items by position.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    # Project: a bare get() pulls the whole conversation, including the inline
    # `transcript_segments_compressed` blob (up to ~1MB). Firestore bills by bytes
    # read and this function needs exactly two fields.
    conv_doc = conv_ref.get(field_paths=_ACTION_ITEM_FIELD_PATHS)

    if not conv_doc.exists:
        return 0

    structured = (conv_doc.to_dict() or {}).get("structured") or {}
    existing = structured.get("action_items") or []
    if not existing:
        return 0

    now = datetime.now(timezone.utc)
    # ⚠️ **Replaces the archive, does not append to it.** Appending looks safer and is
    # not: it accumulates across generations and the accumulation is unrecoverable
    # noise. Gate revokes [A,B] → user `/reprocess` regenerates [A',B'] → that pass
    # also misses the floor → append would archive [A,B,A',B'], and the next passing
    # voiceprint restores all four, two of them stale near-duplicates. Nothing in the
    # archive distinguishes the generations (`revoked_at` is bookkeeping, not a key).
    #
    # Replacing loses nothing: the only items dropped are ones a later `finish_
    # conversation` already superseded. And two voiceprint threads on the *same*
    # generation can't both archive — the first one empties `action_items`, so the
    # second returns on `if not existing` above.
    archived = [
        {**it, "revoked_at": now} if isinstance(it, dict) else {"description": str(it), "revoked_at": now}
        for it in existing
    ]

    conv_ref.update(
        {
            "structured.action_items": [],
            "structured.action_items_revoked": archived,
            "updated_at": now,
        }
    )
    return len(existing)


def restore_revoked_action_items(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    max_age: timedelta = REVOKED_RESTORE_MAX_AGE,
) -> List[Dict[str, Any]]:
    """Move recently-revoked action items back onto `action_items`. Returns them.

    The counterpart to `clear_action_items`. Two callers matter:

    * the gate itself, when a later voiceprint pass proves the wearer *did* speak
      enough — the 2026-08-19 case above, which used to be unrecoverable;
    * ops, for the same conversation after a user manually assigns segments
      (pass `max_age=timedelta.max` to bypass the freshness gate).

    Drops the `revoked_at` bookkeeping key so the restored dicts match what the
    `ActionItem` model expects. No-op when there is nothing fresh enough archived,
    so it is safe to call unconditionally.

    ⚠️ **Returns the items, not a count, because the caller has to write them back
    onto its in-memory `conversation` dict.** `_apply_action_item_dedupe` runs right
    after the gate and reads that dict; left stale it sees an empty list, bails on
    `len < 2`, and the restored items never get deduped at all — the revoking pass
    skipped dedupe for the same reason, so it would be *never*, not *again*.

    Two independent guards, because either one alone lets stale items back in:

    1. **`action_items` must be empty.** Something newer already owns that slot
       otherwise — gate revokes [A,B] → `/reprocess` regenerates [A',B'] → without
       this guard a later passing voiceprint stacks [A,B] on top, four
       near-duplicates.
    2. **The archive must be younger than `max_age`.** Guard 1 does not cover
       `/reprocess` that yields *zero* items: `finish_conversation` writes
       `action_items=[]` (it acts on `is not None`) and leaves the archive alone, so
       the array is empty again and [A,B] would come back — contradicting the newest
       summary, which concluded there are no to-dos. Freshness also shrinks the
       window in which a user's own rejection can be undone (see below). The only
       legitimate restore is "two voiceprint threads on the same processing run
       disagreed", and those land seconds apart (08-19: 56s).

    ⚠️ **Known residue, deliberately not fixed here:** inside `max_age`, a to-do the
    user explicitly rejected can still come back. Sequence: gate revokes → user taps
    「不是待办」→ DELETE 404s (nothing to delete server-side, the app just drops its
    copy) → the second voiceprint thread clears the floor → restore puts it back and
    the bubble card asks again. Nothing on the revoke/restore path records a client
    rejection. Fixing it properly means letting DELETE/PATCH act on the archive by
    `item_idx`, and that index is only unambiguous while `action_items` is still the
    array the client last read — `/reprocess` breaks that. Not worth the ambiguity
    for a window this narrow; the failure mode is one redundant question, not lost
    or wrong data.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get(field_paths=_ACTION_ITEM_FIELD_PATHS)

    if not conv_doc.exists:
        return []

    structured = (conv_doc.to_dict() or {}).get("structured") or {}
    archived = structured.get("action_items_revoked") or []
    if not archived or (structured.get("action_items") or []):
        return []
    if not _revoked_recently_enough(archived, max_age):
        # ⚠️ Must be logged. Refusing here leaves the items sitting in the archive
        # forever, and silence makes that outcome **indistinguishable from the old
        # hard delete** — the whole point of the soft delete is that someone can go
        # look. This line is the only trace that there is something to recover.
        print(
            f"[action-items] Declined to restore {len(archived)} revoked item(s) on "
            f"{conversation_id}: archive older than {max_age} (or missing revoked_at). "
            f"Still recoverable via restore_revoked_action_items(max_age=timedelta.max)"
        )
        return []

    restored = [
        {k: v for k, v in it.items() if k != "revoked_at"}
        for it in archived
        if isinstance(it, dict)
    ]
    if not restored:
        return []

    conv_ref.update(
        {
            "structured.action_items": restored,
            "structured.action_items_revoked": [],
            "updated_at": datetime.now(timezone.utc),
        }
    )
    return restored


def update_action_item(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    item_idx: int,
    description: str = None,
    completed: bool = None,
    confirmed: bool = None,
    due_date=None,
    due_hint: str = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a single action item.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        item_idx: Index of the action item
        description: New description (optional)
        completed: New completed status (optional)
        confirmed: New confirmed status (optional) — user accepted it as a to-do
        due_date: New deadline (optional) — only set when a specific date is known
        due_hint: New spoken timing hint (optional), e.g. "this week"

    Returns:
        Updated action item or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_data = conv_doc.to_dict()
    structured = conv_data.get("structured", {})
    action_items = structured.get("action_items", [])

    if item_idx < 0 or item_idx >= len(action_items):
        return None

    if description is not None:
        action_items[item_idx]["description"] = description
    if completed is not None:
        action_items[item_idx]["completed"] = completed
    if confirmed is not None:
        action_items[item_idx]["confirmed"] = confirmed
    if due_date is not None:
        action_items[item_idx]["due_date"] = due_date
    if due_hint is not None:
        action_items[item_idx]["due_hint"] = due_hint

    conv_ref.update({
        "structured.action_items": action_items,
        "updated_at": datetime.now(timezone.utc),
    })

    return action_items[item_idx]


def batch_update_action_items(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    updates: List[Dict[str, Any]],
) -> Optional[List[Dict[str, Any]]]:
    """
    Batch update action items.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        updates: List of {idx, description?, completed?}

    Returns:
        Updated action items list or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_data = conv_doc.to_dict()
    structured = conv_data.get("structured", {})
    action_items = structured.get("action_items", [])

    for update in updates:
        idx = update.get("idx")
        if idx is not None and 0 <= idx < len(action_items):
            if "description" in update:
                action_items[idx]["description"] = update["description"]
            if "completed" in update:
                action_items[idx]["completed"] = update["completed"]
            if "confirmed" in update:
                action_items[idx]["confirmed"] = update["confirmed"]
            if "due_date" in update:
                action_items[idx]["due_date"] = update["due_date"]
            if "due_hint" in update:
                action_items[idx]["due_hint"] = update["due_hint"]

    conv_ref.update({
        "structured.action_items": action_items,
        "updated_at": datetime.now(timezone.utc),
    })

    return action_items


def delete_action_item(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    item_idx: int,
) -> bool:
    """
    Delete an action item.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        item_idx: Index of the action item to delete

    Returns:
        True if deleted, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return False

    conv_data = conv_doc.to_dict()
    structured = conv_data.get("structured", {})
    action_items = structured.get("action_items", [])

    if item_idx < 0 or item_idx >= len(action_items):
        return False

    action_items.pop(item_idx)

    conv_ref.update({
        "structured.action_items": action_items,
        "updated_at": datetime.now(timezone.utc),
    })

    return True


def remove_action_items(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    item_indexes: List[int],
) -> int:
    """删掉一条对话上的多个待办，返回删掉的条数。

    刻意不是「循环调 `delete_action_item`」：那个函数按下标 pop，删掉第 1 条之后原来
    的第 3 条就变成了第 2 条，逐个删会删错目标。这里一次算完再写一次。
    """
    if not item_indexes:
        return 0
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()
    if not conv_doc.exists:
        return 0

    items = ((conv_doc.to_dict() or {}).get("structured") or {}).get("action_items") or []
    drop = {i for i in item_indexes if 0 <= i < len(items)}
    if not drop:
        return 0

    conv_ref.update(
        {
            "structured.action_items": [it for i, it in enumerate(items) if i not in drop],
            "updated_at": datetime.now(timezone.utc),
        }
    )
    return len(drop)


def add_action_item(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    description: str,
    completed: bool = False,
    due_date=None,
    due_hint: str = '',
) -> Optional[Dict[str, Any]]:
    """
    Add a new action item to a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        description: Action item description
        completed: Whether completed (default False)
        due_date: Deadline (optional) — only when a specific date is known
        due_hint: Timing as spoken (optional), e.g. "this week"

    Returns:
        The added action item or None if conversation not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    action_item = {
        "description": description,
        "completed": completed,
        # 手动添加的待办没有「待确认」环节——加进来就是用户自己要的。
        "confirmed": True,
        "due_date": due_date,
        "due_hint": due_hint,
    }

    conv_data = conv_doc.to_dict()
    structured = conv_data.get("structured", {})
    action_items = structured.get("action_items", [])
    action_items.append(action_item)

    conv_ref.update({
        "structured.action_items": action_items,
        "updated_at": datetime.now(timezone.utc),
    })

    return action_item


# ******************************************************
# ******************** PEOPLE **************************
# ******************************************************


# 一个 Person 是怎么来的。**这是 provenance，不是用户数据**，所以放顶层字段而不是
# metadata（metadata 是对外自由字典，会被 PATCH 覆盖）。
#
# 为什么必须有：2026-08-12 之前一个字段都没写，833 个人的 metadata 全是空的 —— 要分辨
# 「真说话人」和「只是被提到过的名字」只能去扫 GCS 样本 + 20 万条段落做考古
# （见 scripts/diagnose_auto_created_people.py）。
PERSON_SOURCE_SPEAKER_MAPPING = "speaker_mapping"  # LLM 从转录稿里认出他是某个 speaker
PERSON_SOURCE_MENTION = "mention"  # 只是在对话里被提到过，从没说过话
PERSON_SOURCE_MANUAL = "manual"  # 用户自己建的 / 手动标记说话人时建的


def create_person(
    developer_id: str,
    external_user_id: str,
    name: str,
    metadata: Dict[str, Any] = None,
    source: str = None,
) -> Dict[str, Any]:
    """
    Create a person/contact for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        name: Person's name
        metadata: Additional metadata
        source: Provenance — one of PERSON_SOURCE_*. 缺省只在老调用点上出现，
                查询时按「缺字段 = 未知」处理，绝不当成 mention。

    Returns:
        The created person document
    """
    _ensure_user_exists(developer_id, external_user_id)

    person_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    person_data = {
        "id": person_id,
        "name": name,
        "metadata": metadata or {},
        "created_at": now,
        "updated_at": now,
    }
    if source:
        person_data["source"] = source

    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    person_ref.set(person_data)

    return person_data


def create_chapter_person(developer_id: str, external_user_id: str, person_id: str, name: str) -> Dict[str, Any]:
    """Create the explicitly requested person once, without merging namesakes."""
    _ensure_user_exists(developer_id, external_user_id)
    now = datetime.now(timezone.utc)
    data = {'id': person_id, 'name': name, 'source': 'manual', 'metadata': {},
            'created_at': now, 'updated_at': now}
    ref = _get_user_ref(developer_id, external_user_id).collection('people').document(person_id)
    try:
        ref.create(data)
    except AlreadyExists:
        data = ref.get().to_dict()
        if not data or data.get('deleted') or data.get('name') != name:
            raise ValueError('Person creation changed; reopen the picker')
    return data


def get_people(
    developer_id: str,
    external_user_id: str,
    limit: int = 100,
    offset: int = 0,
    include_deleted: bool = False,
    include_mentions: bool = True,
) -> List[Dict[str, Any]]:
    """
    Get people/contacts for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum number of people to return
        offset: Number of people to skip
        include_deleted: 含软删除的（deleted=True）。⚠️ **按名字去重的调用点必须传 True**，
            否则被归档的人会被下一条对话重新建出来，归档白做。
        include_mentions: 含 source='mention' 的（只被提到、从没说过话）。
            列表界面要 False —— 833 个名字里只有 31 个真说过话。

    Returns:
        List of person documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    people_ref = user_ref.collection("people")

    people_ref = people_ref.order_by("created_at", direction=firestore.Query.DESCENDING)

    # 分页在代码层做，和 get_memories 一样，理由也一样：要丢掉的两类文档都没法用
    # Firestore where 表达 —— `deleted` / `source` 都是后加的字段，缺字段的老文档不匹配
    # 任何 == 过滤，用 where 会把它们全部漏掉（而老文档正是这里的大多数）。
    # 先 limit 再过滤的话，一页 100 条会变成「100 条原始文档里的少数幸存者」。
    fetch_limit = offset + limit
    kept: List[Dict[str, Any]] = []
    for doc in people_ref.stream():
        data = doc.to_dict() or {}
        if not include_deleted and data.get("deleted"):
            continue
        # 缺 source 的老文档一律保留：未知 ≠ mention。存量那 802 个是靠 deleted 排掉的，
        # 不是靠这一条 —— 谁只是被提到过，事后无法从文档本身重建。
        if not include_mentions and data.get("source") == PERSON_SOURCE_MENTION:
            continue
        kept.append(data)
        if len(kept) >= fetch_limit:
            break

    return kept[offset:]


def get_people_name_index(
    developer_id: str,
    external_user_id: str,
) -> Dict[str, Dict[str, Any]]:
    """按小写名字索引**整个** people 集合，给去重用。返回 {name_lower: {id, deleted, source}}。

    ⚠️ 存在的理由是 `get_people(limit=1000)` 那种去重是错的，而且错法是静默的：
    `get_people` 按 created_at DESC 排序后截断，超过 limit 时**最老的那批掉出去** ——
    于是老名字重新变成「不存在」，同一个人被反复建出来。实测某账号已经 833 人，离 1000
    只差 167。这里不排序、不截断、只 select 三个字段，全集合永远是准的。

    ⚠️ 含软删除的。归档过的名字必须仍然「已存在」，否则下一条对话又把它建回来。
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = user_ref.collection("people").select(["id", "name", "deleted", "source"])

    index: Dict[str, Dict[str, Any]] = {}
    for doc in query.stream():
        data = doc.to_dict() or {}
        name = (data.get("name") or "").strip().lower()
        if not name:
            continue
        # 同名多条时保留「最像真人」的那条：没删的优先，其次不是 mention 的。
        prev = index.get(name)
        if prev is not None:
            prev_rank = (bool(prev.get("deleted")), prev.get("source") == PERSON_SOURCE_MENTION)
            new_rank = (bool(data.get("deleted")), data.get("source") == PERSON_SOURCE_MENTION)
            if new_rank >= prev_rank:
                continue
        index[name] = {
            "id": data.get("id") or doc.id,
            "deleted": bool(data.get("deleted")),
            "source": data.get("source"),
        }
    return index


def soft_delete_person(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    reason: str = None,
) -> bool:
    """归档一个人物（可回滚）。声纹样本一条不动 —— 归档的判据本来就是「没有样本」。"""
    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    if not person_ref.get().exists:
        return False

    person_ref.update({
        "deleted": True,
        "deleted_at": datetime.now(timezone.utc),
        "deleted_reason": reason or "",
        "updated_at": datetime.now(timezone.utc),
    })
    return True


def restore_person(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    source: str = None,
) -> Optional[Dict[str, Any]]:
    """撤销归档。`source` 给「被提到的人后来真说话了」这种升级用。"""
    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    if not person_ref.get().exists:
        return None

    update_data = {
        "deleted": False,
        "deleted_at": None,
        "deleted_reason": None,
        "updated_at": datetime.now(timezone.utc),
    }
    if source:
        update_data["source"] = source
    person_ref.update(update_data)
    return person_ref.get().to_dict()


def get_people_by_ids(
    developer_id: str,
    external_user_id: str,
    person_ids: list,
) -> List[Dict[str, Any]]:
    """Get multiple people by their IDs.

    ⚠️ **刻意不过滤软删除的**，和 `get_people` 相反。这条路是「段落上挂着 person_id，
    把名字取回来显示」，归档只是不该出现在**名单**里，不代表历史转录稿要退回 Speaker N。
    """
    if not person_ids:
        return []
    user_ref = _get_user_ref(developer_id, external_user_id)
    people_ref = user_ref.collection("people")
    all_people = []
    for i in range(0, len(person_ids), 30):
        chunk_ids = person_ids[i : i + 30]
        query = people_ref.where("id", "in", chunk_ids)
        all_people.extend([doc.to_dict() for doc in query.stream()])
    return all_people


def get_person(
    developer_id: str,
    external_user_id: str,
    person_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a single person by ID.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        person_id: The person's ID

    Returns:
        Person document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    person_doc = person_ref.get()

    if not person_doc.exists:
        return None

    return person_doc.to_dict()


def update_person(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    name: str = None,
    metadata: Dict[str, Any] = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a person.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        person_id: The person's ID
        name: New name (optional)
        metadata: New metadata (optional, merged)

    Returns:
        Updated person document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    person_doc = person_ref.get()

    if not person_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if name is not None:
        update_data["name"] = name
    if metadata is not None:
        existing_data = person_doc.to_dict()
        existing_metadata = existing_data.get("metadata", {})
        existing_metadata.update(metadata)
        update_data["metadata"] = existing_metadata

    person_ref.update(update_data)

    return person_ref.get().to_dict()


def delete_person(
    developer_id: str,
    external_user_id: str,
    person_id: str,
) -> bool:
    """
    Delete a person.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        person_id: The person's ID

    Returns:
        True if deleted, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    person_doc = person_ref.get()

    if not person_doc.exists:
        return False

    person_ref.delete()
    return True


# ******************************************************
# ****************** VOCABULARY ************************
# ******************************************************


def create_vocabulary_entry(
    developer_id: str,
    external_user_id: str,
    term: str,
    metadata: Dict[str, Any] = None,
) -> Dict[str, Any]:
    """
    Create a vocabulary entry (custom term) for a user.

    If an entry with the same (trimmed, exact-match) term already exists,
    the existing entry is returned instead of inserting a duplicate.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        term: The vocabulary term/word
        metadata: Additional metadata

    Returns:
        The created (or existing) vocabulary document
    """
    _ensure_user_exists(developer_id, external_user_id)

    user_ref = _get_user_ref(developer_id, external_user_id)
    vocab_col = user_ref.collection("vocabulary")

    # De-dupe: same term (trimmed) → return existing entry, don't insert a duplicate.
    normalized = term.strip()
    existing = vocab_col.where(filter=FieldFilter("term", "==", normalized)).limit(1).stream()
    for doc in existing:
        return doc.to_dict()

    entry_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    entry_data = {
        "id": entry_id,
        "term": normalized,
        "metadata": metadata or {},
        "created_at": now,
        "updated_at": now,
    }

    vocab_col.document(entry_id).set(entry_data)

    return entry_data


def get_vocabulary(
    developer_id: str,
    external_user_id: str,
    limit: int = 100,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    Get vocabulary entries for a user (newest first).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum number of entries to return
        offset: Number of entries to skip

    Returns:
        List of vocabulary documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    vocab_ref = user_ref.collection("vocabulary")

    vocab_ref = (
        vocab_ref.order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [doc.to_dict() for doc in vocab_ref.stream()]


def get_vocabulary_terms(
    developer_id: str,
    external_user_id: str,
    limit: int = 200,
) -> List[str]:
    """Return just the term strings for a user (newest first), best-effort.

    Used by the summary pipeline to inject the user's custom vocabulary as a
    proper-noun correction hint. Never raises: a read failure here must not
    block conversation processing — it just yields no correction hint.
    """
    if not developer_id or not external_user_id:
        return []
    try:
        entries = get_vocabulary(developer_id, external_user_id, limit=limit, offset=0)
        return [t for t in (e.get("term") for e in entries) if t]
    except Exception as e:
        print(f"[vocabulary] get_vocabulary_terms failed ({e}); skipping hint")
        return []


def get_vocabulary_entry(
    developer_id: str,
    external_user_id: str,
    entry_id: str,
) -> Optional[Dict[str, Any]]:
    """Get a single vocabulary entry by ID."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    entry_ref = user_ref.collection("vocabulary").document(entry_id)
    entry_doc = entry_ref.get()

    if not entry_doc.exists:
        return None

    return entry_doc.to_dict()


def update_vocabulary_entry(
    developer_id: str,
    external_user_id: str,
    entry_id: str,
    term: str = None,
    metadata: Dict[str, Any] = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a vocabulary entry.

    Note: the frontend does not expose an edit UI yet (Phase 0 is add/list/delete
    only), but the backend supports update so a future "edit term" feature needs
    no backend change.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        entry_id: The entry's ID
        term: New term (optional)
        metadata: New metadata (optional, merged)

    Returns:
        Updated vocabulary document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    entry_ref = user_ref.collection("vocabulary").document(entry_id)
    entry_doc = entry_ref.get()

    if not entry_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if term is not None:
        update_data["term"] = term.strip()
    if metadata is not None:
        existing_data = entry_doc.to_dict()
        existing_metadata = existing_data.get("metadata", {})
        existing_metadata.update(metadata)
        update_data["metadata"] = existing_metadata

    entry_ref.update(update_data)

    return entry_ref.get().to_dict()


def delete_vocabulary_entry(
    developer_id: str,
    external_user_id: str,
    entry_id: str,
) -> bool:
    """
    Delete a vocabulary entry.

    Returns:
        True if deleted, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    entry_ref = user_ref.collection("vocabulary").document(entry_id)
    entry_doc = entry_ref.get()

    if not entry_doc.exists:
        return False

    entry_ref.delete()
    return True


def _clamp_speech_samples_duration(ref) -> None:
    """Floor ``speech_samples_duration`` at zero after a negative increment.

    Separate follow-up read rather than a transaction: the counter is reported to
    the user, never used to gate anything, so an atomic read-modify-write buys
    nothing over keeping the increment itself atomic and tidying up after.
    """
    try:
        snapshot = ref.get()
        current = (snapshot.to_dict() or {}).get("speech_samples_duration")
        if isinstance(current, (int, float)) and current < 0:
            ref.update({"speech_samples_duration": 0.0})
    except Exception as e:
        print(f"[DEV_DATA] Could not clamp speech_samples_duration: {e}")


def set_person_speech_samples_duration(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    seconds: float,
) -> None:
    """Overwrite a person's speech_samples_duration outright.

    For wholesale revocation, where the increment counterpart cannot be used:
    samples collected before provenance existed carry no per-sample duration, so
    there is nothing to subtract — only the new total is known (usually zero).
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.collection("people").document(person_id).update({
        "speech_samples_duration": float(seconds),
        "updated_at": datetime.now(timezone.utc),
    })


def set_speech_samples_duration(
    developer_id: str,
    external_user_id: str,
    seconds: float,
) -> None:
    """Overwrite a user's speech_samples_duration outright.

    See ``set_person_speech_samples_duration``. Note this counts only collected
    samples, never the onboarding recording, so zeroing it does not claim the user
    has no speech profile.
    """
    _get_user_ref(developer_id, external_user_id).update({
        "speech_samples_duration": float(seconds),
        "updated_at": datetime.now(timezone.utc),
    })


def increment_person_speech_samples_duration(
    developer_id: str,
    external_user_id: str,
    person_id: str,
    added_seconds: float,
    clamp_at_zero: bool = False,
) -> None:
    """Atomically increment a person's speech_samples_duration field.

    ``added_seconds`` may be negative — revoking a sample takes its seconds back
    out. Pass ``clamp_at_zero`` then: samples collected before provenance existed
    were counted up but cannot be revoked individually, so the total and the
    revokable audio do not reconcile and the field can otherwise go negative.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    person_ref = user_ref.collection("people").document(person_id)
    person_ref.update({
        "speech_samples_duration": firestore.Increment(added_seconds),
        "updated_at": datetime.now(timezone.utc),
    })
    if clamp_at_zero:
        _clamp_speech_samples_duration(person_ref)


def increment_speech_samples_duration(
    developer_id: str,
    external_user_id: str,
    added_seconds: float,
    clamp_at_zero: bool = False,
) -> None:
    """Atomically increment a user's speech_samples_duration field (for is_user profiles).

    See ``increment_person_speech_samples_duration`` for ``clamp_at_zero``.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.update({
        "speech_samples_duration": firestore.Increment(added_seconds),
        "updated_at": datetime.now(timezone.utc),
    })
    if clamp_at_zero:
        _clamp_speech_samples_duration(user_ref)


# ******************************************************
# ********************* USAGE **************************
# ******************************************************


def get_usage_stats(
    developer_id: str,
    external_user_id: str = None,
) -> Dict[str, Any]:
    """
    Get usage statistics for a developer or specific user.

    Args:
        developer_id: The developer's ID
        external_user_id: Optional user ID to get stats for specific user

    Returns:
        Dictionary with usage statistics
    """
    developer_ref = db.collection("developer_data").document(developer_id)

    if external_user_id:
        # Get stats for specific user
        user_ref = _get_user_ref(developer_id, external_user_id)

        memories_count = len(list(user_ref.collection("memories").limit(1000).stream()))
        conversations_count = len(list(user_ref.collection("conversations").limit(1000).stream()))
        people_count = len(list(user_ref.collection("people").limit(1000).stream()))
        facts_count = len(list(user_ref.collection("facts").limit(1000).stream()))

        return {
            "external_user_id": external_user_id,
            "memories_count": memories_count,
            "conversations_count": conversations_count,
            "people_count": people_count,
            "facts_count": facts_count,
            "total_items": memories_count + conversations_count + people_count + facts_count,
        }
    else:
        # Get aggregate stats for all users
        users_ref = developer_ref.collection("users")
        users = list(users_ref.stream())

        total_memories = 0
        total_conversations = 0
        total_people = 0
        total_facts = 0
        user_count = len(users)

        for user_doc in users:
            user_ref = users_ref.document(user_doc.id)
            total_memories += len(list(user_ref.collection("memories").limit(1000).stream()))
            total_conversations += len(list(user_ref.collection("conversations").limit(1000).stream()))
            total_people += len(list(user_ref.collection("people").limit(1000).stream()))
            total_facts += len(list(user_ref.collection("facts").limit(1000).stream()))

        return {
            "user_count": user_count,
            "memories_count": total_memories,
            "conversations_count": total_conversations,
            "people_count": total_people,
            "facts_count": total_facts,
            "total_items": total_memories + total_conversations + total_people + total_facts,
        }


def get_users_list(
    developer_id: str,
    limit: int = 100,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    Get list of users for a developer.

    Args:
        developer_id: The developer's ID
        limit: Maximum users to return
        offset: Number to skip

    Returns:
        List of user documents
    """
    developer_ref = db.collection("developer_data").document(developer_id)
    users_ref = developer_ref.collection("users")

    users_ref = (
        users_ref.order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [doc.to_dict() for doc in users_ref.stream()]


# ******************************************************
# ************ V2 CHAT (FLAT MESSAGES) *****************
# ******************************************************


def add_v2_message(developer_id: str, external_user_id: str, message_data: dict):
    if 'memories' in message_data:
        del message_data['memories']
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.collection('messages').add(message_data)
    return message_data


def get_v2_messages(
    developer_id: str,
    external_user_id: str,
    limit: int = 20,
    offset: int = 0,
    include_conversations: bool = False,
    app_id: Optional[str] = None,
    chat_session_id: Optional[str] = None,
    chat_session_ids: Optional[List[str]] = None,
):
    user_ref = _get_user_ref(developer_id, external_user_id)
    messages_ref = user_ref.collection('messages')
    if chat_session_id:
        messages_ref = messages_ref.where(filter=FieldFilter('chat_session_id', '==', chat_session_id))
    else:
        messages_ref = messages_ref.where(filter=FieldFilter('plugin_id', '==', app_id))

    raw_messages = []
    conversations_id = set()
    files_id = set()

    if chat_session_ids is not None:
        # Firestore supports up to 30 values in a single IN filter. Query only
        # the shared/default and former chapter sessions, within this tenant.
        ids = list(dict.fromkeys(chat_session_ids))
        documents = (doc for start in range(0, len(ids), 30)
                     for doc in user_ref.collection('messages').where(
                         filter=FieldFilter('chat_session_id', 'in', ids[start:start + 30])).stream())
    else:
        documents = messages_ref.stream()
    for doc in documents:
        message = doc.to_dict()
        if (chat_session_id or chat_session_ids is not None) and message.get('plugin_id') != app_id:
            continue
        if message.get('reported') is True:
            continue
        raw_messages.append(message)

    raw_messages.sort(key=lambda m: m.get('created_at') or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    messages = raw_messages[offset:offset + limit]

    for message in messages:
        conversations_id.update(message.get('memories_id', []))
        files_id.update(message.get('files_id', []))

    if not include_conversations:
        return messages

    conversations = {}
    conversations_ref = user_ref.collection('conversations')
    doc_refs = [conversations_ref.document(str(cid)) for cid in conversations_id]
    if doc_refs:
        docs = db.get_all(doc_refs)
        for doc in docs:
            if doc.exists:
                conversation = doc.to_dict()
                conversations[conversation['id']] = conversation

    for message in messages:
        message['memories'] = [
            conversations[cid]
            for cid in message.get('memories_id', [])
            if cid in conversations
        ]

    files = {}
    files_ref = user_ref.collection('files')
    file_doc_refs = [files_ref.document(str(fid)) for fid in files_id]
    if file_doc_refs:
        doc_files = db.get_all(file_doc_refs)
        for doc in doc_files:
            if doc.exists:
                file = doc.to_dict()
                files[file['id']] = file

    for message in messages:
        message['files'] = [files[fid] for fid in message.get('files_id', []) if fid in files]

    return messages


def get_v2_message(developer_id: str, external_user_id: str, message_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    message_ref = user_ref.collection('messages').where('id', '==', message_id).limit(1).stream()
    message_doc = next(message_ref, None)
    if not message_doc:
        return None, None
    return message_doc.to_dict(), message_doc.id


def report_v2_message(developer_id: str, external_user_id: str, msg_doc_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    message_ref = user_ref.collection('messages').document(msg_doc_id)
    message_ref.update({'reported': True})


def report_conversation(developer_id: str, external_user_id: str, conversation_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection('conversations').document(conversation_id)
    conv_ref.update({'reported': True})


def clear_v2_chat(developer_id: str, external_user_id: str, app_id: Optional[str] = None, chat_session_id: Optional[str] = None):
    user_ref = _get_user_ref(developer_id, external_user_id)
    messages_ref = user_ref.collection('messages')
    if chat_session_id:
        messages_ref = messages_ref.where(filter=FieldFilter('chat_session_id', '==', chat_session_id))
    else:
        messages_ref = messages_ref.where(filter=FieldFilter('plugin_id', '==', app_id))

    batch_size = 450
    while True:
        docs_list = list(messages_ref.limit(batch_size).stream())
        if not docs_list:
            break
        batch = db.batch()
        for doc in docs_list:
            batch.delete(doc.reference)
        batch.commit()
        if len(docs_list) < batch_size:
            break


def add_v2_chat_session(developer_id: str, external_user_id: str, chat_session_data: dict):
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection('v2_chat_sessions').document(chat_session_data['id'])
    session_ref.set(chat_session_data)
    return chat_session_data


def get_v2_chat_session(developer_id: str, external_user_id: str, app_id: Optional[str] = None):
    user_ref = _get_user_ref(developer_id, external_user_id)
    sessions_ref = user_ref.collection('v2_chat_sessions')
    docs = list(sessions_ref.stream())
    if docs:
        sessions = [doc.to_dict() for doc in docs if doc.to_dict().get('plugin_id') == app_id
                    and not doc.to_dict().get('context_conversation_ids')]
        sessions.sort(key=lambda s: s.get('created_at') or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
        return sessions[0] if sessions else None
    return None


def get_v2_chat_session_by_id(developer_id: str, external_user_id: str, session_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection('v2_chat_sessions').document(session_id)
    doc = session_ref.get()
    if doc.exists:
        return doc.to_dict()
    return None


def get_v2_chat_sessions(developer_id: str, external_user_id: str, app_id: Optional[str] = None):
    user_ref = _get_user_ref(developer_id, external_user_id)
    sessions_ref = user_ref.collection('v2_chat_sessions')
    sessions = [doc.to_dict() for doc in sessions_ref.stream()]
    sessions = [session for session in sessions if session.get('plugin_id') == app_id]
    sessions.sort(key=lambda s: s.get('created_at') or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return sessions


def create_v2_chat_session(developer_id: str, external_user_id: str, app_id: Optional[str] = None, title: Optional[str] = None):
    now = datetime.now(timezone.utc)
    session_data = {
        'id': str(uuid.uuid4()),
        'plugin_id': app_id,
        'app_id': app_id,
        'title': title or 'New Chat',
        'created_at': now,
        'updated_at': now,
        'message_ids': [],
    }
    return add_v2_chat_session(developer_id, external_user_id, session_data)


def update_v2_chat_session_title(developer_id: str, external_user_id: str, session_id: str, title: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection('v2_chat_sessions').document(session_id)
    session_ref.update({'title': title, 'updated_at': datetime.now(timezone.utc)})


def delete_v2_chat_session(developer_id: str, external_user_id: str, session_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection('v2_chat_sessions').document(session_id)
    session_ref.delete()


def add_v2_message_to_chat_session(developer_id: str, external_user_id: str, session_id: str, message_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection('v2_chat_sessions').document(session_id)
    session_ref.update({
        'message_ids': firestore.ArrayUnion([message_id]),
        'updated_at': datetime.now(timezone.utc),
    })


def get_conversations_by_ids(developer_id: str, external_user_id: str, conversation_ids: list):
    if not conversation_ids:
        return []
    user_ref = _get_user_ref(developer_id, external_user_id)
    conversations_ref = user_ref.collection('conversations')
    doc_refs = [conversations_ref.document(str(cid)) for cid in conversation_ids]
    docs = db.get_all(doc_refs)

    # `db.get_all` makes no ordering guarantee — it returns documents in
    # whatever order the batch resolves. Both callers pass ids ranked by
    # retrieval relevance, so returning them unordered silently discards that
    # ranking: the most relevant conversation ends up wherever Firestore put
    # it, and the answer is built from a list whose order means nothing.
    by_id = {}
    for doc in docs:
        if doc.exists:
            data = _prepare_conversation_for_read(doc.to_dict(), conv_ref=conversations_ref.document(doc.id))
            if not data or data.get('discarded'):
                continue
            by_id[doc.id] = data

    return [by_id[str(cid)] for cid in conversation_ids if str(cid) in by_id]


def get_user_time_zone(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict().get('time_zone')
    return None


def set_user_time_zone(developer_id: str, external_user_id: str, timezone_str: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({'time_zone': timezone_str})


def get_user_fcm_token(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict().get('fcm_token')
    return None


def set_user_fcm_token(developer_id: str, external_user_id: str, token: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({'fcm_token': token})


def set_user_geolocation(developer_id: str, external_user_id: str, geolocation: dict):
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({'geolocation': geolocation})


def set_user_name(developer_id: str, external_user_id: str, name: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({'name': name})


def get_user_name(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict().get('name')
    return None


def set_user_birthday(developer_id: str, external_user_id: str, birthday: str):
    # birthday: 'YYYY-MM-DD'
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({'birthday': birthday})


def get_user_birthday(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict().get('birthday')
    return None


def get_user_profile(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict()
    return None

def get_user_geolocation(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict().get('geolocation')
    return None


# Fields a caller is allowed to write through the generic set_user_field helper.
# Keeping this explicit prevents field injection (e.g. overwriting role /
# permissions) if user-supplied input ever reaches this function.
_SETTABLE_USER_FIELDS = frozenset({
    'language',
    'timezone',
    'time_zone',
    'geolocation',
    'name',
    'given_name',
    'weather_card',
    'mood_pixel_state',
    'home_updates_prefs',
    'pdp_prefs',
})


def set_user_field(developer_id: str, external_user_id: str, field_name: str, value: Any):
    if field_name not in _SETTABLE_USER_FIELDS:
        raise ValueError(f'set_user_field: field "{field_name}" is not allowed')
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({
        field_name: value,
        'updated_at': datetime.now(timezone.utc),
    })


def get_user_recording_paths(developer_id: str, external_user_id: str):
    """Yield exact object names supported by this user's recording metadata."""
    user = _get_user_ref(developer_id, external_user_id)
    live_prefix = f"dev_{developer_id}_{external_user_id}"
    for doc in user.collection("listen_sessions").select(["audio_path"]).stream():
        live_path = f"{live_prefix}/{doc.id}.wav"
        if doc.to_dict().get("audio_path") == live_path:
            yield live_path
    for doc in user.collection("conversations").select(["audio_path"]).stream():
        upload_path = f"{external_user_id}/{doc.id}.wav"
        if doc.to_dict().get("audio_path") == upload_path:
            yield upload_path


def delete_user_data(developer_id: str, external_user_id: str):
    from utils.sharing.store import ShareStore
    ShareStore(db).delete_owner(developer_id, external_user_id)
    from utils.audio_jobs.cleanup import delete_owner_jobs
    delete_owner_jobs(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if not doc.exists:
        return

    # Enumerate subcollections instead of hardcoding names. Firestore does not
    # cascade deletes, so anything missed here outlives the account as orphaned
    # data — which is exactly what happened to `calendar_events` while this list
    # was static. Every new subcollection is now covered automatically.
    for subcol_ref in user_ref.collections():
        batch_size = 450
        while True:
            docs_list = list(subcol_ref.limit(batch_size).stream())
            if not docs_list:
                break
            batch = db.batch()
            for d in docs_list:
                batch.delete(d.reference)
            batch.commit()
            if len(docs_list) < batch_size:
                break

    user_ref.delete()


def store_recording_permission(developer_id: str, external_user_id: str, recording_permission: dict):
    user_ref = _get_user_ref(developer_id, external_user_id)
    _ensure_user_exists(developer_id, external_user_id)
    user_ref.update({'recording_permission': recording_permission})


def get_recording_permission(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if doc.exists:
        return doc.to_dict().get('recording_permission')
    return None


def delete_recording_permission(developer_id: str, external_user_id: str):
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.update({'recording_permission': firestore.DELETE_FIELD})


# ******************************************************
# ************** TRANSCRIPTION TASKS *******************
# ******************************************************


def create_transcription_task(
    developer_id: str,
    external_user_id: str,
    language: str = "en",
    metadata: Dict[str, Any] = None,
) -> Dict[str, Any]:
    """
    Create a transcription task for tracking async audio processing.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        language: Language code
        metadata: Additional metadata

    Returns:
        The created task document
    """
    _ensure_user_exists(developer_id, external_user_id)

    task_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    task_data = {
        "id": task_id,
        "status": "pending",  # pending, processing, completed, failed, cancelled
        "language": language,
        "transcript_segments": [],
        "duration_seconds": 0.0,
        "error": None,
        "metadata": metadata or {},
        "created_at": now,
        "updated_at": now,
    }

    user_ref = _get_user_ref(developer_id, external_user_id)
    task_ref = user_ref.collection("transcription_tasks").document(task_id)
    task_ref.set(task_data)

    return task_data


def get_transcription_task(
    developer_id: str,
    external_user_id: str,
    task_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a transcription task by ID.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        task_id: The task's ID

    Returns:
        Task document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    task_ref = user_ref.collection("transcription_tasks").document(task_id)
    task_doc = task_ref.get()

    if not task_doc.exists:
        return None

    return task_doc.to_dict()


def update_transcription_task(
    developer_id: str,
    external_user_id: str,
    task_id: str,
    status: str = None,
    transcript_segments: List[Dict[str, Any]] = None,
    duration_seconds: float = None,
    error: str = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a transcription task.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        task_id: The task's ID
        status: New status
        transcript_segments: Transcript segments
        duration_seconds: Audio duration
        error: Error message if failed

    Returns:
        Updated task or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    task_ref = user_ref.collection("transcription_tasks").document(task_id)
    task_doc = task_ref.get()

    if not task_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if status is not None:
        update_data["status"] = status
    if transcript_segments is not None:
        update_data["transcript_segments"] = transcript_segments
    if duration_seconds is not None:
        update_data["duration_seconds"] = duration_seconds
    if error is not None:
        update_data["error"] = error

    task_ref.update(update_data)

    return task_ref.get().to_dict()


def get_transcription_tasks(
    developer_id: str,
    external_user_id: str,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    Get transcription tasks for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum tasks to return
        offset: Number to skip

    Returns:
        List of task documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    tasks_ref = user_ref.collection("transcription_tasks")

    tasks_ref = (
        tasks_ref.order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [doc.to_dict() for doc in tasks_ref.stream()]


# ******************************************************
# ************** LISTEN SESSIONS ***********************
# ******************************************************


def create_listen_session(
    developer_id: str,
    external_user_id: str,
    language: str = "en",
    stt_service: str = "deepgram",
    metadata: Dict[str, Any] = None,
) -> Dict[str, Any]:
    """
    Create a real-time listening session.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        language: Language code
        stt_service: STT service name (deepgram, soniox)
        metadata: Additional metadata

    Returns:
        The created session document
    """
    _ensure_user_exists(developer_id, external_user_id)

    session_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    session_data = {
        "id": session_id,
        "status": "pending",  # pending, active, completed, failed
        "language": language,
        "stt_service": stt_service,
        "transcript_segments": [],
        "duration_seconds": 0.0,
        "error": None,
        "metadata": metadata or {},
        "created_at": now,
        "updated_at": now,
    }

    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection("listen_sessions").document(session_id)
    session_ref.set(session_data)

    return session_data


def get_listen_session(
    developer_id: str,
    external_user_id: str,
    session_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a listening session by ID.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        session_id: The session's ID

    Returns:
        Session document or None if not found (with transcript_segments decompressed)
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection("listen_sessions").document(session_id)
    session_doc = session_ref.get()

    if not session_doc.exists:
        return None

    return _prepare_listen_session_for_read(session_doc.to_dict(), session_ref=session_ref)


def update_listen_session(
    developer_id: str,
    external_user_id: str,
    session_id: str,
    status: str = None,
    transcript_segments: List[Dict[str, Any]] = None,
    duration_seconds: float = None,
    error: str = None,
    audio_path: str = None,
    auto_processed_conversation_id: str = None,
    app_processed_conversation_id: str = None,
    audio_kept_intervals: List[Any] = None,
    audio_realtime_factor: float = None,
    transcript_timeline: Optional[Dict[str, Any]] = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a listening session.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        session_id: The session's ID
        status: New status
        transcript_segments: Transcript segments (will be compressed to avoid 1MB Firestore limit)
        duration_seconds: Session duration
        error: Error message if failed
        audio_path: GCS path to the audio recording (for speaker identification)
        auto_processed_conversation_id: ID of conversation auto-created by server-side processing
        app_processed_conversation_id: ID of conversation created by app's POST /process call
        audio_kept_intervals: VAD kept intervals ``[[start_s, end_s], ...]`` in the
            ORIGINAL audio time axis. The wav saved to GCS has silence removed, so
            its time axis no longer matches display timestamps. Audio consumers
            map original_start/end through these intervals on independent copies
            with ``utils.stt.timeline.segments_on_audio_axis``.
        transcript_timeline: Versioned coordinate provenance including the display
            offset and the UTC anchor of the original audio stream.
        audio_realtime_factor: 收到的音频秒数 / 会话墙钟秒数，**按 VAD 裁剪之前的**
            原始解码长度算。>1.5 意味着客户端把同一帧发了多遍（见
            ``routers/developer_listen.py`` 的探测器）。

            ⚠️ **落库不是为了「顺手多存一个指标」，而是因为事后没有任何办法重算它。**
            裁剪后的 wav 时长除以墙钟得到的是另一个数（实测 22fc3b65 原始 5.73×、裁后
            只剩 1.10×，门禁会放行），而 2026-08-17 逐一验过的三个「从音频本身判断」的
            候选判据——相邻帧相关度、逐字节全等帧占比、100Hz 梳状谱强度——全部被健康
            对照组否掉（梳比：健康 53.1 vs 膨胀 50.4，没有缝）。所以这个比值只有在
            会话结束的那一刻算得准，错过就永远没有了。消费方：
            ``scripts/rescue_orphaned_listen_sessions.py`` 靠它跳过重转写。

    Returns:
        Updated session or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection("listen_sessions").document(session_id)
    session_doc = session_ref.get()

    if not session_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if status is not None:
        update_data["status"] = status
    if transcript_segments is not None:
        # Compress transcript_segments to avoid Firestore 1MB document limit
        # This is consistent with how conversations handle large transcript data
        segments_json = json.dumps(transcript_segments)
        compressed_segments = zlib.compress(segments_json.encode('utf-8'))

        # Firestore limits: 1MB per document, 10MB per request payload.
        # The update_data dict includes compressed segments + other fields, and protobuf
        # encoding adds overhead. Use 500KB threshold for inline storage to ensure
        # the total request stays well under limits.
        max_inline_bytes = 500 * 1024  # 500KB - safe within 1MB document limit with overhead
        if len(compressed_segments) > max_inline_bytes:
            # Store in subcollection chunks - each chunk must be under 1MB document limit
            # Use 750KB to leave room for the index/metadata fields in each chunk doc
            chunk_size = 750 * 1024  # 750KB per chunk document
            chunks = [compressed_segments[i:i + chunk_size] for i in range(0, len(compressed_segments), chunk_size)]
            chunks_ref = session_ref.collection("transcript_chunks")
            # Delete existing chunks first
            for old_chunk in chunks_ref.stream():
                old_chunk.reference.delete()
            for idx, chunk in enumerate(chunks):
                chunks_ref.document(f"chunk_{idx:04d}").set({
                    "data": chunk,
                    "index": idx,
                    "total_chunks": len(chunks),
                })
            update_data["transcript_segments_chunked"] = True
            update_data["transcript_segments_chunk_count"] = len(chunks)
            update_data["transcript_segments_compressed"] = True
            # Clear inline segments to avoid stale data
            update_data["transcript_segments"] = None
            print(f"[update_listen_session] Stored {len(compressed_segments)} bytes in {len(chunks)} chunks for session {session_id}")
        else:
            update_data["transcript_segments"] = compressed_segments
            update_data["transcript_segments_compressed"] = True
            update_data["transcript_segments_chunked"] = False
    if duration_seconds is not None:
        update_data["duration_seconds"] = duration_seconds
    if error is not None:
        update_data["error"] = error
    if audio_path is not None:
        update_data["audio_path"] = audio_path
    if audio_realtime_factor is not None:
        update_data["audio_realtime_factor"] = float(audio_realtime_factor)
    if transcript_timeline is not None:
        update_data["transcript_timeline"] = transcript_timeline
    if auto_processed_conversation_id is not None:
        update_data["auto_processed_conversation_id"] = auto_processed_conversation_id
    if app_processed_conversation_id is not None:
        update_data["app_processed_conversation_id"] = app_processed_conversation_id
    if audio_kept_intervals is not None:
        # Firestore rejects nested arrays, so store each interval as a map.
        update_data["audio_kept_intervals"] = [
            {"start": float(s), "end": float(e)} for s, e in audio_kept_intervals
        ]

    session_ref.update(update_data)

    # Return decompressed data for the caller
    return _prepare_listen_session_for_read(session_ref.get().to_dict(), session_ref=session_ref)


def get_listen_sessions(
    developer_id: str,
    external_user_id: str,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    Get listening sessions for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum sessions to return
        offset: Number to skip

    Returns:
        List of session documents (with transcript_segments decompressed)
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    sessions_ref = user_ref.collection("listen_sessions")

    sessions_ref = (
        sessions_ref.order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [_prepare_listen_session_for_read(doc.to_dict(), session_ref=doc.reference) for doc in sessions_ref.stream()]


# ******************************************************
# ********** CONVERSATION UPSERT (FULL DATA) ***********
# ******************************************************


def upsert_conversation_full(
    developer_id: str,
    external_user_id: str,
    conversation_data: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Upsert a full conversation document (used by audio upload).

    This stores the complete conversation data including transcript_segments,
    structured summary, etc. in the developer_data path.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_data: Full conversation data dictionary

    Returns:
        The stored conversation document
    """
    _ensure_user_exists(developer_id, external_user_id)

    conversation_id = conversation_data.get("id")
    if not conversation_id:
        conversation_id = str(uuid.uuid4())
        conversation_data["id"] = conversation_id

    # Normalize legacy string speaker_id to int before persisting
    _normalize_transcript_segments(conversation_data.get("transcript_segments"))

    # Ensure updated_at is set
    conversation_data["updated_at"] = datetime.now(timezone.utc)

    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_ref.set(conversation_data)

    return conversation_data


def update_conversation_status_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    status: str,
) -> Optional[Dict[str, Any]]:
    """
    Update the status of a conversation in developer data path.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        status: New status (in_progress, processing, completed, etc.)

    Returns:
        Updated conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_ref.update({
        "status": status,
        "updated_at": datetime.now(timezone.utc),
    })

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


def get_latest_eir_conversation(
    developer_id: str,
    external_user_id: str,
) -> Optional[Dict[str, Any]]:
    """Return the latest completed, non-discarded conversation with EIR data.

    The Discover Avatar should stay aligned with Mood Trends, so this lookup
    intentionally uses the same conversation set: completed conversations only,
    excluded discarded items, ordered by conversation `created_at`. To avoid
    runaway Firestore reads, only the most recent completed conversations are
    scanned.
    """
    batch_size = 100
    max_conversations_to_scan = 1000
    offset = 0

    while offset < max_conversations_to_scan:
        conversations = get_conversations(
            developer_id=developer_id,
            external_user_id=external_user_id,
            limit=batch_size,
            offset=offset,
            statuses=["completed"],
            include_photos=False,
            include_discarded=False,
        )
        if not conversations:
            return None

        for convo in conversations:
            if convo.get("eir_emotion"):
                return convo

        offset += batch_size

    return None


def update_conversation_eir_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    eir_emotion: str,
    eir_confidence: Optional[float] = None,
) -> Optional[Dict[str, Any]]:
    """Persist EIR emotion result onto a conversation document.

    The mobile Avatar card reads `eir_emotion` to display the latest mood;
    `eir_updated_at` records when the EIR payload was last refreshed.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    now = datetime.now(timezone.utc)
    conv_ref.update({
        "eir_emotion": eir_emotion,
        "eir_confidence": eir_confidence,
        "eir_updated_at": now,
        "updated_at": now,
    })

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


def update_conversation_audio_url_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    audio_url: str,
) -> Optional[Dict[str, Any]]:
    """
    Update the audio_url field for a conversation in developer data path.
    Deprecated: Use update_conversation_audio_path_dev instead.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        audio_url: URL to the audio recording in cloud storage

    Returns:
        Updated conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_ref.update({
        "audio_url": audio_url,
        "updated_at": datetime.now(timezone.utc),
    })

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


def update_conversation_audio_path_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    audio_path: str,
) -> Optional[Dict[str, Any]]:
    """
    Update the audio_path field for a conversation in developer data path.
    Stores GCS path (not signed URL) for on-demand signed URL generation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        audio_path: GCS path to the audio recording (e.g., "{uid}/{conversation_id}.wav")

    Returns:
        Updated conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_ref.update({
        "audio_path": audio_path,
        "updated_at": datetime.now(timezone.utc),
    })

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


def update_conversation_discarded(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    discarded: bool,
    first_person_observation: str = None,
    highlights: List[str] = None,
    title: str = None,
    overview: str = None,
    emoji: str = None,
    category: str = None,
    emotion: str = None,
) -> Optional[Dict[str, Any]]:
    """Flip a conversation's `discarded` flag (and optionally backfill the fields
    that are deliberately skipped while it is discarded).

    Used when a verdict has to be revised after the fact — e.g. speaker
    identification finishes and reveals the user did speak, so a conversation
    discarded as "media playback" has to come back. Summary fields are optional
    because a capture initially summarized as ``[Media Recording]`` needs the
    whole visible card replaced atomically, not just its subtitle.

    Args:
        discarded: New value for the flag.
        first_person_observation: Subtitle to backfill (skipped when None).
        highlights: Highlights to backfill (skipped when None).
        title/overview/emoji/category/emotion: Visible summary fields to replace
            when the original summary itself was the media/fallback placeholder.

    Returns:
        Updated conversation document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    if not conv_ref.get().exists:
        return None

    update_data = {
        "discarded": discarded,
        "updated_at": datetime.now(timezone.utc),
    }
    if first_person_observation is not None:
        update_data["structured.first_person_observation"] = first_person_observation
    if highlights is not None:
        update_data["structured.highlights"] = highlights
    if title is not None:
        update_data["structured.title"] = title
    if overview is not None:
        update_data["structured.overview"] = overview
    if emoji is not None:
        update_data["structured.emoji"] = emoji
    if category is not None:
        update_data["structured.category"] = category
    if emotion is not None:
        update_data["structured.emotion"] = emotion

    conv_ref.update(update_data)

    return _prepare_conversation_for_read(conv_ref.get().to_dict(), conv_ref)


# ******************************************************
# ************** ADDITIONAL CONVERSATION OPS ***********
# ******************************************************


def update_conversation_title_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    title: str,
) -> bool:
    """
    Update the title of a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        title: New title

    Returns:
        True if updated, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return False

    conv_ref.update({
        "structured.title": title,
        "updated_at": datetime.now(timezone.utc),
    })
    return True


def update_conversation_events_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    events: List[Dict[str, Any]],
) -> bool:
    """
    Update the events list of a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        events: List of event dictionaries

    Returns:
        True if updated, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return False

    conv_ref.update({
        "structured.events": events,
        "updated_at": datetime.now(timezone.utc),
    })
    return True


def update_conversation_segments_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
    segments: List[Dict[str, Any]],
) -> bool:
    """
    Update the transcript_segments of a conversation.

    Writes through ``set_conversation_transcript_segments`` so the segments land
    in whatever storage form their size requires (inline compressed, or chunked
    into the ``transcript_chunks`` subcollection).

    It used to write the raw list straight into the document, which broke in two
    ways because every other writer since 2026-03 compresses:

    * **Hitting Firestore's 1MB document limit.** Compression is the only reason
      long transcripts fit at all; a raw write of the same data exceeds the limit
      and raises, where the compressed write succeeds. Measured over all 7926
      production conversations: 4 are already past 1MB raw (largest 3.1MB, 1810
      segments) and 19 past the 500KB inline threshold. So this was not a
      hypothetical — those conversations simply could not be edited.
    * **Silent loss on chunked conversations.** ``_prepare_conversation_for_read``
      checks ``transcript_segments_chunked`` *first*, so as long as that flag
      stayed true the reader kept returning the old subcollection contents and
      this update was invisible — write succeeded, nothing changed. Zero chunked
      conversations exist today, and that is *because* of the bug above: a
      conversation only becomes chunked by being written through the compressing
      path, which this function bypassed.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID
        segments: List of segment dictionaries

    Returns:
        True if updated, False if not found
    """
    return set_conversation_transcript_segments(
        developer_id=developer_id,
        external_user_id=external_user_id,
        conversation_id=conversation_id,
        segments=segments,
    )


def toggle_conversation_pin(developer_id: str, external_user_id: str, conversation_id: str) -> Optional[bool]:
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()
    if not conv_doc.exists:
        return None
    data = conv_doc.to_dict()
    new_pinned = not data.get('pinned', False)
    conv_ref.update({'pinned': new_pinned, 'updated_at': datetime.now(timezone.utc)})
    return new_pinned


def get_closest_conversation_to_timestamps(developer_id: str, external_user_id: str, start_timestamp: int, end_timestamp: int):
    from datetime import timedelta
    start_threshold = datetime.fromtimestamp(start_timestamp, tz=timezone.utc) - timedelta(minutes=2)
    end_threshold = datetime.fromtimestamp(end_timestamp, tz=timezone.utc) + timedelta(minutes=2)

    user_ref = _get_user_ref(developer_id, external_user_id)
    query = (
        user_ref.collection("conversations")
        .where(filter=FieldFilter('finished_at', '>=', start_threshold))
        .where(filter=FieldFilter('started_at', '<=', end_threshold))
        .order_by('created_at', direction=firestore.Query.DESCENDING)
    )

    conversations = [doc.to_dict() for doc in query.stream()]
    if not conversations:
        return None

    closest_conversation = None
    min_diff = float('inf')
    for conversation in conversations:
        conversation_start_timestamp = conversation['started_at'].timestamp()
        conversation_end_timestamp = conversation['finished_at'].timestamp()
        diff1 = abs(conversation_start_timestamp - start_timestamp)
        diff2 = abs(conversation_end_timestamp - end_timestamp)
        if diff1 < min_diff or diff2 < min_diff:
            min_diff = min(diff1, diff2)
            closest_conversation = conversation

    return closest_conversation


def get_conversation_photos_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
) -> Optional[List[Dict[str, Any]]]:
    """
    Get photos for a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID

    Returns:
        List of photo documents or None if conversation not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    # Photos are stored in a subcollection
    photos_ref = conv_ref.collection("photos")
    photos = [doc.to_dict() for doc in photos_ref.stream()]
    return photos


def get_conversation_transcripts_by_model_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
) -> Optional[Dict[str, List[Dict[str, Any]]]]:
    """
    Get transcripts organized by STT model for a conversation.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID

    Returns:
        Dict mapping model name to list of segments, or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    # Transcripts by model are stored in a subcollection
    transcripts_ref = conv_ref.collection("transcripts")
    result = {}
    for doc in transcripts_ref.stream():
        model_name = doc.id
        data = doc.to_dict()
        result[model_name] = data.get("segments", [])
    return result


def check_conversation_recording_exists_dev(
    developer_id: str,
    external_user_id: str,
    conversation_id: str,
) -> Optional[bool]:
    """
    Check if a conversation has an audio recording.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: The conversation's ID

    Returns:
        True if recording exists, False if not, None if conversation not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    conv_ref = user_ref.collection("conversations").document(conversation_id)
    conv_doc = conv_ref.get()

    if not conv_doc.exists:
        return None

    conv_data = conv_doc.to_dict()
    # Check if audio_path is set (indicates recording exists)
    return bool(conv_data.get("audio_path"))


def get_conversation_id_by_source_started_at(
    developer_id: str,
    external_user_id: str,
    source: str,
    started_at: datetime,
) -> Optional[str]:
    """The id of an already-uploaded conversation with this exact time anchor, if any.

    This is the idempotency key for `POST /v1/conversations/upload-audio`.
    `(uid, source, started_at)` identifies one recording exactly: the anchor is
    millisecond-precision and comes from the client's own file name, so the same
    file always presents the same value while two genuinely different recordings
    never do.

    ⚠️ **Why this exists — a retry storm produced four copies of one recording**
    (2026-08-15). The endpoint is synchronous and takes minutes (ffmpeg + VAD +
    a Soniox job that polls up to 300s + LLM), the client got a 504 at the
    middleware's 120s cap, and 504 is correctly retryable — so it re-uploaded,
    while the abandoned request went on to finish and write its conversation.
    Four attempts, four conversations, four Soniox jobs off an account-level
    budget shared with the live streaming path.

    Equality-only filters on purpose: Firestore serves multi-field equality
    without a composite index. Adding an `order_by` here would need one.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = (
        user_ref.collection("conversations")
        .where(filter=FieldFilter('source', '==', source))
        .where(filter=FieldFilter('started_at', '==', started_at))
        .limit(1)
    )
    for doc in query.stream():
        return doc.id
    return None


# ******************************************************
# ****************** IMAGES ****************************
# ******************************************************


def create_image(
    developer_id: str,
    external_user_id: str,
    gcs_path: str,
    content_type: str,
    size_bytes: int,
    description: Optional[str] = None,
    conversation_id: Optional[str] = None,
    metadata: Dict[str, Any] = None,
) -> Dict[str, Any]:
    """
    Create an image record for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        gcs_path: GCS storage path
        content_type: MIME type (image/jpeg or image/png)
        size_bytes: File size in bytes
        description: Optional VLM-generated description
        conversation_id: Optional associated conversation ID
        metadata: Optional additional metadata

    Returns:
        The created image document
    """
    _ensure_user_exists(developer_id, external_user_id)

    user_ref = _get_user_ref(developer_id, external_user_id)
    images_ref = user_ref.collection("images")

    image_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    image_data = {
        "id": image_id,
        "gcs_path": gcs_path,
        "content_type": content_type,
        "size_bytes": size_bytes,
        "description": description,
        "conversation_id": conversation_id,
        "metadata": metadata or {},
        "created_at": now,
        "updated_at": now,
    }

    images_ref.document(image_id).set(image_data)
    return image_data


def get_image(
    developer_id: str,
    external_user_id: str,
    image_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a single image by ID.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        image_id: The image ID

    Returns:
        Image document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    image_ref = user_ref.collection("images").document(image_id)
    image_doc = image_ref.get()

    if not image_doc.exists:
        return None

    return image_doc.to_dict()


def list_images(
    developer_id: str,
    external_user_id: str,
    conversation_id: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    List images for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        conversation_id: Optional filter by conversation
        limit: Maximum number of results
        offset: Number of results to skip

    Returns:
        List of image documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    images_ref = user_ref.collection("images")

    query = images_ref.order_by("created_at", direction=firestore.Query.DESCENDING)

    if conversation_id:
        query = query.where(filter=FieldFilter("conversation_id", "==", conversation_id))

    # Apply pagination
    query = query.offset(offset).limit(limit)

    return [doc.to_dict() for doc in query.stream()]


def update_image(
    developer_id: str,
    external_user_id: str,
    image_id: str,
    description: Optional[str] = None,
    conversation_id: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None,
) -> Optional[Dict[str, Any]]:
    """
    Update an image's metadata.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        image_id: The image ID
        description: New description (optional)
        conversation_id: New conversation association (optional)
        metadata: Metadata to merge (optional)

    Returns:
        Updated image document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    image_ref = user_ref.collection("images").document(image_id)
    image_doc = image_ref.get()

    if not image_doc.exists:
        return None

    updates = {"updated_at": datetime.now(timezone.utc)}

    if description is not None:
        updates["description"] = description

    if conversation_id is not None:
        updates["conversation_id"] = conversation_id

    if metadata is not None:
        existing_data = image_doc.to_dict()
        existing_metadata = existing_data.get("metadata", {})
        existing_metadata.update(metadata)
        updates["metadata"] = existing_metadata

    image_ref.update(updates)
    return image_ref.get().to_dict()


def delete_image(
    developer_id: str,
    external_user_id: str,
    image_id: str,
) -> Optional[str]:
    """
    Delete an image record.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        image_id: The image ID

    Returns:
        GCS path of deleted image (for cleanup) or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    image_ref = user_ref.collection("images").document(image_id)
    image_doc = image_ref.get()

    if not image_doc.exists:
        return None

    gcs_path = image_doc.to_dict().get("gcs_path")
    image_ref.delete()
    return gcs_path


def count_images(
    developer_id: str,
    external_user_id: str,
) -> int:
    """
    Count total images for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID

    Returns:
        Number of images
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    images_ref = user_ref.collection("images")
    return len(list(images_ref.stream()))


# ******************************************************
# **************** DAILY SUMMARIES *********************
# ******************************************************


def create_daily_summary(
    developer_id: str,
    external_user_id: str,
    date_str: str,
    summary_text: str,
    image_url: Optional[str] = None,
    language: str = "en",
    conversations_count: int = 0,
    emotion_title: Optional[str] = None,
    conversation_ids: Optional[List[str]] = None,
    moment_id: Optional[str] = None,
    created_at: Optional[datetime] = None,
) -> Dict[str, Any]:
    """
    Create or update a daily summary for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        date_str: Date in YYYY-MM-DD format
        summary_text: Generated summary text
        image_url: Optional URL to generated image
        language: Language code of the summary
        conversations_count: Number of conversations included
        conversation_ids: The conversations the entry was written from; a catch-up rewrites
            the entry only when the day has conversations outside this set
        moment_id: Id of the diary card (`messages` doc) showing this entry
        created_at: Keep the original creation time when rewriting an entry

    Returns:
        The created/updated summary document
    """
    _ensure_user_exists(developer_id, external_user_id)

    # Use date as document ID for easy retrieval
    summary_id = f"summary_{date_str}"
    now = datetime.now(timezone.utc)

    summary_data = {
        "id": summary_id,
        "date": date_str,
        "summary_text": summary_text,
        "emotion_title": emotion_title,
        "image_url": image_url,
        "language": language,
        "conversations_count": conversations_count,
        "conversation_ids": conversation_ids,
        "moment_id": moment_id,
        "created_at": created_at or now,
        "updated_at": now,
    }

    user_ref = _get_user_ref(developer_id, external_user_id)
    summary_ref = user_ref.collection("daily_summaries").document(date_str)
    summary_ref.set(summary_data)

    return summary_data


def get_daily_summary(
    developer_id: str,
    external_user_id: str,
    date_str: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a daily summary by date.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        date_str: Date in YYYY-MM-DD format

    Returns:
        Summary document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    summary_ref = user_ref.collection("daily_summaries").document(date_str)
    summary_doc = summary_ref.get()

    if not summary_doc.exists:
        return None

    return summary_doc.to_dict()


def list_daily_summaries(
    developer_id: str,
    external_user_id: str,
    limit: int = 30,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    List daily summaries for a user, ordered by date (newest first).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum number of summaries to return
        offset: Number of summaries to skip

    Returns:
        List of summary documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    summaries_ref = user_ref.collection("daily_summaries")

    summaries_ref = (
        summaries_ref.order_by("date", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [doc.to_dict() for doc in summaries_ref.stream()]


def count_daily_summaries(
    developer_id: str,
    external_user_id: str,
) -> int:
    """
    Count total daily summaries for a user.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID

    Returns:
        Number of summaries
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    summaries_ref = user_ref.collection("daily_summaries")
    return len(list(summaries_ref.stream()))


def delete_daily_summary(
    developer_id: str,
    external_user_id: str,
    date_str: str,
) -> bool:
    """
    Delete a daily summary.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        date_str: Date in YYYY-MM-DD format

    Returns:
        True if deleted, False if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    summary_ref = user_ref.collection("daily_summaries").document(date_str)
    summary_doc = summary_ref.get()

    if not summary_doc.exists:
        return False

    summary_ref.delete()
    return True


# ******************************************************
# ************* TIMELINE DAYS (章节缓存) ****************
# ******************************************************
# developer_data/{developer_id}/users/{external_user_id}/timeline_days/{YYYY-MM-DD}
#
# A day's chapters are a *projection* of its conversations (see
# `utils/timeline/chaptering`), so this collection is a cache and never a record:
# it can be dropped entirely and rebuilt. That is what makes the date the document
# id — every write is a whole-document overwrite, so a chapter that no longer
# exists actually disappears instead of surviving next to its replacement, and a
# retry can never produce two documents for one day.


# Ceiling on how many segment back-references one day's document may carry.
# `segment_refs` is the drill-down path from a chapter to the original transcript,
# and it is the only part of the document that grows with recording length rather
# than with chapter count: each ref is ~70 bytes, so a continuous multi-hour
# recording (≈1 segment per 3s once hardware records offline) would approach
# Firestore's 1MB document limit on refs alone. Past the cap they are dropped
# rather than truncated — a half-list would silently make the tail of the day
# undrillable while looking complete.
TIMELINE_DAY_MAX_SEGMENT_REFS = 4000


class TimelineDocumentTooLarge(ValueError):
    """Do not replace a day with a projection Firestore cannot persist."""


def store_timeline_day(
    developer_id: str,
    external_user_id: str,
    date_str: str,
    document: Dict[str, Any],
) -> Dict[str, Any]:
    """Overwrite one day's chapter cache. Idempotent by construction.

    `document` is built by `utils.timeline.store.build_day_document`; this function
    only adds what belongs to storage: the doc id, `created_at` preservation, and
    the `segment_refs` size guard.

    Returns what was actually written (which may have had `segment_refs` dropped),
    so a caller serving the result to a client and a caller reading it back later
    see the same thing.
    """
    _ensure_user_exists(developer_id, external_user_id)

    user_ref = _get_user_ref(developer_id, external_user_id)
    day_ref = user_ref.collection("timeline_days").document(date_str)

    data = copy.deepcopy(document)
    data["id"] = date_str
    data["date"] = date_str

    total_refs = sum(len(ch.get("segment_refs") or []) for ch in data.get("chapters") or [])
    if total_refs > TIMELINE_DAY_MAX_SEGMENT_REFS:
        # Loud on purpose: a silently dropped drill-down path reads as "this
        # chapter has no segments" downstream.
        print(
            f"[timeline] {date_str} carries {total_refs} segment refs (cap "
            f"{TIMELINE_DAY_MAX_SEGMENT_REFS}); storing chapters without refs"
        )
        for chapter in data.get("chapters") or []:
            chapter["segment_refs"] = []
        data["segment_refs_dropped"] = True
    else:
        data["segment_refs_dropped"] = False

    existing = day_ref.get()
    if existing.exists:
        # First computation time survives overwrites. Only `computed_at` moves, and
        # keeping the two apart is what lets "recompute produced no change" be
        # visible rather than looking like a fresh document every time.
        data["created_at"] = (existing.to_dict() or {}).get("created_at") or data.get("computed_at")
    else:
        data.setdefault("created_at", data.get("computed_at"))

    # Measure the actual protobuf representation, including nested timestamps
    # and segment refs. Leave room for the document name and server metadata.
    # Never silently truncate a summary to satisfy Firestore's 1 MiB limit.
    from google.cloud.firestore_v1._helpers import encode_dict
    from google.cloud.firestore_v1.types import Document

    if Document.pb(Document(fields=encode_dict(data))).ByteSize() > 1_000_000:
        raise TimelineDocumentTooLarge('Summary is too large to store; existing summaries were preserved')
    day_ref.set(data)
    return data


def get_timeline_chapter_edits(developer_id: str, external_user_id: str, date_str: str) -> dict:
    """Corrections needed while rebuilding the day's compact identity projection."""
    from database.timeline_edits import get_chapter_edits
    return get_chapter_edits(developer_id, external_user_id, date_str)


def get_timeline_day(
    developer_id: str,
    external_user_id: str,
    date_str: str,
) -> Optional[Dict[str, Any]]:
    """One day's cached chapters, or None if it was never computed."""
    day_ref = (
        _get_user_ref(developer_id, external_user_id)
        .collection("timeline_days")
        .document(date_str)
    )
    doc = day_ref.get()
    if not doc.exists:
        return None
    return doc.to_dict()


# ******************************************************
# ************* DAILY MOOD QUOTE (情绪页·每日一语) ******
# ******************************************************
# 与「自己」Tab 的占卜 (fortune) 完全独立。存储路径：
# developer_data/{developer_id}/users/{external_user_id}/daily_mood_quotes/{date}
# 文档 ID = date（YYYY-MM-DD），天然去重 + 倒序查询友好。


def store_daily_mood_quote(
    developer_id: str,
    external_user_id: str,
    date_str: str,
    quote_dict: Dict[str, Any],
) -> Dict[str, Any]:
    """Create or overwrite the daily mood quote for a user/date.

    Idempotent: same date always overwrites the same document, so retries or
    refreshes are safe to replay.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        date_str: Date in YYYY-MM-DD format (document ID)
        quote_dict: Serialized DailyMoodQuote (e.g. DailyMoodQuote.dict())

    Returns:
        The stored document dict
    """
    _ensure_user_exists(developer_id, external_user_id)

    data = dict(quote_dict)
    data["date"] = date_str

    user_ref = _get_user_ref(developer_id, external_user_id)
    quote_ref = user_ref.collection("daily_mood_quotes").document(date_str)
    quote_ref.set(data)

    return data


def get_daily_mood_quote(
    developer_id: str,
    external_user_id: str,
    date_str: str,
) -> Optional[Dict[str, Any]]:
    """Get a daily mood quote by date.

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        date_str: Date in YYYY-MM-DD format

    Returns:
        Quote document or None if not found
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    quote_ref = user_ref.collection("daily_mood_quotes").document(date_str)
    quote_doc = quote_ref.get()

    if not quote_doc.exists:
        return None

    return quote_doc.to_dict()


def get_daily_mood_quotes(
    developer_id: str,
    external_user_id: str,
    limit: int = 30,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """List daily mood quotes for a user, ordered by date (newest first).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        limit: Maximum number of quotes to return
        offset: Number of quotes to skip

    Returns:
        List of quote documents
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    quotes_ref = user_ref.collection("daily_mood_quotes")

    quotes_ref = (
        quotes_ref.order_by("date", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [doc.to_dict() for doc in quotes_ref.stream()]


# ******************************************************
# *************** TALK SESSIONS ************************
# ******************************************************


def create_talk_session(
    developer_id: str,
    external_user_id: str,
    language: str = "zh",
    stt_service: str = "soniox",
    cleaning_level: str = "standard",
    output_format: str = "paragraph",
    metadata: Dict[str, Any] = None,
) -> Dict[str, Any]:
    """
    Create a real-time talk session (STT + LLM cleaning).

    Args:
        developer_id: The developer's ID
        external_user_id: The external user's ID
        language: Language code
        stt_service: STT service name
        cleaning_level: Cleaning level (light, standard, aggressive)
        output_format: Output format (paragraph, bullets, raw)
        metadata: Additional metadata

    Returns:
        The created session document
    """
    _ensure_user_exists(developer_id, external_user_id)

    session_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    session_data = {
        "id": session_id,
        "status": "pending",
        "language": language,
        "stt_service": stt_service,
        "cleaning_level": cleaning_level,
        "output_format": output_format,
        "transcript_segments": [],
        "cleaned_text": None,
        "cleaning_changes": [],
        "duration_seconds": 0.0,
        "error": None,
        "metadata": metadata or {},
        "created_at": now,
        "updated_at": now,
    }

    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection("talk_sessions").document(session_id)
    session_ref.set(session_data)

    return session_data


def get_talk_session(
    developer_id: str,
    external_user_id: str,
    session_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Get a talk session by ID.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection("talk_sessions").document(session_id)
    session_doc = session_ref.get()

    if not session_doc.exists:
        return None

    return session_doc.to_dict()


def update_talk_session(
    developer_id: str,
    external_user_id: str,
    session_id: str,
    status: str = None,
    transcript_segments: List[Dict[str, Any]] = None,
    cleaned_text: str = None,
    cleaning_changes: List[Dict[str, Any]] = None,
    duration_seconds: float = None,
    error: str = None,
) -> Optional[Dict[str, Any]]:
    """
    Update a talk session.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    session_ref = user_ref.collection("talk_sessions").document(session_id)
    session_doc = session_ref.get()

    if not session_doc.exists:
        return None

    update_data = {"updated_at": datetime.now(timezone.utc)}

    if status is not None:
        update_data["status"] = status
    if transcript_segments is not None:
        update_data["transcript_segments"] = transcript_segments
    if cleaned_text is not None:
        update_data["cleaned_text"] = cleaned_text
    if cleaning_changes is not None:
        update_data["cleaning_changes"] = cleaning_changes
    if duration_seconds is not None:
        update_data["duration_seconds"] = duration_seconds
    if error is not None:
        update_data["error"] = error

    session_ref.update(update_data)

    return session_ref.get().to_dict()


def get_talk_sessions(
    developer_id: str,
    external_user_id: str,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """
    Get talk sessions for a user.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    sessions_ref = user_ref.collection("talk_sessions")

    sessions_ref = (
        sessions_ref.order_by("created_at", direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )

    return [doc.to_dict() for doc in sessions_ref.stream()]


# ******************************************************
# ********** SUBSCRIPTION & USAGE **********************
# ******************************************************


def get_user_subscription(
    developer_id: str,
    external_user_id: str,
) -> Subscription:
    """
    Get the legacy subscription-shaped view used by old clients.

    Data path: developer_data/{developer_id}/users/{external_user_id} -> subscription field
    """
    from utils.subscription import get_plan_limits, resolve_entitlement

    user_ref = _get_user_ref(developer_id, external_user_id)
    user_doc = user_ref.get()
    state = resolve_entitlement(user_doc.to_dict() if user_doc.exists else None)
    return Subscription(
        plan=state.plan,
        status=SubscriptionStatus.active,
        current_period_end=int(state.expires_at.timestamp()) if state.expires_at else None,
        limits=get_plan_limits(state.plan),
    )


def update_hourly_usage(
    developer_id: str,
    external_user_id: str,
    date: datetime,
    updates: dict,
):
    """
    Update hourly usage stats using Firestore atomic increments.

    Data path: developer_data/{developer_id}/users/{external_user_id}/hourly_usage/{doc_id}
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc_id = f'{date.year}-{date.month:02d}-{date.day:02d}-{date.hour:02d}'
    hourly_usage_ref = user_ref.collection('hourly_usage').document(doc_id)
    month_id = f'{date.year}-{date.month:02d}'
    monthly_usage_ref = user_ref.collection('monthly_usage').document(month_id)

    update_doc = {'last_updated': datetime.now(timezone.utc)}
    has_increments = False

    for key, value in updates.items():
        if key in ['transcription_seconds', 'words_transcribed', 'insights_gained', 'memories_created'] and value > 0:
            update_doc[key] = firestore.Increment(value)
            has_increments = True

    if not has_increments:
        return

    update_doc['year'] = date.year
    update_doc['month'] = date.month
    update_doc['day'] = date.day
    update_doc['hour'] = date.hour
    update_doc['id'] = doc_id

    monthly_doc = {
        key: value for key, value in update_doc.items()
        if key in {'transcription_seconds', 'words_transcribed', 'insights_gained', 'memories_created'}
    }
    monthly_doc.update({'year': date.year, 'month': date.month, 'last_updated': update_doc['last_updated']})
    date_utc = date.replace(tzinfo=timezone.utc) if date.tzinfo is None else date.astimezone(timezone.utc)
    counter_started_at = ensure_subscription_usage_counter_started_at()
    if subscription_counter_covers_month(date_utc, counter_started_at):
        monthly_doc['counter_complete'] = True
    batch = db.batch()
    batch.set(hourly_usage_ref, update_doc, merge=True)
    batch.set(monthly_usage_ref, monthly_doc, merge=True)
    batch.commit()


def get_monthly_usage_stats(
    developer_id: str,
    external_user_id: str,
    date: datetime,
) -> dict:
    """
    Aggregate hourly usage stats for a given month.

    Data path: developer_data/{developer_id}/users/{external_user_id}/hourly_usage
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    hourly_usage_collection = user_ref.collection('hourly_usage')

    query = hourly_usage_collection.where(
        filter=FieldFilter('year', '==', date.year)
    ).where(
        filter=FieldFilter('month', '==', date.month)
    )

    stats = {
        'transcription_seconds': 0,
        'words_transcribed': 0,
        'insights_gained': 0,
        'memories_created': 0,
    }
    for doc in query.stream():
        data = doc.to_dict()
        stats['transcription_seconds'] += data.get('transcription_seconds', 0)
        stats['words_transcribed'] += data.get('words_transcribed', 0)
        stats['insights_gained'] += data.get('insights_gained', 0)
        stats['memories_created'] += data.get('memories_created', 0)
    return stats


# ******************************************************
# ************** CONVERSATION HELPERS ******************
# ******************************************************


def store_conversation_photos(developer_id: str, external_user_id: str, conversation_id: str, photos: list):
    """Store photos as subcollection under a conversation."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    conversation_ref = user_ref.collection('conversations').document(conversation_id)
    photos_ref = conversation_ref.collection('photos')
    batch = db.batch()
    count = 0
    for photo in photos:
        data = photo.dict() if hasattr(photo, 'dict') else photo
        photo_id = data.get('id') or str(uuid.uuid4())
        data['id'] = photo_id
        batch.set(photos_ref.document(photo_id), data)
        count += 1
        if count >= 450:
            batch.commit()
            batch = db.batch()
            count = 0
    if count > 0:
        batch.commit()


def get_in_progress_conversation(developer_id: str, external_user_id: str) -> Optional[Dict[str, Any]]:
    """Get the in-progress conversation for a user."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    conversations_ref = user_ref.collection('conversations').where(
        filter=FieldFilter('status', '==', 'in_progress')
    )
    docs = [doc.to_dict() for doc in conversations_ref.stream()]
    return docs[0] if docs else None


def store_model_emotion_predictions(
    developer_id: str, external_user_id: str, conversation_id: str, model_name: str, predictions: list
):
    """Store emotion prediction results as subcollection under a conversation."""
    import json as _json
    user_ref = _get_user_ref(developer_id, external_user_id)
    conversation_ref = user_ref.collection('conversations').document(conversation_id)
    predictions_ref = conversation_ref.collection(model_name)
    now = datetime.now(timezone.utc)
    batch = db.batch()
    count = 0
    for prediction in predictions:
        prediction_id = str(uuid.uuid4())
        prediction_ref = predictions_ref.document(prediction_id)
        from utils.other.hume import HumeJobModelPredictionResponseModel
        batch.set(prediction_ref, {
            "created_at": now,
            "start": prediction.time[0],
            "end": prediction.time[1],
            "emotions": _json.dumps(HumeJobModelPredictionResponseModel.to_multi_dict(prediction.emotions)),
        })
        count += 1
        if count >= 100:
            batch.commit()
            batch = db.batch()
            count = 0
    batch.commit()


# ******************************************************
# ************** MEMORIES HELPERS **********************
# ******************************************************


def delete_memories_for_conversation(developer_id: str, external_user_id: str, conversation_id: str):
    """Delete all memories linked to a specific conversation."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    memories_ref = user_ref.collection('memories')
    query = memories_ref.where(filter=FieldFilter('memory_id', '==', conversation_id))
    batch = db.batch()
    removed_ids = []
    count = 0
    for doc in query.stream():
        batch.delete(doc.reference)
        removed_ids.append(doc.id)
        count += 1
        if count >= 450:
            batch.commit()
            batch = db.batch()
            count = 0
    if count > 0:
        batch.commit()
    print('delete_memories_for_conversation', conversation_id, len(removed_ids))


def save_memories_batch(developer_id: str, external_user_id: str, memories_data: list):
    """Batch save memories (list of dicts with 'id' field)."""
    if not memories_data:
        return
    user_ref = _get_user_ref(developer_id, external_user_id)
    memories_ref = user_ref.collection('memories')
    batch = db.batch()
    count = 0
    for memory in memories_data:
        memory_ref = memories_ref.document(memory['id'])
        batch.set(memory_ref, memory)
        count += 1
        if count >= 450:
            batch.commit()
            batch = db.batch()
            count = 0
    if count > 0:
        batch.commit()


def get_all_memories(developer_id: str, external_user_id: str, limit: int = 100) -> list:
    """Get a user's visible memories (for LLM prompt context)."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    # 边流边过滤，直到凑够 limit 条：软删除的事实不能进「已知事实」上下文，否则被
    # 复筛/用户删掉的条目会永久占位，同一个真事实以后每次都被判成重复而丢弃。
    #
    # 不能用「多取 limit*2 再过滤」：严格复筛之后 98% 的文档都是软删的，取 200 条
    # 只剩十几条真事实，去重上下文残缺会让已知事实被反复重新提取。
    # SCAN_CAP 是兜底，防止在极端脏数据上无限翻页。
    SCAN_CAP = 5000
    memories_ref = (
        user_ref.collection('memories')
        .order_by('created_at', direction=firestore.Query.DESCENDING)
        .limit(SCAN_CAP)
    )
    kept = []
    for doc in memories_ref.stream():
        data = doc.to_dict() or {}
        if data.get('deleted'):
            continue
        if not (data.get('content') or '').strip():
            continue
        kept.append(data)
        if len(kept) >= limit:
            break
    return kept


# ******************************************************
# ************** CHAT HELPERS **************************
# ******************************************************


def create_v2_new_chat_session(
    developer_id: str, external_user_id: str, app_id: Optional[str] = None, title: Optional[str] = None,
    context_conversation_ids: Optional[List[str]] = None,
) -> dict:
    """Create a new v2 chat session with auto-generated title if not provided."""
    if not title:
        existing = get_v2_chat_sessions(developer_id, external_user_id, app_id)
        session_count = len(existing) + 1
        title = f"New Chat {session_count}"

    now = datetime.now(timezone.utc)
    session_data = {
        'id': str(uuid.uuid4()),
        'created_at': now,
        'updated_at': now,
        'plugin_id': app_id,
        'app_id': app_id,
        'message_ids': [],
        'title': title,
        'context_conversation_ids': context_conversation_ids or [],
    }
    return add_v2_chat_session(developer_id, external_user_id, session_data)


# ******************************************************
# ************** NOTIFICATION HELPERS ******************
# ******************************************************


def remove_fcm_token(developer_id: str, external_user_id: str):
    """Remove FCM token for a user."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.update({'fcm_token': firestore.DELETE_FIELD})


def remove_fcm_token_by_value(token: str):
    """Remove FCM token by searching across all developer users. Fallback for invalid token cleanup."""
    # Search across all developer_data for this token
    dev_data_ref = db.collection('developer_data')
    for dev_doc in dev_data_ref.stream():
        users_ref = dev_doc.reference.collection('users')
        query = users_ref.where(filter=FieldFilter('fcm_token', '==', token))
        for user_doc in query.stream():
            user_doc.reference.update({'fcm_token': firestore.DELETE_FIELD})


# ******************************************************
# ************** USER PREFERENCE HELPERS ***************
# ******************************************************


# ******************************************************
# ************** TASKS *********************************
# ******************************************************


def create_task(developer_id: str, external_user_id: str, task_data: dict):
    """Create a task document under the user."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    task_id = task_data['id']
    task_ref = user_ref.collection('tasks').document(task_id)
    task_ref.set(task_data)


def update_task(developer_id: str, external_user_id: str, task_id: str, task_data: dict):
    """Update a task document."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    task_ref = user_ref.collection('tasks').document(task_id)
    task_ref.update(task_data)


def get_task_by_action_request(developer_id: str, external_user_id: str, action: str, request_id: str):
    """Get a task by action and request_id."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = (
        user_ref.collection('tasks')
        .where(filter=FieldFilter('action', '==', action))
        .where(filter=FieldFilter('request_id', '==', request_id))
        .limit(1)
    )
    tasks = [item.to_dict() for item in query.stream()]
    return tasks[0] if tasks else None


# ******************************************************
# ************** TRENDS ********************************
# ******************************************************


def save_trends(developer_id: str, external_user_id: str, conversation_id: str, trends: list):
    """Save trend data under the user's trends subcollection."""
    from database._client import document_id_from_seed

    user_ref = _get_user_ref(developer_id, external_user_id)
    trends_ref = user_ref.collection('trends')

    for trend in trends:
        category = trend.category.value
        topics = trend.topics
        trend_type = trend.type.value
        category_id = document_id_from_seed(category + trend_type)
        category_doc_ref = trends_ref.document(category_id)

        category_doc_ref.set(
            {"id": category_id, "category": category, "type": trend_type, "created_at": datetime.now(timezone.utc)},
            merge=True,
        )

        topics_coll_ref = category_doc_ref.collection('topics')
        for topic in topics:
            topic_id = document_id_from_seed(topic)
            topic_doc_ref = topics_coll_ref.document(topic_id)
            topic_doc_ref.set({"id": topic_id, "topic": topic}, merge=True)
            topic_doc_ref.update({'conversation_ids': firestore.ArrayUnion([conversation_id])})

# ******************************************************
# **************** MOOD PIXEL STATE ********************
# ******************************************************


def store_mood_pixel_state(
    developer_id: str,
    external_user_id: str,
    board_id: str,
    state_dict: Dict[str, Any],
) -> Dict[str, Any]:
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc_ref = user_ref.collection('mood_pixels').document(board_id)
    payload = dict(state_dict)
    payload['board_id'] = board_id
    doc_ref.set(payload)
    return payload


def get_mood_pixel_state(
    developer_id: str,
    external_user_id: str,
    board_id: str,
) -> Optional[Dict[str, Any]]:
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.collection('mood_pixels').document(board_id).get()
    if not doc.exists:
        return None
    return doc.to_dict()


# ******************************************************
# *********************** PDP **************************
# ******************************************************


def store_daily_pdp_snapshot(
    developer_id: str,
    external_user_id: str,
    date_str: str,
    snapshot_dict: Dict[str, Any],
) -> Dict[str, Any]:
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc_ref = user_ref.collection('pdp_daily').document(date_str)
    payload = dict(snapshot_dict)
    payload['date'] = date_str
    doc_ref.set(payload)
    return payload


def get_daily_pdp_snapshot(
    developer_id: str,
    external_user_id: str,
    date_str: str,
) -> Optional[Dict[str, Any]]:
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.collection('pdp_daily').document(date_str).get()
    if not doc.exists:
        return None
    return doc.to_dict()


def delete_daily_pdp_snapshot(
    developer_id: str,
    external_user_id: str,
    date_str: str,
) -> None:
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.collection('pdp_daily').document(date_str).delete()


def get_daily_pdp_snapshots(
    developer_id: str,
    external_user_id: str,
    limit: int = 30,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = (
        user_ref.collection('pdp_daily')
        .order_by('date', direction=firestore.Query.DESCENDING)
        .limit(limit)
        .offset(offset)
    )
    return [doc.to_dict() for doc in query.stream()]


# ******************************************************
# ******** INSIGHT LEDGER (洞察引擎账本) ***************
# ******************************************************
#
# 账本是洞察引擎的记忆：它记住说过什么、否决过什么，保证"惊喜"不重复。
# 关键设计：去重针对**全部历史条目**（含 rejected），不只针对已推送的——
# 否则被怀疑者毙掉的提名会每轮重新冒出来，引擎永远不收敛。
#
# 路径：developer_data/{developer_id}/users/{uid}/insights/{insight_id}

_INSIGHTS_COLLECTION = 'insights'


def upsert_insight(
    developer_id: str,
    external_user_id: str,
    insight: Dict[str, Any],
) -> Dict[str, Any]:
    """Create or update one insight ledger entry (keyed by its id)."""
    _ensure_user_exists(developer_id, external_user_id)

    now = datetime.now(timezone.utc)
    insight_id = insight.get('id')
    if not insight_id:
        raise ValueError('insight must carry an id')

    data = dict(insight)
    data['updated_at'] = now

    user_ref = _get_user_ref(developer_id, external_user_id)
    ref = user_ref.collection(_INSIGHTS_COLLECTION).document(insight_id)

    # created_at 只在首次写入时落。释放阶段会用 merge=True 再 upsert 同一条，
    # 若无条件填 now 会把原始创建时间覆盖成释放时刻，打乱按 created_at 的排序。
    if not data.get('created_at'):
        snapshot = ref.get()
        existing = (snapshot.to_dict() or {}).get('created_at') if snapshot.exists else None
        data['created_at'] = existing or now

    ref.set(data, merge=True)
    return data


def get_insight(
    developer_id: str,
    external_user_id: str,
    insight_id: str,
) -> Optional[Dict[str, Any]]:
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.collection(_INSIGHTS_COLLECTION).document(insight_id).get()
    if not doc.exists:
        return None
    return doc.to_dict()


def find_insight_released_by(
    developer_id: str,
    external_user_id: str,
    job_id: str,
) -> Optional[Dict[str, Any]]:
    """The card a queued insight run released (`released_by_job`), if that run got so far."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = user_ref.collection(_INSIGHTS_COLLECTION).where(
        filter=FieldFilter('released_by_job', '==', job_id)).limit(1)
    for doc in query.stream():
        return doc.to_dict()
    return None


def list_insights(
    developer_id: str,
    external_user_id: str,
    statuses: Optional[List[str]] = None,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """List insights, newest first.

    Firestore can't combine an `in` filter with an order_by on a different
    field without a composite index, so status filtering is done in Python.
    The per-user ledger is small (tens of entries), so this is cheap.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = (
        user_ref.collection(_INSIGHTS_COLLECTION)
        .order_by('created_at', direction=firestore.Query.DESCENDING)
        .limit(limit + offset if statuses is None else 500)
    )
    rows = [doc.to_dict() for doc in query.stream()]

    if statuses:
        wanted = set(statuses)
        rows = [r for r in rows if r.get('status') in wanted]

    return rows[offset:offset + limit]


def get_released_insights(
    developer_id: str,
    external_user_id: str,
    limit: int = 50,
) -> List[Dict[str, Any]]:
    """Cards the user has actually been shown, newest release first."""
    rows = list_insights(
        developer_id=developer_id,
        external_user_id=external_user_id,
        statuses=['released'],
        limit=limit,
    )

    # Sort key must be a single type: a row missing both timestamps would
    # otherwise fall back to '' and blow up comparing str against datetime.
    epoch = datetime.min.replace(tzinfo=timezone.utc)

    def _sort_key(row: Dict[str, Any]) -> datetime:
        for field in ('released_at', 'created_at'):
            value = row.get(field)
            if isinstance(value, datetime):
                return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return epoch

    return sorted(rows, key=_sort_key, reverse=True)


def get_known_topic_keys(
    developer_id: str,
    external_user_id: str,
) -> Dict[str, str]:
    """Return {topic_key: status} across the WHOLE ledger.

    Fed to the nominator as a "don't say these again" list, and used by the
    dedup gate. Includes rejected/material entries on purpose (see module note).
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    known: Dict[str, str] = {}
    for doc in user_ref.collection(_INSIGHTS_COLLECTION).limit(500).stream():
        data = doc.to_dict() or {}
        key = data.get('topic_key')
        if key:
            known[key] = data.get('status') or 'candidate'
    return known


def count_insights(
    developer_id: str,
    external_user_id: str,
    statuses: Optional[List[str]] = None,
) -> int:
    """Total ledger entries (optionally by status), for pagination metadata."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    rows = [doc.to_dict() or {} for doc in user_ref.collection(_INSIGHTS_COLLECTION).stream()]
    if statuses:
        wanted = set(statuses)
        rows = [r for r in rows if r.get('status') in wanted]
    return len(rows)


def set_insight_feedback(
    developer_id: str,
    external_user_id: str,
    insight_id: str,
    feedback: str,
) -> Optional[Dict[str, Any]]:
    """Record the user's 「说得准 / 不太准」 tap on a card."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    ref = user_ref.collection(_INSIGHTS_COLLECTION).document(insight_id)
    doc = ref.get()
    if not doc.exists:
        return None

    ref.update({
        'feedback': feedback,
        'feedback_at': datetime.now(timezone.utc),
        'updated_at': datetime.now(timezone.utc),
    })
    return ref.get().to_dict()


def delete_insight(
    developer_id: str,
    external_user_id: str,
    insight_id: str,
) -> None:
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.collection(_INSIGHTS_COLLECTION).document(insight_id).delete()


_CALENDAR_EVENTS_COLLECTION = 'calendar_events'


def replace_calendar_events(
    developer_id: str,
    external_user_id: str,
    window_start: datetime,
    window_end: datetime,
    events: List[Dict[str, Any]],
) -> Dict[str, int]:
    """Make the stored calendar match the device for [window_start, window_end).

    Full replacement within the window, not an upsert: a user who deletes or
    reschedules an event on their phone expects it gone here too, and an
    id-keyed upsert can only ever add. The device is the single source of
    truth — we never write back to it — so replacing the window is safe and
    keeps deletions working without a tombstone protocol.

    Events are keyed by `instance_id` (event identifier + instance start), so a
    recurring series lands as one document per occurrence rather than
    collapsing onto a single id.

    Returns counts for the sync log: {"written": n, "deleted": n}.
    """
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    collection = user_ref.collection(_CALENDAR_EVENTS_COLLECTION)

    incoming = {e['instance_id']: e for e in events if e.get('instance_id')}

    # Existing docs in the window, so we know what to delete. Range is on
    # starts_at, matching how the device query was bounded.
    existing_ids = set()
    query = (
        collection.where(filter=FieldFilter('starts_at', '>=', window_start))
        .where(filter=FieldFilter('starts_at', '<', window_end))
    )
    for doc in query.stream():
        existing_ids.add(doc.id)

    stale_ids = existing_ids - set(incoming.keys())
    now = datetime.now(timezone.utc)

    batch = db.batch()
    pending = 0

    def flush(force: bool = False):
        nonlocal batch, pending
        # Firestore caps a batch at 500 writes; 450 leaves headroom like the
        # other bulk writers in this module.
        if pending and (force or pending >= 450):
            batch.commit()
            batch = db.batch()
            pending = 0

    for instance_id, event in incoming.items():
        data = dict(event)
        data['id'] = instance_id
        data['synced_at'] = now
        batch.set(collection.document(instance_id), data)
        pending += 1
        flush()

    for stale_id in stale_ids:
        batch.delete(collection.document(stale_id))
        pending += 1
        flush()

    flush(force=True)

    return {'written': len(incoming), 'deleted': len(stale_ids)}


def get_calendar_events(
    developer_id: str,
    external_user_id: str,
    start: Optional[datetime] = None,
    end: Optional[datetime] = None,
    limit: int = 100,
) -> List[Dict[str, Any]]:
    """Stored calendar events overlapping [start, end), earliest first."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = user_ref.collection(_CALENDAR_EVENTS_COLLECTION)

    if start is not None:
        query = query.where(filter=FieldFilter('starts_at', '>=', start))
    if end is not None:
        query = query.where(filter=FieldFilter('starts_at', '<', end))

    query = query.order_by('starts_at', direction=firestore.Query.ASCENDING).limit(limit)
    return [doc.to_dict() for doc in query.stream()]


def delete_all_calendar_events(developer_id: str, external_user_id: str) -> int:
    """Erase every stored calendar event and forget the sync state.

    This is the withdraw-consent path, so it must leave nothing behind: turning
    the calendar toggle off has to actually remove the data from our servers,
    not merely stop adding to it (App Review 5.1.1(ii), GDPR Art. 7(3)).

    Unlike `replace_calendar_events` this is unbounded by window — the point is
    that no trace survives.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    collection = user_ref.collection(_CALENDAR_EVENTS_COLLECTION)

    deleted = 0
    batch_size = 450
    while True:
        docs_list = list(collection.limit(batch_size).stream())
        if not docs_list:
            break
        batch = db.batch()
        for doc in docs_list:
            batch.delete(doc.reference)
        batch.commit()
        deleted += len(docs_list)
        if len(docs_list) < batch_size:
            break

    # Clear the state too, otherwise the app keeps showing "synced N events"
    # for data that no longer exists.
    if user_ref.get().exists:
        user_ref.set({'calendar_sync': firestore.DELETE_FIELD, 'updated_at': datetime.now(timezone.utc)}, merge=True)

    return deleted


def get_calendar_sync_state(developer_id: str, external_user_id: str) -> Optional[Dict[str, Any]]:
    """Last sync metadata, for showing "synced N events · just now" in the app."""
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if not doc.exists:
        return None
    return (doc.to_dict() or {}).get('calendar_sync')


def set_calendar_sync_state(
    developer_id: str,
    external_user_id: str,
    state: Dict[str, Any],
) -> None:
    _ensure_user_exists(developer_id, external_user_id)
    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.set({'calendar_sync': state, 'updated_at': datetime.now(timezone.utc)}, merge=True)


def get_calendar_consent(developer_id: str, external_user_id: str) -> Optional[Dict[str, Any]]:
    """Whether the user agreed to their calendar leaving the device.

    Lives server-side, keyed per user, because it is what the app's calendar
    toggle actually reflects. Keeping it only in the device's NSUserDefaults (as
    it originally was) breaks in a way that looks like a permission bug: a
    reinstall wipes the app sandbox but *not* the iOS calendar permission, so the
    toggle reads "off" while the system permission is still granted and the
    already-synced events are still on our servers.

    Returns None when no decision was ever recorded — see `resolve_calendar_consent`
    in routers/calendar.py, which distinguishes that from an explicit refusal.

    Stored as a sibling of `calendar_sync` rather than inside it: erasing the
    synced data deletes that field wholesale, and the grant/revoke timestamps are
    exactly what must survive for the decision to be auditable.
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    doc = user_ref.get()
    if not doc.exists:
        return None
    return (doc.to_dict() or {}).get('calendar_consent')


def set_calendar_consent(developer_id: str, external_user_id: str, granted: bool) -> Dict[str, Any]:
    """Record a consent decision, keeping both grant and revoke timestamps.

    `merge=True` deep-merges the nested map, so recording a revocation leaves the
    earlier `granted_at` in place: the pair is the consent history, and "when did
    they agree" stays answerable after they withdraw.
    """
    _ensure_user_exists(developer_id, external_user_id)
    now = datetime.now(timezone.utc)
    state: Dict[str, Any] = {'granted': granted, 'updated_at': now}
    state['granted_at' if granted else 'revoked_at'] = now

    user_ref = _get_user_ref(developer_id, external_user_id)
    user_ref.set({'calendar_consent': state, 'updated_at': now}, merge=True)
    return state


# Length cap for a synced-file doc id. Firestore rejects ids over 1500 bytes, and
# a filename is attacker-controlled (it arrives as a multipart part name), so it is
# hashed rather than trusted verbatim — see `_synced_file_doc_id`.
_SYNCED_FILE_ID_CHARS = 64


def _synced_file_doc_id(filename: str) -> str:
    """Doc id for one uploaded audio file: a hash of its name.

    Hashed rather than used raw because a Firestore doc id may not contain '/',
    may not be '.' or '..', and is capped in length — all three are reachable from
    a client-supplied filename. The hash is of the basename only, so the same file
    re-sent from a different local directory still collides (which is the point).
    """
    import hashlib

    base = (filename or '').strip().split('/')[-1]
    return hashlib.sha256(base.encode('utf-8')).hexdigest()[:_SYNCED_FILE_ID_CHARS]


def claim_synced_file(
    developer_id: str,
    external_user_id: str,
    filename: str,
) -> bool:
    """Claim one uploaded audio file, returning False if it was already claimed.

    This is the idempotency gate for `POST /v1/sync-local-files`, which had none:
    the app re-sends files on any partial failure and the endpoint transcribed and
    stored every copy. Worse, the app's batch loop uploads `wals[left..right]`
    inclusive but only marks `left..right-1` synced (`wals.dart` `syncAll`), so one
    file per batch of ten is re-sent on *every* sync even when nothing failed.

    The handle is the **filename**, not the app's `Wal.id`. `Wal.id`
    (`'${device}_$timerStart'`) never reaches the backend — `syncLocalFiles` sends
    `basename(file.path)`. Both naming forms embed the recording start second
    (`audio_{device}_{codec}_{rate}_{ch}_fs{n}_{timerStart}.bin` for buffered wals,
    `audio_{timerStart}.bin` for SD-card chunks), so a retransmit of the same
    recording produces the same name and lands here.

    Uses `create()`, which fails when the document exists: that check-and-set is
    atomic in Firestore, so two concurrent uploads of one file cannot both win. A
    plain `get()` then `set()` would let both through — the same TOCTOU shape that
    let one listen session produce two conversations (see
    `developer_conversations.listen_session_lock_key`).
    """
    try:
        # Inside the try on purpose: `_ensure_user_exists` does its own get+set, so
        # a Firestore outage raises here too, and an exception escaping this function
        # would 500 the whole upload — dropping audio for the sake of a dedup check.
        _ensure_user_exists(developer_id, external_user_id)
        doc_ref = (
            _get_user_ref(developer_id, external_user_id)
            .collection('synced_files')
            .document(_synced_file_doc_id(filename))
        )
        doc_ref.create(
            {
                'filename': (filename or '').strip().split('/')[-1],
                'claimed_at': datetime.now(timezone.utc),
            }
        )
        return True
    except AlreadyExists:
        return False
    except Exception as e:
        # Fail open, deliberately: losing audio is worse than storing it twice.
        # Chapter-level content dedup (`utils/timeline/chaptering.dedup_segment_refs`)
        # is the second line of defence, and unlike this gate it also covers the
        # duplicates that predate it.
        print(f'[sync] claim_synced_file failed for {filename}, failing open: {e}')
        return True


def release_synced_file_claim(
    developer_id: str,
    external_user_id: str,
    filename: str,
) -> None:
    """Undo a claim so a genuinely failed upload can be retried.

    Without this, a file that was claimed and then failed to transcribe would be
    permanently unclaimable — the app would keep re-sending it, the backend would
    keep skipping it, and that audio would never become a conversation. Silent
    permanent data loss is a worse failure than a duplicate.
    """
    try:
        (
            _get_user_ref(developer_id, external_user_id)
            .collection('synced_files')
            .document(_synced_file_doc_id(filename))
            .delete()
        )
    except Exception as e:
        print(f'[sync] release_synced_file_claim failed for {filename}: {e}')


def get_first_conversation_date(
    developer_id: str,
    external_user_id: str,
) -> Optional[datetime]:
    """Earliest completed conversation timestamp — the basis for 陪伴天数.

    There is no stored "companion since" field; the first conversation is a
    truer start of the relationship than account creation (a user can sign up
    and only start wearing the device days later).
    """
    user_ref = _get_user_ref(developer_id, external_user_id)
    query = (
        user_ref.collection('conversations')
        .order_by('created_at', direction=firestore.Query.ASCENDING)
        .limit(1)
    )
    for doc in query.stream():
        data = doc.to_dict() or {}
        created = data.get('created_at')
        if created:
            return created
    return None
