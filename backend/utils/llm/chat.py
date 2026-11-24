from .clients import llm_mini, llm_mini_stream, llm_medium_stream, llm_medium
import re
import os
from datetime import datetime, timezone
from typing import List, Optional, Tuple

from pydantic import BaseModel, Field, ValidationError

import utils.people as people_helper
from models.chat import Message, MessageSender
from models.conversation import CategoryEnum, Conversation, ActionItem, Event, ConversationPhoto
from models.other import Person
from models.transcript_segment import TranscriptSegment
from utils.llms.memory import get_prompt_memories
from .prompt_registry import PromptSpec, get_prompt, resolve_llm


def _render_registry_prompt(key: str, fallback: str, variables: dict, default_llm=llm_mini):
    """
    Resolve a chat prompt from the registry (production label), rendering
    {{var}} placeholders with `variables`. Returns (rendered_prompt, llm).

    The registry template stores the raw prompt WITH its original indentation;
    the caller applies the same post-processing (.replace('    ', '').strip()
    etc.) it always did, so behavior is character-for-character identical to
    the previous hardcoded f-strings. `fallback` is that hardcoded template
    (with {{var}} placeholders) used when the registry is unavailable.
    """
    resolved = get_prompt(key, fallback=PromptSpec(content=fallback))
    return resolved.render(**variables), resolve_llm(resolved, default_llm)


# ****************************************
# ************* CHAT BASICS **************
# ****************************************


def _get_language_instruction(uid: str) -> str:
    import database.developer_data as dev_db
    from utils.people import get_platform_developer_id
    developer_id = get_platform_developer_id()
    lang = dev_db.get_user_language(developer_id, uid) if developer_id else None
    if not lang or lang == 'en':
        return ''
    lang_map = {
        'zh': 'Chinese (中文)',
        'vi': 'Vietnamese (Tiếng Việt)',
        'ja': 'Japanese (日本語)',
        'ko': 'Korean (한국어)',
        'es': 'Spanish (Español)',
        'fr': 'French (Français)',
        'de': 'German (Deutsch)',
        'pt': 'Portuguese (Português)',
        'ru': 'Russian (Русский)',
        'ar': 'Arabic (العربية)',
        'hi': 'Hindi (हिन्दी)',
        'th': 'Thai (ไทย)',
    }
    lang_name = lang_map.get(lang, lang)
    return f'\nIMPORTANT: You MUST respond in {lang_name}. Do not respond in English unless the user explicitly asks for it.\n'


_INITIAL_MESSAGE_DEFAULT = """
You are 'Memorion', a friendly and helpful assistant who aims to make {{user_name}}'s life better 10x.
You know the following about {{user_name}}: {{memories_str}}.
{{lang_instruction}}
{{prev_messages_str}}

Compose {{initial_or_followup}} message to {{user_name}} that fully embodies your friendly and helpful personality. Use warm and cheerful language, and include light humor if appropriate. The message should be short, engaging, and make {{user_name}} feel welcome. Do not mention that you are an assistant or that this is an initial message; just {{start_or_continue}} the conversation naturally, showcasing your personality.
"""

_INITIAL_MESSAGE_PLUGIN = """
You are '{{plugin_name}}', {{plugin_chat_prompt}}.
You know the following about {{user_name}}: {{memories_str}}.
{{lang_instruction}}
{{prev_messages_str}}

As {{plugin_name}}, fully embrace your personality and characteristics in your {{initial_or_followup}} message to {{user_name}}. Use language, tone, and style that reflect your unique personality traits. {{start_or_continue}} the conversation naturally with a short, engaging message that showcases your personality and humor, and connects with {{user_name}}. Do not mention that you are an AI or that this is an initial message.
"""


def initial_chat_message(uid: str, plugin: Optional[object] = None, prev_messages_str: str = '') -> str:
    user_name, memories_str = get_prompt_memories(uid)
    lang_instruction = _get_language_instruction(uid)
    if plugin is None:
        prompt, llm = _render_registry_prompt('chat.initial_message', _INITIAL_MESSAGE_DEFAULT, {
            'user_name': user_name,
            'memories_str': memories_str,
            'lang_instruction': lang_instruction,
            'prev_messages_str': prev_messages_str,
            'initial_or_followup': "an initial" if not prev_messages_str else "a follow-up",
            'start_or_continue': "start" if not prev_messages_str else "continue",
        })
    else:
        prompt, llm = _render_registry_prompt('chat.initial_message_plugin', _INITIAL_MESSAGE_PLUGIN, {
            'plugin_name': plugin.name,
            'plugin_chat_prompt': plugin.chat_prompt,
            'user_name': user_name,
            'memories_str': memories_str,
            'lang_instruction': lang_instruction,
            'prev_messages_str': prev_messages_str,
            'initial_or_followup': "initial" if not prev_messages_str else "follow-up",
            'start_or_continue': "Start" if not prev_messages_str else "Continue",
        })
    prompt = prompt.strip()
    return llm.invoke(prompt).content


