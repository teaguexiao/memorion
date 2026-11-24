"""
Prompt Registry - dynamic prompt/config resolution for production LLM call sites.

Generalizes the transcript_cleaner Supabase-fetch pattern (version/label model
borrowed from Langfuse):
  - Prompts live in Supabase `memorion` schema: prompt_definitions (logical
    key) -> prompt_versions (immutable content+config) -> prompt_labels
    (movable pointer, e.g. 'production'). Promoting/rolling back a prompt is
    a label move in the benchmark dashboard - no ECS deploy needed.
  - Resolution order: in-process cache (SWR) -> Redis shared cache ->
    Supabase REST -> code-embedded fallback PromptSpec.
  - Stale-while-revalidate: once a prompt has been resolved, the production
    path never blocks on the network again; stale entries are refreshed in a
    background thread.
  - Templates use {{var}} placeholders (moustache-style) so prompt content
    can safely contain single-brace JSON examples.

Usage:
    from utils.llm.prompt_registry import PromptSpec, get_prompt

    FALLBACK = PromptSpec(content="Summarize: {{text}}", config={})
    resolved = get_prompt("conversation.structure", fallback=FALLBACK)
    prompt_str = resolved.render(text="...")
"""

import json
import os
import re
import threading
import time
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any, Dict, Optional

import httpx

# Optional PostgREST prompt registry. Without it, versioned code defaults apply.
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")

_CACHE_TTL = int(os.environ.get("PROMPT_REGISTRY_TTL", "300"))  # seconds
_FETCH_TIMEOUT = 3.0

_VAR_PATTERN = re.compile(r"\{\{\s*(\w+)\s*\}\}")


@dataclass
class PromptSpec:
    """Code-embedded fallback prompt (content + LLM config)."""

    content: str
    config: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ResolvedPrompt:
    """A prompt resolved from the registry (or fallback)."""

    key: str
    content: str
    config: Dict[str, Any]
    version: Optional[int] = None  # None when is_fallback
    label: str = "production"
    is_fallback: bool = False
    fallback_content: Optional[str] = None  # code-embedded template for render degradation

    def render(self, **variables) -> str:
        """
        Render {{var}} placeholders.

        A registry prompt referencing variables the call site doesn't supply
        (e.g. a typo'd placeholder added in the dashboard) degrades to the
        code-embedded fallback template instead of crashing production.
        Raises KeyError only if the fallback itself is missing variables,
        which is a programming error at the call site.
        """
        missing = [v for v in _VAR_PATTERN.findall(self.content) if v not in variables]
        if missing and not self.is_fallback and self.fallback_content is not None:
            print(
                f"[prompt_registry] prompt '{self.key}' v{self.version} has unknown "
                f"variables {missing}; degrading to code fallback"
            )
            self.content = self.fallback_content
            self.is_fallback = True
            self.version = None
            missing = [v for v in _VAR_PATTERN.findall(self.content) if v not in variables]
        if missing:
            raise KeyError(f"prompt '{self.key}' missing variables: {missing}")
        return _VAR_PATTERN.sub(lambda m: str(variables[m.group(1)]), self.content)


# In-process cache: key -> {"data": dict|None, "fetched_at": float}
# data=None caches a "not found in registry" result to avoid hammering Supabase.
_cache: Dict[str, Dict[str, Any]] = {}
_cache_lock = threading.Lock()
_refreshing: set = set()


def _redis_cache_key(key: str, label: str) -> str:
    return f"prompt_registry:{key}:{label}"


def _redis_get(key: str, label: str) -> Optional[dict]:
    try:
        from database.redis_db import get_generic_cache

        return get_generic_cache(_redis_cache_key(key, label))
    except Exception:
        return None


def _redis_set(key: str, label: str, data: dict):
    try:
        from database.redis_db import set_generic_cache

        set_generic_cache(_redis_cache_key(key, label), data, ttl=_CACHE_TTL)
    except Exception:
        pass


def invalidate(key: str, label: str = "production"):
    """Drop Redis + in-process cache for a prompt (called by label-change webhook)."""
    try:
        from database.redis_db import delete_generic_cache

        delete_generic_cache(_redis_cache_key(key, label))
    except Exception:
        pass
    with _cache_lock:
        _cache.pop(f"{key}:{label}", None)


def _fetch_from_supabase(key: str, label: str) -> Optional[dict]:
    """Fetch {content, config, version} for a prompt key + label, or None."""
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        return None
    resp = httpx.get(
        f"{SUPABASE_URL}/rest/v1/prompt_labels",
        params={
            "select": "label,version:prompt_versions(version,content,config),definition:prompt_definitions!inner(key)",
            "definition.key": f"eq.{key}",
            "label": f"eq.{label}",
            "limit": "1",
        },
        headers={
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            "Accept-Profile": "memorion",  # PostgREST: query the memorion schema
        },
        timeout=_FETCH_TIMEOUT,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"registry fetch {key}:{label} -> HTTP {resp.status_code}")
    rows = resp.json()
    if not rows or not rows[0].get("version"):
        return None
    v = rows[0]["version"]
    return {
        "content": v["content"],
        "config": v.get("config") or {},
        "version": v.get("version"),
    }


