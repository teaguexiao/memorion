"""
Transcript Cleaner - LLM-based cleaning of raw STT transcripts.

Removes filler words, repetitions, self-corrections, and adds punctuation
while preserving original meaning.

Production prompts are fetched from Supabase (benchmark dashboard),
with hardcoded prompts as fallback.
"""

import json
import os
import time
import httpx
from functools import lru_cache
from typing import Dict, Any, Optional

from .clients import coerce_llm_text_content, create_model_llm
from .model_config import MODEL_CONFIG, resolve_model_id


# --- Supabase prompt sync (zero new dependencies, uses httpx already in project) ---

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")

# In-memory cache: { "light": { "content": "...", "fetched_at": timestamp }, ... }
_prompt_cache: Dict[str, Dict[str, Any]] = {}
_model_cache: Dict[str, Any] = {}  # { "model_id": "openai/gpt-4o-mini", "fetched_at": timestamp }
_CACHE_TTL = 300  # 5 minutes


def _fetch_production_prompt(cleaning_level: str) -> Optional[str]:
    """Fetch the production prompt. Priority:
    1. Local file cache (written by webhook, instant)
    2. HTTP from Supabase (5-min TTL, fallback)
    3. None (use hardcoded)
    """
    # 1. Try local file cache (written by webhook - instant, no network)
    try:
        from routers.internal_benchmark_webhook import get_cached_prompt
        cached = get_cached_prompt(cleaning_level)
        if cached:
            return cached
    except ImportError:
        pass
    
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        return None

    # 2. Fallback: HTTP fetch with in-memory cache
    mem_cached = _prompt_cache.get(cleaning_level)
    if mem_cached and (time.time() - mem_cached["fetched_at"]) < _CACHE_TTL:
        return mem_cached["content"]
    
    try:
        # Query Supabase REST API: prompts table, is_production=true, matching cleaning_level
        resp = httpx.get(
            f"{SUPABASE_URL}/rest/v1/prompts",
            params={
                "is_production": "eq.true",
                "cleaning_level": f"eq.{cleaning_level}",
                "select": "content",
                "limit": "1",
            },
            headers={
                "apikey": SUPABASE_ANON_KEY,
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            },
            timeout=5.0,
        )
        if resp.status_code == 200:
            data = resp.json()
            if data and len(data) > 0 and data[0].get("content"):
                content = data[0]["content"]
                _prompt_cache[cleaning_level] = {"content": content, "fetched_at": time.time()}
                print(f"[transcript_cleaner] Loaded production prompt for {cleaning_level} from Supabase")
                return content
    except Exception as e:
        print(f"[transcript_cleaner] Failed to fetch prompt from Supabase: {e}")
    
    return None


def _fetch_production_model() -> Optional[str]:
    """Fetch the production model. Priority:
    1. Local file cache (written by webhook, instant)
    2. HTTP from Supabase (5-min TTL, fallback)
    3. None (use the versioned transcript_cleaner default)
    """
    # 1. Try local file cache (written by webhook - instant, no network)
    try:
        from routers.internal_benchmark_webhook import get_cached_model
        cached = get_cached_model()
        if cached:
            return cached
    except ImportError:
        pass
    
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        return None

    # 2. Fallback: HTTP fetch with in-memory cache
    cached = _model_cache.get("current")
    if cached and (time.time() - cached["fetched_at"]) < _CACHE_TTL:
        return cached["model_id"]
    
    try:
        resp = httpx.get(
            f"{SUPABASE_URL}/rest/v1/models",
            params={
                "is_production": "eq.true",
                "select": "openrouter_id,name",
                "limit": "1",
            },
            headers={
                "apikey": SUPABASE_ANON_KEY,
                "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
            },
            timeout=5.0,
        )
        if resp.status_code == 200:
            data = resp.json()
            if data and len(data) > 0 and data[0].get("openrouter_id"):
                model_id = data[0]["openrouter_id"]
                model_name = data[0].get("name", model_id)
                _model_cache["current"] = {"model_id": model_id, "fetched_at": time.time()}
                print(f"[transcript_cleaner] Loaded production model: {model_name} ({model_id})")
                return model_id
    except Exception as e:
        print(f"[transcript_cleaner] Failed to fetch model from Supabase: {e}")
    
    return None


