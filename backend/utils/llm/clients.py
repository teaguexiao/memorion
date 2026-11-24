import os
import re
import textwrap
from enum import Enum
from typing import Any, Optional, get_args, get_origin

from botocore.config import Config as BotoConfig
from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.messages import AIMessage
from langchain_openai import ChatOpenAI
from langchain_aws import ChatBedrockConverse
from langchain_google_genai import ChatGoogleGenerativeAI
import tiktoken
import yaml

from models.conversation import Structured
from .model_config import (
    MODEL_CONFIG,
    MODEL_CONFIG_VERSION,
    MODELS_WITHOUT_TEMPERATURE,
    model_accepts_temperature as _model_accepts_temperature,
    model_map,
    model_parameters,
    resolve_model_id,
    tier_provider,
)


def coerce_llm_text_content(content: Any) -> str:
    """Extract plain text from LangChain string or typed content-block output."""
    if isinstance(content, AIMessage):
        content = content.content
    if isinstance(content, list):
        text_parts = []
        for block in content:
            if isinstance(block, str):
                text_parts.append(block)
            elif isinstance(block, dict) and block.get('text') is not None:
                text_parts.append(str(block['text']))
        return '\n'.join(text_parts).strip()
    if content is None:
        return ''
    return str(content).strip()


class MarkdownCleaningParser(PydanticOutputParser):
    """
    A custom parser that cleans markdown code blocks from LLM output before parsing.
    AWS Bedrock Claude models sometimes wrap JSON output in ```json ... ``` blocks,
    which causes parsing failures with the standard PydanticOutputParser.
    """

    def parse(self, text: str):
        """Parse the output, cleaning markdown code blocks first."""
        # Clean markdown code blocks (```json ... ``` or ``` ... ```)
        cleaned = re.sub(r'^```(?:json)?\s*\n?', '', coerce_llm_text_content(text))
        cleaned = re.sub(r'\n?```\s*$', '', cleaned)

        try:
            return super().parse(cleaned)
        except Exception:
            # Gemini occasionally follows the requested schema but emits it as
            # top-level ``field: value`` text instead of JSON.  The payload can
            # still contain the complete, high-quality summary; throwing it away
            # leaves the user with a permanent generic "Conversation" card and an
            # empty overview.  Recover only exact Pydantic field labels, then let
            # model validation remain the final gate.
            recovered = self._parse_labeled_fields(cleaned)
            if recovered is None:
                raise
            return self.pydantic_object.model_validate(recovered)

    def _parse_labeled_fields(self, text: str) -> Optional[dict]:
        fields = self.pydantic_object.model_fields
        if not fields:
            return None

        labels = sorted((re.escape(name) for name in fields), key=len, reverse=True)
        pattern = re.compile(
            rf"^(?P<name>{'|'.join(labels)}):[ \t]*(?P<inline>.*)$",
            re.MULTILINE,
        )
        matches = list(pattern.finditer(text))
        if not matches:
            return None

        recovered = {}
        for idx, match in enumerate(matches):
            name = match.group('name')
            end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
            inline = match.group('inline').rstrip()
            continuation = text[match.end():end].strip('\n')
            raw = inline
            if continuation.strip():
                raw = f"{inline}\n{continuation}" if inline else continuation
            recovered[name] = self._parse_labeled_value(fields[name].annotation, raw)

        # One accidental "title:" line inside prose is not enough evidence that
        # the model attempted the requested shape.
        if len(recovered) < 2:
            return None
        return recovered

    @staticmethod
    def _parse_labeled_value(annotation, raw: str):
        raw = textwrap.dedent(raw).strip()
        origin = get_origin(annotation)

        if annotation is str or (isinstance(annotation, type) and issubclass(annotation, Enum)):
            return raw
        if not raw:
            if origin is list:
                return []
            if origin is dict:
                return {}
            return None

        try:
            value = yaml.safe_load(raw)
        except yaml.YAMLError:
            return raw

        # In YAML, an unquoted highlight such as ``姚草: 不开心。`` is parsed as
        # a one-entry mapping.  For list[str] fields the colon belongs to the
        # verbatim quote, so reconstruct it before Pydantic validation.
        args = get_args(annotation)
        if origin is list and args and args[0] is str and isinstance(value, list):
            normalized = []
            for item in value:
                if isinstance(item, dict) and len(item) == 1:
                    key, item_value = next(iter(item.items()))
                    item = f"{key}: {item_value}"
                normalized.append(item)
            return normalized
        return value

