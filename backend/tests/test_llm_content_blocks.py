import os
import sys
import unittest


sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("OPENAI_API_KEY", "test")

from langchain_core.messages import AIMessage

from models.conversation import Structured
from utils.llm.clients import (
    MarkdownCleaningParser,
    coerce_llm_text_content,
)


class LlmTextContentTests(unittest.TestCase):
    def test_plain_string_is_preserved(self):
        self.assertEqual(coerce_llm_text_content("  hello  "), "hello")

    def test_typed_text_blocks_are_joined(self):
        message = AIMessage(
            content=[
                {"type": "text", "text": "first"},
                {"type": "text", "text": "second"},
            ]
        )
        self.assertEqual(coerce_llm_text_content(message), "first\nsecond")

    def test_markdown_parser_accepts_typed_text_blocks(self):
        parser = MarkdownCleaningParser(pydantic_object=Structured)
        message = AIMessage(
            content=[
                {
                    "type": "text",
                    "text": (
                        "```json\n"
                        '{"title":"测试摘要","overview":"已正确解析",'
                        '"category":"other"}\n'
                        "```"
                    ),
                }
            ]
        )

        parsed = parser.parse(message)

        self.assertEqual(parsed.title, "测试摘要")
        self.assertEqual(parsed.overview, "已正确解析")

    def test_parser_recovers_gemini_labeled_text_without_losing_summary(self):
        """Production returned a complete summary as YAML-like text, not JSON."""
        parser = MarkdownCleaningParser(pydantic_object=Structured)
        output = """title: 学习的挑战与家庭的温暖
overview: 这是一段充满家庭气息的时光，你正和一位大人一起面对数学作业。

电话里，你们也聊到了周末安排，充满了对家庭相聚的期待。
emoji: 👨‍👩‍👧‍👦
category: family
action_items: []
events: []
emotion: calm
first_person_observation: 你在学习中流露出的真性情，被家人的耐心温柔地包围着。
highlights:
  - 姚草: Oh my god。
  - 姚草: 不开心。
  - Speaker 2: 爷爷宠坏了。
"""

        parsed = parser.parse(output)

        self.assertEqual(parsed.title, "学习的挑战与家庭的温暖")
        self.assertIn("周末安排", parsed.overview)
        self.assertEqual(parsed.category.value, "family")
        self.assertEqual(
            parsed.highlights,
            ["姚草: Oh my god。", "姚草: 不开心。", "Speaker 2: 爷爷宠坏了。"],
        )


class SummaryFailureFallbackTests(unittest.TestCase):
    def test_raw_transcript_is_never_used_as_overview(self):
        backend_dir = os.path.dirname(os.path.dirname(__file__))
        for relative_path in (
            "routers/developer_conversations.py",
            "routers/developer_listen.py",
        ):
            with open(os.path.join(backend_dir, relative_path), encoding="utf-8") as source_file:
                source = source_file.read()
            self.assertNotIn("'overview': transcript_text[:500]", source)


if __name__ == "__main__":
    unittest.main()
