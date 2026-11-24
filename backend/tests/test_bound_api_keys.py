"""
Tests for user-bound developer API keys (bound_external_user_id) and the
CLI login flow that issues them under the official Memorion App developer.

Run:
    cd backend && source venv/bin/activate
    python tests/test_bound_api_keys.py

Uses in-memory fakes for Firestore and Redis, so no external services needed.
"""

import sys
import os
import types
import unittest
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


# ======================================================================
# Fake Firestore (only the surface used by database/developers.py)
# ======================================================================


class FakeDoc:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    @property
    def id(self):
        return self._key

    @property
    def exists(self):
        return self._key in self._store

    @property
    def reference(self):
        return self

    def to_dict(self):
        return dict(self._store[self._key])

    def get(self):
        return self

    def set(self, data):
        self._store[self._key] = dict(data)

    def update(self, data):
        self._store.setdefault(self._key, {}).update(data)

    def delete(self):
        self._store.pop(self._key, None)

    def collection(self, name):
        return FakeCollection(self._store.setdefault(f"__sub__{self._key}__{name}", {}))


class FakeQuery:
    def __init__(self, store, filters=None, limit_n=None):
        self._store = store
        self._filters = filters or []
        self._limit = limit_n

    def where(self, field, op, value):
        assert op == "=="
        return FakeQuery(self._store, self._filters + [(field, value)], self._limit)

    def limit(self, n):
        return FakeQuery(self._store, self._filters, n)

    def order_by(self, *a, **k):
        return self

    def stream(self):
        out = []
        for key, data in self._store.items():
            if key.startswith("__sub__"):
                continue
            if all(data.get(f) == v for f, v in self._filters):
                out.append(FakeDoc(self._store, key))
        if self._limit is not None:
            out = out[: self._limit]
        return iter(out)


class FakeCollection(FakeQuery):
    def __init__(self, store):
        super().__init__(store)

    def document(self, doc_id):
        return FakeDoc(self._store, doc_id)


class FakeDB:
    def __init__(self):
        self._collections = {}

    def collection(self, name):
        return FakeCollection(self._collections.setdefault(name, {}))


# ======================================================================
# Fake Redis (matches database/redis_db.py usage)
# ======================================================================


class FakeRedis:
    def __init__(self):
        self.data = {}

    def set(self, key, value, ex=None):
        self.data[key] = value.encode() if isinstance(value, str) else value

    def get(self, key):
        return self.data.get(key)

    def delete(self, *keys):
        for key in keys:
            self.data.pop(key, None)


# ======================================================================
# Install fakes BEFORE importing backend modules
# ======================================================================
#
# ⚠️ `database.redis_db.r` and `developers_db.db` are module-level globals, so
# whichever test file installs a fake LAST wins process-wide. Sibling auth test
# files reuse these fakes (see install_fakes() below); if each built its own
# FakeRedis()/FakeDB(), the loser's `fake_redis.data` assertions would inspect a
# dict nothing ever wrote to. That failed only in combined runs — 4 tests across
# two files, all green when either file ran alone.
#
# So the fakes are process-wide singletons stashed on `sys.modules` rather than
# plain module globals: pytest can load this module twice (as
# `test_bound_api_keys` and as `tests.test_bound_api_keys`, since `tests/` has
# no `__init__.py`), and both copies must land on the SAME instances.

_FAKE_SINGLETON_SLOT = "_memorion_test_fakes"
_slot = sys.modules.get(_FAKE_SINGLETON_SLOT)
if _slot is None:
    _slot = types.ModuleType(_FAKE_SINGLETON_SLOT)
    _slot.db = FakeDB()
    _slot.redis = FakeRedis()
    sys.modules[_FAKE_SINGLETON_SLOT] = _slot

fake_db = _slot.db
fake_redis = _slot.redis

fake_client_module = types.ModuleType("database._client")
fake_client_module.db = fake_db
fake_client_module.fcm_db = None
fake_client_module.document_id_from_seed = lambda seed: seed
fake_client_module.get_users_uid = lambda: []
sys.modules["database._client"] = fake_client_module

# Stub the redis package if not installed locally (the client instance is
# replaced with FakeRedis below either way).
if "redis" not in sys.modules:
    try:
        import redis  # noqa: F401
    except ModuleNotFoundError:
        redis_stub = types.ModuleType("redis")
        redis_stub.Redis = lambda **kwargs: fake_redis
        sys.modules["redis"] = redis_stub

import database.redis_db as redis_db  # noqa: E402

redis_db.r = fake_redis


