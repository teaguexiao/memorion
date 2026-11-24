"""
Tests for per-session idempotency of POST /v1/conversations/process.

Reproduces the concurrency race diagnosed on 2026-07-24: two simultaneous
POST /process for the SAME session_id both passed the Firestore dedup check
(the marker is only written AFTER the multi-second LLM call) and each created
a conversation + ran the LLM, producing two records for one recording.

The fix serializes per session with a Redis distributed lock
(redis_db.acquire_lock, SET NX EX). These tests use in-memory fakes for
Firestore and Redis plus threads to emulate the cross-worker concurrency that
the production ASGI single event loop would otherwise hide, so no external
services are needed.

Run:
    cd backend && source venv/bin/activate  # (or just python3 — self-contained)
    python tests/test_process_conversation_idempotent.py
"""

import asyncio
import os
import sys
import threading
import time
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("REDIS_DB_HOST", "localhost")
os.environ.setdefault("REDIS_DB_PORT", "6379")


# ======================================================================
# Thread-safe fake Redis client (supports SET NX EX used by acquire_lock)
# ======================================================================
class FakeRedisClient:
    def __init__(self):
        self.data = {}
        self._lock = threading.Lock()

    def set(self, key, value, nx=False, ex=None):
        with self._lock:
            if nx and key in self.data:
                return None
            self.data[key] = value
            return True

    def get(self, key):
        with self._lock:
            return self.data.get(key)

    def delete(self, *keys):
        with self._lock:
            for key in keys:
                self.data.pop(key, None)


# ======================================================================
# Fake developer_data store (only the surface the orchestration touches)
# ======================================================================
class FakeDevStore:
    def __init__(self):
        self.listen_sessions = {}   # session_id -> markers dict
        self.conversations = {}     # conversation_id -> conversation dict
        self._lock = threading.Lock()

    def get_listen_session(self, developer_id, external_user_id, session_id):
        with self._lock:
            s = self.listen_sessions.get(session_id)
            return dict(s) if s is not None else None

    def get_conversation(self, developer_id, external_user_id, conversation_id):
        with self._lock:
            c = self.conversations.get(conversation_id)
            return dict(c) if c is not None else None

    def mark_processed(self, session_id, conversation):
        with self._lock:
            self.conversations[conversation["id"]] = dict(conversation)
            self.listen_sessions.setdefault(session_id, {})[
                "app_processed_conversation_id"
            ] = conversation["id"]


# ======================================================================
# Stub heavy modules BEFORE importing the router so the import is cheap
# and dependency-free (fastapi/redis/utils are not installed globally).
# ======================================================================
def _install_stubs(dev_store, redis_client):
    # --- fastapi ---
    fastapi_stub = types.ModuleType("fastapi")

    class _APIRouter:
        def _decorator(self, *a, **k):
            def wrap(fn):
                return fn
            return wrap

        post = get = patch = delete = put = _decorator

    class _HTTPException(Exception):
        def __init__(self, status_code=None, detail=None):
            super().__init__(detail)
            self.status_code = status_code
            self.detail = detail

    fastapi_stub.APIRouter = _APIRouter
    fastapi_stub.Depends = lambda x=None: x
    fastapi_stub.HTTPException = _HTTPException
    fastapi_stub.Query = lambda default=None, **k: default
    sys.modules["fastapi"] = fastapi_stub

    # --- fastapi.concurrency ---
    # The router dispatches its blocking pipeline with `run_in_threadpool` so a
    # 10s LLM call cannot stall the single event loop (see the handler docstring).
    # `asyncio.to_thread` has the same signature and really does switch threads,
    # so the race below is still exercised across threads rather than inlined.
    fastapi_concurrency_stub = types.ModuleType("fastapi.concurrency")
    fastapi_concurrency_stub.run_in_threadpool = asyncio.to_thread
    sys.modules["fastapi.concurrency"] = fastapi_concurrency_stub

    # --- redis package (redis_db does `r = redis.Redis(...)`) ---
    if "redis" not in sys.modules:
        try:
            import redis  # noqa: F401
        except ModuleNotFoundError:
            redis_stub = types.ModuleType("redis")
            redis_stub.Redis = lambda **kwargs: FakeRedisClient()
            sys.modules["redis"] = redis_stub

    # --- database.developer_data (dev_db) ---
    dev_db_stub = types.ModuleType("database.developer_data")
    dev_db_stub.get_listen_session = dev_store.get_listen_session
    dev_db_stub.get_conversation = dev_store.get_conversation
    sys.modules["database.developer_data"] = dev_db_stub

    # --- dependencies ---
    deps_stub = types.ModuleType("dependencies")
    deps_stub.get_developer_id_from_api_key = lambda: "dev1"
    sys.modules["dependencies"] = deps_stub

    # --- models.conversation ---
    models_conv = types.ModuleType("models.conversation")
    models_conv.Conversation = object
    models_conv.ConversationStatus = object
    models_conv.ConversationSource = object
    models_conv.Structured = object
    sys.modules["models.conversation"] = models_conv

    # --- models.transcript_segment ---
    models_seg = types.ModuleType("models.transcript_segment")
    models_seg.coerce_speaker_id = lambda x: x
    sys.modules["models.transcript_segment"] = models_seg

    # --- assorted heavy utils touched only inside the (monkeypatched) pipeline ---
    for name, attrs in {
        "utils.conversations.process_conversation": {"process_conversation_developer": lambda *a, **k: None},
        # Every name the router imports must be here. A missing one is an
        # ImportError at collection time, i.e. the whole file silently stops
        # testing anything — which is what happened when the router grew
        # `should_discard_conversation` / `clear_action_items_if_user_absent`.
        "utils.llm.conversation_processing": {
            "get_transcript_structure": lambda *a, **k: None,
            "should_discard_conversation": lambda *a, **k: False,
            "summary_marks_media": lambda *a, **k: False,
            "merge_discard_verdict": lambda discarded, structured: bool(discarded),
            "clear_action_items_if_user_absent": lambda *a, **k: None,
        },
        "utils.other.storage": {"get_signed_url_from_path": lambda *a, **k: None},
        "utils.speech_sample_collector": {"collect_speech_samples_developer": lambda *a, **k: None},
        "utils.stt.speech_profile": {
            "identify_developer_speakers": lambda *a, **k: (None, False),
            "_speaker_key": lambda seg: (seg.get("speaker") if isinstance(seg, dict) else None),
        },
    }.items():
        mod = types.ModuleType(name)
        for k, v in attrs.items():
            setattr(mod, k, v)
        sys.modules[name] = mod