_SESSION_TITLE_DEFAULT = """
    You are an expert at creating concise, meaningful titles for conversations.

    Your task is to generate a short title (3-4 words maximum) that captures the main topic or intent of this message.
    The title should be:
    - Very concise (3-4 words max)
    - Clear and descriptive
    - Focus on the main topic, not implementation details
    - {{casing_rule}}
    - Avoid generic words like "Help", "Question", "Issue" unless very specific
    - Avoid quotes or special characters

    Examples of good titles:
    - "Python Data Analysis" (for questions about analyzing data with Python)
    - "Travel Planning Europe" (for questions about planning European travel)
    - "Career Change Advice" (for questions about switching careers)
    - "Recipe Recommendations" (for asking about food recipes)
    - "Investment Strategy" (for financial planning questions)
    - "Machine Learning Setup" (for ML environment questions)
    - "React Component Design" (for React development questions)

    Message: ```{{clean_text}}```

    Output only the title, nothing else.
    """


def generate_session_title(message_text: str, output_language: Optional[str] = None) -> str:
    """
    Generate a concise, meaningful title for a chat session based on the first user message.
    The title should be 3-4 words maximum and capture the main topic or intent.

    `output_language` (when provided and non-English) instructs the model to
    output the title in that language and disables the Title-Case post-processing
    to avoid mangling non-Latin scripts.
    """

    if not message_text or not message_text.strip():
        return "New Chat"

    clean_text = message_text.strip()[:500]

    # Decide whether to apply Title Case (only safe for Latin-script English).
    from utils.locales import base_language, language_name_for_prompt
    is_english = (not output_language) or base_language(output_language) == 'en'

    prompt, llm = _render_registry_prompt('chat.session_title', _SESSION_TITLE_DEFAULT, {
        'casing_rule': 'Use Title Case (capitalize first letter of each word)' if is_english else 'Use natural casing for the target language (do not force Title Case)',
        'clean_text': clean_text,
    })
    prompt = prompt.replace('    ', '').strip()

    if not is_english:
        prompt += f"\n\nOutput the title in {language_name_for_prompt(output_language)}."

    try:
        response = llm.invoke(prompt)
        title = response.content.strip()

        title = title.replace('"', '').replace("'", "").strip()

        words = title.split()
        if len(words) > 4:
            title = ' '.join(words[:4])
        elif len(words) == 0:
            title = "New Chat"

        # Title-Case post-processing only for English; other scripts may break.
        if is_english:
            title = ' '.join(word.capitalize() for word in title.split())

        return title

    except Exception as e:
        print(f"Error generating session title: {e}")
        words = clean_text.split()[:3]
        fallback_title = ' '.join(words).title() if (words and is_english) else (' '.join(words) if words else "New Chat")
        
        fallback_title = fallback_title.replace('?', '').replace('!', '').strip()
        return fallback_title[:50]


# *********************************************
# ************* RETRIEVAL + CHAT **************
# *********************************************


class RequiresContext(BaseModel):
    value: bool = Field(description="Based on the conversation, this tells if context is needed to respond")


class TopicsContext(BaseModel):
    topics: List[CategoryEnum] = Field(default=[], description="List of topics.")


class DatesContext(BaseModel):
    dates_range: List[datetime] = Field(
        default=[],
        examples=[['2024-12-23T00:00:00+07:00', '2024-12-23T23:59:00+07:00']],
        description="Dates range. (Optional)",
    )


_REQUIRES_CONTEXT_DEFAULT = '''
    Based on the current question your task is to determine whether the user is asking a question that requires context outside the conversation to be answered.
    Take as example: if the user is saying "Hi", "Hello", "How are you?", "Good morning", etc, the answer is False.

    User's Question:
    {{question}}
    '''


def requires_context(question: str) -> bool:
    prompt, llm = _render_registry_prompt('chat.requires_context', _REQUIRES_CONTEXT_DEFAULT, {'question': question})
    with_parser = llm.with_structured_output(RequiresContext)
    response: RequiresContext = with_parser.invoke(prompt)
    try:
        return response.value
    except ValidationError:
        return False


_DATES_CONTEXT_DEFAULT = '''
    You MUST determine the appropriate date range in {{tz}} that provides context for answering the <question> provided.

    If the <question> does not reference a date or a date range, respond with an empty list: []

    Current date time in UTC: {{now_utc}}

    <question>
    {{question}}
    </question>

    '''


