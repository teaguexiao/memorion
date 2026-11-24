"""Exercise the SDK request and response boundary used in production."""
import copy
from unittest import mock

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from pydantic import BaseModel

from utils.llm import clients, model_config, prompt_registry


class Answer(BaseModel):
    answer: str


def test_sol_provider_and_reasoning_reach_converse_without_sampling():
    client = clients.create_llm('medium_experiment', provider='bedrock', temperature=0.3)
    response = {'output': {'message': {'role': 'assistant', 'content': [{'text': 'OK'}]}},
                'stopReason': 'end_turn', 'usage': {'inputTokens': 2, 'outputTokens': 1},
                'metrics': {'latencyMs': 1}}
    with mock.patch.object(client.client, 'converse', return_value=response) as converse:
        assert clients.coerce_llm_text_content(client.invoke('Reply OK')) == 'OK'
    payload = converse.call_args.kwargs
    assert client.provider == 'openai'
    assert payload['additionalModelRequestFields']['reasoning']['effort'] == 'low'
    assert 'temperature' not in payload['inferenceConfig']
    assert payload['inferenceConfig']['maxTokens'] == 16384


def test_new_models_use_real_converse_stream_including_tool_deltas():
    for tier in ('mini', 'medium_experiment', 'medium', 'large'):
        client = clients.create_llm(tier, provider='bedrock', streaming=True)
        events = [{'messageStart': {'role': 'assistant'}},
                  {'contentBlockStart': {'start': {'toolUse': {'toolUseId': 'call-1', 'name': 'Answer'}}, 'contentBlockIndex': 0}},
                  {'contentBlockDelta': {'delta': {'toolUse': {'input': '{"answer":"yes"}'}}, 'contentBlockIndex': 0}},
                  {'contentBlockStop': {'contentBlockIndex': 0}},
                  {'messageStop': {'stopReason': 'tool_use'}},
                  {'metadata': {'usage': {'inputTokens': 1, 'outputTokens': 1}, 'metrics': {'latencyMs': 1}}}]
        with mock.patch.object(client.client, 'converse_stream', return_value={'stream': events}) as stream, \
                mock.patch.object(client.client, 'converse', side_effect=AssertionError('stream fell back to invoke')):
            chunks = list(client.bind_tools([Answer]).stream('Use Answer'))
        combined = chunks[0]
        for chunk in chunks[1:]:
            combined += chunk
        assert combined.tool_calls[0]['args'] == {'answer': 'yes'}
        assert stream.call_args.kwargs['toolConfig']['tools'][0]['toolSpec']['name'] == 'Answer'


def test_opus_pin_upgrades_and_explicit_provider_can_keep_comparison():
    assert clients.create_model_llm('global.anthropic.claude-opus-5').model_id == 'global.anthropic.claude-opus-5-5'
    assert clients.create_model_llm('anthropic/claude-opus-5', provider='openrouter').model_name == 'anthropic/claude-opus-5.5'


def test_luna_extraction_uses_native_tool_schema_and_parses_result():
    with mock.patch.object(clients, 'LLM_PROVIDER', 'openrouter'):
        client = clients.create_llm('mini')
    response = {'output': {'message': {'role': 'assistant', 'content': [
        {'toolUse': {'toolUseId': 'call-1', 'name': 'Answer', 'input': {'answer': 'yes'}}}]}},
        'stopReason': 'tool_use', 'usage': {'inputTokens': 2, 'outputTokens': 1},
        'metrics': {'latencyMs': 1}}
    with mock.patch.object(client.client, 'converse', return_value=response) as converse:
        assert client.with_structured_output(Answer).invoke('Answer yes').answer == 'yes'
    payload = converse.call_args.kwargs
    assert payload['modelId'] == 'global.openai.gpt-6-luna'
    assert payload['toolConfig']['toolChoice'] == {'tool': {'name': 'Answer'}}
    assert payload['additionalModelRequestFields']['reasoning']['effort'] == 'none'
    assert 'temperature' not in payload['inferenceConfig']


def test_staged_routes_preserve_vertex_and_explicit_provider_selection():
    with mock.patch.object(clients, 'LLM_PROVIDER', 'gemini'):
        assert clients.create_llm('mini').model == 'gemini-3.8-flash'
    assert clients.create_llm('mini', provider='openrouter').model_name == 'openai/gpt-6-luna'
    assert clients.create_model_llm('anthropic/claude-haiku-4.5').model_id == 'global.openai.gpt-6-luna'


