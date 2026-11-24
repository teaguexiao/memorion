import re
from typing import List, Optional, Tuple

from langchain_core.output_parsers import PydanticOutputParser
from pydantic import BaseModel, Field

import utils.people as people_helper
from models.memories import Memory, MemoryCategory
from models.other import Person
from models.transcript_segment import TranscriptSegment
from utils.prompts import (
    extract_memories_prompt_text,
    extract_learnings_prompt_text,
    extract_memories_text_content_prompt_text,
)
from utils.llms.memory import get_prompt_memories
from .clients import coerce_llm_text_content, llm_mini, llm_high
from .prompt_registry import get_prompt, resolve_llm, single_brace_spec


class Memories(BaseModel):
    facts: List[Memory] = Field(
        min_items=0,
        max_items=2,
        description="Profile-worthy facts about the user. Empty list is the normal outcome.",
        default=[],
    )


class MemoriesByTexts(BaseModel):
    facts: List[Memory] = Field(
        description="List of **new** facts. If any",
        default=[],
    )


# Map for converting categories from old to new format
LEGACY_TO_NEW_CATEGORY = {
    'core': MemoryCategory.system,
    'hobbies': MemoryCategory.system,
    'lifestyle': MemoryCategory.system,
    'interests': MemoryCategory.system,
    'work': MemoryCategory.system,
    'skills': MemoryCategory.system,
    'learnings': MemoryCategory.system,
    'habits': MemoryCategory.system,
    'other': MemoryCategory.system,
}


# 换语言时必须重申第二人称，否则人称规则会被一起丢掉。
#
# 实测（2026-08-09，Teague 的 6 段真实对话）：prompt 主体改成第二人称后，英文路径
# 6/6 输出 "You have a young daughter..."，而 zh 路径 **0/3** —— 输出的仍是
# "Teague 有一个年幼的女儿"。根因是语言指令拼在 prompt 的最末尾（覆盖力最强的位置），
# 它只讲"用中文写"，模型在切换语言的同时把上文的人称约束一起丢了。
#
# 所以这句话必须跟着语言指令走，而不是只写在上面的 Output rules 里：末尾这一句是
# 中文路径唯一还在生效的约束。
_SECOND_PERSON_REMINDER = (
    'Still address the user in the second person ("you" / "your") in that language '
    '— never by name and never in the third person.'
)


def _build_output_language_instruction(output_language: Optional[str]) -> str:
    """Build a single-line output-language instruction for memory extraction prompts.

    事实是展示在「关于我」页里的用户画像，语言必须跟用户的 profile 语言一致——
    中文用户看到一屏英文事实，观感上就不像"它记住的关于我的事"。

    英文返回空串（prompt 本身就是英文的，不必再加一句）。'auto' / 'multi' 不是具体
    语言，不能拼进 "Write ... in {name}"（会变成 "in auto"，模型只能猜，实测退化成
    英文输出）——改成跟随对话本身的语言。

    ⚠️ 非英文分支都要带上 `_SECOND_PERSON_REMINDER`——见它上面的注释，不带的话中文
    路径的事实会退回第三人称。英文分支返回空串是安全的：prompt 主体本身就是英文，
    Output rules 里的人称约束没有被任何后续指令覆盖。
    """
    if not output_language:
        return ''
    try:
        from utils.locales import base_language, is_language_unspecified, language_name_for_prompt
    except Exception:
        return ''
    if base_language(output_language) == 'en':
        return ''
    if is_language_unspecified(output_language):
        return (
            "IMPORTANT: Write the extracted memory text content in the same language as the "
            f"conversation transcript above. {_SECOND_PERSON_REMINDER} "
            "Keep category and tag fields in their original English enum values."
        )
    name = language_name_for_prompt(output_language)
    return (
        f"IMPORTANT: Write the extracted memory text content in {name}, "
        f"even when the conversation is in another language. {_SECOND_PERSON_REMINDER} "
        "Keep category and tag fields in their original English enum values."
    )



