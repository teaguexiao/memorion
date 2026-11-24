from typing import List, Dict, Any, Union
import os

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
import firebase_admin
from firebase_admin import auth as firebase_auth

import database.developer_data as dev_db
from database import (
    user_usage as user_usage_db,
)
from database.redis_db import (
    cache_user_geolocation,
    set_user_data_protection_level,
    delete_generic_cache,
)
from database.users import (
    set_conversation_summary_rating_score,
    get_conversation_summary_rating_score,
    set_chat_message_rating_score,
    delete_user_data as delete_user_firestore_data,
)
from models.conversation import Geolocation
from models.developer import MEMORION_APP_DEVELOPER_ID
from typing import Optional
from models.user_usage import UserUsageResponse, UsagePeriod
from datetime import datetime, timezone
import math

from models.users import (
    AccessLevel,
    PricingOption,
    SubscriptionPlan,
    UserSubscriptionResponse,
    PlanType,
    SubscriptionStatus,
    Subscription,
)
from utils.subscription import (
    APPLE_ANNUAL_PRODUCT_ID,
    APPLE_MONTHLY_PRODUCT_ID,
    BASIC_TIER_MONTHLY_SECONDS_LIMIT,
    get_plan_features,
    get_plan_limits,
    resolve_entitlement,
)
from utils.other import endpoints as auth
from utils.other.storage import (
    delete_conversation_recordings,
    delete_all_user_speech_data,
)

router = APIRouter()


class UpdateNameRequest(BaseModel):
    name: str


class UpdateBirthdayRequest(BaseModel):
    birthday: str  # 'YYYY-MM-DD'


class VerifyAppleSubscriptionRequest(BaseModel):
    transaction_id: str
    product_id: str
    signed_transaction: str


class AppleServerNotificationRequest(BaseModel):
    signedPayload: str