def test_invalid_migration_routes_fail_before_runtime(tmp_path):
    import copy
    import json
    config = copy.deepcopy(model_config.MODEL_CONFIG)
    config['model_routes']['openai/gpt-6.1-sol'] = 'unknown'
    path = tmp_path / 'config.json'
    path.write_text(json.dumps(config))
    import pytest
    with pytest.raises(ValueError, match='model_routes'):
        model_config.load_model_config(path)


def test_anthropic_cache_points_reach_sync_and_async_sdk_calls_without_mutation():
    import asyncio
    import copy

    messages = [SystemMessage(content=[{'type': 'text', 'text': 'Stable system',
                                       'cache_control': {'type': 'ephemeral'}}]),
                HumanMessage(content=[{'type': 'text', 'text': 'Stable history',
                                      'cache_control': {'type': 'ephemeral'}}]),
                AIMessage(content='Prior answer'), HumanMessage(content='Next question')]
    original = copy.deepcopy(messages)
    response = {'output': {'message': {'role': 'assistant', 'content': [{'text': 'OK'}]}},
                'stopReason': 'end_turn', 'usage': {'inputTokens': 2, 'outputTokens': 1},
                'metrics': {'latencyMs': 1}}
    events = [{'messageStart': {'role': 'assistant'}},
              {'contentBlockDelta': {'delta': {'text': 'OK'}, 'contentBlockIndex': 0}},
              {'contentBlockStop': {'contentBlockIndex': 0}},
              {'messageStop': {'stopReason': 'end_turn'}},
              {'metadata': {'usage': {'inputTokens': 2, 'outputTokens': 1,
                                      'cacheReadInputTokens': 10}, 'metrics': {'latencyMs': 1}}}]
    for tier in ('medium', 'large'):
        client = clients.create_llm(tier, provider='bedrock')
        with mock.patch.object(client.client, 'converse', side_effect=lambda **kwargs: copy.deepcopy(response)) as invoke, \
                mock.patch.object(client.client, 'converse_stream', side_effect=lambda **kwargs: {'stream': copy.deepcopy(events)}) as stream:
            client.invoke(messages)
            list(client.stream(messages))

            async def collect():
                return [chunk async for chunk in client.astream(messages)]

            chunks = asyncio.run(collect())
            combined = chunks[0]
            for chunk in chunks[1:]:
                combined += chunk
            assert combined.usage_metadata['input_token_details']['cache_read'] == 10
        assert stream.call_count == 2
        for call in [invoke.call_args, *stream.call_args_list]:
            payload = call.kwargs
            assert payload['system'] == [{'text': 'Stable system'}, {'cachePoint': {'type': 'default'}}]
            assert payload['messages'][0]['content'] == [
                {'text': 'Stable history'}, {'cachePoint': {'type': 'default'}}]
        assert messages == original


def test_openai_models_do_not_receive_anthropic_cache_points():
    response = {'output': {'message': {'role': 'assistant', 'content': [{'text': 'OK'}]}},
                'stopReason': 'end_turn', 'usage': {'inputTokens': 2, 'outputTokens': 1},
                'metrics': {'latencyMs': 1}}
    for tier in ('mini', 'medium_experiment'):
        client = clients.create_llm(tier, provider='bedrock')
        with mock.patch.object(client.client, 'converse', side_effect=lambda **kwargs: copy.deepcopy(response)) as invoke:
            client.invoke([SystemMessage(content=[{'type': 'text', 'text': 'Stable system',
                                                  'cache_control': {'type': 'ephemeral'}}]),
                           HumanMessage(content='Question')])
        assert invoke.call_args.kwargs['system'] == [{'text': 'Stable system'}]


def test_sonnet_prompt_pin_keeps_effort_using_anthropic_native_field():
    resolved = prompt_registry.ResolvedPrompt(
        key='test', content='test', config={'model_id': 'anthropic/claude-sonnet-5', 'reasoning_effort': 'low'})
    client = prompt_registry.resolve_llm(resolved, object())
    assert client.model_id == 'global.anthropic.claude-sonnet-5-5'
    assert client.additional_model_request_fields == {'output_config': {'effort': 'low'}}
    assert clients.create_model_llm('anthropic/claude-opus-5').model_id == 'global.anthropic.claude-opus-5-5'
    with mock.patch.object(clients, 'LLM_PROVIDER', 'openrouter'):
        assert clients.create_llm('medium').model_id == client.model_id
    assert clients.create_llm('medium', provider='openrouter').model_name == 'anthropic/claude-sonnet-5.5'


