"""Chat-agent tracing: real OTel spans, exported as one JSON line per span to stdout.

The research is in `evaluation/TRACING.md`. **This module deviates from that
document's export path on purpose** — read §"Why not the X-Ray OTLP endpoint"
below before changing it.

## What gets recorded

Three span kinds, all under one trace per chat turn:

    chat.turn                     one per /v2/messages (or per eval question)
      ├── llm.<model>             one per LLM call the agent makes
      ├── tool.memory_search      one per tool call
      └── llm.<model>             the answer turn

## Metadata only, and enforced by construction

Production traces record the tool name, the **keys** of its arguments, durations,
token counts and hit counts. **Never the user's question, never memory content,
never a tool's return value.** That is the standing decision in `TRACING.md` §0.

"Enforced by construction" is the point of `_tool_attributes`: it is handed the
kwargs dict and only ever reads `.keys()` off it, so there is no code path that
can write an argument *value* into a span. A denylist would have to be kept
correct forever; this cannot go wrong by omission. `tests/test_tracing_metadata_only.py`
holds it in place by feeding it marker strings and asserting none survive.

⚠️ `enduser.id` (the uid) *is* recorded. A uid is an identifier, not content —
it is already in every access log line, and without it "why did this user's turn
not call memory_search" is unanswerable, which is the whole reason this exists.

## Why not the X-Ray OTLP endpoint (the path TRACING.md §2 describes)

Two blockers, one hard:

1. **`opentelemetry-proto >= 1.28` requires `protobuf >= 5.0`, and
   `google-cloud-firestore==2.17.0` requires `protobuf < 5.0.0dev`.** Production
   pins `protobuf==4.25.4`. So the OTLP protobuf exporter cannot be installed
   without upgrading Firestore (2.28 now wants `protobuf >= 6.33.5`) — i.e. a
   version cascade through the entire data layer, to add tracing. Staying on
   `opentelemetry-proto < 1.28` would in turn contradict `TRACING.md` §6, which
   sets a `>= 1.41.0` floor because older HTTP exporters log export failures in a
   shape nothing in that section's diagnosis table matches.
2. The X-Ray OTLP endpoint needs **account-level** Transaction Search switched on
   (§2.3: creates log groups, a service-linked role, a resource policy, a
   CloudTrail channel) plus an IAM change on the task role via a manual
   `terraform apply`.

`opentelemetry-sdk` itself pulls in only `opentelemetry-api`,
`opentelemetry-semantic-conventions` and `typing-extensions` — **no protobuf** —
so spans, parent/child context and durations all come from the real SDK, and only
the exporter is ours. The spans land in the existing `/ecs/memorion-api-rest` log
group, queryable by `trace_id` in Logs Insights, with no account-level change:

    fields @timestamp, span, dur_ms, attrs.gen_ai.tool.name
    | filter otel_span = 1 and trace_id = "…"
    | sort @timestamp asc

What this gives up: the X-Ray service map, the Transaction Search UI, and the
waterfall view. What it keeps is everything the offline-iteration use case needs.
To switch to OTLP later, replace `_JsonLineSpanExporter` and nothing else —
`init_tracing` is the only place that names it.

⚠️ Do not "simplify" this into plain log lines without the SDK. The SDK is what
supplies trace/span ids, parenting and timing; hand-rolling those is exactly what
`TRACING.md` §2 warns against, and it is also what makes the offline and online
traces the same shape.

## Failure policy

Tracing must never break a chat turn. Every boundary here swallows exceptions and
logs at most once per process. The one thing that fails loudly is
`instrument_tools` not finding `.func` on a tool: a silently unwrapped tool table
looks identical to "the model called no tools", which is a conclusion people draw
from these traces (`golden_run.py:132` learned this the hard way).
"""

import json
import logging
import os
from contextlib import contextmanager

logger = logging.getLogger(__name__)

# Spans go out on their own logger so the JSON line is never mixed into a
# multi-line message. main.py's formatter is '%(asctime)s - %(message)s', so the
# emitted record must be a single self-contained JSON object.
_span_logger = logging.getLogger("memorion.spans")

# `1` / `true` / `yes` turns it on. Off means every hook here is a no-op with no
# import of the SDK at all, so a broken OTel install cannot take down chat.
_ENV_FLAG = "AGENT_TRACING"

_state = {"ready": False, "attempted": False, "tracer": None, "provider": None}