def install_fakes():
    """
    Re-point the backend module globals at the shared fakes. Idempotent, and the
    ONLY sanctioned way for a sibling test file to install them — calling it is
    a no-op if this module already did, which is exactly the property that keeps
    a combined run from cross-contaminating.
    """
    import database.developers as _developers_db

    redis_db.r = fake_redis
    _developers_db.db = fake_db
    return fake_db, fake_redis

import database.developers as developers_db  # noqa: E402
from models.developer import ApiKeyCreate, ApiKeyEnvironment  # noqa: E402
from utils.developer_api_keys import hash_api_key, parse_api_key  # noqa: E402

from fastapi import Depends, FastAPI, Query  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from dependencies import (  # noqa: E402
    get_developer_id_for_developer_scope,
    get_developer_id_from_api_key,
    require_developer_for_external_user,
)
import utils.other.endpoints as endpoints_auth  # noqa: E402
import routers.cli_auth as cli_auth  # noqa: E402


# ======================================================================
# Test app
# ======================================================================

app = FastAPI()
app.include_router(cli_auth.router)


@app.get("/test/query")
async def route_query(
    external_user_id: str = Query(...),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    return {"developer_id": developer_id, "external_user_id": external_user_id}


@app.post("/test/body")
async def route_body(
    payload: dict,
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    return {"developer_id": developer_id, "external_user_id": payload.get("external_user_id")}


@app.get("/test/developer-scope")
async def route_developer_scope(
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    return {"developer_id": developer_id}


@app.get("/test/tenant-management")
def route_tenant_management(developer_id: str = Depends(get_developer_id_for_developer_scope)):
    return {"developer_id": developer_id}


@app.delete("/test/user-data")
def route_user_data(ctx: tuple = Depends(endpoints_auth.get_current_user_context_for_deletion)):
    return {"developer_id": ctx[0], "external_user_id": ctx[1]}


@app.get("/test/legacy-context")
def route_legacy_context(ctx: tuple = Depends(endpoints_auth.get_current_user_context)):
    return {"developer_id": ctx[0], "external_user_id": ctx[1]}


@app.get("/test/ws-style")
async def route_ws_style(
    external_user_id: str = Query(...),
    api_key: str = Query(...),
):
    developer_id = require_developer_for_external_user(api_key, external_user_id)
    return {"developer_id": developer_id}


client = TestClient(app, raise_server_exceptions=False)

OFFICIAL_DEV = cli_auth.MEMORION_APP_DEVELOPER_ID


def _seed_official_developer():
    fake_db.collection("developer_data").document(OFFICIAL_DEV).set(
        {
            "id": OFFICIAL_DEV,
            "email": "app@memorion.me",
            "name": "Memorion App",
            "tier": "enterprise",
            "is_active": True,
            "credits_balance": 0.0,
            "created_at": datetime.utcnow(),
            "updated_at": None,
        }
    )


class BoundApiKeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _seed_official_developer()
        cls.unbound_key, _ = developers_db.create_api_key(
            OFFICIAL_DEV, ApiKeyCreate(name="unbound", environment=ApiKeyEnvironment.PROD)
        )
        cls.bound_key, cls.bound_key_obj = developers_db.create_api_key(
            OFFICIAL_DEV,
            ApiKeyCreate(
                name="cli",
                environment=ApiKeyEnvironment.PROD,
                bound_external_user_id="uid_alice",
            ),
        )

    def setUp(self):
        fake_redis.data.clear()

    # ---------- binding enforcement: HTTP header dependency ----------

    def test_bound_key_own_uid_query_ok(self):
        resp = client.get(
            "/test/query",
            params={"external_user_id": "uid_alice"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["developer_id"], OFFICIAL_DEV)

    def test_bound_key_other_uid_query_403(self):
        resp = client.get(
            "/test/query",
            params={"external_user_id": "uid_bob"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 403)

    def test_bound_key_own_uid_body_ok(self):
        resp = client.post(
            "/test/body",
            json={"external_user_id": "uid_alice", "text": "hi"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 200)

    def test_bound_key_other_uid_body_403(self):
        resp = client.post(
            "/test/body",
            json={"external_user_id": "uid_bob", "text": "hi"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 403)

    def test_bound_key_body_and_query_mismatch_403(self):
        # query says own uid but body says another user's -> must reject
        resp = client.post(
            "/test/body",
            params={"external_user_id": "uid_alice"},
            json={"external_user_id": "uid_bob"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 403)

    def test_bound_key_developer_scope_403(self):
        resp = client.get(
            "/test/developer-scope",
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 403)

    def test_app_keys_cannot_manage_the_whole_tenant(self):
        for key in (self.bound_key, self.unbound_key):
            response = client.get("/test/tenant-management", headers={"Authorization": key})
            self.assertEqual(response.status_code, 403)

    def test_official_user_data_deletion_requires_the_bound_key(self):
        for key, expected in ((self.bound_key, 200), (self.unbound_key, 403)):
            response = client.delete(
                "/test/user-data",
                params={"external_user_id": "uid_alice"},
                headers={"Authorization": key},
            )
            self.assertEqual(response.status_code, expected)

    # ---------- unbound key: behavior unchanged ----------

    def test_unbound_key_any_uid_ok(self):
        for uid in ["uid_alice", "uid_bob"]:
            resp = client.get(
                "/test/query",
                params={"external_user_id": uid},
                headers={"Authorization": self.unbound_key},
            )
            self.assertEqual(resp.status_code, 200)

    def test_unbound_key_developer_scope_ok(self):
        resp = client.get(
            "/test/developer-scope",
            headers={"Authorization": self.unbound_key},
        )
        self.assertEqual(resp.status_code, 200)

    def test_invalid_key_401(self):
        resp = client.get(
            "/test/query",
            params={"external_user_id": "uid_alice"},
            headers={"Authorization": "memorion_dev_prod_" + "0" * 32},
        )
        self.assertEqual(resp.status_code, 401)

    # ---------- legacy get_current_user_context path ----------

    def test_legacy_context_bound_ok_and_403(self):
        ok = client.get(
            "/test/legacy-context",
            params={"external_user_id": "uid_alice"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["developer_id"], OFFICIAL_DEV)

        bad = client.get(
            "/test/legacy-context",
            params={"external_user_id": "uid_bob"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(bad.status_code, 403)

    def test_legacy_context_unbound_unchanged(self):
        resp = client.get(
            "/test/legacy-context",
            params={"external_user_id": "uid_bob"},
            headers={"Authorization": self.unbound_key},
        )
        self.assertEqual(resp.status_code, 200)

    # ---------- WS/query-param style helper ----------

    def test_ws_style_bound_enforcement(self):
        ok = client.get(
            "/test/ws-style",
            params={"external_user_id": "uid_alice", "api_key": self.bound_key},
        )
        self.assertEqual(ok.status_code, 200)

        bad = client.get(
            "/test/ws-style",
            params={"external_user_id": "uid_bob", "api_key": self.bound_key},
        )
        self.assertEqual(bad.status_code, 403)

    # ---------- Redis cache compatibility ----------

    def test_legacy_cache_entry_does_not_bypass_binding(self):
        # Simulate an entry written by an OLD instance: legacy format only.
        parsed = parse_api_key(self.bound_key)
        hashed = hash_api_key(parsed[2])
        fake_redis.data.clear()
        fake_redis.data[f"developer_api_key:{hashed}"] = OFFICIAL_DEV.encode()

        # Binding must still be enforced (auth falls back to Firestore).
        resp = client.get(
            "/test/query",
            params={"external_user_id": "uid_bob"},
            headers={"Authorization": self.bound_key},
        )
        self.assertEqual(resp.status_code, 403)

    def test_new_cache_roundtrip_preserves_binding(self):
        parsed = parse_api_key(self.bound_key)
        hashed = hash_api_key(parsed[2])
        fake_redis.data.clear()

        # First call populates the cache from Firestore.
        auth1 = developers_db.get_api_key_auth(self.bound_key)
        self.assertEqual(auth1["bound_external_user_id"], "uid_alice")
        self.assertIn(f"developer_api_key_auth:{hashed}", fake_redis.data)
        # Legacy entry also kept in sync for old readers.
        self.assertEqual(fake_redis.data[f"developer_api_key:{hashed}"].decode(), OFFICIAL_DEV)

        # Second call is served from cache and still carries the binding.
        auth2 = developers_db.get_api_key_auth(self.bound_key)
        self.assertEqual(auth2["bound_external_user_id"], "uid_alice")

    def test_corrupt_cache_entry_is_ignored(self):
        parsed = parse_api_key(self.bound_key)
        hashed = hash_api_key(parsed[2])
        fake_redis.data[f"developer_api_key_auth:{hashed}"] = b"not-json"
        auth = developers_db.get_api_key_auth(self.bound_key)
        self.assertIsNotNone(auth)
        self.assertEqual(auth["bound_external_user_id"], "uid_alice")

    # ---------- revocation clears both cache formats ----------

    def test_revoke_clears_cache_and_key(self):
        raw, key_obj = developers_db.create_api_key(
            OFFICIAL_DEV,
            ApiKeyCreate(
                name="tmp",
                environment=ApiKeyEnvironment.PROD,
                bound_external_user_id="uid_tmp",
            ),
        )
        developers_db.get_api_key_auth(raw)  # populate cache
        parsed = parse_api_key(raw)
        hashed = hash_api_key(parsed[2])
        self.assertIn(f"developer_api_key_auth:{hashed}", fake_redis.data)

        self.assertTrue(developers_db.revoke_api_key(OFFICIAL_DEV, key_obj.id))
        self.assertNotIn(f"developer_api_key_auth:{hashed}", fake_redis.data)
        self.assertNotIn(f"developer_api_key:{hashed}", fake_redis.data)
        self.assertIsNone(developers_db.get_api_key_auth(raw))


class PlatformCronKeyTests(unittest.TestCase):
    """
    `allow_any_user` —— 平台级 cron key 的跨用户口子（§9.5 阶段 3 第一步）。

    Modal 的三个 cron（每日总结 / 每日一刻 / insights）横跨全体用户，天然不可能
    绑定到某个 uid。阶段 3 收紧「未绑定 key 一律拒绝」时，这个标记是它们唯一的
    通行证，所以它必须在**每一条**路径上都不丢：写入、读取、Redis 缓存往返、
    以及轮换。

    这里盯的是三个会「静默」出事的点——出事时没有报错，只是 cron 某天开始 403：
      1. rotate 重建 key 时丢掉标记 → 轮换后 cron 降级成普通未绑定 key
      2. Redis 里阶段 3 之前缓存的旧 auth dict 没有这个字段 → 读成 None
      3. 标记默认值必须是 False（收紧的那一侧），绝不能是 None/缺失
    """

    @classmethod
    def setUpClass(cls):
        _seed_official_developer()

    def setUp(self):
        fake_redis.data.clear()

    def _mint_cron_key(self, name="cron"):
        return developers_db.create_api_key(
            OFFICIAL_DEV,
            ApiKeyCreate(
                name=name,
                environment=ApiKeyEnvironment.PROD,
                bound_external_user_id=None,
                allow_any_user=True,
            ),
        )

    def test_flag_defaults_to_false(self):
        """默认必须是 False —— 缺省值站在收紧的那一侧。"""
        _raw, key_obj = developers_db.create_api_key(
            OFFICIAL_DEV, ApiKeyCreate(name="plain", environment=ApiKeyEnvironment.PROD)
        )
        self.assertFalse(key_obj.allow_any_user)

    def test_flag_survives_auth_lookup(self):
        raw, _ = self._mint_cron_key()
        auth = developers_db.get_api_key_auth(raw)
        self.assertTrue(auth["allow_any_user"])
        # cron key 是 unbound 的——这正是它需要这个标记的原因。
        self.assertIsNone(auth["bound_external_user_id"])

    def test_flag_survives_cache_roundtrip(self):
        raw, _ = self._mint_cron_key()
        first = developers_db.get_api_key_auth(raw)   # 从 Firestore 读并写缓存
        second = developers_db.get_api_key_auth(raw)  # 从缓存读
        self.assertTrue(first["allow_any_user"])
        self.assertTrue(second["allow_any_user"])

    def test_legacy_cache_entry_without_flag_reads_as_false(self):
        """
        阶段 3 部署后，Redis 里还躺着部署前缓存的 auth dict（TTL 3600s），
        它们没有 `allow_any_user` 字段。缺字段必须读成 False——读成 None 的话，
        `if not allow_any_user` 恰好也成立所以碰巧安全，但任何写成
        `if allow_any_user is False` 的判断都会漏放。归一化在
        `get_cached_developer_api_key_auth` 里做。
        """
        raw, _ = self._mint_cron_key()
        parsed = parse_api_key(raw)
        hashed = hash_api_key(parsed[2])

        # 手工塞一个「旧格式」条目：有 developer_id，但没有 allow_any_user。
        import json
        fake_redis.data[f"developer_api_key_auth:{hashed}"] = json.dumps({
            "developer_id": OFFICIAL_DEV,
            "bound_external_user_id": None,
            "api_key_id": "whatever",
        }).encode()

        auth = developers_db.get_api_key_auth(raw)
        self.assertIn("allow_any_user", auth)
        self.assertIs(auth["allow_any_user"], False)

    def test_rotate_preserves_flag(self):
        """
        轮换必须带上标记。丢了的话 cron key 会静默降级成普通未绑定 key，
        阶段 3 上线后三条 cron 一起 403，而 diff 里看不出任何线索。
        """
        raw, key_obj = self._mint_cron_key(name="cron-rotate")
        rotated = developers_db.rotate_api_key(OFFICIAL_DEV, key_obj.id)
        self.assertIsNotNone(rotated)
        _new_raw, new_key_obj, _old_id = rotated
        self.assertTrue(new_key_obj.allow_any_user)
        self.assertIsNone(new_key_obj.bound_external_user_id)

    def test_rotate_does_not_grant_flag_to_ordinary_key(self):
        """反方向也要钉住：普通 key 轮换后不该凭空获得跨用户权限。"""
        _raw, key_obj = developers_db.create_api_key(
            OFFICIAL_DEV, ApiKeyCreate(name="plain-rotate", environment=ApiKeyEnvironment.PROD)
        )
        rotated = developers_db.rotate_api_key(OFFICIAL_DEV, key_obj.id)
        self.assertIsNotNone(rotated)
        self.assertFalse(rotated[1].allow_any_user)

    def test_flag_is_not_settable_through_the_public_create_endpoint(self):
        """
        `POST /v1/keys` 绝不能把这个标记透传出去——它授予的正是「读写任意用户
        数据」的能力，是被提取的 key 最想设的字段。路由用 name+environment 自己
        重建 ApiKeyCreate，所以外部请求碰不到它。这里用源码断言钉住这个形态，
        因为一旦有人「顺手」改成 `ApiKeyCreate(**key_data.dict())` 就破防了。
        """
        path = os.path.join(os.path.dirname(__file__), "..", "routers", "api_keys.py")
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        self.assertNotIn("allow_any_user", src)
        self.assertIn("ApiKeyCreate(name=key_data.name.strip(), environment=key_data.environment)", src)

class CliTokenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        _seed_official_developer()

    def setUp(self):
        fake_redis.data.clear()
        self._orig_verify = cli_auth._verify_firebase_token

        def _fake_verify(credentials):
            # Mirror the real function's missing-token handling.
            if credentials is None or not credentials.credentials:
                from fastapi import HTTPException

                raise HTTPException(status_code=401, detail="Missing Bearer token")
            return {"uid": "uid_firebase_1", "email": "user@example.com"}

        cli_auth._verify_firebase_token = _fake_verify

    def tearDown(self):
        cli_auth._verify_firebase_token = self._orig_verify

    def test_happy_path_issues_bound_key_under_official_developer(self):
        resp = client.post(
            "/v1/auth/cli-token",
            json={"device_name": "my-macbook"},
            headers={"Authorization": "Bearer fake-firebase-token"},
        )
        self.assertEqual(resp.status_code, 200, resp.text)
        data = resp.json()
        self.assertEqual(data["developer_id"], OFFICIAL_DEV)
        self.assertEqual(data["external_user_id"], "uid_firebase_1")
        self.assertEqual(data["email"], "user@example.com")
        self.assertTrue(data["api_key"].startswith("memorion_dev_prod_"))

        # The issued key works for the user's own uid...
        ok = client.get(
            "/test/query",
            params={"external_user_id": "uid_firebase_1"},
            headers={"Authorization": data["api_key"]},
        )
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(ok.json()["developer_id"], OFFICIAL_DEV)

        # ...and is rejected for anyone else's uid.
        bad = client.get(
            "/test/query",
            params={"external_user_id": "someone_else"},
            headers={"Authorization": data["api_key"]},
        )
        self.assertEqual(bad.status_code, 403)

    def test_key_limit_counts_only_this_users_bound_keys(self):
        # Another user's bound keys and unbound keys must not count.
        for i in range(3):
            developers_db.create_api_key(
                OFFICIAL_DEV,
                ApiKeyCreate(
                    name=f"other-{i}",
                    environment=ApiKeyEnvironment.PROD,
                    bound_external_user_id="uid_other",
                ),
            )

        cli_auth._verify_firebase_token = lambda credentials: {
            "uid": "uid_limit_test",
            "email": "limit@example.com",
        }
        cli_auth.MAX_CLI_KEYS_PER_USER, orig_max = 2, cli_auth.MAX_CLI_KEYS_PER_USER
        try:
            for _ in range(2):
                resp = client.post(
                    "/v1/auth/cli-token",
                    headers={"Authorization": "Bearer fake"},
                )
                self.assertEqual(resp.status_code, 200)
            resp = client.post(
                "/v1/auth/cli-token",
                headers={"Authorization": "Bearer fake"},
            )
            self.assertEqual(resp.status_code, 429)
        finally:
            cli_auth.MAX_CLI_KEYS_PER_USER = orig_max

    def test_missing_token_401(self):
        resp = client.post("/v1/auth/cli-token")
        self.assertEqual(resp.status_code, 401)


if __name__ == "__main__":
    unittest.main(verbosity=2)