# 「Speaker N 怎样怎样」这类事实写的是某个未归属的陌生说话人，不是用户画像。
# 注意：线上转录的 is_user/person_id 往往全空（声纹没标出），所以这里只拦
# 明确带 "Speaker N" 字样的输出，不能反过来要求"必须确认是用户说的"。
# 用正则而不是枚举编号：存量数据里出现过 Speaker 0 一直到 Speaker 6。
# 数字后面刻意不加 \b：中文事实里紧跟汉字（"Speaker 1提到暑假……"），而汉字也算
# \w，两个词字符之间没有边界，加了 \b 这类条目会整批漏过去。
# 开头的 \b 要保留，否则会误伤 "The speaker prefers……" 这种正常句子。
_ANONYMOUS_SPEAKER_RE = re.compile(r'\bspeaker[\s_-]*\d+', re.IGNORECASE)

# 「事实」写太长基本都是把会议结论/世界知识塞进来了；画像事实天然很短。
# 阈值放在 120：实测 90 会误杀合格的英文长句（中文事实普遍在 40 字以内）。
_MAX_FACT_CHARS = 120


def _normalize_fact(text: str) -> str:
    """去掉标点/空白/大小写差异，用于判重（英文和中文都适用）。"""
    return ''.join(ch for ch in text.lower() if ch.isalnum())


# 近似判重的相似度阈值（字符 3-gram 的 Jaccard）。
# 逐字判重挡不住换个说法的同一件事：线上出现过「用户的团队使用 EC2。」×3 和
# 「用户的团队使用 Fargate 和 EC2。」并存。0.8 定得刻意保守——实测同一个人的不同事实
# （"Teague 住在第 24 楼" / "Teague 拥有两个上海公寓"）相似度远低于此，只有真正的
# 复述才会命中。用字符 n-gram 而不是按词切：中文没有空格，按词切对中文完全无效。
#
# 🚨 **这道近似判重实际上从未生效，而且不要去调这个阈值。** 2026-08-17 在生产数据上量
# 过：对 12 对真重复（LLM 独立认定的同一件事）命中 **0/12**。也没有可用的分界——
#
#     真重复对   min 0.015  median 0.279  max 0.500
#     非重复对   「你有一个母亲」×「你有一个婆婆」= 0.333   ← 高于 8 个真重复对
#
# 两个分布完全重叠，降阈值第一批误杀的就是「你有一个X。」这类句式模板事实。语义判重
# 已经挪到 `utils/llm/deduplication.py`（独立的一次 LLM 判决 + 向量复核）；这里保留的是
# 逐字判重那部分的价值，n-gram 这层当作免费的额外一道、不指望它拦住什么。
_NEAR_DUP_THRESHOLD = 0.8
_NGRAM_SIZE = 3


def _fact_ngrams(normalized: str) -> set:
    if len(normalized) <= _NGRAM_SIZE:
        return {normalized}
    return {normalized[i : i + _NGRAM_SIZE] for i in range(len(normalized) - _NGRAM_SIZE + 1)}


def _is_near_duplicate(candidate: str, existing: List[set]) -> bool:
    """candidate 与任一已知事实的字符 n-gram Jaccard 超过阈值就算重复。"""
    grams = _fact_ngrams(candidate)
    if not grams:
        return False
    for other in existing:
        if not other:
            continue
        union = len(grams | other)
        if union and len(grams & other) / union >= _NEAR_DUP_THRESHOLD:
            return True
    return False


