import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest import mock

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.Status import Status
from cryptography import x509
from utils import apple_iap


class AppleIAPEntitlementTests(unittest.TestCase):
    def test_bundled_trust_store_contains_apple_roots(self):
        apple_iap._trusted_roots.cache_clear()
        roots = [x509.load_der_x509_certificate(value) for value in apple_iap._trusted_roots()]
        subjects = {certificate.subject.rfc4514_string() for certificate in roots}
        self.assertTrue(any('Apple Root CA - G2' in subject for subject in subjects))
        self.assertTrue(any('Apple Root CA - G3' in subject for subject in subjects))

    def _payload(self, **overrides):
        now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        values = {
            'bundleId': apple_iap.APPLE_BUNDLE_ID,
            'productId': 'me.memorion.pro.monthly',
            'transactionId': '200000000000001',
            'originalTransactionId': '200000000000000',
            'revocationDate': None,
            'expiresDate': now_ms + int(timedelta(days=30).total_seconds() * 1000),
            'purchaseDate': now_ms,
            'originalPurchaseDate': now_ms,
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    def test_verified_transaction_becomes_active_entitlement(self):
        with mock.patch.object(
            apple_iap,
            '_verify_signed_transaction',
            return_value=(self._payload(), Environment.SANDBOX),
        ):
            result = apple_iap.verify_subscription_transaction(
                '200000000000001',
                'me.memorion.pro.monthly',
                'signed-jws',
            )

        self.assertEqual(result['kind'], 'apple_subscription')
        self.assertEqual(result['status'], 'active')
        self.assertEqual(result['original_transaction_id'], '200000000000000')
        self.assertEqual(result['environment'], 'Sandbox')

    def test_product_mismatch_is_rejected(self):
        with mock.patch.object(
            apple_iap,
            '_verify_signed_transaction',
            return_value=(
                self._payload(productId='me.memorion.pro.annual'),
                Environment.SANDBOX,
            ),
        ):
            with self.assertRaisesRegex(apple_iap.AppleIAPVerificationError, 'product'):
                apple_iap.verify_subscription_transaction(
                    '200000000000001',
                    'me.memorion.pro.monthly',
                    'signed-jws',
                )

    def test_expired_transaction_is_rejected(self):
        expired = int((datetime.now(timezone.utc) - timedelta(seconds=1)).timestamp() * 1000)
        with mock.patch.object(
            apple_iap,
            '_verify_signed_transaction',
            return_value=(self._payload(expiresDate=expired), Environment.PRODUCTION),
        ):
            with self.assertRaisesRegex(apple_iap.AppleIAPVerificationError, 'expired'):
                apple_iap.verify_subscription_transaction(
                    '200000000000001',
                    'me.memorion.pro.monthly',
                    'signed-jws',
                )

    def _notification_verifier(self, transaction, status=None, renewal=None):
        notification = SimpleNamespace(
            data=SimpleNamespace(
                signedTransactionInfo='signed-transaction',
                signedRenewalInfo='signed-renewal' if renewal else None,
                status=status,
            ),
            notificationUUID='notification-uuid',
        )
        verifier = mock.Mock()
        verifier.verify_and_decode_notification.return_value = notification
        verifier.verify_and_decode_signed_transaction.return_value = transaction
        verifier.verify_and_decode_renewal_info.return_value = renewal
        return verifier

    def test_grace_period_uses_verified_grace_expiry(self):
        now = datetime.now(timezone.utc)
        transaction = self._payload(
            expiresDate=int((now - timedelta(days=1)).timestamp() * 1000),
        )
        grace_expiry = int((now + timedelta(days=5)).timestamp() * 1000)
        renewal = SimpleNamespace(
            originalTransactionId=transaction.originalTransactionId,
            productId=transaction.productId,
            autoRenewProductId=transaction.productId,
            gracePeriodExpiresDate=grace_expiry,
        )
        verifier = self._notification_verifier(
            transaction,
            Status.BILLING_GRACE_PERIOD,
            renewal,
        )

        with mock.patch.object(apple_iap, '_verifier', return_value=verifier):
            result = apple_iap.verify_server_notification('signed-notification')

        self.assertEqual(result['entitlement']['status'], 'grace_period')
        self.assertEqual(
            result['entitlement']['expires_at'],
            datetime.fromtimestamp(grace_expiry / 1000, tz=timezone.utc),
        )
        verifier.verify_and_decode_renewal_info.assert_called_once_with('signed-renewal')

    def test_missing_status_does_not_reactivate_expired_transaction(self):
        expired = int((datetime.now(timezone.utc) - timedelta(seconds=1)).timestamp() * 1000)
        verifier = self._notification_verifier(self._payload(expiresDate=expired))

        with mock.patch.object(apple_iap, '_verifier', return_value=verifier):
            result = apple_iap.verify_server_notification('signed-notification')

        self.assertEqual(result['entitlement']['status'], 'expired')

    def test_revocation_date_overrides_active_status(self):
        revoked = int(datetime.now(timezone.utc).timestamp() * 1000)
        verifier = self._notification_verifier(
            self._payload(revocationDate=revoked),
            Status.ACTIVE,
        )

        with mock.patch.object(apple_iap, '_verifier', return_value=verifier):
            result = apple_iap.verify_server_notification('signed-notification')

        self.assertEqual(result['entitlement']['status'], 'revoked')


if __name__ == '__main__':
    unittest.main()