def retrieve_context_dates_by_question(question: str, tz: str) -> List[datetime]:
    prompt, llm = _render_registry_prompt('chat.dates_context', _DATES_CONTEXT_DEFAULT, {
        'tz': tz,
        'now_utc': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S'),
        'question': question,
    })
    prompt = prompt.replace('    ', '').strip()

    # print(prompt)
    # print(llm_mini.invoke(prompt).content)
    with_parser = llm.with_structured_output(DatesContext)
    response: DatesContext = with_parser.invoke(prompt)
    return response.dates_range


class SummaryOutput(BaseModel):
    summary: str = Field(description="The extracted content, maximum 500 words.")


_CHUNK_EXTRACTION_DEFAULT = '''
    You are an experienced detective, your task is to extract the key points of the conversation related to the topics you were provided.
    You will be given a conversation transcript of a low quality recording, and a list of topics.

    Include the most relevant information about the topics, people mentioned, events, locations, facts, phrases, and any other relevant information.
    It is possible that the conversation doesn't have anything related to the topics, in that case, output an empty string.

    Conversation:
    {{content}}

    Topics: {{topics}}
    '''


def chunk_extraction(segments: List[TranscriptSegment], topics: List[str], people: List[Person] = None) -> str:
    content = TranscriptSegment.segments_as_string(segments, people=people)
    prompt, llm = _render_registry_prompt('chat.chunk_extraction', _CHUNK_EXTRACTION_DEFAULT, {
        'content': content,
        'topics': topics,
    })
    with_parser = llm.with_structured_output(SummaryOutput)
    response: SummaryOutput = with_parser.invoke(prompt)
    return response.summary


_SIMPLE_MESSAGE_DEFAULT = """
    You are an assistant for engaging personal conversations.
    You are made for {{user_name}}, {{memories_str}}
    {{lang_instruction}}

    Use what you know about {{user_name}}, to continue the conversation, feel free to ask questions, share stories, or just say hi.
    {{plugin_info}}

    Conversation History:
    {{conversation_history}}

    Answer:
    """


def _get_answer_simple_message_prompt(uid: str, messages: List[Message], app: Optional[object] = None) -> str:
    conversation_history = Message.get_messages_as_string(
        messages, use_user_name_if_available=True, use_plugin_name_if_available=True
    )
    user_name, memories_str = get_prompt_memories(uid)
    lang_instruction = _get_language_instruction(uid)

    plugin_info = ""
    if app:
        plugin_info = f"Your name is: {app.name}, and your personality/description is '{app.description}'.\nMake sure to reflect your personality in your response.\n"

    resolved = get_prompt('chat.simple_answer', fallback=PromptSpec(content=_SIMPLE_MESSAGE_DEFAULT))
    return resolved.render(
        user_name=user_name,
        memories_str=memories_str,
        lang_instruction=lang_instruction,
        plugin_info=plugin_info,
        conversation_history=conversation_history,
    ).replace('    ', '').strip()


def answer_simple_message(uid: str, messages: List[Message], plugin: Optional[object] = None) -> str:
    prompt = _get_answer_simple_message_prompt(uid, messages, plugin)
    return llm_mini.invoke(prompt).content


def answer_simple_message_stream(uid: str, messages: List[Message], plugin: Optional[object] = None, callbacks=[]) -> str:
    prompt = _get_answer_simple_message_prompt(uid, messages, plugin)
    return llm_mini_stream.invoke(prompt, {'callbacks': callbacks}).content


_QA_RAG_DEFAULT = """
    <assistant_role>
        You are an assistant for question-answering tasks.
    </assistant_role>

    <task>
        Write an accurate, detailed, and comprehensive response to the <question> in the most personalized way possible, using the <memories>, <user_facts> provided.
    </task>

    <instructions>
    - Refine the <question> based on the last <previous_messages> before answering it.
    - DO NOT use the AI's message from <previous_messages> as references to answer the <question>
    - Use <question_timezone> and <current_datetime_utc> to refer to the time context of the <question>
    - It is EXTREMELY IMPORTANT to directly answer the question, keep the answer concise and high-quality.
    - NEVER say "based on the available memories". Get straight to the point.
    - If you don't know the answer or the premise is incorrect, explain why. If the <memories> are empty or unhelpful, answer the question as well as you can with existing knowledge.
    - You MUST follow the <reports_instructions> if the user is asking for reporting or summarizing their dates, weeks, months, or years.
    {{cited_instruction}}
    {{plugin_regard}}.
    {{lang_instruction}}
    </instructions>

    <plugin_instructions>
    {{plugin_info}}
    </plugin_instructions>

    <reports_instructions>
    - Answer with the template:
     - Goals and Achievements
     - Mood Tracker
     - Gratitude Log
     - Lessons Learned
    </reports_instructions>

    <question>
    {{question}}
    <question>

    <memories>
    {{context}}
    </memories>

    <previous_messages>
    {{previous_messages}}
    </previous_messages>

    <user_facts>
    [Use the following User Facts if relevant to the <question>]
        {{user_facts}}
    </user_facts>

    <current_datetime_utc>
        Current date time in UTC: {{now_utc}}
    </current_datetime_utc>

    <question_timezone>
        Question's timezone: {{tz}}
    </question_timezone>

    <answer>
    """