@lru_cache(maxsize=8)
def _create_cleaner_client(model_id: str):
    """Reuse credentials and HTTP pools; failed construction is not cached."""
    return create_model_llm(model_id, temperature=0.3, max_tokens=4096)


def _get_llm_client():
    """Get the LLM client for transcript cleaning.
    
    Priority: Supabase production model > the versioned cleaner default.
    Both pass through provider routes and migrations, including stale caches.
    Gemini selections use the same Vertex service account as image generation.
    """
    model = resolve_model_id(_fetch_production_model() or MODEL_CONFIG['transcript_cleaner']['model_id'])
    model = MODEL_CONFIG.get('model_routes', {}).get(model, model)
    return _create_cleaner_client(model)


CLEANING_PROMPT_FAST = """Clean this speech transcript. Remove filler words (嗯、呃、那个、就是说、就是、然后、所以说、like、um、uh、you know, etc.), remove repetitions, fix self-corrections. Keep the same language. Output ONLY the cleaned text, nothing else.

{text}"""

CLEANING_PROMPT_LIGHT = """You are a transcript cleaning assistant. Clean the following raw speech-to-text transcript with LIGHT cleaning only:

Rules (apply ALL):
1. Remove filler words (嗯、呃、那个、就是说、就是、然后、所以说、对吧、你知道、like、um、uh、you know、so、well、I mean, etc.)
2. Add proper punctuation (periods, commas, question marks, etc.)

Rules (do NOT apply):
- Do NOT remove repetitions
- Do NOT fix self-corrections
- Do NOT restructure sentences

CRITICAL: Preserve the original meaning and wording exactly. Only remove fillers and add punctuation.
CRITICAL: The output language MUST match the input language exactly. If the input is Chinese, output Chinese. If the input is English, output English. NEVER translate or switch languages.

Raw transcript:
{text}

Respond in JSON format:
{{"text": "cleaned text here", "changes": [{{"kind": "filler|formatting", "detail": "description of change"}}]}}"""

CLEANING_PROMPT_STANDARD = """You are a transcript cleaning assistant. Clean the following raw speech-to-text transcript with STANDARD cleaning:

Rules (apply ALL):
1. Remove filler words (嗯、呃、那个、就是说、就是、然后、所以说、对吧、你知道、like、um、uh、you know、so、well、I mean, etc.)
2. Remove repetitions (e.g., 这个这个 → 这个, the the → the)
3. Detect and resolve self-corrections (e.g., 周三不对周四 → 周四, Monday no Tuesday → Tuesday)
4. Add proper punctuation (periods, commas, question marks, etc.)

CRITICAL: Preserve the original meaning exactly. Do not add, infer, or restructure content.
CRITICAL: The output language MUST match the input language exactly. If the input is Chinese, output Chinese. If the input is English, output English. NEVER translate or switch languages.

Raw transcript:
{text}

Respond in JSON format:
{{"text": "cleaned text here", "changes": [{{"kind": "filler|repetition|correction|formatting", "detail": "description of change"}}]}}"""

CLEANING_PROMPT_AGGRESSIVE = """You are a transcript cleaning assistant. Clean the following raw speech-to-text transcript with AGGRESSIVE cleaning:

Rules (apply ALL):
1. Remove filler words (嗯、呃、那个、就是说、就是、然后、所以说、对吧、你知道、like、um、uh、you know、so、well、I mean, etc.)
2. Remove repetitions (e.g., 这个这个 → 这个, the the → the)
3. Detect and resolve self-corrections (e.g., 周三不对周四 → 周四, Monday no Tuesday → Tuesday)
4. Add proper punctuation (periods, commas, question marks, etc.)
5. Light restructuring for readability: fix run-on sentences, merge fragmented thoughts, improve flow. Do NOT change meaning or add new information.

CRITICAL: Preserve the original meaning exactly. Only restructure for clarity, never add content.
CRITICAL: The output language MUST match the input language exactly. If the input is Chinese, output Chinese. If the input is English, output English. NEVER translate or switch languages.

Raw transcript:
{text}

Respond in JSON format:
{{"text": "cleaned text here", "changes": [{{"kind": "filler|repetition|correction|formatting|restructure", "detail": "description of change"}}]}}"""

