import json
import logging
from types import SimpleNamespace

from langchain_core.messages import AIMessage
from langchain_core.outputs import ChatGeneration, LLMResult
from utils.timeline.inference_usage import InferenceUsage


def event(caplog):
    return json.loads(caplog.records[-1].getMessage().split('] ', 1)[1])


def test_openrouter_reports_actual_cost_and_caching_without_content(caplog):
    caplog.set_level(logging.INFO)
    usage = {'prompt_tokens': 1044, 'completion_tokens': 197, 'cost': 0.0045785,
             'prompt_tokens_details': {'cached_tokens': 128, 'cache_write_tokens': 1041},
             'completion_tokens_details': {'reasoning_tokens': 4}, 'unexpected': 'PRIVATE_USAGE_VALUE'}
    response = LLMResult(generations=[[ChatGeneration(message=AIMessage(content='PRIVATE_COMPLETION'))]],
                         llm_output={'token_usage': usage, 'unrelated': 'PRIVATE_METADATA'})
    callback = InferenceUsage('grounded', SimpleNamespace(model_name='openai/gpt-6.1-sol'))
    callback.on_llm_end(response)
    logged = event(caplog)
    assert logged['reported_cost_usd'] == usage['cost']
    assert logged['input_tokens'] == 1044 and logged['output_tokens'] == 197
    assert logged['cache_read_tokens'] == 128 and logged['cache_write_tokens'] == 1041
    assert logged['reasoning_tokens'] == 4
    assert 'PRIVATE' not in caplog.text


def test_normalized_provider_usage_and_unknown_cost(caplog):
    caplog.set_level(logging.INFO)
    message = AIMessage(content='PRIVATE', usage_metadata={
        'input_tokens': 10, 'output_tokens': 5, 'total_tokens': 15,
        'input_token_details': {'cache_read': 4, 'cache_creation': 3},
        'output_token_details': {'reasoning': 2}})
    InferenceUsage('draft', SimpleNamespace(model_id='bedrock-model')).on_llm_end(
        LLMResult(generations=[[ChatGeneration(message=message)]]))
    logged = event(caplog)
    assert logged['input_tokens'] == 10 and logged['reasoning_tokens'] == 2
    assert logged['cache_read_tokens'] == 4 and logged['cache_write_tokens'] == 3
    assert 'reported_cost_usd' not in logged
    assert 'PRIVATE' not in caplog.text


def test_malformed_or_missing_usage_does_not_fabricate_zero_cost(caplog):
    caplog.set_level(logging.INFO)
    callback = InferenceUsage('draft', SimpleNamespace(model_name='model'))
    callback.on_llm_end(LLMResult(generations=[], llm_output={'token_usage': {
        'cost': float('nan'), 'completion_tokens': True, 'prompt_tokens': 'PRIVATE'}}))
    assert not any(key.endswith('tokens') or key.endswith('usd') for key in event(caplog))
    assert 'PRIVATE' not in caplog.text
    callback.on_llm_end(LLMResult(generations=[]))
    assert 'reported_cost_usd' not in event(caplog)


def test_failure_does_not_log_exception_body(caplog):
    caplog.set_level(logging.INFO)
    InferenceUsage('grounded', SimpleNamespace(model_name='model')).on_llm_error(RuntimeError('PRIVATE_PROMPT'))
    assert event(caplog)['error_type'] == 'RuntimeError'
    assert 'PRIVATE' not in caplog.text


def test_real_langchain_structured_and_text_clients_emit_usage_only_on_cache_miss(caplog):
    import httpx
    import fakeredis
    from langchain_openai import ChatOpenAI
    from utils.llm.prompt_registry import ResolvedPrompt
    from utils.timeline import rollup
    from utils.timeline.batch_cache import BatchCache
    caplog.set_level(logging.INFO, logger='utils.timeline.inference_usage')
    calls = []
    answer = rollup.ChapterRollup(title='Fact', overview='Budget 37. Approval unknown.')
    def completion(request):
        payload = json.loads(request.content)
        calls.append(payload['model'])
        return httpx.Response(200, json={
            'id': 'synthetic', 'object': 'chat.completion', 'created': 0, 'model': payload['model'],
            'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': answer.model_dump_json()},
                         'finish_reason': 'stop'}],
            'usage': {'prompt_tokens': 100, 'completion_tokens': 30, 'total_tokens': 130, 'cost': 0.001}})
    with httpx.Client(transport=httpx.MockTransport(completion)) as transport, fakeredis.FakeRedis() as redis:
        draft = ChatOpenAI(model='openai/gpt-6-luna', api_key='synthetic', http_client=transport)
        grounded = ChatOpenAI(model='openai/gpt-6.1-sol', api_key='synthetic', http_client=transport)
        deps = rollup.SummaryDependencies(
            ResolvedPrompt('timeline.chapter_rollup', rollup._ROLLUP_TEMPLATE.content, {}),
            ResolvedPrompt('timeline.chapter_grounding', rollup._GROUNDING_TEMPLATE.content, {}), draft, grounded)
        req = rollup.prepare_rollup([{'source_text': 'Budget 37. Approval unknown.', 'requires_rollup': True}], dependencies=deps)
        cache = BatchCache(redis, 'dev', 'user', '2026-10-14')
        assert rollup.run_rollup(req, cache)['rollup'] is True
        assert rollup.run_rollup(req, cache)['rollup'] is True
    assert calls == ['openai/gpt-6-luna', 'openai/gpt-6.1-sol']
    events = [json.loads(r.getMessage().split('] ', 1)[1]) for r in caplog.records
              if r.name == 'utils.timeline.inference_usage']
    assert [entry['stage'] for entry in events] == ['draft', 'grounded']
    assert sum(entry['reported_cost_usd'] for entry in events) == 0.002  # Synthetic HTTP fixture.
    assert all('Budget' not in json.dumps(entry) for entry in events)