def _filter_profile_facts(facts: List[Memory], user_name: str, memories_str: str) -> List[Memory]:
    """代码层收口：prompt 会漂移，这些硬规则不会。

    过滤三类明确无价值的输出（线上实测最常见的噪音）：
    1. 写匿名说话人的事（"Speaker 2's hearing is poor"）——不是用户画像；
    2. 过长的句子——基本都是会议结论或技术知识点；
    3. 与已有事实或本批其它事实重复——逐字相同，或换个说法的同一件事。
    """
    known = {_normalize_fact(line.strip('- ').strip()) for line in memories_str.splitlines() if line.strip()}
    known.discard('')
    known_grams = [_fact_ngrams(k) for k in known]

    kept: List[Memory] = []
    seen = set()
    for fact in facts:
        content = (fact.content or '').strip()
        if not content:
            continue

        if _ANONYMOUS_SPEAKER_RE.search(content):
            print(f'_filter_profile_facts: dropped anonymous-speaker fact: {content}')
            continue

        if len(content) > _MAX_FACT_CHARS:
            print(f'_filter_profile_facts: dropped over-long fact ({len(content)} chars): {content}')
            continue

        key = _normalize_fact(content)
        if key in known or key in seen:
            print(f'_filter_profile_facts: dropped duplicate fact: {content}')
            continue

        if _is_near_duplicate(key, known_grams):
            print(f'_filter_profile_facts: dropped near-duplicate fact: {content}')
            continue

        seen.add(key)
        known_grams.append(_fact_ngrams(key))
        kept.append(fact)

    return kept


def _user_attributed_segments(segments: List[TranscriptSegment]) -> List[TranscriptSegment]:
    """Only owner-attributed speech is admissible evidence for profile facts.

    A wearable records everyone in the room. Passing the full transcript to an
    LLM lets a fluent rewrite turn another person's first-person statement into
    a second-person fact about the wearer. Prompt rules cannot make that
    impossible; removing non-owner speech from the evidence can.

    Fail closed when voice matching did not identify the owner. Missing a fact
    is recoverable; showing somebody else's life in "About me" is a trust break.
    """
    return [segment for segment in segments if segment.is_user]


def new_memories_extractor(
    uid: str,
    segments: List[TranscriptSegment],
    user_name: Optional[str] = None,
    memories_str: Optional[str] = None,
    output_language: Optional[str] = None,
) -> List[Memory]:
    # print('new_memories_extractor', uid, 'segments', len(segments), user_name, 'len(memories_str)', len(memories_str))
    evidence_segments = _user_attributed_segments(segments)
    if not evidence_segments:
        print(f'[MEMORY] Skipped profile facts for {uid}: no user-attributed speech')
        return []

    if user_name is None or memories_str is None:
        user_name, memories_str = get_prompt_memories(uid)

    # Deliberately exclude every non-user line. The production prompt still sees
    # normal ``Teague: ...`` labels, but it can no longer borrow a spouse's,
    # child's, colleague's, or stranger's statement and rewrite it as "you ...".
    content = TranscriptSegment.segments_as_string(evidence_segments, user_name=user_name)
    # 太短的对话不可能承载稳定的画像事实（原阈值 25 字符只挡得住一句话）。
    if not content or len(content) < 200:
        return []
    # TODO: include negative facts too? Things the user doesn't like?

    try:
        parser = PydanticOutputParser(pydantic_object=Memories)
        resolved = get_prompt('memories.extract', fallback=single_brace_spec(extract_memories_prompt_text))
        llm = resolve_llm(resolved, llm_mini)
        prompt_str = resolved.render(
            user_name=user_name,
            conversation=content,
            memories_str=memories_str,
            output_language_instruction=_build_output_language_instruction(output_language),
            format_instructions=parser.get_format_instructions(),
        )
        raw_output = coerce_llm_text_content(llm.invoke(prompt_str))

        # 「没有可提取的事实」时模型有时直接回 null / 空串，parser 会抛异常。
        # 这是正常结果而不是错误，别让它变成噪音日志。
        if not raw_output or raw_output.strip().lower() in ('null', '{}', '[]'):
            return []

        response: Memories = parser.parse(raw_output)

        # Ensure all new memories use the new category format
        for memory in response.facts:
            if isinstance(memory.category, str) and memory.category in LEGACY_TO_NEW_CATEGORY:
                memory.category = LEGACY_TO_NEW_CATEGORY[memory.category]

        return _filter_profile_facts(response.facts, user_name, memories_str)
    except Exception as e:
        print(f'Error extracting new facts: {e}')
        return []


