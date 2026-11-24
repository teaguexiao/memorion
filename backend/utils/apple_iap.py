"""Cryptographically verify StoreKit 2 subscription transactions."""

import re
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.models.Status import Status
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
)

from utils.subscription import APPLE_PRODUCT_IDS

APPLE_BUNDLE_ID = 'me.memorion.api'
APPLE_APP_ID = 6758304534
APPLE_ROOT_CERTIFICATES_PATH = Path(__file__).with_name('apple_root_certificates.pem')


class AppleIAPVerificationError(ValueError):
    pass


@lru_cache(maxsize=1)
def _trusted_roots() -> list[bytes]:
    """Load Apple's published root certificates as DER for its verifier."""
    with APPLE_ROOT_CERTIFICATES_PATH.open(encoding='ascii') as handle:
        pem_bundle = handle.read()
    roots = []
    for block in re.findall(
        r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
        pem_bundle,
        flags=re.DOTALL,
    ):
        cert = x509.load_pem_x509_certificate(block.encode())
        roots.append(cert.public_bytes(serialization.Encoding.DER))
    if not roots:
        raise AppleIAPVerificationError('Apple root certificates are unavailable')
    return roots


@lru_cache(maxsize=2)
def _verifier(environment: Environment) -> SignedDataVerifier:
    return SignedDataVerifier(
        _trusted_roots(),
        enable_online_checks=True,
        environment=environment,
        bundle_id=APPLE_BUNDLE_ID,
        app_apple_id=APPLE_APP_ID if environment == Environment.PRODUCTION else None,
    )


def _verify_signed_transaction(signed_transaction: str) -> tuple[Any, Environment]:
    if not signed_transaction:
        raise AppleIAPVerificationError('Missing signed Apple transaction')
    for environment in (Environment.PRODUCTION, Environment.SANDBOX):
        try:
            return (
                _verifier(environment).verify_and_decode_signed_transaction(signed_transaction),
                environment,
            )
        except VerificationException:
            continue
    raise AppleIAPVerificationError('Apple transaction signature is invalid')


def verify_subscription_transaction(
    transaction_id: str,
    expected_product_id: str,
    signed_transaction: str,
) -> Dict[str, Any]:
    if not transaction_id:
        raise AppleIAPVerificationError('Missing Apple transaction id')
    if expected_product_id not in APPLE_PRODUCT_IDS:
        raise AppleIAPVerificationError('Unknown subscription product')

    payload, environment = _verify_signed_transaction(signed_transaction)
    if payload.bundleId != APPLE_BUNDLE_ID:
        raise AppleIAPVerificationError('Transaction belongs to a different app')
    if payload.productId != expected_product_id:
        raise AppleIAPVerificationError('Transaction product does not match')
    if str(payload.transactionId) != str(transaction_id):
        raise AppleIAPVerificationError('Transaction id does not match signed data')
    if payload.revocationDate is not None:
        raise AppleIAPVerificationError('Subscription was revoked')
    if not payload.originalTransactionId:
        raise AppleIAPVerificationError('Subscription transaction chain is missing')
    if not payload.expiresDate:
        raise AppleIAPVerificationError('Subscription has no expiry date')

    expires_at = datetime.fromtimestamp(payload.expiresDate / 1000, tz=timezone.utc)
    if expires_at <= datetime.now(timezone.utc):
        raise AppleIAPVerificationError('Subscription has expired')

    purchase_ms = payload.purchaseDate or payload.originalPurchaseDate or payload.expiresDate
    return {
        'kind': 'apple_subscription',
        'status': 'active',
        'product_id': payload.productId,
        'transaction_id': str(payload.transactionId),
        'original_transaction_id': str(payload.originalTransactionId),
        'purchase_date': datetime.fromtimestamp(purchase_ms / 1000, tz=timezone.utc),
        'expires_at': expires_at,
        'environment': environment.value,
        'verified_at': datetime.now(timezone.utc),
    }


def verify_server_notification(signed_payload: str) -> Dict[str, Any]:
    """Verify App Store Server Notifications V2 and normalize entitlement state."""
    if not signed_payload:
        raise AppleIAPVerificationError('Missing signed notification')

    notification = None
    environment = None
    for candidate in (Environment.PRODUCTION, Environment.SANDBOX):
        try:
            notification = _verifier(candidate).verify_and_decode_notification(signed_payload)
            environment = candidate
            break
        except VerificationException:
            continue
    if notification is None or environment is None:
        raise AppleIAPVerificationError('Apple notification signature is invalid')

    if not notification.data or not notification.data.signedTransactionInfo:
        return {'test': True, 'notification_uuid': notification.notificationUUID}

    transaction = _verifier(environment).verify_and_decode_signed_transaction(
        notification.data.signedTransactionInfo
    )
    if transaction.productId not in APPLE_PRODUCT_IDS or not transaction.originalTransactionId:
        raise AppleIAPVerificationError('Notification is for an unknown subscription')

    renewal = None
    if notification.data.signedRenewalInfo:
        renewal = _verifier(environment).verify_and_decode_renewal_info(
            notification.data.signedRenewalInfo
        )
        if (
            renewal.originalTransactionId
            and str(renewal.originalTransactionId) != str(transaction.originalTransactionId)
        ):
            raise AppleIAPVerificationError('Renewal info belongs to a different subscription')
        renewal_product_id = renewal.productId or renewal.autoRenewProductId
        if renewal_product_id and renewal_product_id not in APPLE_PRODUCT_IDS:
            raise AppleIAPVerificationError('Renewal info is for an unknown subscription')

    status = notification.data.status
    expires_ms = transaction.expiresDate or 0
    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    if transaction.revocationDate is not None or status == Status.REVOKED:
        status_value = 'revoked'
    elif status == Status.EXPIRED:
        status_value = 'expired'
    elif status == Status.BILLING_RETRY:
        status_value = 'billing_retry'
    elif status == Status.BILLING_GRACE_PERIOD:
        status_value = 'grace_period'
        if renewal and renewal.gracePeriodExpiresDate:
            expires_ms = max(expires_ms, renewal.gracePeriodExpiresDate)
    elif expires_ms and expires_ms <= now_ms:
        # Some notification types omit status. Never turn an already-expired
        # transaction back into active access merely because status is absent.
        status_value = 'expired'
    else:
        status_value = 'active'

    if not expires_ms:
        raise AppleIAPVerificationError('Notification transaction has no expiry date')
    return {
        'test': False,
        'original_transaction_id': str(transaction.originalTransactionId),
        'entitlement': {
            'kind': 'apple_subscription',
            'status': status_value,
            'product_id': transaction.productId,
            'transaction_id': str(transaction.transactionId),
            'original_transaction_id': str(transaction.originalTransactionId),
            'expires_at': datetime.fromtimestamp(expires_ms / 1000, tz=timezone.utc),
            'environment': environment.value,
            'notification_uuid': notification.notificationUUID,
            'verified_at': datetime.now(timezone.utc),
        },
    }
