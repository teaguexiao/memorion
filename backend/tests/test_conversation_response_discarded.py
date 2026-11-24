"""Regression test: `discarded` must survive serialization through
`ConversationResponse`.

A FastAPI `response_model` silently DROPS fields it doesn't declare. The model
omitted `discarded`, so every conversation reached the client looking
`discarded=false` regardless of what Firestore held. The Flutter client reads
`json['discarded'] ?? false`, so its three discard filters (`_filterOutConvos`,
`groupedConversations`, the calendar heat map) all became no-ops, and judged
media/near-silent captures rendered on the home timeline — with no subtitle,
since the process path deliberately skips `first_person_observation` for
discarded conversations.

This test pins the field to the model directly (no network, no Firestore).

Run:
    cd backend && python3 tests/test_conversation_response_discarded.py
"""

import os
import sys
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

os.environ.setdefault("OPENAI_API_KEY", "test")


def _load_response_model():
    """Import ConversationResponse without importing the whole router module
    (which pulls in Firestore/LLM clients). The class body is self-contained,
    so exec'ing just that block keeps this test dependency-free."""
    import ast
    import textwrap
    from typing import Any, Dict, List, Optional  # noqa: F401  (used by exec'd source)

    from pydantic import BaseModel  # noqa: F401  (used by exec'd source)

    path = os.path.join(os.path.dirname(__file__), "..", "routers", "developer_conversations.py")
    with open(path, "r", encoding="utf-8") as fh:
        source = fh.read()

    tree = ast.parse(source)
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "ConversationResponse":
            namespace = {
                "BaseModel": BaseModel,
                "datetime": datetime,
                "Optional": Optional,
                "List": List,
                "Dict": Dict,
                "Any": Any,
            }
            exec(textwrap.dedent(ast.get_source_segment(source, node)), namespace)
            return namespace["ConversationResponse"]
    raise AssertionError("ConversationResponse not found in developer_conversations.py")


ConversationResponse = _load_response_model()


def _raw(**overrides):
    data = dict(
        id="conv-1",
        created_at=datetime.now(timezone.utc),
        started_at=None,
        finished_at=None,
        language="zh",
        source="app",
        status="completed",
        transcript_segments=[],
        structured={"title": "[Media Recording]"},
        metadata={},
        updated_at=datetime.now(timezone.utc),
    )
    data.update(overrides)
    return data


class DiscardedFieldSurvivesSerialization(unittest.TestCase):
    def test_field_is_declared(self):
        self.assertIn(
            "discarded",
            ConversationResponse.model_fields,
            "response_model drops undeclared fields — the client would always see discarded=false",
        )

    def test_discarded_true_is_preserved(self):
        dumped = ConversationResponse(**_raw(discarded=True)).model_dump()
        self.assertIn("discarded", dumped)
        self.assertIs(dumped["discarded"], True)

    def test_discarded_false_is_preserved(self):
        dumped = ConversationResponse(**_raw(discarded=False)).model_dump()
        self.assertIs(dumped["discarded"], False)

    def test_defaults_to_false_when_absent(self):
        # Legacy documents written before the flag existed must not blow up and
        # must read as "not discarded" (matches the client's `?? false`).
        dumped = ConversationResponse(**_raw()).model_dump()
        self.assertIs(dumped["discarded"], False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
