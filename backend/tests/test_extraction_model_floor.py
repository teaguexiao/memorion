"""抽取类调用不能落到「实测产出为 0」的模型上。

存在的理由：2026-08-10 的一次纯延迟优化（`7b502106f`）把 `GEMINI_MODELS` 的每个 tier
都映射成 `gemini-3.5-flash-lite`。延迟确实减半了，抽取也确实归零了 —— 生产 api-ws 容器
跑的正是 `LLM_PROVIDER=gemini`，而对话后处理全在那儿，于是「它记住的事实」和「你答应过
的事」同时停产五天，没人发现。

失败形态一点也不像 bug：模型返回**合法**的 `{"facts": []}`，`finish_reason=STOP`，无
safety 拦截，无异常 —— 全链路零错误日志。所以「上线后看日志没报错」不能作为这类改动的
验证；唯一有分辨力的证据是拿真实转录跑一遍、数产出条数。

2026-08-15 实测（同一批对话、同一份注册表 prompt）：

    gemini-2.5-flash        8 条 / 4 条对话
    gemini-3.5-flash-lite   0                        ← 曾经上线的
    gemini-3.7-flash        0（思考了 1341 output tokens 然后返回空）
    openrouter haiku-4.5    6

注意 `gemini-3.7-flash` 也是 0：**「换更新的模型」在这个任务上不成立**，别把这个清单
当成「旧模型黑名单」来理解。

这个测试挡不住「换成另一个没验过的模型」，它只挡住已经付过代价的那几个。换模型时请重跑
一次真实语料，别只看延迟。
"""

import os
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

# 实测在事实提取 prompt 下恒返回空列表的模型。
KNOWN_ZERO_EXTRACTION_MODELS = {
    'gemini-3.5-flash-lite',
    'gemini-3.7-flash',
}


class TestExtractionModelFloor(unittest.TestCase):
    def test_no_gemini_tier_uses_a_zero_extraction_model(self):
        """WS 容器整条后处理都走 gemini，所以任何 tier 落到这些模型都会让抽取停产。"""
        from utils.llm.clients import GEMINI_MODELS

        for tier, model in sorted(GEMINI_MODELS.items()):
            with self.subTest(tier=tier):
                self.assertNotIn(
                    model,
                    KNOWN_ZERO_EXTRACTION_MODELS,
                    f"tier '{tier}' 指向 {model}，实测该模型在抽取 prompt 下恒返回空列表。"
                    f"要改回去，先拿真实转录跑一遍并数产出条数 —— 见本文件 docstring。",
                )

    def test_summary_and_memory_call_sites_still_resolve_a_tier(self):
        """两个抽取调用点必须仍然经过 tier 映射。

        如果哪天有人把它们改成直接 new 一个客户端、绕开 GEMINI_MODELS，上面那条断言就
        看不见真正生效的模型了 —— 测试会继续绿，而抽取可以照样是 0。
        """
        import ast

        checks = (
            ('utils/llm/memories.py', 'new_memories_extractor'),
            ('utils/llm/conversation_processing.py', 'get_transcript_structure'),
        )
        for rel, func in checks:
            with self.subTest(func=func):
                with open(os.path.join(BACKEND_DIR, rel), encoding='utf-8') as f:
                    src = f.read()
                tree = ast.parse(src)
                body = None
                for node in ast.walk(tree):
                    if isinstance(node, ast.FunctionDef) and node.name == func:
                        body = ast.get_source_segment(src, node)
                        break
                self.assertIsNotNone(body, f"{rel} 里找不到 {func}")
                self.assertIn('resolve_llm(', body)


if __name__ == '__main__':
    unittest.main(verbosity=2)
