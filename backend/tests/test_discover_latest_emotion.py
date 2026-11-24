#!/usr/bin/env python3
"""
Focused unit tests for Discover latest-emotion selection.

These tests lock in the bug fix where the Avatar card must select from the
same conversation set as Mood Trends:
- completed conversations only
- discarded conversations excluded
- newest conversation by created_at wins, even if an older conversation was
  reprocessed later and has a newer eir_updated_at
"""

import importlib
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))


def _install_firestore_import_stubs():
    """Install minimal stubs so this test can run without full backend deps."""
    google_mod = sys.modules.setdefault("google", types.ModuleType("google"))
    cloud_mod = sys.modules.setdefault("google.cloud", types.ModuleType("google.cloud"))

    firestore_mod = types.ModuleType("google.cloud.firestore")

    class Query:
        DESCENDING = "DESCENDING"

    firestore_mod.Query = Query
    sys.modules["google.cloud.firestore"] = firestore_mod
    cloud_mod.firestore = firestore_mod

    firestore_v1_mod = types.ModuleType("google.cloud.firestore_v1")

    class FieldFilter:
        def __init__(self, *args, **kwargs):
            self.args = args
            self.kwargs = kwargs

    firestore_v1_mod.FieldFilter = FieldFilter
    sys.modules["google.cloud.firestore_v1"] = firestore_v1_mod
    cloud_mod.firestore_v1 = firestore_v1_mod
    google_mod.cloud = cloud_mod

    client_mod = types.ModuleType("database._client")
    client_mod.db = object()
    client_mod.document_id_from_seed = lambda seed: seed
    sys.modules["database._client"] = client_mod


def _import_developer_data():
    """Import the module under test, falling back to local stubs if needed."""
    try:
        return importlib.import_module("database.developer_data")
    except (ImportError, ModuleNotFoundError):
        sys.modules.pop("database.developer_data", None)
        _install_firestore_import_stubs()
        return importlib.import_module("database.developer_data")


dev_data = _import_developer_data()


class LatestEmotionSelectionTests(unittest.TestCase):
    def test_prefers_newest_completed_conversation_by_created_at(self):
        """A reprocessed older conversation must not override yesterday's latest mood."""
        now = datetime.now(timezone.utc)
        newest_calm = {
            "id": "conv-newest-calm",
            "created_at": now,
            "eir_emotion": "calm",
            "eir_updated_at": now,
        }
        older_angry_reprocessed_later = {
            "id": "conv-older-angry",
            "created_at": now - timedelta(hours=6),
            "eir_emotion": "angry",
            "eir_updated_at": now + timedelta(hours=1),
        }

        with patch.object(
            dev_data,
            "get_conversations",
            return_value=[newest_calm, older_angry_reprocessed_later],
        ) as mock_get_conversations:
            result = dev_data.get_latest_eir_conversation("dev-123", "user-456")

        self.assertEqual(result["id"], "conv-newest-calm")
        self.assertEqual(result["eir_emotion"], "calm")
        self.assertEqual(
            mock_get_conversations.call_args.kwargs,
            {
                "developer_id": "dev-123",
                "external_user_id": "user-456",
                "limit": 100,
                "offset": 0,
                "statuses": ["completed"],
                "include_photos": False,
                "include_discarded": False,
            },
        )

    def test_pages_forward_until_it_finds_a_completed_conversation_with_eir(self):
        """If the newest completed conversations lack EIR, keep scanning later pages."""
        first_page = [
            {"id": "conv-no-eir-1", "created_at": datetime.now(timezone.utc), "eir_emotion": None},
            {"id": "conv-no-eir-2", "created_at": datetime.now(timezone.utc), "eir_emotion": ""},
        ]
        second_page = [
            {
                "id": "conv-page-2-calm",
                "created_at": datetime.now(timezone.utc) - timedelta(days=1),
                "eir_emotion": "calm",
            }
        ]

        with patch.object(
            dev_data,
            "get_conversations",
            side_effect=[first_page, second_page],
        ) as mock_get_conversations:
            result = dev_data.get_latest_eir_conversation("dev-123", "user-456")

        self.assertEqual(result["id"], "conv-page-2-calm")
        self.assertEqual(
            [call.kwargs["offset"] for call in mock_get_conversations.call_args_list],
            [0, 100],
        )

    def test_returns_none_when_no_completed_conversation_has_eir(self):
        with patch.object(
            dev_data,
            "get_conversations",
            side_effect=[
                [{"id": "conv-no-eir", "created_at": datetime.now(timezone.utc), "eir_emotion": None}],
                [],
            ],
        ):
            result = dev_data.get_latest_eir_conversation("dev-123", "user-456")

        self.assertIsNone(result)

    def test_stops_after_the_scan_limit_without_running_forever(self):
        with patch.object(
            dev_data,
            "get_conversations",
            return_value=[
                {"id": "conv-no-eir", "created_at": datetime.now(timezone.utc), "eir_emotion": None}
            ],
        ) as mock_get_conversations:
            result = dev_data.get_latest_eir_conversation("dev-123", "user-456")

        self.assertIsNone(result)
        self.assertEqual(mock_get_conversations.call_count, 10)
        self.assertEqual(
            [call.kwargs["offset"] for call in mock_get_conversations.call_args_list],
            list(range(0, 1000, 100)),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
