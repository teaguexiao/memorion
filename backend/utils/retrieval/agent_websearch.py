"""Web search for the chat agent, backed by Tavily (overhaul plan §5.1 / §14).

Why Tavily and not the AgentCore connector the plan originally named: AgentCore's
web search returned poor Chinese-language results, and it also forced an AWS
SigV4 JSON-RPC path (and a boto3 bump) that bought nothing for our OpenRouter/
Claude stack. Tavily is a plain REST call — it returns Google-grade results
(strong Chinese coverage), we hand them to Claude ourselves, and it costs a
fraction of AgentCore. See §14.7 for the decision record.

This module is deliberately provider-shaped, not tool-shaped: it exposes one
`tavily_search()` function that does the HTTP and normalizes the response. The
`web_search` @tool that wraps it lives in agent_tools.make_agent_tools, next to
the other tools, so the tool surface stays in one place and this file stays easy
to mock in tests.
"""

import logging
import os
from typing import List, Optional

import requests

logger = logging.getLogger(__name__)

TAVILY_SEARCH_URL = "https://api.tavily.com/search"

# One HTTP round trip; Tavily p95 is a few seconds. Kept short so a slow search
# never stalls a chat turn — a timeout surfaces as "no results" and the agent
# answers from what it has.
TAVILY_TIMEOUT_S = 12

# Default breadth. The tool caps to this range; "basic" depth is one credit and
# plenty for the quick factual lookups chat needs (advanced is 2 credits and
# aimed at research fan-out).
DEFAULT_WEB_RESULTS = 5
MAX_WEB_RESULTS = 10

# Chars of each result's content passed to the model. Enough to judge and quote
# from, short enough that a handful of hits doesn't blow up the context.
WEB_SNIPPET_CHARS = 500

# Statuses where retrying within the same turn cannot possibly help, mapped to the
# sentence the model is told. Kept separate from transient failures because the two
# call for opposite behaviour: retry vs. stop and say search is unavailable.
#
# 🚨 **432 is Tavily's "this key's configured usage limit" status, and it is not
# 429.** It means a cap someone set on the dashboard, not exhausted credits and not
# rate limiting — so waiting does nothing and the fix is a dashboard knob. This is
# the one that took us longest to identify (2026-08-12), because the error field
# was being dropped before the model ever saw it (see the web_search tool).
_PERMANENT_STATUSES = {
    401: "web search unavailable: the search key was rejected. Do not retry.",
    403: "web search unavailable: the search key was rejected. Do not retry.",
    429: "web search unavailable: rate limited. Do not retry in this turn.",
    432: "web search unavailable: the search key has hit its usage limit. Do not retry.",
    402: "web search unavailable: the search account is out of credit. Do not retry.",
}


def _api_key() -> Optional[str]:
    return os.environ.get("TAVILY_API_KEY")


def tavily_search(
    query: str,
    max_results: int = DEFAULT_WEB_RESULTS,
    topic: str = "general",
    time_range: Optional[str] = None,
) -> dict:
    """Run one Tavily web search and return normalized results.

    Returns ``{"results": [{"title","url","snippet","score"}], "answer": str|None}``.
    On any failure (no key, network, non-200, malformed body) returns
    ``{"results": [], "error": <reason>, "retryable": bool}`` — callers/tools
    translate that into a graceful "couldn't search" rather than raising into the
    agent loop.

    ⚠️ **`error` must be forwarded to the model, not dropped.** ``{"results": []}``
    with the error stripped is indistinguishable from "the web genuinely has
    nothing on this", and the tool docstring tells the model to refine and search
    again when a search misses. That combination is a retry storm: one capped key
    produced 18 consecutive `web_search` calls on a single question, and the eval
    reported it as a model failure on `general_knowledge` rather than as broken
    infrastructure.
    """
    key = _api_key()
    if not key:
        # Not configured (e.g. a dev env without the secret). Fail soft so the
        # rest of the agent still works.
        logger.warning("tavily_search: TAVILY_API_KEY not set; skipping web search")
        return {"results": [], "error": "web search is not available. Do not retry.",
                "retryable": False}

    capped = max(1, min(max_results or DEFAULT_WEB_RESULTS, MAX_WEB_RESULTS))
    payload = {
        "query": query,
        "search_depth": "basic",
        "topic": topic if topic in ("general", "news", "finance") else "general",
        "max_results": capped,
        # We synthesize the answer with Claude ourselves; asking Tavily for an
        # answer too would waste a credit and isn't what feeds the citation.
        "include_answer": False,
        "include_raw_content": False,
    }
    if time_range in ("day", "week", "month", "year"):
        payload["time_range"] = time_range

    resp = None
    try:
        resp = requests.post(
            TAVILY_SEARCH_URL,
            json=payload,
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            timeout=TAVILY_TIMEOUT_S,
        )
        status = resp.status_code
        if status in _PERMANENT_STATUSES:
            # Quota / auth: retrying inside this turn cannot help. Say so, because
            # the tool docstring tells the model to "refine and search again if
            # the first misses" — with an unlabelled failure that instruction
            # turns one dead key into a retry storm (measured: 18 web_search
            # calls on a single eval question, all of them 432s).
            logger.error("tavily_search: permanent failure http=%s body=%s", status,
                         (resp.text or "")[:200])
            return {"results": [], "error": _PERMANENT_STATUSES[status], "retryable": False}
        resp.raise_for_status()
        body = resp.json()
    except requests.RequestException:
        # ⚠️ Log the status code, not just the traceback. Everything used to come
        # out as one line ("request failed"), so "the key hit its cap" and "one
        # slow request timed out" were the same log entry — which is how a dead
        # key survived two full eval runs unnoticed.
        logger.exception("tavily_search: request failed http=%s query_len=%d",
                         getattr(resp, "status_code", "-"), len(query or ""))
        return {"results": [], "error": "web search failed", "retryable": True}
    except ValueError:
        logger.exception("tavily_search: bad JSON query_len=%d", len(query or ""))
        return {"results": [], "error": "web search failed", "retryable": True}

    return {"results": _normalize(body.get("results") or []), "answer": body.get("answer")}


def _normalize(raw_results: List[dict]) -> List[dict]:
    normalized = []
    for item in raw_results:
        if not isinstance(item, dict):
            continue
        content = (item.get("content") or "").strip()
        if len(content) > WEB_SNIPPET_CHARS:
            content = content[:WEB_SNIPPET_CHARS].rstrip() + "…"
        normalized.append(
            {
                "title": item.get("title") or "",
                "url": item.get("url") or "",
                "snippet": content,
                "score": item.get("score"),
            }
        )
    return normalized
