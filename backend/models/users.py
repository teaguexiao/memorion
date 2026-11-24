from enum import Enum
from typing import Optional, List

from pydantic import BaseModel


class WebhookType(str, Enum):
    audio_bytes = 'audio_bytes'
    audio_bytes_websocket = 'audio_bytes_websocket'
    realtime_transcript = 'realtime_transcript'
    memory_created = ('memory_created',)
    day_summary = 'day_summary'


class PlanType(str, Enum):
    basic = 'basic'
    unlimited = 'unlimited'


class SubscriptionStatus(str, Enum):
    active = 'active'
    inactive = 'inactive'


class AccessLevel(str, Enum):
    legacy_unlimited = 'legacy_unlimited'
    trial_available = 'trial_available'
    founding_trial = 'founding_trial'
    pro = 'pro'
    starter = 'starter'


class PlanLimits(BaseModel):
    transcription_seconds: Optional[int] = None
    words_transcribed: Optional[int] = None
    insights_gained: Optional[int] = None
    memories_created: Optional[int] = None


class Subscription(BaseModel):
    plan: PlanType = PlanType.basic
    status: SubscriptionStatus = SubscriptionStatus.active
    current_period_end: Optional[int] = None
    stripe_subscription_id: Optional[str] = None
    features: List[str] = []
    cancel_at_period_end: bool = False
    limits: PlanLimits = PlanLimits()


class PricingOption(BaseModel):
    id: str  # price_id
    title: str
    description: Optional[str] = None
    price_string: str


class SubscriptionPlan(BaseModel):
    id: str  # e.g., 'unlimited'
    title: str
    features: List[str] = []
    prices: List[PricingOption] = []


class UserSubscriptionResponse(BaseModel):
    subscription: Subscription
    transcription_seconds_used: int
    transcription_seconds_limit: int
    words_transcribed_used: int
    words_transcribed_limit: int
    insights_gained_used: int
    insights_gained_limit: int
    memories_created_used: int
    memories_created_limit: int
    # Always expose the Starter allowance so Pro and trial users can compare
    # plans without showing their personal consumption.
    starter_transcription_seconds_limit: int = 18_000
    available_plans: List[SubscriptionPlan] = []
    show_subscription_ui: bool = True
    access_level: AccessLevel = AccessLevel.starter
    trial_ends_at: Optional[int] = None
    trial_days_remaining: Optional[int] = None
    is_legacy: bool = False
    can_purchase: bool = False
