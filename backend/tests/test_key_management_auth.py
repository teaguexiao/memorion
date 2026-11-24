"""
Tests for API-key management authorization (/v1/keys*).

Guards the privilege-escalation fix: the key embedded in the shipped mobile app
belongs to the official Memorion App developer account, so it must not be able
to mint or revoke keys for that account. Also covers the inactive-developer
check the key endpoints previously bypassed.

Critically, this also asserts the *data-plane* endpoints are unaffected — the
app's entire feature set (conversations, chat, STT auth, ...) goes through
get_developer_id_from_api_key, which must keep working exactly as before.

Run:
    cd backend && python tests/test_key_management_auth.py

Uses in-memory fakes for Firestore and Redis, so no external services needed.
"""

import os
import sys
import types
import unittest
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

# ⚠️ No `tests.` prefix — see the note in test_app_token_exchange.py. The
# prefixed form loads a second copy of this module and clobbers `redis_db.r`.
#
# `install_fakes()` rather than FakeDB()/FakeRedis() of our own: the fakes are
# process-wide singletons because the backend globals they replace are, and a
# second set would silently steal `redis_db.r` from whichever file installed
# first. See the long note at test_bound_api_keys.py's install site.
from test_bound_api_keys import install_fakes  # noqa: E402


class KeyManagementAuthTest(unittest.TestCase):
    """
    Spins up a real FastAPI app with the real dependency graph, so the test
    exercises actual request routing rather than calling the dependency
    functions directly.
    """

    @classmethod
    def setUpClass(cls):
        # Point the backend globals at the shared fakes (no-op if the import of
        # test_bound_api_keys already did it — that idempotence is the point).
        fake_db, fake_redis = install_fakes()

        client_mod = types.ModuleType("database._client")
        client_mod.db = fake_db
        client_mod.document_id_from_seed = lambda seed: str(seed)
        sys.modules["database._client"] = client_mod

        cls.fake_db = fake_db
        cls.fake_redis = fake_redis

        import database.developers as developers_db
        from models.developer import (
            MEMORION_APP_DEVELOPER_ID,
            ApiKeyCreate,
            ApiKeyEnvironment,
        )
        cls.developers_db = developers_db
        cls.official_dev = MEMORION_APP_DEVELOPER_ID

        # --- three developer accounts ---
        for dev_id, active in [
            (MEMORION_APP_DEVELOPER_ID, True),   # official App account
            ("third_party_dev", True),           # a real API customer
            ("inactive_dev", False),             # deactivated account
        ]:
            fake_db.collection("developer_data").document(dev_id).set(
                {
                    "id": dev_id,
                    "email": f"{dev_id}@example.com",
                    "is_active": active,
                    "created_at": datetime.utcnow(),
                }
            )

        def mint(dev_id, name, bound=None):
            raw, _ = developers_db.create_api_key(
                dev_id,
                ApiKeyCreate(
                    name=name,
                    environment=ApiKeyEnvironment.PROD,
                    bound_external_user_id=bound,
                ),
            )
            return raw

        # The key that ships inside the mobile app: official account, unbound.
        cls.app_key = mint(MEMORION_APP_DEVELOPER_ID, "Mobile App")
        # A CLI login key: official account, bound to one user.
        cls.bound_key = mint(MEMORION_APP_DEVELOPER_ID, "CLI", bound="uid_alice")
        cls.third_party_key = mint("third_party_dev", "Customer key")
        cls.inactive_key = mint("inactive_dev", "Deactivated key")

        # --- app under test ---
        from fastapi import APIRouter, Depends, FastAPI
        from fastapi.testclient import TestClient

        from dependencies import get_developer_id_from_api_key
        from routers import api_keys

        # A stand-in for every data-plane endpoint (conversations, chat,
        # listen/STT token checks, ...). Same dependency they all use.
        probe = APIRouter()

        @probe.get("/probe/data")
        async def data_plane(
            developer_id: str = Depends(get_developer_id_from_api_key),
        ):
            return {"developer_id": developer_id}

        app = FastAPI()
        app.include_router(api_keys.router)
        app.include_router(probe)
        cls.client = TestClient(app)

    def _h(self, key):
        return {"Authorization": key}

    # ---------- the fix: App key cannot manage keys ----------

    def test_app_key_cannot_list_keys(self):
        r = self.client.get("/v1/keys", headers=self._h(self.app_key))
        self.assertEqual(r.status_code, 403, r.text)

    def test_app_key_cannot_create_keys(self):
        """The escalation that mattered most: minting new keys for the account."""
        before = len(self.developers_db.get_api_keys_for_developer(self.official_dev))
        r = self.client.post(
            "/v1/keys",
            headers=self._h(self.app_key),
            json={"name": "attacker key", "environment": "prod"},
        )
        self.assertEqual(r.status_code, 403, r.text)
        after = len(self.developers_db.get_api_keys_for_developer(self.official_dev))
        self.assertEqual(before, after, "no key may be created")

    def test_app_key_cannot_revoke_keys(self):
        """The availability attack: revoking the key the whole user base uses."""
        keys = self.developers_db.get_api_keys_for_developer(self.official_dev)
        target = keys[0].id
        r = self.client.delete(f"/v1/keys/{target}", headers=self._h(self.app_key))
        self.assertEqual(r.status_code, 403, r.text)
        still = [k.id for k in self.developers_db.get_api_keys_for_developer(self.official_dev)]
        self.assertIn(target, still, "key must survive")

    def test_app_key_cannot_rotate_keys(self):
        keys = self.developers_db.get_api_keys_for_developer(self.official_dev)
        r = self.client.post(
            f"/v1/keys/{keys[0].id}/rotate", headers=self._h(self.app_key)
        )
        self.assertEqual(r.status_code, 403, r.text)

    def test_app_key_cannot_read_single_key(self):
        keys = self.developers_db.get_api_keys_for_developer(self.official_dev)
        r = self.client.get(f"/v1/keys/{keys[0].id}", headers=self._h(self.app_key))
        self.assertEqual(r.status_code, 403, r.text)

    def test_bound_cli_key_also_blocked(self):
        """Bound keys were already 403 (no external_user_id); still are."""
        r = self.client.get("/v1/keys", headers=self._h(self.bound_key))
        self.assertEqual(r.status_code, 403, r.text)

    # ---------- M13: inactive developer ----------

    def test_inactive_developer_cannot_manage_keys(self):
        r = self.client.get("/v1/keys", headers=self._h(self.inactive_key))
        self.assertEqual(r.status_code, 403, r.text)

    # ---------- no regression for real API customers ----------

    def test_third_party_developer_can_still_list_keys(self):
        r = self.client.get("/v1/keys", headers=self._h(self.third_party_key))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(any(k["name"] == "Customer key" for k in r.json()))

    def test_third_party_developer_can_still_create_and_revoke(self):
        r = self.client.post(
            "/v1/keys",
            headers=self._h(self.third_party_key),
            json={"name": "second key", "environment": "dev"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        new_id = r.json()["id"]
        self.assertTrue(r.json()["key"].startswith("memorion_dev_"))

        r2 = self.client.get(f"/v1/keys/{new_id}", headers=self._h(self.third_party_key))
        self.assertEqual(r2.status_code, 200, r2.text)

        r3 = self.client.delete(
            f"/v1/keys/{new_id}", headers=self._h(self.third_party_key)
        )
        self.assertEqual(r3.status_code, 204, r3.text)

    def test_scoping_still_enforced_across_developers(self):
        """A customer must not touch the official account's keys."""
        official = self.developers_db.get_api_keys_for_developer(self.official_dev)
        r = self.client.get(
            f"/v1/keys/{official[0].id}", headers=self._h(self.third_party_key)
        )
        self.assertEqual(r.status_code, 404, r.text)

    # ---------- the App must keep working (zero client impact) ----------

    def test_app_key_still_works_on_data_plane(self):
        """
        The whole point of scoping the fix this narrowly: every app feature —
        conversations, memories, chat, STT auth — must be untouched.
        """
        r = self.client.get("/probe/data", headers=self._h(self.app_key))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["developer_id"], self.official_dev)

    def test_bound_key_still_works_on_data_plane_for_its_user(self):
        r = self.client.get(
            "/probe/data?external_user_id=uid_alice", headers=self._h(self.bound_key)
        )
        self.assertEqual(r.status_code, 200, r.text)

    def test_bound_key_still_rejected_for_other_users(self):
        r = self.client.get(
            "/probe/data?external_user_id=uid_bob", headers=self._h(self.bound_key)
        )
        self.assertEqual(r.status_code, 403, r.text)

    def test_invalid_key_still_401(self):
        r = self.client.get("/v1/keys", headers=self._h("memorion_dev_prod_deadbeef"))
        self.assertEqual(r.status_code, 401, r.text)

    def test_missing_auth_still_401(self):
        r = self.client.get("/v1/keys")
        self.assertEqual(r.status_code, 401, r.text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
