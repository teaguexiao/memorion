"""Chat retrieval, driven by a tool-calling agent.

This used to be a fixed LangGraph pipeline (classify → maybe retrieve → answer)
where the graph decided, once, whether to search and with what. It is now a
`create_react_agent` loop: the model chooses when to call `memory_search` /
`memory_get` / `resolve_time_range`, can search more than once, and synthesizes
the answer itself. See the overhaul plan §7 (P1) for why.

Two things are deliberately preserved so callers do not change:

- `execute_graph_chat` / `execute_graph_chat_stream` keep their exact signatures
  and return/`callback_data` contracts (answer, ask_for_nps, memories_found).
- `memories_found` holds the full conversation dicts the answer may cite, in
  1-based citation order, so `developer_chat.process_message` maps `[index]` back
  to `memories[index-1]` unchanged. That order is maintained by the
  CitationAccumulator the tools write to (see agent_tools).
"""

import asyncio
import logging
from typing import AsyncGenerator, List, Optional, Tuple

from langchain.agents import create_agent
from langchain_core.callbacks import BaseCallbackHandler
from langchain_core.messages import AIMessage, AIMessageChunk, HumanMessage

import database.developer_data as dev_db
from models.chat import ChatSession, Message
from models.conversation import Conversation
from utils.llm.clients import create_llm
from utils.observability.tracing import instrument_tools, llm_callbacks, turn_span
from utils.other.endpoints import timeit
from utils.retrieval.agent_prompt import build_system_prompt, build_time_context
from utils.retrieval.agent_tools import CitationAccumulator, RequestContext, make_agent_tools

logger = logging.getLogger(__name__)


class AsyncStreamingCallback(BaseCallbackHandler):
    """SSE transport for the streaming path.

    In the old pipeline this was also wired in as an LLM callback, but a react
    agent makes several LLM calls per turn and `on_llm_end` firing after the first
    (tool-selection) call would close the stream before the answer arrived. It is
    now driven manually by the astream loop below — put_data for answer text,
    put_thought for tool progress, end() once when the run finishes.
    """

    def __init__(self):
        self.queue = asyncio.Queue()

    async def put_data(self, text):
        await self.queue.put(f"data: {text}")

    async def put_thought(self, text):
        await self.queue.put(f"think: {text}")

    def put_thought_nowait(self, text):
        self.queue.put_nowait(f"think: {text}")

    async def end(self):
        await self.queue.put(None)

    def put_data_nowait(self, text):
        self.queue.put_nowait(f"data: {text}")

    def end_nowait(self):
        self.queue.put_nowait(None)


def _to_lc_messages(messages: List[Message], tz: str = "UTC") -> list:
    """Chat history → LangChain messages for the agent's initial state.

    Only human/ai turns; ordering as given (callers already sort oldest-first).

    The per-turn time block (§6.2) is prepended to the *latest* human turn rather
    than added to the system prefix: it changes every request, and anything that
    varies inside the cached system prefix drives cache hits to zero (§6.1 ③).
    The render order is tools → system → messages, so the message tail is after
    the system cache breakpoint — the model still reads "now" alongside the
    question, but the cached prefix stays byte-identical across turns.
    """
    lc_messages = []
    human_idxs = []
    for message in messages:
        if not message.text:
            continue
        if message.sender == 'ai':
            lc_messages.append(AIMessage(content=message.text))
        else:
            content = message.text
            if message.context_conversation_ids:
                content += "\n\n[Source recording IDs: " + ", ".join(message.context_conversation_ids) + "]"
            lc_messages.append(HumanMessage(content=content))
            human_idxs.append(len(lc_messages) - 1)

    if human_idxs:
        last_human_idx = human_idxs[-1]
        latest = lc_messages[last_human_idx]
        lc_messages[last_human_idx] = HumanMessage(
            content=f"{build_time_context(tz)}\n\n{latest.content}"
        )

    # Second cache breakpoint on the history tail (§6.2, window raised to 80).
    #
    # The system prompt carries the first breakpoint (tools+system prefix). With
    # up to 80 turns now in-context, the history that follows it is re-read at
    # full price every turn unless we cache it too. Anthropic supports up to
    # 4 breakpoints; the Bedrock adapter converts these to native cachePoints.
    #
    # Anchor it on the *previous* human turn (second-to-last human). Two reasons:
    #   1. Byte stability: the per-turn clock is prepended only to the LATEST
    #      human (above); everything up to and including the previous human is
    #      identical across turns, so turn N reads turn N-1's cached prefix and
    #      writes only the one-turn delta (incremental caching). Marking the
    #      volatile latest human would rewrite a fresh prefix every turn.
    #   2. langchain_openai's chat/completions serializer passes cache_control
    #      through on system and *user* content blocks but strips it from
    #      *assistant* blocks (verified live on v1.1.7). So the anchor must be a
    #      human turn — anchoring the AI turn just before the latest human (the
    #      obvious "everything before the question") silently no-ops.
    #
    # Needs at least two human turns; with one, the system breakpoint already
    # covers the only stable prefix there is.
    if len(human_idxs) >= 2:
        anchor_idx = human_idxs[-2]
        anchor = lc_messages[anchor_idx]
        lc_messages[anchor_idx] = HumanMessage(
            content=[{
                "type": "text",
                "text": anchor.content,
                "cache_control": {"type": "ephemeral"},
            }]
        )
    return lc_messages


