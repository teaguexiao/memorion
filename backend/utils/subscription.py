import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

import database.developer_data as dev_db
import database.user_usage as user_usage_db
from models.user_usage import SUBSCRIPTION_ENFORCEMENT_START_AT, subscription_enforcement_start_at_utc
from models.users import AccessLevel, PlanType, SubscriptionStatus, Subscription, PlanLimits
from utils.audio_jobs.store import AUDIO_JOBS_COLLECTION

FOUNDING_TRIAL_DAYS = int(os.getenv('FOUNDING_TRIAL_DAYS', '90'))
# The one-time production migration completed at this instant. Keeping the
# cutoff in the resolver is a defensive backstop: a historical account can
# never lose Legacy Unlimited merely because its entitlement field is missing.
LEGACY_ACCESS_CUTOFF = datetime(2026, 9, 7, 3, 45, 47, tzinfo=timezone.utc)
BASIC_TIER_MINUTES_LIMIT_PER_MONTH = int(os.getenv('BASIC_TIER_MINUTES_LIMIT_PER_MONTH', '300'))
BASIC_TIER_MONTHLY_SECONDS_LIMIT = BASIC_TIER_MINUTES_LIMIT_PER_MONTH * 60
MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR = 'monthly_cloud_transcription_allowance_exceeded'
MONTHLY_TRANSCRIPTION_UPLOAD_TOO_LARGE_ERROR = 'monthly_cloud_transcription_upload_exceeds_remaining'
BASIC_TIER_WORDS_TRANSCRIBED_LIMIT_PER_MONTH = int(os.getenv('BASIC_TIER_WORDS_TRANSCRIBED_LIMIT_PER_MONTH', '0'))
BASIC_TIER_INSIGHTS_GAINED_LIMIT_PER_MONTH = int(os.getenv('BASIC_TIER_INSIGHTS_GAINED_LIMIT_PER_MONTH', '0'))
BASIC_TIER_MEMORIES_CREATED_LIMIT_PER_MONTH = int(os.getenv('BASIC_TIER_MEMORIES_CREATED_LIMIT_PER_MONTH', '0'))
SUBSCRIPTION_ENFORCEMENT_ENABLED = os.getenv('SUBSCRIPTION_ENFORCEMENT_ENABLED', 'false').lower() == 'true'
APPLE_MONTHLY_PRODUCT_ID = os.getenv('APPLE_MONTHLY_PRODUCT_ID', 'me.memorion.pro.monthly')
APPLE_ANNUAL_PRODUCT_ID = os.getenv('APPLE_ANNUAL_PRODUCT_ID', 'me.memorion.pro.annual')
APPLE_PRODUCT_IDS = {APPLE_MONTHLY_PRODUCT_ID, APPLE_ANNUAL_PRODUCT_ID}


@dataclass(frozen=True)
class EntitlementState:
    access_level: AccessLevel
    plan: PlanType
    active: bool
    trial_ends_at: Optional[datetime] = None
    expires_at: Optional[datetime] = None
    is_legacy: bool = False

    @property
    def has_pro_access(self) -> bool:
        return self.access_level in {
            AccessLevel.legacy_unlimited,
            AccessLevel.founding_trial,
            AccessLevel.pro,
        }


@dataclass(frozen=True)
class UsageReservation:
    allowed: bool
    newly_reserved: bool
    error_code: Optional[str] = None