def test_journal_clients_hold_a_whole_day_of_thinking():
    # Whole-day prompts wait 30-140s for the first token (botocore defaults to 60s), and the
    # Claude 5.5 models think inside max_tokens: one fact-check used 15,159 output tokens for a
    # 3,204-character entry (2026-10-28), against a tier default of 16,384.
    import ast
    from pathlib import Path
    assert clients.JOURNAL_MAX_TOKENS >= 2 * 15159
    response = {'output': {'message': {'role': 'assistant', 'content': [{'text': 'OK'}]}},
                'stopReason': 'end_turn', 'usage': {'inputTokens': 2, 'outputTokens': 1},
                'metrics': {'latencyMs': 1}}
    for tier in ('medium', 'large'):
        client = clients.create_llm(tier, provider='bedrock', read_timeout=clients.JOURNAL_READ_TIMEOUT_SECONDS,
                                    max_tokens=clients.JOURNAL_MAX_TOKENS)
        with mock.patch.object(client.client, 'converse', side_effect=lambda **kwargs: copy.deepcopy(response)) as converse:
            client.invoke('Reply OK')
        assert converse.call_args.kwargs['inferenceConfig']['maxTokens'] == clients.JOURNAL_MAX_TOKENS
        assert client.client.meta.config.read_timeout == clients.JOURNAL_READ_TIMEOUT_SECONDS
    # Other call sites keep the tier default.
    assert clients.create_llm('medium', provider='bedrock').max_tokens == 16384
    # The module-level journal clients are built with both settings, whatever LLM_PROVIDER is here.
    tree = ast.parse(Path(clients.__file__).read_text())
    built = {node.targets[0].id: {k.arg: getattr(k.value, 'id', None) for k in node.value.keywords}
             for node in tree.body if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
             and node.targets[0].id in ('llm_medium_journal', 'llm_large_journal')}
    assert set(built) == {'llm_medium_journal', 'llm_large_journal'}
    for kwargs in built.values():
        assert kwargs == {'read_timeout': 'JOURNAL_READ_TIMEOUT_SECONDS', 'max_tokens': 'JOURNAL_MAX_TOKENS'}


def test_insight_client_holds_a_whole_nomination():
    # The nominator's call is not streamed, so the read timeout spans the whole answer, and its
    # length follows the output: 12,966 tokens took 127s and 5,896 took 62s on Bedrock (2026-10-28),
    # ~95-102 tokens/s. Every nomination had failed since the move to Bedrock on the 60s default.
    # The timeout must hold an answer that uses the whole max_tokens, with room for a slower hour.
    import ast
    from pathlib import Path
    assert clients.INSIGHT_MAX_TOKENS >= 2 * 12966
    assert clients.INSIGHT_READ_TIMEOUT_SECONDS >= 1.5 * clients.INSIGHT_MAX_TOKENS / 95
    tree = ast.parse(Path(clients.__file__).read_text())
    built = {node.targets[0].id: {k.arg: getattr(k.value, 'id', None) for k in node.value.keywords}
             for node in tree.body if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
             and node.targets[0].id == 'llm_medium_insight'}
    assert built == {'llm_medium_insight': {'read_timeout': 'INSIGHT_READ_TIMEOUT_SECONDS',
                                            'max_tokens': 'INSIGHT_MAX_TOKENS'}}
    # Both model calls of the engine default to it (a prompt pin would still override it).
    from utils.llm import insight_engine
    engine_tree = ast.parse(Path(insight_engine.__file__).read_text())
    defaults = {}
    for node in engine_tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in ('nominate', 'judge'):
            calls = [sub for sub in ast.walk(node) if isinstance(sub, ast.Call)
                     and getattr(sub.func, 'id', None) == 'resolve_llm']
            defaults[node.name] = [ast.unparse(call.args[1]) for call in calls]
    assert defaults == {'nominate': ['llm_medium_insight'], 'judge': ['llm_medium_insight']}