def _get_qa_rag_prompt(
    uid: str,
    question: str,
    context: str,
    plugin: Optional[object] = None,
    cited: Optional[bool] = False,
    messages: List[Message] = [],
    tz: Optional[str] = "UTC",
) -> str:
    user_name, memories_str = get_prompt_memories(uid)
    lang_instruction = _get_language_instruction(uid)
    memories_str = '\n'.join(memories_str.split('\n')[1:]).strip()

    # Use as template (make sure it varies every time): "If I were you $user_name I would do x, y, z."
    context = context.replace('\n\n', '\n').strip()
    plugin_info = ""
    if plugin:
        plugin_info = f"Your name is: {plugin.name}, and your personality/description is '{plugin.description}'.\nMake sure to reflect your personality in your response.\n"

    # Ref: https://www.reddit.com/r/perplexity_ai/comments/1hi981d
    cited_instruction = """
    - You MUST cite the most relevant <memories> that answer the question. \
      - Only cite in <memories> not <user_facts>, not <previous_messages>.
      - Cite in memories using [index] at the end of sentences when needed, for example "You discussed optimizing firmware with your teammate yesterday[1][2]".
      - NO SPACE between the last word and the citation.
      - Avoid citing irrelevant memories.
    """

    resolved = get_prompt('chat.qa_rag', fallback=PromptSpec(content=_QA_RAG_DEFAULT))
    return (
        resolved.render(
            cited_instruction=cited_instruction if cited and len(context) > 0 else "",
            plugin_regard="- Regard the <plugin_instructions>" if len(plugin_info) > 0 else "",
            lang_instruction=lang_instruction,
            plugin_info=plugin_info,
            question=question,
            context=context,
            previous_messages=Message.get_messages_as_xml(messages),
            user_facts=memories_str.strip(),
            now_utc=datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S'),
            tz=tz,
        )
        .replace('    ', '')
        .replace('\n\n\n', '\n\n')
        .strip()
    )


def qa_rag(
    uid: str,
    question: str,
    context: str,
    plugin: Optional[object] = None,
    cited: Optional[bool] = False,
    messages: List[Message] = [],
    tz: Optional[str] = "UTC",
) -> str:
    prompt = _get_qa_rag_prompt(uid, question, context, plugin, cited, messages, tz)
    # print('qa_rag prompt', prompt)
    return llm_medium.invoke(prompt).content


def qa_rag_stream(
    uid: str,
    question: str,
    context: str,
    plugin: Optional[object] = None,
    cited: Optional[bool] = False,
    messages: List[Message] = [],
    tz: Optional[str] = "UTC",
    callbacks=[],
) -> str:
    prompt = _get_qa_rag_prompt(uid, question, context, plugin, cited, messages, tz)
    # print('qa_rag prompt', prompt)
    return llm_medium_stream.invoke(prompt, {'callbacks': callbacks}).content


# **************************************************
# ************* RETRIEVAL (EMOTIONAL) **************
# **************************************************


_TOPICS_CONTEXT_DEFAULT = '''
    Based on the current transcript of a conversation.

    Your task is to extract the correct and most accurate context in the conversation, to be used to retrieve more information.
    Provide a list of topics in which the current conversation needs context about, in order to answer the most recent user request.

    Conversation:
    {{transcript}}
    '''


def retrieve_memory_context_params(uid: str, memory: Conversation) -> List[str]:
    person_ids = [s.person_id for s in memory.transcript_segments if s.person_id]
    people = []
    if person_ids:
        people_data = people_helper.get_people_by_ids(uid, list(set(person_ids)))
        people = [Person(**p) for p in people_data]

    transcript = memory.get_transcript(False, people=people)
    if len(transcript) == 0:
        return []

    prompt, llm = _render_registry_prompt('chat.topics_context', _TOPICS_CONTEXT_DEFAULT, {'transcript': transcript})
    prompt = prompt.replace('    ', '').strip()

    try:
        with_parser = llm.with_structured_output(TopicsContext)
        response: TopicsContext = with_parser.invoke(prompt)
        return response.topics
    except Exception as e:
        print(f'Error determining memory discard: {e}')
        return []