def _utc(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if isinstance(value, (int, float)):
        # Firestore timestamps arrive as datetime; this also keeps tests and migrations convenient.
        if value > 10_000_000_000:
            value /= 1000
        return datetime.fromtimestamp(value, tz=timezone.utc)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        except (TypeError, ValueError, OverflowError):
            return None
        return parsed.astimezone(timezone.utc) if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    return None


def subscription_enforcement_active(now: Optional[datetime] = None) -> bool:
    """Whether quota blocking is active, including the staged rollout date."""
    if not SUBSCRIPTION_ENFORCEMENT_ENABLED:
        return False
    now = _utc(now) or datetime.now(timezone.utc)
    starts_at = subscription_enforcement_start_at_utc(SUBSCRIPTION_ENFORCEMENT_START_AT)
    return starts_at is not None and now >= starts_at


def resolve_entitlement(user_data: Optional[Dict[str, Any]], now: Optional[datetime] = None) -> EntitlementState:
    """Resolve stored entitlement data without mutating it.

    Missing entitlement data means trial available for post-migration accounts.
    Historical accounts retain Legacy Unlimited through the immutable cutoff,
    even if their explicit migration field is unexpectedly absent.
    """
    now = _utc(now) or datetime.now(timezone.utc)
    entitlement = (user_data or {}).get('entitlement') or {}
    kind = entitlement.get('kind')
    status = entitlement.get('status', 'active')

    if kind == AccessLevel.legacy_unlimited.value:
        return EntitlementState(
            access_level=AccessLevel.legacy_unlimited,
            plan=PlanType.unlimited,
            active=True,
            is_legacy=True,
        )

    if kind == 'apple_subscription':
        raw_expires_at = entitlement.get('expires_at')
        expires_at = _utc(raw_expires_at)
        valid_expiry = raw_expires_at is None or expires_at is not None
        is_active = valid_expiry and status in {'active', 'billing_retry', 'grace_period'} and (
            expires_at is None or expires_at > now
        )
        if is_active:
            return EntitlementState(
                access_level=AccessLevel.pro,
                plan=PlanType.unlimited,
                active=True,
                expires_at=expires_at,
            )
        return EntitlementState(
            access_level=AccessLevel.starter,
            plan=PlanType.basic,
            active=True,
            expires_at=expires_at,
        )

    if kind == AccessLevel.founding_trial.value:
        trial_ends_at = _utc(entitlement.get('trial_ends_at'))
        if trial_ends_at and trial_ends_at > now:
            return EntitlementState(
                access_level=AccessLevel.founding_trial,
                plan=PlanType.unlimited,
                active=True,
                trial_ends_at=trial_ends_at,
            )
        return EntitlementState(
            access_level=AccessLevel.starter,
            plan=PlanType.basic,
            active=True,
            trial_ends_at=trial_ends_at,
        )

    if kind == AccessLevel.starter.value:
        return EntitlementState(access_level=AccessLevel.starter, plan=PlanType.basic, active=True)

    created_at = _utc((user_data or {}).get('created_at'))
    if not entitlement and created_at and created_at <= LEGACY_ACCESS_CUTOFF:
        return EntitlementState(
            access_level=AccessLevel.legacy_unlimited,
            plan=PlanType.unlimited,
            active=True,
            is_legacy=True,
        )

    return EntitlementState(access_level=AccessLevel.trial_available, plan=PlanType.basic, active=True)


def founding_trial_payload(now: Optional[datetime] = None) -> Dict[str, Any]:
    now = _utc(now) or datetime.now(timezone.utc)
    return {
        'kind': AccessLevel.founding_trial.value,
        'status': 'active',
        'trial_started_at': now,
        'trial_ends_at': now + timedelta(days=FOUNDING_TRIAL_DAYS),
        'updated_at': now,
    }


def legacy_unlimited_payload(now: Optional[datetime] = None) -> Dict[str, Any]:
    now = _utc(now) or datetime.now(timezone.utc)
    return {
        'kind': AccessLevel.legacy_unlimited.value,
        'status': 'active',
        'legacy_granted_at': now,
        'updated_at': now,
    }


def ensure_entitlement_for_use(developer_id: str, external_user_id: str) -> EntitlementState:
    """Atomically start the one-time 90-day trial on first meaningful use."""
    user_data = dev_db.ensure_founding_trial(
        developer_id,
        external_user_id,
        founding_trial_payload(),
        legacy_cutoff=LEGACY_ACCESS_CUTOFF,
        legacy_payload=legacy_unlimited_payload(),
    )
    return resolve_entitlement(user_data)


def get_basic_plan_limits() -> PlanLimits:
    """Returns the PlanLimits object for the basic tier."""
    return PlanLimits(
        transcription_seconds=BASIC_TIER_MONTHLY_SECONDS_LIMIT,
        words_transcribed=BASIC_TIER_WORDS_TRANSCRIBED_LIMIT_PER_MONTH,
        insights_gained=BASIC_TIER_INSIGHTS_GAINED_LIMIT_PER_MONTH,
        memories_created=BASIC_TIER_MEMORIES_CREATED_LIMIT_PER_MONTH,
    )


def get_unlimited_plan_limits() -> PlanLimits:
    """Returns unlimited limits (all None = no cap)."""
    return PlanLimits(
        transcription_seconds=None,
        words_transcribed=None,
        insights_gained=None,
        memories_created=None,
    )


def get_default_subscription() -> Subscription:
    """Backward-compatible default for a new, not-yet-started Starter account."""
    return Subscription(plan=PlanType.basic, status=SubscriptionStatus.active, limits=get_basic_plan_limits())


# Backwards-compatible alias retained for older imports.
get_default_basic_subscription = get_default_subscription


def get_plan_limits(plan: PlanType) -> PlanLimits:
    if plan == PlanType.unlimited:
        return get_unlimited_plan_limits()
    return get_basic_plan_limits()


def get_plan_features(plan: PlanType) -> List[str]:
    if plan == PlanType.basic:
        return [
            f"{BASIC_TIER_MINUTES_LIMIT_PER_MONTH} minutes of cloud transcription each month",
            "Unlimited on-device transcription",
            "Your existing history stays available",
        ]
    return [
        "Unlimited listening time",
        "Unlimited words transcribed",
        "Unlimited insights",
        "Unlimited memories",
    ]


def has_transcription_credits(uid: str) -> bool:
    # The non-developer collection is legacy-only in the current app architecture.
    return True


def has_transcription_credits_developer(
    developer_id: str,
    external_user_id: str,
    *,
    additional_seconds: int = 0,
    now: Optional[datetime] = None,
) -> bool:
    """Check cloud allowance, optionally reserving room for a known upload.

    On-device STT bypasses this function at the caller. Batch callers pass the
    validated audio duration so a two-hour upload cannot overshoot a nearly
    exhausted allowance.
    """
    now = _utc(now) or datetime.now(timezone.utc)
    if not subscription_enforcement_active(now):
        return True

    user_data = dev_db.get_user_doc(developer_id, external_user_id)
    state = resolve_entitlement(user_data)
    if state.has_pro_access:
        return True

    # Realtime and batch paths must use the same authority boundary. If the
    # durable counter started after this UTC month began, hourly fallback can
    # report usage but cannot safely enforce under concurrent sessions.
    counter_authoritative, used = user_usage_db.get_monthly_transcription_quota_state(
        external_user_id,
        now,
        developer_id=developer_id,
    )
    if not counter_authoritative:
        return True
    if additional_seconds > 0:
        return used + additional_seconds <= BASIC_TIER_MONTHLY_SECONDS_LIMIT
    return used < BASIC_TIER_MONTHLY_SECONDS_LIMIT


def reserve_transcription_credits_developer(
    developer_id: str,
    external_user_id: str,
    event_id: str,
    transcription_seconds: int,
    *,
    now: Optional[datetime] = None,
    reservation_owner: Optional[str] = None,
    refund_guard_until: Optional[datetime] = None,
) -> bool:
    """Reserve known batch duration exactly once before cloud processing starts."""
    return reserve_transcription_credits_developer_result(
        developer_id,
        external_user_id,
        event_id,
        transcription_seconds,
        now=now,
        reservation_owner=reservation_owner,
        refund_guard_until=refund_guard_until,
    ).allowed


def reserve_transcription_credits_developer_result(
    developer_id: str,
    external_user_id: str,
    event_id: str,
    transcription_seconds: int,
    *,
    now: Optional[datetime] = None,
    reservation_owner: Optional[str] = None,
    refund_guard_until: Optional[datetime] = None,
) -> UsageReservation:
    """Reserve usage and report whether this call created the reservation."""
    now = _utc(now) or datetime.now(timezone.utc)
    user_data = dev_db.get_user_doc(developer_id, external_user_id)
    entitlement = resolve_entitlement(user_data, now)
    if not subscription_enforcement_active(now) or entitlement.has_pro_access:
        recorded = user_usage_db.record_transcription_usage_once(
            external_user_id,
            event_id,
            transcription_seconds,
            developer_id=developer_id,
            occurred_at=now,
            reservation_owner=reservation_owner,
            refund_guard_until=refund_guard_until,
        )
        return UsageReservation(allowed=True, newly_reserved=recorded)
    result = user_usage_db.reserve_transcription_usage_once_result(
        external_user_id,
        event_id,
        transcription_seconds,
        limit_seconds=BASIC_TIER_MONTHLY_SECONDS_LIMIT,
        developer_id=developer_id,
        occurred_at=now,
        reservation_owner=reservation_owner,
        refund_guard_until=refund_guard_until,
    )
    error_code = None
    if result == 'limit_exceeded':
        used = user_usage_db.get_monthly_transcription_seconds(
            external_user_id, now, developer_id=developer_id
        )
        error_code = (
            MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR
            if used >= BASIC_TIER_MONTHLY_SECONDS_LIMIT
            else MONTHLY_TRANSCRIPTION_UPLOAD_TOO_LARGE_ERROR
        )
    return UsageReservation(
        allowed=result != 'limit_exceeded',
        newly_reserved=result in {'recorded', 'recorded_unenforced'},
        error_code=error_code,
    )


def commit_transcription_credits_developer(
    developer_id: str,
    external_user_id: str,
    event_id: str,
    transcription_seconds: int,
    *,
    occurred_at: datetime,
) -> None:
    """Ensure completed provider work remains charged after a stale-lease race."""
    user_usage_db.record_transcription_usage_once(
        external_user_id,
        event_id,
        transcription_seconds,
        developer_id=developer_id,
        occurred_at=occurred_at,
        reservation_owner='committed',
    )


def release_transcription_credits_developer(
    developer_id: str,
    external_user_id: str,
    event_id: str,
    *,
    failed_job_id: Optional[str] = None,
    reservation_owner: Optional[str] = None,
    upload_job_id: Optional[str] = None,
    upload_token: Optional[str] = None,
    job_collection: str = AUDIO_JOBS_COLLECTION,
) -> bool:
    """Refund a failed or speechless batch request if it had reserved usage."""
    return user_usage_db.release_transcription_usage_once(
        external_user_id,
        event_id,
        developer_id=developer_id,
        failed_job_id=failed_job_id,
        reservation_owner=reservation_owner,
        upload_job_id=upload_job_id,
        upload_token=upload_token,
        job_collection=job_collection,
    )