def _build_agent(ctx: RequestContext, citations: CitationAccumulator, streaming: bool):
    # The versioned registry selects the medium model and its provider.
    # It does not accept temperature, so we never pass one. The agent binds
    # its tools onto the returned LangChain chat model.
    model = create_llm('medium', streaming=streaming)
    # instrument_tools wraps each tool's .func in a span (metadata only) and is a
    # no-op unless AGENT_TRACING is on. It must wrap the *built* list here rather
    # than patch make_agent_tools: this module imported that name, so patching the
    # module would leave this call site on the unwrapped function.
    tools = instrument_tools(make_agent_tools(ctx, citations))
    if ctx.scoped_conversations is not None:
        for conversation in ctx.scoped_conversations:
            citations.add(conversation)
    prompt = build_system_prompt(ctx.uid, tz=ctx.tz, cited=ctx.cited, plugin=ctx.plugin,
                                 scoped_conversations=ctx.scoped_conversations)
    return create_agent(model, tools, system_prompt=prompt)


def _agent_config():
    """`config=` for invoke/astream. Empty dict when tracing is off.

    ⚠️ Both call sites need it. Wiring only the streaming path would make the
    production traces (/v2/messages) and the offline eval traces (which use the
    sync path) different shapes, and the whole point of one seam is that a finding
    offline means something online.
    """
    callbacks = llm_callbacks()
    return {"callbacks": callbacks} if callbacks else {}


@timeit
def execute_graph_chat(
    uid: str, messages: List[Message], app: Optional[object] = None, cited: Optional[bool] = False,
    developer_id: Optional[str] = None,
) -> Tuple[str, bool, List[Conversation]]:
    print('execute_graph_chat app    :', app.id if app else '<none>')
    tz = None
    if developer_id:
        tz = dev_db.get_user_time_zone(developer_id, uid)

    ctx = RequestContext(uid=uid, developer_id=developer_id, tz=tz or "UTC", cited=cited, plugin=app)
    citations = CitationAccumulator()
    agent = _build_agent(ctx, citations, streaming=False)

    with turn_span("chat.turn", **{
        "gen_ai.operation.name": "chat",
        "enduser.id": uid,
        "memorion.developer_id": developer_id,
        "memorion.streaming": False,
        "memorion.history_turns": len(messages),
    }) as span:
        result = agent.invoke({"messages": _to_lc_messages(messages, tz=ctx.tz)},
                              config=_agent_config() or None)
        answer = _final_answer(result.get("messages", []))
        # Lengths and counts, not text (TRACING.md §0).
        span.set_attribute("memorion.answer_chars", len(answer or ""))
        span.set_attribute("memorion.citations", len(citations))
    return answer, len(citations) > 0, citations.ordered