def _resolve_uncached(key: str, label: str) -> Optional[dict]:
    """Redis -> Supabase. Returns registry data dict, None (not registered), or raises."""
    data = _redis_get(key, label)
    if data:
        return data
    data = _fetch_from_supabase(key, label)
    if data:
        _redis_set(key, label, data)
    return data


def _background_refresh(key: str, label: str):
    cache_key = f"{key}:{label}"
    try:
        data = _resolve_uncached(key, label)
        with _cache_lock:
            _cache[cache_key] = {"data": data, "fetched_at": time.time()}
    except Exception as e:
        # Keep serving the stale entry; just bump fetched_at so we don't
        # spawn a refresh thread on every call while the registry is down.
        print(f"[prompt_registry] background refresh failed for {cache_key}: {e}")
        with _cache_lock:
            entry = _cache.get(cache_key)
            if entry:
                entry["fetched_at"] = time.time() - _CACHE_TTL + 30
    finally:
        _refreshing.discard(cache_key)


def get_prompt(key: str, fallback: PromptSpec, label: str = "production") -> ResolvedPrompt:
    """
    Resolve a prompt from the registry with SWR caching.

    Never blocks the caller once a value (including "not registered") has been
    cached; only the very first call per process may hit the network (3s cap).
    Falls back to the code-embedded PromptSpec when the registry is
    unreachable or the key has no version behind the requested label.
    """
    cache_key = f"{key}:{label}"

    with _cache_lock:
        entry = _cache.get(cache_key)

    if entry is not None:
        age = time.time() - entry["fetched_at"]
        if age >= _CACHE_TTL and cache_key not in _refreshing:
            _refreshing.add(cache_key)
            threading.Thread(
                target=_background_refresh, args=(key, label), daemon=True
            ).start()
        data = entry["data"]
    else:
        # Cold path: synchronous fetch with short timeout, degrade to fallback.
        try:
            data = _resolve_uncached(key, label)
        except Exception as e:
            print(f"[prompt_registry] fetch failed for {cache_key}, using fallback: {e}")
            data = None
            # Cache the failure briefly so we retry soon but don't block every call.
            with _cache_lock:
                _cache[cache_key] = {"data": None, "fetched_at": time.time() - _CACHE_TTL + 30}
            return ResolvedPrompt(
                key=key, content=fallback.content, config=dict(fallback.config),
                label=label, is_fallback=True,
            )
        with _cache_lock:
            _cache[cache_key] = {"data": data, "fetched_at": time.time()}

    if data is None:
        return ResolvedPrompt(
            key=key, content=fallback.content, config=dict(fallback.config),
            label=label, is_fallback=True,
        )

    # Merge config: registry values override fallback defaults.
    config = dict(fallback.config)
    config.update(data.get("config") or {})
    return ResolvedPrompt(
        key=key,
        content=data["content"],
        config=config,
        version=data.get("version"),
        label=label,
        is_fallback=False,
        fallback_content=fallback.content,
    )


def single_brace_spec(content: str, config: Optional[Dict[str, Any]] = None) -> PromptSpec:
    """
    Build a PromptSpec from legacy single-brace template text ({var} ->
    {{var}}), so existing langchain-style prompts can be used as fallbacks
    without rewriting them. Literal braces in the source are not supported.
    """
    return PromptSpec(
        content=re.sub(r"\{(\w+)\}", r"{{\1}}", content),
        config=config or {},
    )


@lru_cache(maxsize=16)
def _override_client(model_id: str, options_json: str, provider: Optional[str] = None):
    """Share clients for repeated registry settings, as we already do for tiers.

    Keeps cache checks from creating HTTP connection pools per request. Failed
    construction is not cached; transient errors can recover on the next lookup.
    """
    from .clients import create_model_llm

    return create_model_llm(model_id, provider=provider, **json.loads(options_json))


def resolve_llm(resolved: ResolvedPrompt, default_llm):
    """
    Return the LLM client for a resolved prompt.

    If the prompt version's config pins a model (config.model_id), resolve it
    through the model registry. config.provider can pin an explicit provider;
    otherwise return the call site's default client. Mirrors
    transcript_cleaner._get_llm_client but driven by per-version config.
    """
    model_id = (resolved.config or {}).get("model_id")
    if not model_id:
        return default_llm
    try:
        kwargs = {
            key: resolved.config[key]
            for key in ("temperature", "max_tokens", "reasoning_effort")
            if key in resolved.config
        }
        return _override_client(model_id, json.dumps(kwargs, sort_keys=True), resolved.config.get('provider'))
    except Exception as e:
        print(f"[prompt_registry] failed to build model override client ({model_id}): {e}")
        return default_llm