# =============================================================================
# LLM Provider Configuration
# =============================================================================
# Set LLM_PROVIDER environment variable to switch between providers:
#   - "openrouter" (default): Uses OpenRouter API with various models
#   - "bedrock": Uses AWS Bedrock model IDs from the versioned configuration
#   - "gemini": Uses Google Gemini API
# =============================================================================

LLM_PROVIDER = os.environ.get('LLM_PROVIDER', 'openrouter')

# OpenRouter configuration
OPENROUTER_API_KEY = os.environ.get('OPENROUTER_API_KEY')
OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
OPENROUTER_HEADERS = {"X-Title": "Memorion Chat"}

# All model IDs, migrations, and inference defaults are versioned in
# backend/config/llm_models.json. Keep these exported maps for existing callers.
OPENROUTER_MODELS = model_map('openrouter')
BEDROCK_MODELS = model_map('bedrock')
GEMINI_MODELS = model_map('gemini')

# Bedrock configuration
AWS_REGION = os.environ.get('AWS_REGION', 'us-west-2')
BEDROCK_REGION = os.environ.get('BEDROCK_REGION', AWS_REGION)

# Gemini/Vertex AI configuration
# Uses Service Account authentication via GOOGLE_APPLICATION_CREDENTIALS
GOOGLE_CLOUD_PROJECT = os.environ.get('GOOGLE_CLOUD_PROJECT')
GOOGLE_CLOUD_LOCATION = os.environ.get('GOOGLE_CLOUD_LOCATION', 'us-central1')

# Gemini model mappings (capability-based) - Vertex AI model names
#
# ⚠️ Do NOT move this branch onto a *-flash-lite model again without measuring
# extraction OUTPUT, not just latency. 2026-08-10 mapped every tier here to
# gemini-3.5-flash-lite on the strength of an A/B that showed summary/memory
# latency halving (~8s → ~4s). Latency did improve; extraction went to zero.
# The api-ws container runs LLM_PROVIDER=gemini, so at that time both
# "它记住的事实" and "你答应过的事" stopped
# producing anything for five days. Measured 2026-08-15 on the same
# transcripts and the same registry prompt:
#
#   gemini-2.5-flash        8 facts / 4 conversations
#   gemini-3.5-flash-lite   0                          ← what was shipped
#   gemini-3.7-flash        0  (spent 1341 output tokens, then returned [])
#   openrouter haiku-4.5    6
#
# The failure mode is silent and looks nothing like a bug: a well-formed
# `{"facts": []}` with finish_reason=STOP, no safety block, no exception, so
# not a single error line anywhere. And the latency that was bought is
# unobservable — memory extraction runs on a background thread and summaries
# are triggered by the silence timer, so neither is on a path a user waits on.

# Kept separate from GOOGLE_CLOUD_LOCATION so that changing where chat models are
# served never silently moves the embeddings call (utils/llm/embeddings.py) onto an
# endpoint it was never validated on. Introduced because gemini-3.5-flash-lite is
# served *only* on `global` (404s on regional endpoints); that model is gone now,
# and the replacement gemini-3.8-flash is also verified on `global`. Keep the
# embeddings endpoint independent when migrating the chat/vision model.
GEMINI_LLM_LOCATION = 'global'


class ConfiguredChatGoogleGenerativeAI(ChatGoogleGenerativeAI):
    """Remove SDK-injected legacy fields for models that no longer accept them.

    langchain-google-genai 4.2.0 supplies temperature and candidate_count even
    when the caller omits them. Sanitize the final request so sync, async,
    streaming and tool calls all use the same compatible payload.
    """

    def _prepare_request(self, *args, **kwargs):
        request = super()._prepare_request(*args, **kwargs)
        if not _model_accepts_temperature(self.model):
            request['config'] = request['config'].model_copy(update={
                'temperature': None, 'top_p': None, 'top_k': None, 'candidate_count': None,
            })
        return request


class ConfiguredChatBedrockConverse(ChatBedrockConverse):
    """Preserve the agent's cache breakpoints at the Converse boundary.

    The pinned SDK drops cache_control from typed text blocks. Anthropic
    Converse accepts a separate cachePoint after the block instead. OpenAI
    models use implicit caching and must not receive these checkpoints.
    """

    def _cache_messages(self, messages):
        copied = [message.model_copy(deep=True) for message in messages]
        if self.provider != 'anthropic':
            return copied
        for message in copied:
            if not isinstance(message.content, list):
                continue
            content = []
            for block in message.content:
                if (isinstance(block, dict) and block.get('type') == 'text'
                        and block.get('cache_control', {}).get('type') == 'ephemeral'):
                    block.pop('cache_control')
                    content.extend([block, {'cachePoint': {'type': 'default'}}])
                else:
                    content.append(block)
            message.content = content
        return copied

    def _generate(self, messages, *args, **kwargs):
        return super()._generate(self._cache_messages(messages), *args, **kwargs)

    def _stream(self, messages, *args, **kwargs):
        yield from super()._stream(self._cache_messages(messages), *args, **kwargs)