async def execute_graph_chat_stream(
    uid: str,
    messages: List[Message],
    app: Optional[object] = None,
    cited: Optional[bool] = False,
    callback_data: dict = {},
    chat_session: Optional[ChatSession] = None,
    developer_id: Optional[str] = None,
    scoped_conversations: Optional[List[dict]] = None,
) -> AsyncGenerator[str, None]:
    print('execute_graph_chat_stream app: ', app.id if app else '<none>')
    tz = None
    if developer_id:
        tz = dev_db.get_user_time_zone(developer_id, uid)

    callback = AsyncStreamingCallback()
    ctx = RequestContext(
        uid=uid, developer_id=developer_id, tz=tz or "UTC", cited=cited, plugin=app, callback=callback,
        scoped_conversations=scoped_conversations,
    )
    citations = CitationAccumulator()
    agent = _build_agent(ctx, citations, streaming=True)

    final_answer = {"text": ""}

    async def run():
        # The turn span opens inside the task, not around the generator. An async
        # generator's `with` block is torn down whenever the consumer stops
        # iterating (including on client disconnect), which would end the span
        # while tool calls are still running in this task. Opening it here also
        # puts the span in *this* task's context, which is what parents the tool
        # and LLM spans — contextvars set in the caller before create_task would
        # be copied in, but ones set after would not.
        try:
            with turn_span("chat.turn", **{
                "gen_ai.operation.name": "chat",
                "enduser.id": uid,
                "memorion.developer_id": developer_id,
                "memorion.streaming": True,
                "memorion.history_turns": len(messages),
            }) as span:
                await _stream_agent()
                # Lengths and counts, not text (TRACING.md §0).
                span.set_attribute("memorion.answer_chars", len(final_answer["text"] or ""))
                span.set_attribute("memorion.citations", len(citations))
        finally:
            await callback.end()

    async def _stream_agent():
        # Two stream modes at once:
        #  - "messages" yields (chunk, metadata) as tokens are produced; we
        #    forward AI text as `data:`. The tool-selection turn carries its
        #    payload in tool_calls, not content, so intermediate reasoning is
        #    not leaked. Tool progress arrives as `think:` events the tools emit.
        #  - "values" yields the full state after each step; its last AI message
        #    is the authoritative answer. Reading it here (rather than
        #    concatenating token chunks) keeps the stored answer correct even if
        #    the model backend doesn't emit token-level chunks.
        async for mode, payload in agent.astream(
            {"messages": _to_lc_messages(messages, tz=ctx.tz)}, stream_mode=["messages", "values"],
            config=_agent_config() or None,
        ):
            if mode == "messages":
                chunk, metadata = payload
                # Only the agent's own answer node ("model") is user-facing.
                # Tools may make their own LLM calls (resolve_time_range runs a
                # structured-output model to parse dates); those stream under
                # langgraph_node="tools" and must NOT be forwarded, or their raw
                # JSON ({"dates_range": [...]}) leaks into the answer.
                if (metadata or {}).get("langgraph_node") != "model":
                    continue
                if isinstance(chunk, AIMessageChunk):
                    text = _chunk_text(chunk)
                    if text and not chunk.tool_calls and not chunk.tool_call_chunks:
                        await callback.put_data(text)
            elif mode == "values":
                answer = _final_answer(payload.get("messages", []))
                if answer:
                    final_answer["text"] = answer

    task = asyncio.create_task(run())

    try:
        while True:
            if task.done() and callback.queue.empty():
                break
            try:
                chunk = await asyncio.wait_for(callback.queue.get(), timeout=0.5)
                if chunk:
                    yield chunk
                else:
                    break
            except asyncio.TimeoutError:
                continue
        await task
    except Exception:
        logger.exception("execute_graph_chat_stream failed uid=%s developer_id=%s", uid, developer_id)
        raise
    finally:
        # A client leaving Ask closes the generator at a yield too (GeneratorExit),
        # not only during queue.get. Cancel the model task in either case.
        if not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    callback_data['answer'] = final_answer["text"]
    callback_data['memories_found'] = citations.ordered
    callback_data['ask_for_nps'] = len(citations) > 0

    yield None
    return


def _final_answer(lc_messages: list) -> str:
    """Text of the last AI message in the agent's output."""
    for message in reversed(lc_messages):
        if isinstance(message, AIMessage):
            return _chunk_text(message)
    return ""


def _chunk_text(message) -> str:
    """Flatten message content to a string.

    Anthropic-style content can be a list of blocks; keep only the text blocks.
    """
    content = getattr(message, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        return "".join(parts)
    return ""
