"""Inference accounting without prompt, transcript, completion or user identifiers."""
import json
import logging
import math
import time

from langchain_core.callbacks import BaseCallbackHandler

logger = logging.getLogger(__name__)


def _mapping(value):
    return value if isinstance(value, dict) else {}


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else None


class InferenceUsage(BaseCallbackHandler):
    def __init__(self, stage, client):
        self.stage = stage
        values = vars(client)
        self.model = next((values[k] for k in ('model_name', 'model', 'model_id')
                           if isinstance(values.get(k), str)), type(client).__name__)
        self.started = time.monotonic()

    def _emit(self, status, **fields):
        event = {'stage': self.stage, 'model': self.model, 'status': status,
                 'elapsed_ms': round((time.monotonic() - self.started) * 1000), **fields}
        logger.info('[timeline_inference] %s', json.dumps(event, ensure_ascii=False))

    def on_llm_end(self, response, **kwargs):
        # Providers expose raw OpenAI usage or LangChain's normalized metadata.
        # Read only explicit accounting fields, never serialize the response.
        raw = _mapping(_mapping(response.llm_output).get('token_usage'))
        normalized = {}
        if response.generations and response.generations[0]:
            message = getattr(response.generations[0][0], 'message', None)
            metadata = _mapping(getattr(message, 'response_metadata', None))
            raw = raw or _mapping(metadata.get('token_usage')) or _mapping(metadata.get('usage'))
            normalized = _mapping(getattr(message, 'usage_metadata', None))
        inputs = _mapping(raw.get('prompt_tokens_details'))
        outputs = _mapping(raw.get('completion_tokens_details'))
        normalized_inputs = _mapping(normalized.get('input_token_details'))
        normalized_outputs = _mapping(normalized.get('output_token_details'))
        values = {
            'input_tokens': raw.get('prompt_tokens', normalized.get('input_tokens')),
            'output_tokens': raw.get('completion_tokens', normalized.get('output_tokens')),
            'cache_read_tokens': inputs.get('cached_tokens', normalized_inputs.get('cache_read')),
            'cache_write_tokens': inputs.get('cache_write_tokens', normalized_inputs.get('cache_creation')),
            'reasoning_tokens': outputs.get('reasoning_tokens', normalized_outputs.get('reasoning')),
            # Unknown cost stays absent. Do not estimate it from catalog prices.
            'reported_cost_usd': raw.get('cost'),
        }
        self._emit('completed', **{key: value for key, value in values.items() if _number(value) is not None})

    def on_llm_error(self, error, **kwargs):
        self._emit('failed', error_type=type(error).__name__)


def usage_config(stage, client):
    return {'callbacks': [InferenceUsage(stage, client)]}
