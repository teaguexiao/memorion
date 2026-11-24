"""
Tests for the App login token exchange (POST /v1/auth/app-token).

Phase 1 of the API-key auth fix: each App user gets a key bound to their own
Firebase uid, replacing the single shared key compiled into the binary.

What must hold:
  - the issued key works for the caller's own uid and 403s for anyone else's
  - re-login REPLACES the previous App key (the old one stops working) — the
    App has no key-management UI, so accumulating keys would be unrevocable
  - replacement is scoped: another user's keys and this user's CLI keys survive
  - the embedded (unbound) key keeps working — old app versions must not break

Run:
    cd backend && python tests/test_app_token_exchange.py

Uses in-memory fakes for Firestore and Redis, so no external services needed.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

# Installs the Firestore/Redis fakes as an import side effect, and gives us the
# shared TestClient with the /test/query data-plane probe already mounted.
#
# ⚠️ No `tests.` prefix. `tests/` has no `__init__.py`, so pytest loads it under
# the bare name `test_bound_api_keys`; the prefixed form loads a *second*,
# independent module object whose import side effect repoints `redis_db.r` at a
# fresh FakeRedis — and then test_bound_api_keys' own cache assertions see an
# empty dict. Each file passes alone; only a combined run fails.
from test_bound_api_keys import (  # noqa: E402
    OFFICIAL_DEV,
    app,
    client,
    developers_db,
    fake_db,
    fake_redis,
    _seed_official_developer,
)

import routers.app_auth as app_auth  # noqa: E402
from models.developer import ApiKeyCreate, ApiKeyEnvironment  # noqa: E402

app.include_router(app_auth.router)


class AppTokenExchangeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _seed_official_developer()

    def setUp(self):
        fake_redis.data.clear()
        self._orig_verify = app_auth._verify_firebase_token

    def tearDown(self):
        app_auth._verify_firebase_token = self._orig_verify

    def _login_as(self, uid):
        """Exchange a Firebase token for a bound App key, as `uid` would."""
        app_auth._verify_firebase_token = lambda credentials: {
            "uid": uid,
            "email": f"{uid}@example.com",
        }
        resp = client.post(
            "/v1/auth/app-token",
            headers={"Authorization": "Bearer fake-firebase-token"},
        )
        return resp

    def _probe(self, api_key, uid):
        return client.get(
            "/test/query",
            params={"external_user_id": uid},
            headers={"Authorization": api_key},
        )

    # ---------- the key it hands out ----------

    def test_issues_key_bound_to_caller(self):
        resp = self._login_as("uid_app_1")
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertEqual(data["external_user_id"], "uid_app_1")
        self.assertTrue(data["api_key"].startswith("memorion_dev_prod_"))

        # Works for its own user...
        ok = self._probe(data["api_key"], "uid_app_1")
        self.assertEqual(ok.status_code, 200, ok.text)
        self.assertEqual(ok.json()["developer_id"], OFFICIAL_DEV)

        # ...and cannot reach anyone else. This is the whole point of Phase 1.
        bad = self._probe(data["api_key"], "uid_someone_else")
        self.assertEqual(bad.status_code, 403, bad.text)

    def test_missing_firebase_token_401(self):
        resp = client.post("/v1/auth/app-token")
        self.assertEqual(resp.status_code, 401)

    # ---------- re-login replaces, never accumulates ----------

    def test_relogin_revokes_previous_app_key(self):
        first = self._login_as("uid_app_2").json()["api_key"]
        self.assertEqual(self._probe(first, "uid_app_2").status_code, 200)

        second = self._login_as("uid_app_2").json()["api_key"]
        self.assertNotEqual(first, second)

        fake_redis.data.clear()  # don't let a cached entry mask revocation
        self.assertEqual(self._probe(second, "uid_app_2").status_code, 200)
        self.assertEqual(
            self._probe(first, "uid_app_2").status_code,
            401,
            "the superseded key must be dead",
        )

    def test_repeated_logins_leave_exactly_one_key(self):
        for _ in range(5):
            self.assertEqual(self._login_as("uid_app_3").status_code, 200)
        keys = [
            k
            for k in developers_db.get_api_keys_for_developer(OFFICIAL_DEV)
            if k.bound_external_user_id == "uid_app_3"
        ]
        self.assertEqual(len(keys), 1, [k.name for k in keys])
        self.assertEqual(keys[0].name, app_auth.APP_KEY_NAME)

    # ---------- revocation stays in its lane ----------

    def test_other_users_keys_untouched(self):
        alice = self._login_as("uid_app_alice").json()["api_key"]
        self._login_as("uid_app_bob")

        fake_redis.data.clear()
        self.assertEqual(
            self._probe(alice, "uid_app_alice").status_code,
            200,
            "bob logging in must not revoke alice's key",
        )

    def test_cli_key_for_same_user_untouched(self):
        """CLI keys are user-revocable and long-lived; App login must not eat them."""
        cli_raw, _ = developers_db.create_api_key(
            OFFICIAL_DEV,
            ApiKeyCreate(
                name="Memorion CLI",
                environment=ApiKeyEnvironment.PROD,
                bound_external_user_id="uid_app_4",
            ),
        )
        self._login_as("uid_app_4")

        fake_redis.data.clear()
        self.assertEqual(self._probe(cli_raw, "uid_app_4").status_code, 200)

    # ---------- zero client impact for existing builds ----------

    def test_embedded_unbound_key_still_works(self):
        """
        Old App versions keep using the shared embedded key. Phase 1 must not
        touch it — it stays valid until Phase 2 revokes it deliberately.
        """
        unbound_raw, _ = developers_db.create_api_key(
            OFFICIAL_DEV,
            ApiKeyCreate(name="Mobile App (embedded)", environment=ApiKeyEnvironment.PROD),
        )
        self._login_as("uid_app_5")

        fake_redis.data.clear()
        for uid in ["uid_app_5", "uid_anyone"]:
            resp = self._probe(unbound_raw, uid)
            self.assertEqual(resp.status_code, 200, resp.text)

    # ---------- the safety net ----------

    def test_cap_refuses_when_revocation_is_broken(self):
        """
        If revocation silently fails, the cap must stop unbounded minting rather
        than letting one user accumulate keys forever.
        """
        orig = developers_db.revoke_bound_api_keys_by_name
        developers_db.revoke_bound_api_keys_by_name = lambda *a, **k: 0
        orig_max, app_auth.MAX_APP_KEYS_PER_USER = app_auth.MAX_APP_KEYS_PER_USER, 2
        try:
            self.assertEqual(self._login_as("uid_app_6").status_code, 200)
            self.assertEqual(self._login_as("uid_app_6").status_code, 200)
            self.assertEqual(self._login_as("uid_app_6").status_code, 429)
        finally:
            developers_db.revoke_bound_api_keys_by_name = orig
            app_auth.MAX_APP_KEYS_PER_USER = orig_max

    def test_revocation_failure_does_not_block_login(self):
        """A Firestore hiccup during cleanup must not lock the user out."""
        orig = developers_db.revoke_bound_api_keys_by_name

        def _boom(*a, **k):
            raise RuntimeError("firestore unavailable")

        developers_db.revoke_bound_api_keys_by_name = _boom
        try:
            resp = self._login_as("uid_app_7")
            self.assertEqual(resp.status_code, 200, resp.text)
            self.assertEqual(
                self._probe(resp.json()["api_key"], "uid_app_7").status_code, 200
            )
        finally:
            developers_db.revoke_bound_api_keys_by_name = orig

    def _mint_app_keys(self, uid, n):
        """Create n active App-named keys bound to uid, return their doc ids."""
        for _ in range(n):
            developers_db.create_api_key(
                OFFICIAL_DEV,
                ApiKeyCreate(
                    name=app_auth.APP_KEY_NAME,
                    environment=ApiKeyEnvironment.PROD,
                    bound_external_user_id=uid,
                ),
            )
        store = fake_db.collection("developer_data")._store[
            f"__sub__{OFFICIAL_DEV}__api_keys"
        ]
        return [
            kid
            for kid, data in store.items()
            if data.get("bound_external_user_id") == uid and data.get("is_active")
        ], store

    def test_doc_missing_id_field_is_still_revoked(self):
        """
        Revocation must key off the Firestore doc id, not a mirrored `id` field.
        Reading `data["id"]` would raise on a doc that lacks it and abort the
        whole loop, leaving every key of that user active — each re-login then
        walks them closer to MAX_APP_KEYS_PER_USER and eventual 429 lockout.
        """
        uid = "uid_app_8"
        key_ids, store = self._mint_app_keys(uid, 3)
        self.assertEqual(len(key_ids), 3)
        store[key_ids[0]].pop("id")

        revoked = developers_db.revoke_bound_api_keys_by_name(
            OFFICIAL_DEV, uid, app_auth.APP_KEY_NAME
        )
        self.assertEqual(revoked, 3)
        self.assertEqual(developers_db.count_active_bound_api_keys(OFFICIAL_DEV, uid), 0)

    def test_one_failing_revocation_does_not_abort_the_others(self):
        """One key that can't be revoked must not strand the user's other keys."""
        uid = "uid_app_9"
        key_ids, _ = self._mint_app_keys(uid, 3)
        doomed = key_ids[0]

        orig = developers_db.revoke_api_key

        def _flaky(dev_id, key_id):
            if key_id == doomed:
                raise RuntimeError("firestore unavailable")
            return orig(dev_id, key_id)

        developers_db.revoke_api_key = _flaky
        try:
            revoked = developers_db.revoke_bound_api_keys_by_name(
                OFFICIAL_DEV, uid, app_auth.APP_KEY_NAME
            )
        finally:
            developers_db.revoke_api_key = orig

        self.assertEqual(revoked, 2, "the two healthy keys must still be revoked")
        self.assertEqual(
            developers_db.count_active_bound_api_keys(OFFICIAL_DEV, uid),
            1,
            "only the un-revokable one may survive",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