def create_openrouter_llm(model_id: str, **options):
    """Build both tier defaults and registry overrides through the same config."""
    model = resolve_model_id(model_id)
    kwargs = model_parameters(model, **options)
    kwargs.update({
        'model': model,
        'api_key': OPENROUTER_API_KEY,
        'base_url': OPENROUTER_BASE_URL,
        'default_headers': OPENROUTER_HEADERS,
        'metadata': {'model_config_version': MODEL_CONFIG_VERSION},
    })
    return ChatOpenAI(**kwargs)


def create_bedrock_llm(model_id: str, **options):
    """Set verified capabilities explicitly instead of SDK name heuristics."""
    model = resolve_model_id(model_id)
    parts = model.split('.')
    provider = parts[1] if parts[0] in ('global', 'us', 'eu', 'apac') else parts[0]
    options.pop('streaming', None)  # Converse chooses the API at invoke/stream time.
    effort = options.pop('reasoning_effort', None)
    kwargs = model_parameters(model, **options)
    if effort is not None:
        fields = kwargs.setdefault('additional_model_request_fields', {})
        if provider == 'anthropic':
            if effort not in ('low', 'medium', 'high', 'xhigh', 'max'):
                raise ValueError(f'Unsupported Anthropic effort: {effort}')
            fields.setdefault('output_config', {})['effort'] = effort
        else:
            fields.setdefault('reasoning', {})['effort'] = effort
    if model in BEDROCK_MODELS.values():
        kwargs['disable_streaming'] = False
    return ConfiguredChatBedrockConverse(
        model=model, provider=provider, region_name=BEDROCK_REGION,
        metadata={'model_config_version': MODEL_CONFIG_VERSION}, **kwargs,
    )


def create_gemini_llm(model_id: str, **options):
    """Use the shared Google service account and Vertex global endpoint."""
    model = resolve_model_id(model_id)
    if model.startswith('google/'):
        model = model.removeprefix('google/')
    if not model.startswith('gemini-'):
        raise ValueError(f'Unsupported Vertex Gemini model: {model}')
    effort = options.pop('reasoning_effort', None)
    if effort is not None:
        # Vertex exposes three levels for the registered Gemini models. Clamp
        # legacy OpenRouter extremes to the nearest supported level.
        levels = {'none': 'low', 'minimal': 'low', 'low': 'low',
                  'medium': 'medium', 'high': 'high', 'xhigh': 'high', 'max': 'high'}
        if effort not in levels:
            raise ValueError(f'Unsupported Gemini effort: {effort}')
        options['thinking_level'] = levels[effort]
    return ConfiguredChatGoogleGenerativeAI(
        model=model,
        project=GOOGLE_CLOUD_PROJECT,
        location=GEMINI_LLM_LOCATION,
        vertexai=True,
        metadata={'model_config_version': MODEL_CONFIG_VERSION},
        **model_parameters(model, **options),
    )


def create_model_llm(model_id: str, provider: Optional[str] = None, **options):
    """Resolve prompt pins through the same registry as the default routes.

    An explicit provider keeps a deliberately pinned OpenRouter comparison.
    Otherwise migrated OpenRouter IDs follow their Bedrock or Vertex route.
    """
    model = resolve_model_id(model_id)
    if provider is None:
        model = MODEL_CONFIG.get('model_routes', {}).get(model, model)
        if model.startswith(('global.', 'us.', 'eu.', 'apac.')):
            provider = 'bedrock'
        elif model.startswith('gemini-'):
            provider = 'gemini'
        else:
            provider = 'openrouter'
    if provider == 'bedrock':
        if model in OPENROUTER_MODELS.values():
            tier = next(tier for tier, value in OPENROUTER_MODELS.items() if value == model)
            model = BEDROCK_MODELS[tier]
        return create_bedrock_llm(model, **options)
    if provider == 'openrouter':
        return create_openrouter_llm(model, **options)
    if provider == 'gemini':
        return create_gemini_llm(model, **options)
    raise ValueError(f'Unsupported pinned model provider: {provider}')


