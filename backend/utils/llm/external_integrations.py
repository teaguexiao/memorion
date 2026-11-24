from datetime import datetime
from typing import List
from langchain_core.messages import SystemMessage
import database.developer_data as dev_db
import utils.people as people_helper
from models.conversation import Structured, Conversation
from utils.llm.clients import parser, llm_mini
from utils.llm.daily_summary import generate_daily_journal
from utils.llm.daily_journal_sources import build_daily_journal_history, parse_daily_journal_people
from utils.llm.prompt_registry import PromptSpec, get_prompt, resolve_llm
from utils.llms.memory import get_prompt_memories

# Fallback template (registry key 'external_integrations.message_structure').
# Pre-de-indented (the legacy prompt was de-indented via .replace('    ', '')).
_MESSAGE_STRUCTURE = PromptSpec(content='''You are an expert message analyzer. Your task is to analyze the message content and provide structure and clarity.
The message language is {{language_code}}. You MUST write your entire response in {{output_language}}. All titles, summaries, action items, and other output must be in {{output_language}}.

For the title, create a concise title that captures the main topic of the message.
For the overview, summarize the message with the main points discussed, make sure to capture the key information and important details.
For the action items, include any tasks or actions that need to be taken based on the message.
For the category, classify the message into one of the available categories.
For Calendar Events, include any events or meetings mentioned in the message. For date context, this message was sent on {{started_at}}. {{tz}} is the user's timezone, convert it to UTC and respond in UTC.

Message Content: ```{{text}}```
Message Source: {{text_source_spec}}

{{format_instructions}}''')

# Fallback template (registry key 'external_integrations.summarize_experience').
# Pre-de-indented (the legacy prompt was de-indented via .replace('    ', '')).
_SUMMARIZE_EXPERIENCE = PromptSpec(content='''The user sent a text of {{source_context}}, and wants to create a memory from it.
  For the title, use the main topic of the experience or thought.
  For the overview, condense the descriptions into a brief summary with the main topics discussed, make sure to capture the key points and important details.
  For the category, classify the scenes into one of the available categories.
  For the action items, include any tasks or actions that need to be taken based on the content.
  For Calendar Events, include any events or meetings mentioned in the content.

  Text: ```{{text}}```''')


def get_message_structure(
    text: str, started_at: datetime, language_code: str, tz: str, text_source_spec: str = None,
    output_language: str = None,
) -> Structured:
    effective_output_language = output_language or language_code

    resolved = get_prompt('external_integrations.message_structure', fallback=_MESSAGE_STRUCTURE)
    prompt_text = resolved.render(
        language_code=language_code,
        output_language=effective_output_language,
        started_at=started_at.isoformat(),
        tz=tz,
        text=text,
        text_source_spec=text_source_spec if text_source_spec else 'Messaging App',
        format_instructions=parser.get_format_instructions(),
    )

    llm = resolve_llm(resolved, llm_mini)
    response = parser.invoke(llm.invoke([SystemMessage(content=prompt_text)]))

    for event in response.events or []:
        if event.duration > 180:
            event.duration = 180
        event.created = False
    return response


def summarize_experience_text(text: str, text_source_spec: str = None) -> Structured:
    source_context = f"Source: {text_source_spec}" if text_source_spec else "their own experiences or thoughts"
    resolved = get_prompt('external_integrations.summarize_experience', fallback=_SUMMARIZE_EXPERIENCE)
    # Legacy behavior: 4-space runs are stripped from the interpolated prompt.
    prompt = resolved.render(source_context=source_context, text=text).replace('    ', '').strip()
    llm = resolve_llm(resolved, llm_mini)
    return llm.with_structured_output(Structured).invoke(prompt)


def get_conversation_summary(uid: str, memories: List[Conversation]) -> str:
    user_name, memories_str = get_prompt_memories(uid)

    all_person_ids = []
    for m in memories:
        all_person_ids.extend([s.person_id for s in m.transcript_segments if s.person_id])

    people = []
    if all_person_ids:
        people_data = people_helper.get_people_by_ids(uid, list(set(all_person_ids)))
        people = parse_daily_journal_people(people_data)

    conversation_history = build_daily_journal_history(memories, people=people)

    # Determine language from conversations with fallback strategy
    language_code = _get_conversation_language(uid, memories)

    # Use a more capable model for high-signal daily summaries. Draft + fact-check
    # pass; raises rather than returning an unchecked draft. The journal clients allow
    # the long first-token wait of whole-day prompts (see `llm_medium_journal`).
    from utils.llm.clients import llm_medium_journal, llm_large_journal
    return generate_daily_journal(
        llm_medium_journal,
        user_name=user_name,
        conversation_history=conversation_history,
        language_code=language_code,
        memories_context=memories_str,
        grounding_llm=llm_large_journal,
    )


def _get_conversation_language(uid: str, memories: List[Conversation]) -> str:
    """
    Get language code from conversations with fallback strategy.
    Priority: user preference -> conversation.language -> default 'en'
    """

    from utils.people import get_platform_developer_id
    developer_id = get_platform_developer_id()
    user_language = dev_db.get_user_language(developer_id, uid) if developer_id else None
    if user_language:
        return user_language

    # Fallback to try to get language from conversations
    for memory in memories:
        if hasattr(memory, 'language') and memory.language:
            return memory.language

    # Default to English
    return 'en'


def get_language_instruction_for_code(language_code: str) -> str:
    """Generate language instruction based on language code."""
    if language_code in ['zh', 'zh-cn', 'zh-tw']:
        return """
CRITICAL LANGUAGE REQUIREMENT: You MUST respond entirely in Chinese (中文).
- All section headers must be in Chinese
- All content, analysis, and insights must be in Chinese
- All quotes from conversations must remain in their original Chinese
- Do not translate any part of your response to English or any other language
- Use Chinese throughout the entire summary
"""
    elif language_code == 'en':
        return """
LANGUAGE REQUIREMENT: Respond entirely in English.
All section headers, content, analysis, and insights must be in English.
"""
    else:
        # For other languages, use the language code directly in instruction
        return f"""
CRITICAL LANGUAGE REQUIREMENT: You MUST respond entirely in the language corresponding to code '{language_code}'.
- All section headers must be in this language
- All content, analysis, and insights must be in this language
- All quotes from conversations must remain in their original language
- Do not translate any part of your response to English or any other language
- Use the language corresponding to '{language_code}' throughout the entire summary
"""


def get_localized_daily_summary_title(language_code: str) -> str:
    from utils.locales import get_localized_daily_summary_title as _impl
    return _impl(language_code)


def get_conversation_language_for_notification(uid: str, memories: List[Conversation]) -> str:
    """
    Resolve notification language with user profile language as the source of truth.
    This is a wrapper for _get_conversation_language that can be used by notification modules.

    Args:
        uid: User ID
        memories: List of Conversation objects

    Returns:
        Language code string (e.g., 'en', 'zh', 'zh-cn')
    """
    return _get_conversation_language(uid, memories)