OUTPUT_FORMAT_BULLETS = """

Additionally, format the cleaned text as bullet points. Each distinct thought or topic should be a separate bullet point. Use "- " prefix for each bullet."""

OUTPUT_FORMAT_PARAGRAPH = """

Additionally, format the cleaned text as well-structured paragraphs. Group related thoughts together."""


def _get_prompt(level: str, output_format: str) -> str:
    """Get the appropriate cleaning prompt for the given level and output format.
    
    Priority: Supabase production prompt > hardcoded fallback.
    """
    # Try fetching from Supabase (benchmark dashboard)
    remote_prompt = _fetch_production_prompt(level)
    if remote_prompt:
        prompt = remote_prompt
    elif level == "light":
        prompt = CLEANING_PROMPT_LIGHT
    elif level == "aggressive":
        prompt = CLEANING_PROMPT_AGGRESSIVE
    else:
        prompt = CLEANING_PROMPT_STANDARD

    if output_format == "bullets":
        prompt += OUTPUT_FORMAT_BULLETS
    elif output_format == "paragraph":
        prompt += OUTPUT_FORMAT_PARAGRAPH

    return prompt


async def clean_transcript(
    text: str,
    level: str = "standard",
    output_format: str = "paragraph",
) -> Dict[str, Any]:
    """
    Clean a raw STT transcript.

    All levels use their production prompt and the configured LLM.

    Args:
        text: Raw transcript text from STT
        level: Cleaning level - "light", "standard", or "aggressive"
        output_format: Output format - "paragraph", "bullets", or "raw"

    Returns:
        Dict with "text" (cleaned text) and "changes" (list of changes made)
    """
    if not text or not text.strip():
        return {"text": "", "changes": []}

    # Validate parameters
    if level not in ("light", "standard", "aggressive"):
        level = "standard"
    if output_format not in ("paragraph", "bullets", "raw"):
        output_format = "paragraph"

    # Use full prompt for all levels (production prompts from Supabase or hardcoded)
    prompt_template = _get_prompt(level, output_format)
    
    # Split prompt into system (instructions) and user (transcript) parts
    # This enables prompt caching: system prefix is identical across requests
    if "{text}" in prompt_template:
        # Split at the {text} placeholder
        parts = prompt_template.split("{text}", 1)
        system_prompt = parts[0].rstrip()
        user_suffix = parts[1].lstrip() if len(parts) > 1 else ""
        user_content = text + ("\n\n" + user_suffix if user_suffix else "")
    else:
        # Fallback: use template as system, text as user
        system_prompt = prompt_template
        user_content = text

    # Resolve production/cache selections through versioned model migrations.
    llm = _get_llm_client()

    try:
        from langchain_core.messages import SystemMessage, HumanMessage
        messages = [
            SystemMessage(content=system_prompt),
            HumanMessage(content=user_content),
        ]
        response = await llm.ainvoke(messages)
        content = coerce_llm_text_content(response)
        if not content:
            raise RuntimeError('Model returned no cleaned transcript text')

        # Try parsing as JSON (standard/aggressive prompts expect JSON)
        try:
            if content.startswith("```"):
                lines = content.split("\n")
                lines = [l for l in lines if not l.strip().startswith("```")]
                content = "\n".join(lines)
            result = json.loads(content)
            return {
                "text": result.get("text", text),
                "changes": result.get("changes", []),
            }
        except (json.JSONDecodeError, ValueError):
            # Plain text response (e.g., from FAST prompt or non-JSON production prompt)
            return {"text": content, "changes": []}

    except Exception as e:
        print(f"[transcript_cleaner] Error cleaning transcript: {e}")
        return {"text": text, "changes": []}