_EMOTIONAL_SUPPORT_ZH = """
        你是一个体贴、温暖的朋友。
        你的好朋友是 {{user_name}}，{{memories_str}}

        {{user_name}} 刚刚完成了一段对话，在对话中 {{user_name}} 表现出 {{emotion}} 的情绪。

        你将看到对话记录和之前相关对话的上下文。

        记住，{{user_name}} 现在感到 {{emotion}}。
        根据你对 {{user_name}} 的了解、对话记录和相关上下文，帮助 {{user_name}} 克服这种情绪（如果是负面的），
        或者一起庆祝（如果是正面的），给予建议、鼓励、支持或建议最佳行动。

        消息要简短温暖，不超过30个字，用中文回复。

        对话记录:
        {{transcript}}

        上下文:
        ```
        {{context}}
        ```
        """

_EMOTIONAL_SUPPORT_EN = """
        You are a thoughtful and encouraging Friend.
        Your best friend is {{user_name}}, {{memories_str}}

        {{user_name}} just finished a conversation where {{user_name}} experienced {{emotion}}.

        You will be given the conversation transcript, and context from previous related conversations of {{user_name}}.

        Remember, {{user_name}} is feeling {{emotion}}.
        Use what you know about {{user_name}}, the transcript, and the related context, to help {{user_name}} overcome this feeling \
        (if bad), or celebrate (if good), by giving advice, encouragement, support, or suggesting the best action to take.

        Make sure the message is nice and short, no more than 20 words.

        Conversation Transcript:
        {{transcript}}

        Context:
        ```
        {{context}}
        ```
        """


def obtain_emotional_message(
    uid: str,
    memory: Conversation,
    context: str,
    emotion: str,
    output_language: Optional[str] = None,
) -> str:
    user_name, memories_str = get_prompt_memories(uid)

    person_ids = [s.person_id for s in memory.transcript_segments if s.person_id]
    people = []
    if person_ids:
        people_data = people_helper.get_people_by_ids(uid, list(set(person_ids)))
        people = [Person(**p) for p in people_data]

    transcript = memory.get_transcript(False, people=people)

    # 选择输出语言：优先使用 user.language；缺失时退回字符占比启发式检测
    if output_language:
        from utils.locales import base_language as _base_language
        is_chinese = _base_language(output_language) == 'zh'
    else:
        chinese_chars = sum(1 for c in transcript if '\u4e00' <= c <= '\u9fff')
        is_chinese = chinese_chars > len(transcript) * 0.1  # 超过10%是中文字符

    if is_chinese:
        prompt, llm = _render_registry_prompt('chat.emotional_support.zh', _EMOTIONAL_SUPPORT_ZH, {
            'user_name': user_name,
            'memories_str': memories_str,
            'emotion': emotion,
            'transcript': transcript,
            'context': context,
        })
        prompt = prompt.replace('        ', '').strip()
    else:
        prompt, llm = _render_registry_prompt('chat.emotional_support.en', _EMOTIONAL_SUPPORT_EN, {
            'user_name': user_name,
            'memories_str': memories_str,
            'emotion': emotion,
            'transcript': transcript,
            'context': context,
        })
        prompt = prompt.replace('        ', '').strip()

        # Append language hint for non-English/non-Chinese users (ja, ko, es, ...)
        if output_language:
            from utils.locales import base_language as _base_language
            from utils.locales import language_name_for_prompt as _lang_name
            if _base_language(output_language) not in ('en', 'zh'):
                prompt += f"\n\nRespond in {_lang_name(output_language)}."

    return llm.invoke(prompt).content


# **********************************************
# ************* CHAT V2 LANGGRAPH **************
# **********************************************


class ExtractedInformation(BaseModel):
    people: List[str] = Field(
        default=[],
        examples=[['John Doe', 'Jane Doe']],
        description='Identify all the people names who were mentioned during the conversation.',
    )
    topics: List[str] = Field(
        default=[],
        examples=[['Artificial Intelligence', 'Machine Learning']],
        description='List all the main topics and subtopics that were discussed.',
    )
    entities: List[str] = Field(
        default=[],
        examples=[['OpenAI', 'GPT-4']],
        description='List any products, technologies, places, or other entities that are relevant to the conversation.',
    )
    dates: List[str] = Field(
        default=[],
        examples=[['2024-01-01', '2024-01-02']],
        description=f'Extract any dates mentioned in the conversation. Use the format YYYY-MM-DD.',
    )


class OutputQuestion(BaseModel):
    question: str = Field(description='The extracted user question from the conversation.')