# Argument keys are recorded, values never are. A key is part of the tool schema
# (public, in the prompt); a value is user content.
_MAX_ARG_KEYS = 12


def enabled() -> bool:
    return str(os.getenv(_ENV_FLAG, "")).strip().lower() in ("1", "true", "yes", "on")


def init_tracing() -> bool:
    """Set up the tracer provider once. Returns whether tracing is live.

    Safe to call from anywhere, any number of times. Called from `main.py` at
    startup so the provider exists before the first request.

    The eval harness calls it too (`golden_run.py --trace`), which is the point of
    putting the seam in `graph.py`: one span definition serves production and
    offline. The harness keeps its own ToolTap alongside — that is what records
    full argument and result *content*, which spans deliberately never carry.
    """
    if _state["attempted"]:
        return _state["ready"]
    _state["attempted"] = True
    if not enabled():
        return False
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        service = os.getenv("OTEL_SERVICE_NAME") or "memorion-api"
        provider = TracerProvider(resource=Resource.create({"service.name": service}))
        provider.add_span_processor(BatchSpanProcessor(_JsonLineSpanExporter()))
        trace.set_tracer_provider(provider)
        _state["provider"] = provider
        _state["tracer"] = trace.get_tracer("memorion.chat_agent")
        _state["ready"] = True
        logger.info("agent tracing on (json spans → stdout, service.name=%s)", service)
    except Exception:
        # Missing SDK, or a version whose API moved. Chat must still work.
        logger.warning("agent tracing requested but could not start; continuing without it",
                       exc_info=True)
    return _state["ready"]


def flush_tracing(timeout_millis: int = 30000) -> bool:
    """Drain the batch processor. Returns whether anything was flushed.

    🚨 **Short-lived processes lose spans without this.** `BatchSpanProcessor`
    holds spans until a batch fills or its timer fires (5s by default), so a
    script that exits promptly takes the tail of its trace with it. Production is
    a long-lived server and never noticed; the eval harness would have — and the
    failure looks like "tracing produced nothing", i.e. exactly like tracing being
    off, which is the hardest form to diagnose.

    Safe to call when tracing was never started; then it is a no-op returning False.
    """
    provider = _state.get("provider")
    if provider is None:
        return False
    try:
        provider.force_flush(timeout_millis)
        return True
    except Exception:
        logger.warning("span flush failed; the tail of this run's trace is lost",
                       exc_info=True)
        return False


def _tracer():
    if not _state["attempted"]:
        init_tracing()
    return _state["tracer"]


class _JsonLineSpanExporter:
    """One JSON line per finished span, on stdout, for CloudWatch Logs to pick up.

    Implemented duck-typed rather than subclassing `SpanExporter` so this module
    imports with no OTel installed (the class body must not reference the SDK).
    `BatchSpanProcessor` only calls `export` / `shutdown` / `force_flush`.
    """

    def export(self, spans):
        for span in spans:
            try:
                _span_logger.info(json.dumps(_span_to_dict(span), ensure_ascii=False,
                                             separators=(",", ":")))
            except Exception:
                logger.debug("failed to serialize span", exc_info=True)
        # SpanExportResult.SUCCESS is an IntEnum member equal to 0; the processor
        # only compares it, so returning the enum requires importing the SDK here.
        try:
            from opentelemetry.sdk.trace.export import SpanExportResult
            return SpanExportResult.SUCCESS
        except Exception:
            return 0

    def shutdown(self):
        return None

    def force_flush(self, timeout_millis: int = 30000):
        return True


