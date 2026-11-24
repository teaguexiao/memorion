#!/usr/bin/env python3
"""
Unit tests for the daily-summary FCM push `data` payload builder.

Focus: the deep-link contract between backend and app.
- `navigate_to` MUST stay '/moments' (older app builds only know that route).
- `moment_id` is added only when present, so new builds can deep-link to the
  day's diary detail page while old payloads / old apps keep working.

These are pure-logic tests (no Firebase / network). Run with:
    pytest backend/tests/test_daily_summary_push_payload.py
"""

import sys
from pathlib import Path

import pytest

# Add the backend directory to Python path so `routers` imports resolve.
backend_dir = Path(__file__).parent.parent
sys.path.insert(0, str(backend_dir))

try:
    from routers.developer_daily_summary import _build_daily_summary_push_data
except Exception as exc:  # pragma: no cover - only when backend deps are absent
    pytest.skip(f"backend deps unavailable: {exc}", allow_module_level=True)


def test_payload_includes_moment_id_when_present():
    data = _build_daily_summary_push_data("moment-123")
    assert data["moment_id"] == "moment-123"
    # navigate_to stays '/moments' for backward compatibility.
    assert data["navigate_to"] == "/moments"
    assert data["type"] == "day_summary"
    assert data["notification_type"] == "daily_summary"
    # `id` is a fresh per-push uuid, unrelated to the moment.
    assert data["id"] and data["id"] != "moment-123"


def test_payload_omits_moment_id_when_none():
    data = _build_daily_summary_push_data(None)
    assert "moment_id" not in data
    assert data["navigate_to"] == "/moments"


def test_payload_omits_moment_id_when_empty_string():
    # Empty string is falsy: better to omit than to send a dead deep-link target.
    data = _build_daily_summary_push_data("")
    assert "moment_id" not in data


def test_each_push_gets_a_unique_id():
    a = _build_daily_summary_push_data("m1")
    b = _build_daily_summary_push_data("m1")
    assert a["id"] != b["id"]