_EXTRACT_QUESTION_DEFAULT = '''
    You will be given a recent conversation between a <user> and an <AI>. \
    The conversation may include a few messages exchanged in <previous_messages> and partly build up the proper question. \
    Your task is to understand the <user_last_messages> and identify the question or follow-up question the user is asking.

    You will be provided with <previous_messages> between you and the user to help you indentify the question.

    First, determine whether the user is asking a question or a follow-up question. \
    If the user is not asking a question or does not want to follow up, respond with an empty message. \
    For example, if the user says "Hi", "Hello", "How are you?", or "Good morning", the answer should be empty.

    If the <user_last_messages> contain a complete question, maintain the original version as accurately as possible. \
    Avoid adding unnecessary words.

    You MUST keep the original <date_in_term>

    Output a WH-question, that is, a question that starts with a WH-word, like "What", "When", "Where", "Who", "Why", "How".

    Example 1:
    <user_last_messages>
    <message>
        <sender>User</sender>
        <content>
            According to WHOOP, my HRV this Sunday was the highest it's been in a month. Here's what I did:

            Attended an outdoor party (cold weather, talked a lot more than usual).
            Smoked weed (unusual for me).
            Drank lots of relaxing tea.

            Can you prioritize each activity on a 0-10 scale for how much it might have influenced my HRV?
        </content>
    </message>
    </user_last_messages>
    Expected output: "How should each activity (going to a party and talking a lot, smoking weed, and drinking lots of relaxing tea) be prioritized on a scale of 0-10 in terms of their impact on my HRV, considering the recent activities that led to the highest HRV this month?"

    <user_last_messages>
    {{user_last_messages}}
    </user_last_messages>

    <previous_messages>
    {{previous_messages}}
    </previous_messages>

    <date_in_term>
    - today
    - my day
    - my week
    - this week
    - this day
    - etc.
    </date_in_term>
    '''


def extract_question_from_conversation(messages: List[Message]) -> str:
    # user last messages
    print("extract_question_from_conversation")
    user_message_idx = len(messages)
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].sender == MessageSender.ai:
            break
        if messages[i].sender == MessageSender.human:
            user_message_idx = i
    user_last_messages = messages[user_message_idx:]
    if len(user_last_messages) == 0:
        return ""

    prompt, llm = _render_registry_prompt('chat.extract_question', _EXTRACT_QUESTION_DEFAULT, {
        'user_last_messages': Message.get_messages_as_xml(user_last_messages),
        'previous_messages': Message.get_messages_as_xml(messages),
    })
    prompt = prompt.replace('    ', '').strip()
    # print(prompt)
    question = llm.with_structured_output(OutputQuestion).invoke(prompt).question
    # print(question)
    return question


_EXTRACT_METADATA_TRANSCRIPT_DEFAULT = '''
    You will be given content which could be a raw transcript of a conversation, a series of photo descriptions from a wearable camera, or both. The transcript has about 20% word error rate, and diarization is also made very poorly.

    Your task is to extract the most accurate information from the content in the output object indicated below.

    Make sure as a first step, you infer and fix any raw transcript errors and then proceed to extract the information from the entire content.

    For context when extracting dates, today is {{today}} in UTC. {{tz}} is the user's timezone, convert it to UTC and respond in UTC.
    If one says "today", it means the current day.
    If one says "tomorrow", it means the next day after today.
    If one says "yesterday", it means the day before today.
    If one says "next week", it means the next monday.

    Content:
    ```
    {{full_context}}
    ```
    '''


def retrieve_metadata_fields_from_transcript(
    uid: str, created_at: datetime, transcript_segment: List[dict], tz: str, photos: List[ConversationPhoto] = None
) -> ExtractedInformation:
    context_parts = []
    if transcript_segment:
        transcript = ''
        for segment in transcript_segment:
            transcript += f'{segment["text"].strip()}\n\n'
        if transcript.strip():
            context_parts.append(f"Conversation Transcript:\n```\n{transcript.strip()}\n```")

    if photos:
        photo_descriptions = ConversationPhoto.photos_as_string(photos, include_timestamps=True)
        if photo_descriptions != 'None':
            context_parts.append(f"Photo Descriptions from a wearable camera:\n{photo_descriptions}")

    if not context_parts:
        return {'people': [], 'topics': [], 'entities': [], 'dates': []}

    full_context = "\n\n".join(context_parts)

    # TODO: ask it to use max 2 words? to have more standardization possibilities
    prompt, llm = _render_registry_prompt('chat.extract_metadata_transcript', _EXTRACT_METADATA_TRANSCRIPT_DEFAULT, {
        'today': created_at.astimezone(timezone.utc).strftime('%Y-%m-%d'),
        'tz': tz,
        'full_context': full_context,
    })
    prompt = prompt.replace('    ', '')
    try:
        result: ExtractedInformation = llm.with_structured_output(ExtractedInformation).invoke(prompt)
        if result is None:
            print('retrieve_metadata_fields_from_transcript: LLM returned None')
            return {'people': [], 'topics': [], 'entities': [], 'dates': []}
    except Exception as e:
        print('e', e)
        return {'people': [], 'topics': [], 'entities': [], 'dates': []}

    def normalize_filter(value: str) -> str:
        # Convert to lowercase and strip whitespace
        value = value.lower().strip()

        # Remove special characters and extra spaces
        value = re.sub(r'[^\w\s-]', '', value)
        value = re.sub(r'\s+', ' ', value)

        # Remove common filler words
        filler_words = {'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to'}
        value = ' '.join(word for word in value.split() if word not in filler_words)

        # Standardize common variations
        value = value.replace('artificial intelligence', 'ai')
        value = value.replace('machine learning', 'ml')
        value = value.replace('natural language processing', 'nlp')

        return value.strip()

    metadata = {
        'people': [normalize_filter(p) for p in result.people],
        'topics': [normalize_filter(t) for t in result.topics],
        'entities': [normalize_filter(e) for e in result.entities],
        'dates': [],
    }
    # 'dates': [date.strftime('%Y-%m-%d') for date in result.dates],
    for date in result.dates:
        try:
            date = datetime.strptime(date, '%Y-%m-%d')
            metadata['dates'].append(date.strftime('%Y-%m-%d'))
        except Exception as e:
            print(f'Error parsing date: {e}')

    return metadata


