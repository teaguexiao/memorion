"""Fingerprints of inference inputs, never credentials or unrelated model roles."""

import hashlib
import json
from pydantic_core import to_jsonable_python


def digest(value) -> str:
    return hashlib.sha256(json.dumps(to_jsonable_python(value), sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode('utf-8')).hexdigest()


def model_identity(client) -> dict:
    """Allowlist actual instantiated client settings (including registry overrides).

    Do not serialize a whole LangChain model: that includes credentials, callbacks
    and unrelated metadata such as the global model configuration version.
    These fields cover the three clients supported by create_llm.
    """
    fields = (
        'model_name', 'model', 'model_id', 'temperature', 'top_p', 'top_k', 'n',
        'max_tokens', 'max_output_tokens', 'stop', 'stop_sequences', 'seed',
        'frequency_penalty', 'presence_penalty', 'reasoning_effort', 'reasoning',
        'thinking_level', 'thinking_budget', 'include_thoughts', 'model_kwargs',
        'extra_body', 'additional_model_request_fields', 'safety_settings',
        'supports_tool_choice_values', 'openai_api_base', 'region_name',
        'project', 'location', 'vertexai',
    )
    values = vars(client)
    return {
        'client': f'{type(client).__module__}.{type(client).__qualname__}',
        'parameters': {key: values[key] for key in fields if values.get(key) is not None},
    }


def prompt_identity(prompt) -> dict:
    # A registry outage or a label/version promotion with identical content is
    # not a different inference input. Effective model parameters are hashed
    # separately, including changes introduced by a fallback config.
    return {'key': prompt.key, 'content': prompt.content}