FAKE_DEV_STORE = FakeDevStore()
FAKE_REDIS = FakeRedisClient()
_install_stubs(FAKE_DEV_STORE, FAKE_REDIS)

import database.redis_db as redis_db  # noqa: E402
redis_db.r = FAKE_REDIS  # route acquire_lock/release_lock to the shared fake

import routers.developer_conversations as dev_conv  # noqa: E402
from routers.developer_conversations import ConversationProcess, TranscriptSegment  # noqa: E402


def _make_request(session_id):
    return ConversationProcess(
        external_user_id="user1",
        segments=[TranscriptSegment(text="hello world this is a test", speaker_id=0, start=0.0, end=5.0)],
        session_id=session_id,
    )


class AcquireLockTest(unittest.TestCase):
    def setUp(self):
        FAKE_REDIS.data.clear()

    def test_lock_is_mutually_exclusive(self):
        key = "process_conversation:dev1:user1:sess-lock"
        self.assertTrue(redis_db.acquire_lock(key, ttl_seconds=30))
        # Second acquire while held must fail.
        self.assertFalse(redis_db.acquire_lock(key, ttl_seconds=30))
        redis_db.release_lock(key)
        # After release it can be acquired again.
        self.assertTrue(redis_db.acquire_lock(key, ttl_seconds=30))
        redis_db.release_lock(key)


class ConcurrentProcessTest(unittest.TestCase):
    def setUp(self):
        FAKE_REDIS.data.clear()
        FAKE_DEV_STORE.listen_sessions.clear()
        FAKE_DEV_STORE.conversations.clear()
        self.process_calls = 0
        self._call_lock = threading.Lock()

    def _fake_pipeline(self, process_data, developer_id):
        """Stand-in for the real create+LLM+finish pipeline.

        Counts invocations and simulates the multi-second LLM latency that
        opens the race window, then writes the dedup marker (as the real
        pipeline does at its end).
        """
        with self._call_lock:
            self.process_calls += 1
        time.sleep(0.3)  # emulate slow LLM
        conv = {"id": f"conv-{process_data.session_id}", "status": "completed"}
        FAKE_DEV_STORE.mark_processed(process_data.session_id, conv)
        return conv

    def _run_two_concurrent(self, session_id):
        results = {}

        def worker(idx):
            req = _make_request(session_id)
            results[idx] = asyncio.run(dev_conv.process_conversation(req, developer_id="dev1"))

        t1 = threading.Thread(target=worker, args=(0,))
        t2 = threading.Thread(target=worker, args=(1,))
        t1.start()
        # tiny stagger so both are past the optimistic pre-check but contend on the lock
        time.sleep(0.02)
        t2.start()
        t1.join()
        t2.join()
        return results

    def test_concurrent_same_session_creates_one(self):
        dev_conv._do_process_conversation = self._fake_pipeline
        results = self._run_two_concurrent("sess-A")

        # The pipeline (create + LLM) must run exactly once for the session.
        self.assertEqual(self.process_calls, 1, "pipeline ran more than once — dedup lock failed")
        # Both requests return the SAME conversation id.
        self.assertEqual(results[0]["id"], results[1]["id"])
        self.assertEqual(results[0]["id"], "conv-sess-A")
        # Exactly one conversation persisted.
        self.assertEqual(len(FAKE_DEV_STORE.conversations), 1)

    def test_without_lock_would_duplicate(self):
        """Control: with the lock disabled (acquire always 'succeeds' without
        exclusion), the original race reproduces — the pipeline runs twice.
        Proves the test harness actually exercises the race the lock fixes."""
        dev_conv._do_process_conversation = self._fake_pipeline
        original_acquire = redis_db.acquire_lock
        redis_db.acquire_lock = lambda *a, **k: True  # no mutual exclusion
        try:
            self._run_two_concurrent("sess-B")
        finally:
            redis_db.acquire_lock = original_acquire

        self.assertEqual(
            self.process_calls, 2,
            "expected the unguarded race to double-process; harness may not be exercising it",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