_EXTRACT_METADATA_MESSAGE_DEFAULT = '''
    You will be given the content of a message or conversation {{source_context}}.

    Your task is to extract the most accurate information from the message in the output object indicated below.

    Focus on identifying:
    1. People mentioned in the message (sender, recipients, and anyone referenced)
    2. Topics discussed in the message
    3. Organizations, products, locations, or other entities mentioned
    4. Any dates or time references

    For context when extracting dates, today is {{today}} in UTC. 
    {{tz}} is the user's timezone, convert it to UTC and respond in UTC.
    If the message mentions "today", it means the current day.
    If the message mentions "tomorrow", it means the next day after today.
    If the message mentions "yesterday", it means the day before today.
    If the message mentions "next week", it means the next monday.

    Message Content:
    ```
    {{message_text}}
    ```
    '''


def retrieve_metadata_from_message(
    uid: str, created_at: datetime, message_text: str, tz: str, source_spec: str = None
) -> ExtractedInformation:
    """Extract metadata from messaging app content"""
    source_context = f"from {source_spec}" if source_spec else "from a messaging application"

    prompt, _ = _render_registry_prompt('chat.extract_metadata_message', _EXTRACT_METADATA_MESSAGE_DEFAULT, {
        'source_context': source_context,
        'today': created_at.astimezone(timezone.utc).strftime('%Y-%m-%d'),
        'tz': tz,
        'message_text': message_text,
    })
    prompt = prompt.replace('    ', '')

    return _process_extracted_metadata(uid, prompt)


_EXTRACT_METADATA_TEXT_DEFAULT = '''
    You will be given the content of a text {{source_context}}.

    Your task is to extract the most accurate information from the text in the output object indicated below.

    Focus on identifying:
    1. People mentioned in the text (author, recipients, and anyone referenced)
    2. Topics discussed in the text
    3. Organizations, products, locations, or other entities mentioned
    4. Any dates or time references

    For context when extracting dates, today is {{today}} in UTC. 
    {{tz}} is the user's timezone, convert it to UTC and respond in UTC.
    If the text mentions "today", it means the current day.
    If the text mentions "tomorrow", it means the next day after today.
    If the text mentions "yesterday", it means the day before today.
    If the text mentions "next week", it means the next monday.

    Text Content:
    ```
    {{text}}
    ```
    '''


def retrieve_metadata_from_text(
    uid: str, created_at: datetime, text: str, tz: str, source_spec: str = None
) -> ExtractedInformation:
    """Extract metadata from generic text content"""
    source_context = f"from {source_spec}" if source_spec else "from a text document"

    prompt, _ = _render_registry_prompt('chat.extract_metadata_text', _EXTRACT_METADATA_TEXT_DEFAULT, {
        'source_context': source_context,
        'today': created_at.astimezone(timezone.utc).strftime('%Y-%m-%d'),
        'tz': tz,
        'text': text,
    })
    prompt = prompt.replace('    ', '')

    return _process_extracted_metadata(uid, prompt)


