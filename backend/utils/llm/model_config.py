"""Versioned model routing and request defaults; no provider SDKs or network IO.

Model IDs and compatibility settings live in config/llm_models.json. Bump its
version with every change. An invalid configuration fails at startup rather
than silently bringing back a retired model.
"""

import copy
import json
import os
from pathlib import Path
from typing import Any, Dict


DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[2] / 'config' / 'llm_models.json'
MODEL_TIERS = frozenset({
    'mini', 'medium', 'medium_experiment', 'large', 'high',
    'persona_mini', 'persona_medium',
})


def load_model_config(path: Path) -> Dict[str, Any]:
    with path.open(encoding='utf-8') as handle:
        config = json.load(handle)
    if config.get('schema_version') != 1:
        raise ValueError('Unsupported LLM model configuration schema_version')
    if not isinstance(config.get('version'), str) or not config['version'].strip():
        raise ValueError('LLM model configuration requires a nonempty version')
    providers = config.get('providers', {})
    if set(providers) != {'openrouter', 'bedrock', 'gemini'}:
        raise ValueError('LLM model configuration must define all three providers')
    for provider, routes in providers.items():
        if set(routes) != MODEL_TIERS:
            raise ValueError(f'Incomplete LLM model tiers for {provider}')
        if any(not isinstance(model, str) or not model.strip() for model in routes.values()):
            raise ValueError(f'Invalid model ID for {provider}')
    for provider, overrides in config.get('provider_overrides', {}).items():
        if (provider not in providers or not isinstance(overrides, dict)
                or any(tier not in MODEL_TIERS or target not in providers
                       for tier, target in overrides.items())):
            raise ValueError('Invalid provider_overrides')
    for source, target in config.get('model_routes', {}).items():
        if (not isinstance(source, str) or '/' not in source
                or target not in {*providers['bedrock'].values(), *providers['gemini'].values()}):
            raise ValueError('Invalid model_routes')
    replacements = config.get('replacements', {})
    for role in ('conversation_summary', 'image_description'):
        route = config.get(role, {})
        if (set(route) != {'provider', 'model_tier'}
                or route['provider'] not in providers or route['model_tier'] not in MODEL_TIERS):
            raise ValueError(f'Invalid {role} model route')
    if config['image_description']['provider'] != 'gemini':
        raise ValueError('image_description requires the gemini provider')
    for role in ('image_generation',):
        route = config.get(role, {})
        if (not isinstance(route, dict)
                or set(route) != {'model_id', 'location'}
                or not isinstance(route['model_id'], str)
                or not route['model_id'].strip()
                or route['location'] != 'global'):
            raise ValueError(f'Invalid {role} Vertex global model route')
    reviewer = config.get('image_generation_review', {})
    if (not isinstance(reviewer, dict) or set(reviewer) != {'provider', 'model_id', 'region'}
            or reviewer.get('provider') != 'bedrock'
            or reviewer.get('model_id') not in providers['bedrock'].values()
            or reviewer.get('region') not in {'us-east-1', 'us-west-2'}):
        raise ValueError('Invalid image_generation_review registered Bedrock model route')
    cleaner = config.get('transcript_cleaner', {})
    known_models = {model for routes in providers.values() for model in routes.values()}
    known_models.update(config.get('model_routes', {}))
    known_models.update(replacements)
    if (set(cleaner) != {'model_id'} or not isinstance(cleaner['model_id'], str)
            or cleaner['model_id'] not in known_models):
        raise ValueError('Invalid transcript_cleaner registered model route')
    chapter = config.get('chapter_rollup', {})
    if set(chapter) != {'generation_tier', 'grounding_tier'} or any(tier not in MODEL_TIERS for tier in chapter.values()):
        raise ValueError('Invalid chapter_rollup model tiers')
    for original in replacements:
        seen = set()
        model = original
        while model in replacements:
            if model in seen:
                raise ValueError(f'Cyclic LLM model replacement: {original}')
            seen.add(model)
            model = replacements[model]
            if not isinstance(model, str) or not model.strip():
                raise ValueError(f'Invalid LLM replacement for {original}')
    for model, parameters in config.get('model_parameters', {}).items():
        if not isinstance(parameters, dict):
            raise ValueError(f'Invalid model parameters for {model}')
        # Configuration controls inference settings, never credentials or endpoints.
        unknown = set(parameters) - {
            'reasoning_effort', 'additional_model_request_fields',
            'supports_tool_choice_values', 'max_tokens', 'thinking_level',
        }
        if unknown:
            raise ValueError(f'Unsupported model parameters for {model}: {sorted(unknown)}')
        if 'thinking_level' in parameters and parameters['thinking_level'] not in {'low', 'medium', 'high'}:
            raise ValueError(f'Invalid thinking_level for {model}')
    blocked = config.get('models_without_temperature', [])
    if not isinstance(blocked, list) or any(not isinstance(item, str) or not item for item in blocked):
        raise ValueError('Invalid models_without_temperature')
    return config


MODEL_CONFIG = load_model_config(Path(os.environ.get('LLM_MODEL_CONFIG_FILE') or DEFAULT_CONFIG_PATH))
MODEL_CONFIG_VERSION = MODEL_CONFIG['version']
MODELS_WITHOUT_TEMPERATURE = frozenset(MODEL_CONFIG['models_without_temperature'])


def resolve_model_id(model_id: str) -> str:
    """Apply explicitly configured migrations, including old registry overrides."""
    replacements = MODEL_CONFIG['replacements']
    while model_id in replacements:
        model_id = replacements[model_id]
    return model_id


def model_map(provider: str) -> Dict[str, str]:
    return {tier: resolve_model_id(model) for tier, model in MODEL_CONFIG['providers'][provider].items()}


def tier_provider(provider: str, tier: str) -> str:
    return MODEL_CONFIG.get('provider_overrides', {}).get(provider, {}).get(tier, provider)


def model_accepts_temperature(model_id: str) -> bool:
    return not any(base in model_id for base in MODELS_WITHOUT_TEMPERATURE)


def model_parameters(model_id: str, **overrides) -> Dict[str, Any]:
    """Merge inference options and remove unsupported sampling parameters.

    Callers resolve the ID first. Explicit prompt-version options take precedence
    over model defaults, except parameters the target model does not accept.
    """
    parameters = copy.deepcopy(MODEL_CONFIG['model_parameters'].get(model_id, {}))
    parameters.update({key: value for key, value in overrides.items() if value is not None})
    if not model_accepts_temperature(model_id):
        for key in ('temperature', 'top_p', 'top_k'):
            parameters.pop(key, None)
    return parameters