@router.get('/v1/users/profile', tags=['v1'])
def get_user_profile_endpoint(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    profile = dev_db.get_user_profile(developer_id, uid) if developer_id else None
    if not profile:
        raise HTTPException(status_code=410, detail="User not found")
    return profile


@router.delete('/v1/users/delete-account', tags=['v1'])
def delete_account(ctx: tuple = Depends(auth.get_current_user_context_for_deletion)):
    developer_id, uid = ctx
    try:
        delete_conversation_recordings(dev_db.get_user_recording_paths(developer_id, uid))
        if developer_id == MEMORION_APP_DEVELOPER_ID:
            delete_all_user_speech_data(uid)
            delete_user_firestore_data(uid)
            try:
                fcm_app = firebase_admin.get_app('fcm')
                firebase_auth.delete_user(uid, app=fcm_app)
            except (ValueError, firebase_auth.UserNotFoundError):
                pass

            try:
                firebase_auth.delete_user(uid)
            except firebase_auth.UserNotFoundError:
                pass

        dev_db.delete_user_data(developer_id, uid)
        return {'status': 'ok', 'message': 'Account deleted successfully'}
    except Exception as e:
        print(f"Account deletion failed: {type(e).__name__}")
        raise HTTPException(status_code=500, detail="Account deletion failed")


@router.patch('/v1/users/geolocation', tags=['v1'])
def set_user_geolocation(geolocation: Geolocation, ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    cache_user_geolocation(uid, geolocation.dict())
    if developer_id:
        dev_db.set_user_geolocation(developer_id, uid, geolocation.dict())
    return {'status': 'ok'}


# *************************************************
# ************* RECORDING PERMISSION **************
# *************************************************


@router.post('/v1/users/store-recording-permission', tags=['v1'])
def store_recording_permission(value: bool, ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    if developer_id:
        dev_db.store_recording_permission(developer_id, uid, {'store_recording_permission': value})
    return {'status': 'ok'}


@router.get('/v1/users/store-recording-permission', tags=['v1'])
def get_store_recording_permission(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    if developer_id:
        perm = dev_db.get_recording_permission(developer_id, uid)
        return {'store_recording_permission': perm.get('store_recording_permission', False) if perm else False}
    return {'store_recording_permission': False}


@router.delete('/v1/users/store-recording-permission', tags=['v1'])
def delete_permission_and_recordings(ctx: tuple = Depends(auth.get_current_user_context_for_deletion)):
    developer_id, uid = ctx
    dev_db.store_recording_permission(developer_id, uid, {'store_recording_permission': False})
    from utils.audio_jobs.cleanup import delete_owner_jobs

    delete_owner_jobs(developer_id, uid)
    delete_conversation_recordings(dev_db.get_user_recording_paths(developer_id, uid))
    return {'status': 'ok'}


# **************************************
# ************* Analytics **************
# **************************************


@router.post('/v1/users/analytics/memory_summary', tags=['v1'])
def set_memory_summary_rating(
    memory_id: str,
    value: int,
    uid: str = Depends(auth.get_current_user_uid),
):
    set_conversation_summary_rating_score(uid, memory_id, value)
    return {'status': 'ok'}


@router.get('/v1/users/analytics/memory_summary', tags=['v1'])
def get_memory_summary_rating(
    memory_id: str,
    _: str = Depends(auth.get_current_user_uid),
):
    rating = get_conversation_summary_rating_score(memory_id)
    if not rating:
        return {'has_rating': False}
    return {'has_rating': rating.get('value', -1) != -1, 'rating': rating.get('value', -1)}


@router.post('/v1/users/analytics/chat_message', tags=['v1'])
def set_chat_message_analytics(
    message_id: str,
    value: int,
    uid: str = Depends(auth.get_current_user_uid),
):
    set_chat_message_rating_score(uid, message_id, value)
    return {'status': 'ok'}


# ***************************************
# ************* Display Name ************
# ***************************************


@router.get('/v1/users/name', tags=['v1'])
def get_user_name_endpoint(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    name = dev_db.get_user_name(developer_id, uid) if developer_id else None
    return {'name': name}


@router.patch('/v1/users/name', tags=['v1'])
def set_user_name_endpoint(data: UpdateNameRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    import re
    name = data.name.strip()
    name = re.sub(r'[\x00-\x1f\x7f]', '', name)
    if not name or len(name) > 40:
        raise HTTPException(status_code=400, detail="Name is required and must be <= 40 characters")
    if developer_id:
        dev_db.set_user_name(developer_id, uid, name)
    return {'status': 'ok'}


# ***************************************
# ************* Birthday ****************
# ***************************************


@router.get('/v1/users/birthday', tags=['v1'])
def get_user_birthday_endpoint(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    birthday = dev_db.get_user_birthday(developer_id, uid) if developer_id else None
    return {'birthday': birthday}


@router.patch('/v1/users/birthday', tags=['v1'])
def set_user_birthday_endpoint(data: UpdateBirthdayRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    import re

    birthday = (data.birthday or '').strip()
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', birthday):
        raise HTTPException(status_code=400, detail="birthday must be in YYYY-MM-DD format")
    try:
        bd = datetime.strptime(birthday, '%Y-%m-%d').date()
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid birthday")
    if bd > datetime.utcnow().date():
        raise HTTPException(status_code=400, detail="birthday cannot be in the future")
    if developer_id:
        dev_db.set_user_birthday(developer_id, uid, birthday)
        # Invalidate today's cached fortune so a birthday change recomputes it.
        today_str = datetime.utcnow().strftime('%Y-%m-%d')
        delete_generic_cache(f'fortune:{uid}:{today_str}')
    return {'status': 'ok'}


# **************************************
# ************* Usage ******************
# **************************************


@router.get('/v1/users/me/usage', tags=['v1'], response_model=UserUsageResponse)
def get_user_usage_stats_endpoint(
    ctx: tuple = Depends(auth.get_current_user_context),
    period: UsagePeriod = UsagePeriod.TODAY,
):
    developer_id, uid = ctx
    stats = user_usage_db.get_current_user_usage(uid, period.value, developer_id=developer_id)
    return stats


@router.get('/v1/users/me/subscription', tags=['v1'], response_model=UserSubscriptionResponse)
def get_user_subscription_endpoint(ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    state = resolve_entitlement(dev_db.get_user_doc(developer_id, uid))
    subscription = Subscription(
        plan=state.plan,
        status=SubscriptionStatus.active,
        current_period_end=int(state.expires_at.timestamp()) if state.expires_at else None,
        limits=get_plan_limits(state.plan),
        features=get_plan_features(state.plan),
    )

    # These counters stay in the response for old app versions, but the new
    # subscription screen intentionally does not expose minutes or consumption.
    usage = user_usage_db.get_monthly_usage_stats(uid, datetime.utcnow(), developer_id=developer_id)
    trial_days_remaining = None
    if state.trial_ends_at:
        remaining = state.trial_ends_at - datetime.now(timezone.utc)
        trial_days_remaining = max(0, math.ceil(remaining.total_seconds() / 86400))

    can_purchase = state.access_level == AccessLevel.starter or (
        state.access_level == AccessLevel.founding_trial
        and trial_days_remaining is not None
        and trial_days_remaining <= 14
    )

    return UserSubscriptionResponse(
        subscription=subscription,
        transcription_seconds_used=usage.get('transcription_seconds', 0),
        transcription_seconds_limit=(
            0 if state.has_pro_access else BASIC_TIER_MONTHLY_SECONDS_LIMIT
        ),
        words_transcribed_used=usage.get('words_transcribed', 0),
        words_transcribed_limit=0,
        insights_gained_used=usage.get('insights_gained', 0),
        insights_gained_limit=0,
        memories_created_used=usage.get('memories_created', 0),
        memories_created_limit=0,
        starter_transcription_seconds_limit=BASIC_TIER_MONTHLY_SECONDS_LIMIT,
        available_plans=[
            SubscriptionPlan(
                id='pro',
                title='Memorion Pro',
                features=get_plan_features(PlanType.unlimited),
                prices=[
                    PricingOption(
                        id=APPLE_MONTHLY_PRODUCT_ID,
                        title='Monthly',
                        price_string='$14.99/month',
                    ),
                    PricingOption(
                        id=APPLE_ANNUAL_PRODUCT_ID,
                        title='Annual',
                        description='Save about 17%',
                        price_string='$149.99/year',
                    ),
                ],
            ),
        ],
        show_subscription_ui=True,
        access_level=state.access_level,
        trial_ends_at=int(state.trial_ends_at.timestamp()) if state.trial_ends_at else None,
        trial_days_remaining=trial_days_remaining,
        is_legacy=state.is_legacy,
        can_purchase=can_purchase,
    )


@router.post('/v1/users/me/subscription/apple/verify', tags=['v1'], response_model=UserSubscriptionResponse)
def verify_apple_subscription_endpoint(
    request: VerifyAppleSubscriptionRequest,
    ctx: tuple = Depends(auth.get_current_user_context),
):
    developer_id, uid = ctx
    try:
        from utils.apple_iap import (
            AppleIAPVerificationError,
            verify_subscription_transaction,
        )

        entitlement = verify_subscription_transaction(
            request.transaction_id,
            request.product_id,
            request.signed_transaction,
        )
        dev_db.activate_apple_subscription(developer_id, uid, entitlement)
    except (AppleIAPVerificationError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return get_user_subscription_endpoint(ctx=ctx)


@router.post('/v1/apple/app-store/notifications', tags=['apple-iap'])
def apple_server_notification_endpoint(request: AppleServerNotificationRequest):
    from utils.apple_iap import AppleIAPVerificationError, verify_server_notification

    try:
        result = verify_server_notification(request.signedPayload)
        if not result.get('test'):
            dev_db.update_apple_subscription_from_notification(
                result['original_transaction_id'],
                result['entitlement'],
            )
        return {'status': 'ok'}
    except AppleIAPVerificationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