def create_llm(
    model_tier: str,
    streaming: bool = False,
    temperature: Optional[float] = None,
    provider: Optional[str] = None,
    read_timeout: Optional[float] = None,
    max_tokens: Optional[int] = None,
):
    """Resolve a tier using the versioned configuration and selected provider.

    `read_timeout` (seconds) and `max_tokens` apply to Bedrock only. Its botocore client
    otherwise waits at most 60s for the next byte, and that includes the wait for the first
    token, so streaming does not avoid it. `max_tokens` replaces the model's default cap,
    which on the Claude 5.5 models also has to hold their thinking.
    """
    provider = provider or tier_provider(LLM_PROVIDER, model_tier)
    if provider == 'bedrock':
        options = {'config': BotoConfig(read_timeout=read_timeout)} if read_timeout else {}
        if max_tokens:
            options['max_tokens'] = max_tokens
        return create_bedrock_llm(BEDROCK_MODELS[model_tier], temperature=temperature, **options)
    elif provider == 'gemini':
        options = {'streaming': True} if streaming else {}
        return create_gemini_llm(GEMINI_MODELS[model_tier], temperature=temperature, **options)
    elif provider == 'openrouter':
        return create_openrouter_llm(
            OPENROUTER_MODELS[model_tier],
            streaming=streaming,
            temperature=temperature,
        )
    raise ValueError(f'Unsupported LLM provider: {provider}')


# =============================================================================
# LLM Client Instances
# =============================================================================

# Mini models - for lightweight tasks
llm_mini = create_llm('mini')
llm_mini_stream = create_llm('mini', streaming=True)

# Medium models - for standard tasks
llm_medium = create_llm('medium')
llm_medium_stream = create_llm('medium', streaming=True)
llm_medium_experiment = create_llm('medium_experiment')

# Large models - for complex reasoning
llm_large = create_llm('large')
llm_large_stream = create_llm('large', streaming=True, temperature=1)

# High models - for advanced tasks
llm_high = create_llm('high')
llm_high_stream = create_llm('high', streaming=True, temperature=1)

# Persona models - for persona chat
llm_persona_mini_stream = create_llm('persona_mini', streaming=True, temperature=0.8)
llm_persona_medium_stream = create_llm('persona_medium', streaming=True, temperature=0.8)

# Daily journal - drafting, detail review and the fact-check each carry the whole day.
# On Bedrock the first token alone took 30-140s at 60-80k characters (2026-10-27), past
# botocore's default 60s read timeout: from #123 on, most long days failed with
# "Read timed out" and no entry, while short ones still worked.
JOURNAL_READ_TIMEOUT_SECONDS = 300
# That wait is thinking, and thinking counts against max_tokens. One long day's fact-check
# used 15,159 output tokens to return a 3,204-character entry (2026-10-28). The tier default
# of 16,384 left the longest days failing with "hit output token limit".
JOURNAL_MAX_TOKENS = 32000
llm_medium_journal = create_llm('medium', read_timeout=JOURNAL_READ_TIMEOUT_SECONDS, max_tokens=JOURNAL_MAX_TOKENS)
llm_large_journal = create_llm('large', read_timeout=JOURNAL_READ_TIMEOUT_SECONDS, max_tokens=JOURNAL_MAX_TOKENS)

# Insight engine - the nominator reads the user's last 60 days in one call, and the call is not
# streamed: the read timeout has to cover the whole answer. Its length is set by the output, not
# the prompt: measured on Bedrock (2026-10-28), 12,966 output tokens took 127s and 5,896 took 62s,
# about 100 tokens/s either way. With the 60s default every nomination failed from the move to
# Bedrock (2026-10-20) on, after botocore's five tries each; the cards released since came from
# the backlog nominated before. 600s fits an answer that uses all of INSIGHT_MAX_TOKENS at ~55/s.
INSIGHT_READ_TIMEOUT_SECONDS = 600
INSIGHT_MAX_TOKENS = 32000
llm_medium_insight = create_llm('medium', read_timeout=INSIGHT_READ_TIMEOUT_SECONDS, max_tokens=INSIGHT_MAX_TOKENS)

parser = MarkdownCleaningParser(pydantic_object=Structured)

encoding = tiktoken.encoding_for_model('gpt-4')


def num_tokens_from_string(string: str) -> int:
    """Returns the number of tokens in a text string."""
    num_tokens = len(encoding.encode(string))
    return num_tokens


# Embeddings moved to utils/llm/embeddings.py — they run on Vertex AI now, and
# the write and read paths need different task types, so a single
# `generate_embedding` is no longer the right shape. Import
# `generate_embedding_document` / `generate_embedding_query` from there.
