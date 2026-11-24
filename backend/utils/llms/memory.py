from typing import List, Tuple, Optional

import database.developer_data as dev_db
from database.auth import get_user_name
from models.memories import Memory, MemoryCategory


# 事实正文从 2026-08-09 起用第二人称书写（"你住在宝山"），因为它们要展示在
# 「关于我 → 它记住的事实」里，和「你答应过的事」「洞察」并排——第三人称读起来像
# 别人写的旁观笔记。
#
# ⚠️ 但同一份文本还会被塞进多个 LLM 的 system prompt（chat agent 的 {{user_facts}}、
# 每日一刻、洞察、EIR）。在那个位置，裸着的「你」会被模型读成指它自己，可能答出
# 「我住在宝山」这种串主体的话。所以拼装时必须带上这句消歧说明——它是让存储层
# 统一用第二人称、而消费方不必逐个改写的唯一一处闸门。
#
# 别把这句删成"看起来多余的一行"：删掉不会报错，只会让模型偶尔认领用户的人生。
#
# ⚠️ 它必须落在**第二行**，不能并进第一行。两个消费方
# （utils/retrieval/agent_prompt.py 的 build_system_prompt、utils/llm/chat.py 的
# _get_qa_rag_prompt）会用 split('\n')[1:] 砍掉第一行来去掉 "you already know..."
# 抬头——那是有意的（它们自己带抬头）。说明写进第一行就会被这两条路径一起砍掉，
# 而 chat agent 恰恰是最需要它的地方。test_memory_facts_second_person.py 钉住了这点。
_SECOND_PERSON_NOTE = (
    'In the facts below, "you" / "your" always refers to {user_name} (the user), '
    'never to you the assistant.'
)


def get_prompt_memories(uid: str) -> str:
    user_name, user_made_memories, generated_memories = get_prompt_data(uid)
    note = _SECOND_PERSON_NOTE.format(user_name=user_name)
    memories_str = (
        f'you already know the following facts about {user_name}: \n'
        f'{note}\n'
        f'{Memory.get_memories_as_str(generated_memories)}.'
    )
    if user_made_memories:
        memories_str += (
            f'\n\n{user_name} also shared the following about self: \n{Memory.get_memories_as_str(user_made_memories)}'
        )
    return user_name, memories_str + '\n'


def safe_create_memory(memory_data):
    """Safely create a Memory instance handling legacy categories"""
    try:
        return Memory(**memory_data)
    except Exception as e:
        # Handle legacy category conversion if needed
        if 'category' in memory_data and isinstance(memory_data['category'], str):
            # Make a copy to avoid modifying the original data
            fixed_data = dict(memory_data)
            # Set a default/fallback category if the category is causing issues
            if 'category' in str(e):
                # Use a safe default category
                if memory_data['category'] in [
                    'core',
                    'hobbies',
                    'lifestyle',
                    'interests',
                    'work',
                    'skills',
                    'learnings',
                ]:
                    fixed_data['category'] = 'interesting'
                else:
                    fixed_data['category'] = 'system'
                return Memory(**fixed_data)
        # If we couldn't fix it, re-raise the exception
        raise


def get_prompt_data(uid: str) -> Tuple[str, List[Memory], List[Memory]]:
    from utils.people import get_platform_developer_id
    developer_id = get_platform_developer_id()
    existing_memories = dev_db.get_all_memories(developer_id, uid, limit=100) if developer_id else []

    # Use a safer approach to create Memory objects from existing memories
    user_made = []
    for memory in existing_memories:
        if memory.get('manually_added', False):
            try:
                user_made.append(safe_create_memory(memory))
            except Exception as e:
                print(f"Error creating memory from user-made memory: {e}")

    # Similarly for generated memories
    generated = []
    for memory in existing_memories:
        if not memory.get('manually_added', False):
            try:
                generated.append(safe_create_memory(memory))
            except Exception as e:
                print(f"Error creating memory from generated memory: {e}")

    # Prefer the name the user set in the app (developer path) over the Firebase
    # Auth display_name — the app writes `name` here, and Firebase often only
    # has an email-derived or empty display_name. Falls back to get_user_name's
    # 'The User' default, which is what the extraction prompt expects.
    user_name = None
    if developer_id:
        try:
            user_name = dev_db.get_user_name(developer_id, uid)
        except Exception as e:
            print(f"get_prompt_data: failed to load developer-path user name: {e}")
    if not user_name:
        user_name = get_user_name(uid)
    # print('get_prompt_data', user_name, len(user_made), len(generated))
    return user_name, user_made, generated
