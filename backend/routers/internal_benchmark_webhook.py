"""
Internal webhook for receiving production config updates from Sayd Benchmark Dashboard.

When a prompt or model is set as "production" in the benchmark dashboard,
Supabase Database Webhook triggers this endpoint to refresh the local cache.
"""

import hmac
import os
import json
import time
from typing import Optional
from pathlib import Path

from fastapi import APIRouter, HTTPException, Header
from pydantic import BaseModel

router = APIRouter()

# Secret for authenticating webhook calls from Supabase
BENCHMARK_WEBHOOK_SECRET = os.environ.get("BENCHMARK_WEBHOOK_SECRET", "")

# Local file cache for production config (survives process restarts)
_CACHE_DIR = Path(__file__).parent.parent.parent / ".cache"
_PROMPT_CACHE_FILE = _CACHE_DIR / "production_prompts.json"
_MODEL_CACHE_FILE = _CACHE_DIR / "production_model.json"


class WebhookPayload(BaseModel):
    type: str  # "UPDATE" / "INSERT"
    table: str  # "prompts" / "models"
    record: dict  # The new row data
    old_record: Optional[dict] = None


def _ensure_cache_dir():
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)


def get_cached_prompt(cleaning_level: str) -> Optional[str]:
    """Read cached production prompt from local file. Used by transcript_cleaner."""
    try:
        if _PROMPT_CACHE_FILE.exists():
            data = json.loads(_PROMPT_CACHE_FILE.read_text())
            return data.get(cleaning_level, {}).get("content")
    except Exception:
        pass
    return None


def get_cached_model() -> Optional[str]:
    """Read cached production model OpenRouter ID from local file. Used by transcript_cleaner."""
    try:
        if _MODEL_CACHE_FILE.exists():
            data = json.loads(_MODEL_CACHE_FILE.read_text())
            return data.get("openrouter_id")
    except Exception:
        pass
    return None


@router.post(
    "/v1/internal/benchmark-webhook",
    tags=["internal"],
    summary="Receive production config updates from Benchmark Dashboard",
)
async def benchmark_webhook(
    payload: WebhookPayload,
    x_webhook_secret: Optional[str] = Header(None, alias="x-webhook-secret"),
):
    """
    Called by Supabase Database Webhook when prompts or models table is updated.
    Updates local file cache for production prompts and models.
    
    Authentication: x-webhook-secret header must match BENCHMARK_WEBHOOK_SECRET env var.
    """
    if not BENCHMARK_WEBHOOK_SECRET:
        raise HTTPException(status_code=503, detail="Webhook is unavailable")
    if not x_webhook_secret or not hmac.compare_digest(
        x_webhook_secret.encode("utf-8"), BENCHMARK_WEBHOOK_SECRET.encode("utf-8")
    ):
        raise HTTPException(status_code=401, detail="Invalid webhook secret")

    _ensure_cache_dir()
    record = payload.record

    if payload.table == "prompts" and record.get("is_production"):
        # Update prompt cache
        cleaning_level = record.get("cleaning_level", "standard")
        content = record.get("content", "")
        
        # Read existing cache, update the specific level
        prompts = {}
        try:
            if _PROMPT_CACHE_FILE.exists():
                prompts = json.loads(_PROMPT_CACHE_FILE.read_text())
        except Exception:
            pass
        
        prompts[cleaning_level] = {
            "content": content,
            "version": record.get("version", ""),
            "updated_at": time.time(),
        }
        _PROMPT_CACHE_FILE.write_text(json.dumps(prompts, ensure_ascii=False, indent=2))
        print(f"[benchmark-webhook] Updated production prompt: {cleaning_level} ({record.get('version', '')})")
        
        return {"status": "ok", "updated": "prompt", "cleaning_level": cleaning_level}

    elif payload.table == "prompt_labels":
        # Memorion prompt registry: a label moved to a new version in the
        # benchmark dashboard. Invalidate Redis + in-process cache so all
        # call sites pick up the new version immediately (instead of waiting
        # for the SWR TTL). The definition key is resolved via Supabase by
        # the registry on next access; here we only need the key to drop.
        definition_key = record.get("definition_key") or ""
        label = record.get("label", "production")
        if definition_key:
            from utils.llm.prompt_registry import invalidate

            invalidate(definition_key, label)
            print(f"[benchmark-webhook] Invalidated prompt cache: {definition_key}:{label}")
            return {"status": "ok", "updated": "prompt_label", "key": definition_key, "label": label}
        return {"status": "ok", "updated": "none", "reason": "missing definition_key in payload"}

    elif payload.table == "models" and record.get("is_production"):
        # Update model cache
        model_data = {
            "name": record.get("name", ""),
            "openrouter_id": record.get("openrouter_id", ""),
            "updated_at": time.time(),
        }
        _MODEL_CACHE_FILE.write_text(json.dumps(model_data, ensure_ascii=False, indent=2))
        print(f"[benchmark-webhook] Updated production model: {record.get('name')} ({record.get('openrouter_id')})")
        
        return {"status": "ok", "updated": "model", "model": record.get("name")}

    return {"status": "ok", "updated": "none", "reason": "not a production record"}
