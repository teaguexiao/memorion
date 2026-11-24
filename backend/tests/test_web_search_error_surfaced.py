"""web_search 的失败必须传到模型手里，而不是被压成「网上没有」。

存在的理由（2026-08-12 实测）：`web_search` 那个 @tool 原来 `return {"results":
result.get("results", [])}`——**把 `error` 整个丢了**。于是 Tavily 因为 key 打满上限返回 432
时，模型看到的是 `{"results": []}`，与「这题网上真的查不到」完全一样。而同一个工具的
docstring 明确写着 "refine and search again if the first misses"。两件事凑起来就是重试风暴：
一道题上连打 18 次 `web_search`，全是 432。

**代价不是慢，是结论错。** 离线评测把这些题记成 `general_knowledge` 上的模型失败，而它其实
是一条挂掉的基础设施；而生产侧完全无声——旧的日志行只有一句 "request failed"，不带状态码，
所以「key 打满」和「一次请求超时」是同一条日志。

⚠️ **432 不是 429。** 它是 Tavily 的「这把 key 被人在 dashboard 上设了用量上限」，不是欠费也
不是限流——等待没有用，得去调那个旋钮。这是当时最难认出来的一点。

⚠️ 工具那一侧用**读源码**而不是 import：`agent_tools` 会连带拉起 `.env` 与凭证落盘（沙箱里
直接 OSError），import 断言会退化成环境问题而不是回归信号。同 `test_summarizer_user_label.py`。
"""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import utils.retrieval.agent_websearch as w  # noqa: E402  只 import requests/logging，安全

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "utils", "retrieval", "agent_tools.py")


class _FakeResp:
    def __init__(self, status, text="", body=None):
        self.status_code = status
        self.text = text
        self._body = body

    def raise_for_status(self):
        if self.status_code >= 400:
            import requests
            raise requests.HTTPError(f"{self.status_code}")

    def json(self):
        return self._body or {}


class TestClassification(unittest.TestCase):
    def setUp(self):
        self._post = w.requests.post
        os.environ["TAVILY_API_KEY"] = "tvly-test-not-a-real-key"

    def tearDown(self):
        w.requests.post = self._post

    def _search(self, resp):
        w.requests.post = lambda *a, **kw: resp
        return w.tavily_search("anything")

    def test_432_usage_limit_is_permanent_and_named(self):
        """432 的实测报文：This request exceeds this API key's set usage limit。"""
        out = self._search(_FakeResp(432, '{"detail":{"error":"exceeds this API key\'s set usage limit"}}'))
        self.assertEqual(out["results"], [])
        self.assertFalse(out["retryable"], "432 标成可重试就会重新造出重试风暴")
        self.assertIn("usage limit", out["error"])
        self.assertIn("Do not retry", out["error"],
                      "错误串必须明说别重试——docstring 里那句 refine and search again 会盖过一切")

    def test_transient_failure_stays_retryable(self):
        """网络抖动要允许重试，否则一次超时会让模型直接放弃查网。"""
        import requests

        def boom(*a, **kw):
            raise requests.Timeout("timed out")

        w.requests.post = boom
        out = w.tavily_search("anything")
        self.assertEqual(out["results"], [])
        self.assertTrue(out["retryable"])

    def test_missing_key_is_permanent(self):
        os.environ.pop("TAVILY_API_KEY", None)
        try:
            out = w.tavily_search("anything")
        finally:
            os.environ["TAVILY_API_KEY"] = "tvly-test-not-a-real-key"
        self.assertFalse(out["retryable"])
        self.assertEqual(out["results"], [])

    def test_success_has_no_error_key(self):
        """成功时不能带 error——否则模型每次查完都以为查失败了。"""
        out = self._search(_FakeResp(200, body={"results": [
            {"title": "t", "url": "u", "content": "c", "score": 0.9}]}))
        self.assertNotIn("error", out)
        self.assertEqual(len(out["results"]), 1)

    def test_query_text_never_logged(self):
        """日志里不许出现提问原文（TRACING.md §0 的同一条口径：只记元数据）。

        原来两处 `logger.exception(... query=%r ...)` 记的就是用户提问原文。
        """
        src = open(w.__file__, encoding="utf-8").read()
        # 允许 query_len，不允许 query=%r / query=%s
        self.assertNotRegex(src, r"query=%[rs]",
                            "把 query 的值写进日志了——只记长度")


class TestToolForwardsError(unittest.TestCase):
    def _web_search_body(self):
        """截出 `web_search` 这个 @tool 的函数体。

        ⚠️ 定位到函数体而不是全文搜 `"error"`——全文搜会被别的工具满足，于是「这里又把 error
        丢了」照样通过，而那正是本文件唯一要防的东西。
        """
        src = open(TOOLS, encoding="utf-8").read()
        m = re.search(r"def web_search\(.*?\n(    def |    @tool)", src, re.S)
        self.assertIsNotNone(m, "找不到 web_search 这个工具——改名了？")
        return m.group(0)

    def test_error_is_forwarded(self):
        body = self._web_search_body()
        self.assertGreater(len(body), 400, "只截到一点点，正则大概坏了，下面的断言就是空跑")
        self.assertIn('result.get("error")', body,
                      "web_search 又不看 tavily_search 的 error 了——"
                      "模型会把「key 挂了」读成「网上没有」，见本文件头部")
        self.assertRegex(body, r'out\["error"\]\s*=',
                         "error 没往返回值里放")
        self.assertRegex(body, r'out\["retryable"\]\s*=',
                         "retryable 没往返回值里放——模型分不清该不该重试")


if __name__ == "__main__":
    unittest.main(verbosity=2)