def _process_extracted_metadata(uid: str, prompt: str) -> dict:
    """Process the extracted metadata from any source"""
    try:
        result: ExtractedInformation = llm_mini.with_structured_output(ExtractedInformation).invoke(prompt)
        if result is None:
            print('_process_extracted_metadata: LLM returned None')
            return {'people': [], 'topics': [], 'entities': [], 'dates': []}
    except Exception as e:
        print(f'Error extracting metadata: {e}')
        return {'people': [], 'topics': [], 'entities': [], 'dates': []}

    def normalize_filter(value: str) -> str:
        # Convert to lowercase and strip whitespace
        value = value.lower().strip()

        # Remove special characters and extra spaces
        value = re.sub(r'[^\w\s-]', '', value)
        value = re.sub(r'\s+', ' ', value)

        # Remove common filler words
        filler_words = {'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to'}
        value = ' '.join(word for word in value.split() if word not in filler_words)

        # Standardize common variations
        value = value.replace('artificial intelligence', 'ai')
        value = value.replace('machine learning', 'ml')
        value = value.replace('natural language processing', 'nlp')

        return value.strip()

    metadata = {
        'people': [normalize_filter(p) for p in result.people],
        'topics': [normalize_filter(t) for t in result.topics],
        'entities': [normalize_filter(e) for e in result.entities],
        'dates': [],
    }

    for date in result.dates:
        try:
            date = datetime.strptime(date, '%Y-%m-%d')
            metadata['dates'].append(date.strftime('%Y-%m-%d'))
        except Exception as e:
            print(f'Error parsing date: {e}')

    return metadata


# **************************************************
# ************* REALTIME V2 LANGGRAPH **************
# **************************************************


_REALTIME_QUESTION_DEFAULT = '''
    {{user_name}} is having a conversation.

    This is what you know about {{user_name}}: {{memories_str}}

    You will be the transcript of a recent conversation between {{user_name}} and a few people, \
    your task is to understand the last few exchanges, and identify in order to provide advice to {{user_name}}, what other things about {{user_name}} \
    you should know.

    For example, if the conversation is about a new job, you should output a question like "What discussions have I had about job search?".
    For example, if the conversation is about a new programming languages, you should output a question like "What have I chatted about programming?".

    Make sure as a first step, you infer and fix the raw transcript errors and then proceed to figure out the most meaningful question to ask.

    You must output at WH-question, that is, a question that starts with a WH-word, like "What", "When", "Where", "Who", "Why", "How".

    Conversation:
    ```
    {{transcript}}
    ```
    '''


def extract_question_from_transcript(uid: str, segments: List[TranscriptSegment]) -> str:
    user_name, memories_str = get_prompt_memories(uid)

    person_ids = [s.person_id for s in segments if s.person_id]
    people = []
    if person_ids:
        people_data = people_helper.get_people_by_ids(uid, list(set(person_ids)))
        people = [Person(**p) for p in people_data]

    prompt, llm = _render_registry_prompt('chat.realtime_question', _REALTIME_QUESTION_DEFAULT, {
        'user_name': user_name,
        'memories_str': memories_str,
        'transcript': TranscriptSegment.segments_as_string(segments, people=people),
    })
    prompt = prompt.replace('    ', '').strip()
    return llm.with_structured_output(OutputQuestion).invoke(prompt).question


class OutputMessage(BaseModel):
    message: str = Field(description='The message to be sent to the user.', max_length=200)


_REALTIME_ADVICE_DEFAULT = """
    You are a brutally honest, very creative, sometimes funny, indefatigable personal life coach who helps people improve their own agency in life, \
    pulling in pop culture references and inspirational business and life figures from recent history, mixed in with references to recent personal memories,
    to help drive the point across.

    {{memories_str}}

    {{user_name}} just had a conversation and is asking for advice on what to do next.

    In order to answer you must analyize:
    - The conversation transcript.
    - The related conversations from previous days.
    - The facts you know about {{user_name}}.

    You start all your sentences with:
    - "If I were you, I would do this..."
    - "I think you should do x..."
    - "I believe you need to do y..."

    Your sentences are short, to the point, and very direct, at most 20 words.
    MUST OUTPUT 20 words or less.

    Conversation Transcript:
    {{transcript}}

    Context:
    ```
    {{context}}
    ```
    """


def provide_advice_message(uid: str, segments: List[TranscriptSegment], context: str) -> str:
    user_name, memories_str = get_prompt_memories(uid)

    person_ids = [s.person_id for s in segments if s.person_id]
    people = []
    if person_ids:
        people_data = people_helper.get_people_by_ids(uid, list(set(person_ids)))
        people = [Person(**p) for p in people_data]

    transcript = TranscriptSegment.segments_as_string(segments, people=people)
    # TODO: tweak with different type of requests, like this, or roast, or praise or emotional, etc.

    prompt, llm = _render_registry_prompt('chat.realtime_advice', _REALTIME_ADVICE_DEFAULT, {
        'memories_str': memories_str,
        'user_name': user_name,
        'transcript': transcript,
        'context': context,
    })
    prompt = prompt.replace('    ', '').strip()
    return llm.with_structured_output(OutputMessage).invoke(prompt).message