def extract_memories_from_text(
    uid: str,
    text: str,
    text_source: str,
    user_name: Optional[str] = None,
    memories_str: Optional[str] = None,
    output_language: Optional[str] = None,
) -> List[Memory]:
    """Extract memories from external integration text sources like email, posts, messages"""
    if user_name is None or memories_str is None:
        user_name, memories_str = get_prompt_memories(uid)

    if not text or len(text) == 0:
        return []

    try:
        parser = PydanticOutputParser(pydantic_object=MemoriesByTexts)
        resolved = get_prompt(
            'memories.extract_from_text', fallback=single_brace_spec(extract_memories_text_content_prompt_text)
        )
        llm = resolve_llm(resolved, llm_mini)
        prompt_str = resolved.render(
            user_name=user_name,
            text_content=text,
            text_source=text_source,
            memories_str=memories_str,
            output_language_instruction=_build_output_language_instruction(output_language),
            format_instructions=parser.get_format_instructions(),
        )
        response: Memories = parser.parse(coerce_llm_text_content(llm.invoke(prompt_str)))

        # Ensure all new memories use the new category format
        for memory in response.facts:
            if isinstance(memory.category, str) and memory.category in LEGACY_TO_NEW_CATEGORY:
                memory.category = LEGACY_TO_NEW_CATEGORY[memory.category]

        # 外部文本走的是同一个画像列表，同样收口（该 prompt 仍允许最多 100 条，
        # 且会混入 learnings/世界知识——过滤器至少挡掉重复和超长条目）。
        return _filter_profile_facts(response.facts, user_name, memories_str)
    except Exception as e:
        print(f'Error extracting facts from {text_source}: {e}')
        return []


class Learnings(BaseModel):
    result: List[str] = Field(
        min_items=0,
        max_items=2,
        description="List of **new** learnings. If any",
        default=[],
    )


def new_learnings_extractor(
    uid: str,
    segments: List[TranscriptSegment],
    user_name: Optional[str] = None,
    learnings_str: Optional[str] = None,
    output_language: Optional[str] = None,
) -> List[Memory]:
    if user_name is None or learnings_str is None:
        user_name, memories_str = get_prompt_memories(uid)

    person_ids = list(set([s.person_id for s in segments if s.person_id]))
    people = [Person(**p) for p in people_helper.get_people_by_ids(uid, person_ids)] if person_ids else []
    content = TranscriptSegment.segments_as_string(segments, user_name=user_name, people=people)
    if not content or len(content) < 100:
        return []

    try:
        parser = PydanticOutputParser(pydantic_object=Learnings)
        resolved = get_prompt('memories.extract_learnings', fallback=single_brace_spec(extract_learnings_prompt_text))
        llm = resolve_llm(resolved, llm_high)
        prompt_str = resolved.render(
            user_name=user_name,
            conversation=content,
            learnings_str=learnings_str,
            output_language_instruction=_build_output_language_instruction(output_language),
            format_instructions=parser.get_format_instructions(),
        )
        response: Learnings = parser.parse(coerce_llm_text_content(llm.invoke(prompt_str)))
        return list(map(lambda x: Memory(content=x, category=MemoryCategory.interesting), response.result))
    except Exception as e:
        print(f'Error extracting new facts: {e}')
        return []


def identify_category_for_memory(memory: str, categories: List) -> str:
    # TODO: this should be structured output!!
    categories_str = ', '.join(categories)
    prompt_template = """
    You are an AI tasked with identifying the category of a fact from a list of predefined categories. 

    Your task is to determine the most relevant category for the given fact. 

    Respond only with the category name.

    The categories are: {categories_str}

    Fact: {memory}
    """
    resolved = get_prompt('memories.identify_category', fallback=single_brace_spec(prompt_template))
    prompt = resolved.render(categories_str=categories_str, memory=memory)
    llm = resolve_llm(resolved, llm_mini)
    response = llm.invoke(prompt)
    return coerce_llm_text_content(response)
