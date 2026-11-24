import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from models.users import AccessLevel, PlanType
from models import user_usage as usage_models
from utils import subscription


NOW = datetime(2026, 9, 7, 12, 0, tzinfo=timezone.utc)


class SubscriptionEntitlementTests(unittest.TestCase):
    def test_missing_entitlement_is_trial_available_not_legacy(self):
        state = subscription.resolve_entitlement({}, NOW)
        self.assertEqual(state.access_level, AccessLevel.trial_available)
        self.assertEqual(state.plan, PlanType.basic)
        self.assertFalse(state.is_legacy)

    def test_historical_account_without_entitlement_keeps_legacy_access(self):
        state = subscription.resolve_entitlement(
            {'created_at': subscription.LEGACY_ACCESS_CUTOFF - timedelta(seconds=1)},
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.legacy_unlimited)
        self.assertTrue(state.has_pro_access)
        self.assertTrue(state.is_legacy)

    def test_post_migration_account_without_entitlement_gets_trial(self):
        state = subscription.resolve_entitlement(
            {'created_at': subscription.LEGACY_ACCESS_CUTOFF + timedelta(seconds=1)},
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.trial_available)
        self.assertFalse(state.has_pro_access)

    def test_initial_entitlement_write_receives_legacy_cutoff(self):
        historical = {
            'created_at': subscription.LEGACY_ACCESS_CUTOFF - timedelta(seconds=1),
            'entitlement': {'kind': 'legacy_unlimited', 'status': 'active'},
        }
        with mock.patch.object(
            subscription.dev_db,
            'ensure_founding_trial',
            return_value=historical,
        ) as ensure:
            state = subscription.ensure_entitlement_for_use('dev', 'user')

        self.assertTrue(state.is_legacy)
        self.assertEqual(
            ensure.call_args.kwargs['legacy_cutoff'],
            subscription.LEGACY_ACCESS_CUTOFF,
        )
        self.assertEqual(
            ensure.call_args.kwargs['legacy_payload']['kind'],
            'legacy_unlimited',
        )

    def test_legacy_is_permanently_unlimited(self):
        state = subscription.resolve_entitlement(
            {'entitlement': {'kind': 'legacy_unlimited', 'status': 'active'}},
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.legacy_unlimited)
        self.assertTrue(state.has_pro_access)
        self.assertTrue(state.is_legacy)

    def test_active_trial_has_pro_access(self):
        state = subscription.resolve_entitlement(
            {
                'entitlement': {
                    'kind': 'founding_trial',
                    'status': 'active',
                    'trial_ends_at': NOW + timedelta(days=1),
                },
            },
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.founding_trial)
        self.assertEqual(state.plan, PlanType.unlimited)
        self.assertTrue(state.has_pro_access)

    def test_expired_trial_downgrades_without_losing_the_record(self):
        state = subscription.resolve_entitlement(
            {
                'entitlement': {
                    'kind': 'founding_trial',
                    'status': 'active',
                    'trial_ends_at': NOW - timedelta(seconds=1),
                },
            },
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.starter)
        self.assertEqual(state.plan, PlanType.basic)
        self.assertFalse(state.has_pro_access)

    def test_expired_billing_retry_downgrades_to_starter(self):
        state = subscription.resolve_entitlement(
            {
                'entitlement': {
                    'kind': 'apple_subscription',
                    'status': 'billing_retry',
                    'expires_at': NOW - timedelta(seconds=1),
                },
            },
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.starter)
        self.assertFalse(state.has_pro_access)

    def test_grace_period_keeps_pro_access_until_grace_expiry(self):
        state = subscription.resolve_entitlement(
            {
                'entitlement': {
                    'kind': 'apple_subscription',
                    'status': 'grace_period',
                    'expires_at': NOW + timedelta(days=1),
                },
            },
            NOW,
        )
        self.assertEqual(state.access_level, AccessLevel.pro)
        self.assertTrue(state.has_pro_access)

    def test_trial_payload_is_exactly_ninety_days(self):
        payload = subscription.founding_trial_payload(NOW)
        self.assertEqual(payload['trial_started_at'], NOW)
        self.assertEqual(payload['trial_ends_at'], NOW + timedelta(days=90))

    def test_starter_limit_converts_minutes_to_seconds(self):
        self.assertEqual(
            subscription.BASIC_TIER_MONTHLY_SECONDS_LIMIT,
            subscription.BASIC_TIER_MINUTES_LIMIT_PER_MONTH * 60,
        )

    def test_enforcement_allows_pro_without_reading_usage(self):
        future = datetime.now(timezone.utc) + timedelta(days=1)
        unlimited_entitlements = (
            {'kind': 'legacy_unlimited'},
            {
                'kind': 'founding_trial',
                'status': 'active',
                'trial_ends_at': future,
            },
            {
                'kind': 'apple_subscription',
                'status': 'active',
                'expires_at': future,
            },
        )
        for entitlement in unlimited_entitlements:
            with self.subTest(kind=entitlement['kind']), \
                    mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                    mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2000-01-01T00:00:00Z'), \
                    mock.patch.object(subscription, 'BASIC_TIER_MONTHLY_SECONDS_LIMIT', 300 * 60), \
                    mock.patch.object(
                        subscription.dev_db,
                        'get_user_doc',
                        return_value={'entitlement': entitlement},
                    ), \
                    mock.patch.object(
                        subscription.user_usage_db,
                        'get_monthly_transcription_quota_state',
                    ) as usage:
                self.assertTrue(subscription.has_transcription_credits_developer('dev', 'user'))
                usage.assert_not_called()

    def test_enforcement_blocks_starter_at_monthly_limit(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2000-01-01T00:00:00Z'), \
                mock.patch.object(subscription, 'BASIC_TIER_MONTHLY_SECONDS_LIMIT', 300 * 60), \
                mock.patch.object(
                    subscription.dev_db,
                    'get_user_doc',
                    return_value={'entitlement': {'kind': 'starter'}},
                ), \
                mock.patch.object(
                    subscription.user_usage_db,
                    'get_monthly_transcription_quota_state',
                    return_value=(True, 300 * 60),
                ):
            self.assertFalse(subscription.has_transcription_credits_developer('dev', 'user'))

    def test_incomplete_month_does_not_enforce_realtime_allowance(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2000-01-01T00:00:00Z'), \
                mock.patch.object(
                    subscription.dev_db,
                    'get_user_doc',
                    return_value={'entitlement': {'kind': 'starter'}},
                ), \
                mock.patch.object(
                    subscription.user_usage_db,
                    'get_monthly_transcription_quota_state',
                    return_value=(False, 0),
                ) as quota:
            self.assertTrue(subscription.has_transcription_credits_developer('dev', 'user'))
            quota.assert_called_once()

    def test_enforcement_start_date_preserves_current_month(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2026-10-01T00:00:00Z'), \
                mock.patch.object(subscription.dev_db, 'get_user_doc') as user_doc:
            self.assertTrue(
                subscription.has_transcription_credits_developer(
                    'dev',
                    'user',
                    now=datetime(2026, 9, 30, 23, 59, tzinfo=timezone.utc),
                )
            )
            user_doc.assert_not_called()

    def test_invalid_enforcement_start_does_not_break_requests(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', 'not-a-date'):
            self.assertFalse(subscription.subscription_enforcement_active())

    def test_midmonth_enforcement_waits_for_next_complete_utc_month(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2026-10-15T12:00:00Z'):
            self.assertFalse(subscription.subscription_enforcement_active(datetime(2026, 10, 31, tzinfo=timezone.utc)))
            self.assertTrue(subscription.subscription_enforcement_active(datetime(2026, 11, 1, tzinfo=timezone.utc)))

    def test_monthly_counter_is_authoritative_only_if_live_before_month_start(self):
        october = datetime(2026, 10, 15, tzinfo=timezone.utc)
        with mock.patch.object(usage_models, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2026-10-01T00:00:00Z'):
            self.assertTrue(
                usage_models.subscription_counter_covers_month(october, '2026-09-21T00:00:00Z')
            )
            self.assertFalse(
                usage_models.subscription_counter_covers_month(october, '2026-10-02T00:00:00Z')
            )
            self.assertTrue(
                usage_models.subscription_counter_covers_month(
                    datetime(2026, 11, 1, tzinfo=timezone.utc),
                    '2026-10-02T00:00:00Z',
                )
            )
            self.assertFalse(usage_models.subscription_counter_covers_month(october))

    def test_invalid_apple_expiry_does_not_grant_pro(self):
        state = subscription.resolve_entitlement({
            'entitlement': {
                'kind': 'apple_subscription',
                'status': 'active',
                'expires_at': 'not-a-date',
            },
        })
        self.assertEqual(state.access_level, subscription.AccessLevel.starter)

    def test_known_upload_duration_cannot_overshoot_allowance(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2000-01-01T00:00:00Z'), \
                mock.patch.object(subscription, 'BASIC_TIER_MONTHLY_SECONDS_LIMIT', 300 * 60), \
                mock.patch.object(
                    subscription.dev_db,
                    'get_user_doc',
                    return_value={'entitlement': {'kind': 'starter'}},
                ), \
                mock.patch.object(
                    subscription.user_usage_db,
                    'get_monthly_transcription_quota_state',
                    return_value=(True, 295 * 60),
                ):
            self.assertFalse(
                subscription.has_transcription_credits_developer(
                    'dev',
                    'user',
                    additional_seconds=6 * 60,
                )
            )
            self.assertTrue(
                subscription.has_transcription_credits_developer(
                    'dev',
                    'user',
                    additional_seconds=5 * 60,
                )
            )

    def test_reservation_distinguishes_exhausted_from_upload_too_large(self):
        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2000-01-01T00:00:00Z'), \
                mock.patch.object(subscription, 'BASIC_TIER_MONTHLY_SECONDS_LIMIT', 18_000), \
                mock.patch.object(subscription.dev_db, 'get_user_doc', return_value={'entitlement': {'kind': 'starter'}}), \
                mock.patch.object(subscription.user_usage_db, 'reserve_transcription_usage_once_result', return_value='limit_exceeded'), \
                mock.patch.object(subscription.user_usage_db, 'get_monthly_transcription_seconds', return_value=17_900):
            result = subscription.reserve_transcription_credits_developer_result('dev', 'user', 'event', 600)
            self.assertEqual(result.error_code, subscription.MONTHLY_TRANSCRIPTION_UPLOAD_TOO_LARGE_ERROR)

        with mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_ENABLED', True), \
                mock.patch.object(subscription, 'SUBSCRIPTION_ENFORCEMENT_START_AT', '2000-01-01T00:00:00Z'), \
                mock.patch.object(subscription, 'BASIC_TIER_MONTHLY_SECONDS_LIMIT', 18_000), \
                mock.patch.object(subscription.dev_db, 'get_user_doc', return_value={'entitlement': {'kind': 'starter'}}), \
                mock.patch.object(subscription.user_usage_db, 'reserve_transcription_usage_once_result', return_value='limit_exceeded'), \
                mock.patch.object(subscription.user_usage_db, 'get_monthly_transcription_seconds', return_value=18_000):
            result = subscription.reserve_transcription_credits_developer_result('dev', 'user', 'event', 600)
            self.assertEqual(result.error_code, subscription.MONTHLY_TRANSCRIPTION_ALLOWANCE_ERROR)


if __name__ == '__main__':
    unittest.main()