def _undouble(value: str) -> str:
    """`"tool_callstool_calls"` → `"tool_calls"`。

    🚨 流式响应下 `finish_reason` 是被**字符串拼接**出来的，不是覆盖。langchain 聚合
    streamed chunk 时用 `merge_dicts`，同名键遇到 str 就相加——所以两个 chunk 各带一份
    `finish_reason` 就变成 `"stopstop"`。2026-08-12 在生产 span 里实测到的原样值就是
    `"tool_callstool_calls"` 和 `"stopstop"`。

    ⚠️ **这不是显示问题。** span 属性存在的意义就是拿来分组/过滤（「多少轮以 tool_calls
    收尾」），而一个会随 chunk 数变形的值让这一列彻底不可聚合，且**看起来是有值的**。

    只还原「整串恰好是某个更短单元的整数次重复」这一种形态。finish_reason 的取值域是个
    小枚举（stop / length / tool_calls / content_filter / function_call），没有一个本身
    是重复串，所以不会误伤。
    """
    n = len(value)
    for size in range(1, n // 2 + 1):
        if n % size == 0 and value[:size] * (n // size) == value:
            return value[:size]
    return value


def _span_to_dict(span) -> dict:
    ctx = span.get_span_context()
    parent = getattr(span, "parent", None)
    started, ended = span.start_time, span.end_time
    out = {
        # A fixed marker so Logs Insights can select spans out of ordinary logs
        # without pattern-matching the message.
        "otel_span": 1,
        "span": span.name,
        "trace_id": f"{ctx.trace_id:032x}",
        "span_id": f"{ctx.span_id:016x}",
        "parent_id": f"{parent.span_id:016x}" if parent else None,
        "dur_ms": round((ended - started) / 1e6, 2) if (started and ended) else None,
        "status": getattr(getattr(span, "status", None), "status_code", None)
        and span.status.status_code.name,
        "attrs": dict(span.attributes or {}),
    }
    return out


# 🚨 Every `start_as_current_span` here must pass these.
#
# The SDK's defaults are `record_exception=True, set_status_on_exception=True`, and
# `record_exception` attaches an **event** carrying `exception.message` and
# `exception.stacktrace`. An exception message routinely quotes the argument that
# caused it — measured, not hypothesized: a tool raising
# `ValueError(f"invalid query: {query}")` produced an event holding the verbatim
# user question. `_span_to_dict` does not serialize events, so it does not reach
# CloudWatch today; that is a property of the *exporter*, and this module tells the
# next reader they can swap the exporter and change nothing else. With OTLP, events
# ship. So the suppression belongs on the span, not on the exporter.
#
# Status is set explicitly instead (see `_mark_error`) — losing the ERROR status
# would be a real cost, and it carries no content.
_NO_EXC_CAPTURE = {"record_exception": False, "set_status_on_exception": False}


def _mark_error(span):
    """Status=ERROR with no description. The description field would be the message."""
    try:
        from opentelemetry.trace import Status, StatusCode

        span.set_status(Status(StatusCode.ERROR))
    except Exception:
        logger.debug("failed to set error status", exc_info=True)


@contextmanager
def turn_span(name: str, **attributes):
    """A span around one chat turn (or any parent unit). No-op when tracing is off."""
    tracer = _tracer()
    if tracer is None:
        yield _NullSpan()
        return
    with tracer.start_as_current_span(name, **_NO_EXC_CAPTURE) as span:
        for key, value in attributes.items():
            if value is not None:
                span.set_attribute(key, value)
        try:
            yield span
        except Exception as exc:
            try:
                span.set_attribute("exception.type", type(exc).__name__)
            except Exception:
                pass
            _mark_error(span)
            raise


class _NullSpan:
    """Stand-in so callers can `span.set_attribute(...)` unconditionally."""

    def set_attribute(self, *_a, **_kw):
        return None

    def record_exception(self, *_a, **_kw):
        return None

    def is_recording(self):
        return False


def _tool_attributes(name: str, kwargs: dict, positional: int) -> dict:
    """Span attributes for one tool call. **Reads only the keys of `kwargs`.**

    This function is the metadata-only guarantee. It never indexes into `kwargs`,
    so no argument value can reach a span, and adding a new tool with a new
    parameter cannot leak content by default. Keep it that way: if you ever need a
    value here, add an explicit allowlist of (tool, param) pairs whose values are
    known to be enums or ints — do not reach for `str(v)[:N]`, which is how the
    eval harness's own `args` field ends up holding user text (that file is
    gitignored precisely because of it).
    """
    keys = sorted(str(k) for k in (kwargs or {}).keys())[:_MAX_ARG_KEYS]
    attrs = {
        "gen_ai.tool.name": name,
        # Comma-joined rather than a list: CloudWatch Logs Insights cannot group
        # by an array field, and "which parameters did the model actually set"
        # is the question this answers.
        "memorion.tool.arg_keys": ",".join(keys),
        "memorion.tool.arg_count": len(keys) + (1 if positional else 0),
    }
    return attrs


def _result_shape(result) -> dict:
    """Size/shape of a tool result. Sizes are metadata; the payload is not.

    `hit_count` is the one number worth having: "the search ran and returned
    nothing" and "the search never ran" are the two readings people confuse when
    a turn answers from thin air, and only this tells them apart.
    """
    shape = {}
    try:
        if isinstance(result, (list, tuple)):
            shape["memorion.tool.hit_count"] = len(result)
        elif isinstance(result, dict):
            for key in ("results", "memories", "items", "events", "todos", "people"):
                value = result.get(key)
                if isinstance(value, (list, tuple)):
                    shape["memorion.tool.hit_count"] = len(value)
                    break
            if "ok" in result:
                # NOT the same field as `memorion.tool.ok`, which only says the
                # call did not raise. A tool can return {"ok": False} perfectly
                # normally (a lookup that found nobody), so conflating the two
                # turns "no match" into "tool error" in any query that filters on
                # one and reads the other.
                shape["memorion.tool.result_ok"] = bool(result.get("ok"))
        elif isinstance(result, str):
            shape["memorion.tool.result_chars"] = len(result)
    except Exception:
        logger.debug("failed to measure tool result shape", exc_info=True)
    return shape


def instrument_tools(tools):
    """Wrap each tool's `.func` in a span. Returns `tools` untouched if tracing is off.

    Wrapping the objects returned by `make_agent_tools` — rather than patching the
    module — is deliberate: `graph.py` does `from ... import make_agent_tools` and
    holds its own binding, so module-level patching misses the real call site
    (`lme_run.py:191` and `golden_run.py:99` both document that trap). Here we are
    already holding the built list, so the problem does not arise.
    """
    if _tracer() is None:
        return tools
    for tool in tools:
        name = getattr(tool, "name", "?")
        func = getattr(tool, "func", None)
        if func is None:
            # Loud on purpose: an unwrapped tool table produces traces where no
            # tool was ever called, which reads as a finding about the model.
            raise RuntimeError(
                f"tool {name!r} has no .func to wrap — langchain's tool object shape "
                f"changed; fix instrument_tools rather than shipping blind traces")
        tool.func = _wrap_tool(name, func)
    return tools


def _wrap_tool(name, func):
    def wrapped(*args, **kwargs):
        tracer = _tracer()
        if tracer is None:
            return func(*args, **kwargs)
        with tracer.start_as_current_span(f"tool.{name}", **_NO_EXC_CAPTURE) as span:
            try:
                for key, value in _tool_attributes(name, kwargs, len(args)).items():
                    span.set_attribute(key, value)
            except Exception:
                logger.debug("failed to set tool span attributes", exc_info=True)
            try:
                result = func(*args, **kwargs)
            except Exception as exc:
                try:
                    span.set_attribute("memorion.tool.ok", False)
                    # Type only. An exception message can quote the argument that
                    # caused it, and that argument is user content. The SDK would
                    # have recorded the message for us — see _NO_EXC_CAPTURE.
                    span.set_attribute("exception.type", type(exc).__name__)
                except Exception:
                    pass
                _mark_error(span)
                raise
            try:
                span.set_attribute("memorion.tool.ok", True)
                for key, value in _result_shape(result).items():
                    span.set_attribute(key, value)
            except Exception:
                logger.debug("failed to set tool result attributes", exc_info=True)
            return result

    # Keep the docstring: langchain already read it when it built the tool, but
    # anything that re-reads `.func.__doc__` (the eval harness patches docstrings)
    # must still see the real one.
    wrapped.__name__ = getattr(func, "__name__", name)
    wrapped.__doc__ = getattr(func, "__doc__", None)
    return wrapped


def llm_callbacks():
    """LangChain callbacks to hand to `agent.invoke` / `agent.astream`.

    Empty list when tracing is off, so callers can splat it unconditionally.

    Written by hand instead of installing `openinference-instrumentation-langchain`
    or `opentelemetry-instrumentation-langchain`: both capture prompt and
    completion text by default and rely on env vars to turn that off, which makes
    the metadata-only rule one typo or one dependency bump away from breaking
    (`TRACING.md` §4.2). ⚠️ Also do not reach for the already-installed
    `langsmith` — it ships the data to a third party.
    """
    if _tracer() is None:
        return []
    return [_LlmSpanCallback()]


try:
    from langchain_core.callbacks import BaseCallbackHandler as _Base
except Exception:  # pragma: no cover - langchain is a hard dep of the chat path
    _Base = object


class _LlmSpanCallback(_Base):
    """One span per LLM call: model, token counts, finish reason. No text.

    Token counts are the payoff beyond tool routing. `graph._to_lc_messages` places
    two prompt-cache breakpoints and there is currently no measurement of whether
    they hit — `gen_ai.usage.cache_read_input_tokens` is that measurement.
    """

    # `on_llm_start` receives `prompts`; `on_chat_model_start` receives `messages`.
    # Neither is touched. Both are accepted because langchain routes chat models
    # through the latter and a plain LLM through the former.
    def on_llm_start(self, serialized, prompts, **kwargs):
        self._start(serialized, kwargs)

    def on_chat_model_start(self, serialized, messages, **kwargs):
        self._start(serialized, kwargs)

    def _start(self, serialized, kwargs):
        tracer = _tracer()
        if tracer is None:
            return
        try:
            model = self._model_name(serialized, kwargs)
            span = tracer.start_span(f"llm.{model or 'unknown'}")
            span.set_attribute("gen_ai.operation.name", "chat")
            if model:
                span.set_attribute("gen_ai.request.model", model)
            # Provider, not vendor guesswork: the single switch is LLM_PROVIDER.
            span.set_attribute("gen_ai.system", os.getenv("LLM_PROVIDER", "openrouter"))
            run_id = kwargs.get("run_id")
            self._spans()[run_id] = span
        except Exception:
            logger.debug("failed to start llm span", exc_info=True)

    def on_llm_end(self, response, **kwargs):
        span = self._spans().pop(kwargs.get("run_id"), None)
        if span is None:
            return
        try:
            for key, value in self._usage(response).items():
                span.set_attribute(key, value)
        except Exception:
            logger.debug("failed to record llm usage", exc_info=True)
        finally:
            try:
                span.end()
            except Exception:
                pass

    def on_llm_error(self, error, **kwargs):
        span = self._spans().pop(kwargs.get("run_id"), None)
        if span is None:
            return
        try:
            span.set_attribute("exception.type", type(error).__name__)
        except Exception:
            pass
        finally:
            try:
                span.end()
            except Exception:
                pass

    # --- helpers -------------------------------------------------------------

    def _spans(self):
        if not hasattr(self, "_by_run"):
            self._by_run = {}
        return self._by_run

    @staticmethod
    def _model_name(serialized, kwargs):
        params = (kwargs or {}).get("invocation_params") or {}
        for key in ("model", "model_name", "model_id"):
            value = params.get(key)
            if isinstance(value, str) and value:
                return value
        for key in ("model", "model_name"):
            value = ((serialized or {}).get("kwargs") or {}).get(key)
            if isinstance(value, str) and value:
                return value
        return None

    @staticmethod
    def _usage(response) -> dict:
        """Token counts, from whichever of the two places the provider filled in.

        ⚠️ Both are needed. `llm_output['token_usage']` is the OpenAI-shaped path
        (OpenRouter goes through langchain_openai); `usage_metadata` on the message
        is the LangChain-normalized one and is the only place the cache counters
        show up. Reading just one silently records zeros for the other provider.
        """
        attrs = {}
        usage = ((getattr(response, "llm_output", None) or {}).get("token_usage")) or {}
        mapping = {
            "prompt_tokens": "gen_ai.usage.input_tokens",
            "completion_tokens": "gen_ai.usage.output_tokens",
            "total_tokens": "gen_ai.usage.total_tokens",
        }
        for src, dst in mapping.items():
            value = usage.get(src)
            if isinstance(value, int):
                attrs[dst] = value

        generations = getattr(response, "generations", None) or []
        message = None
        finish = None
        for batch in generations:
            for gen in batch or []:
                message = getattr(gen, "message", None) or message
                info = getattr(gen, "generation_info", None) or {}
                finish = info.get("finish_reason") or finish
        if finish:
            attrs["gen_ai.response.finish_reasons"] = _undouble(str(finish))
        meta = getattr(message, "usage_metadata", None) or {}
        if isinstance(meta, dict):
            if isinstance(meta.get("input_tokens"), int):
                attrs.setdefault("gen_ai.usage.input_tokens", meta["input_tokens"])
            if isinstance(meta.get("output_tokens"), int):
                attrs.setdefault("gen_ai.usage.output_tokens", meta["output_tokens"])
            details = meta.get("input_token_details") or {}
            if isinstance(details.get("cache_read"), int):
                attrs["gen_ai.usage.cache_read_input_tokens"] = details["cache_read"]
            if isinstance(details.get("cache_creation"), int):
                attrs["gen_ai.usage.cache_creation_input_tokens"] = details["cache_creation"]
        return attrs
