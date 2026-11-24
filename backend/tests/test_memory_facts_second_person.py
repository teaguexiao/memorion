"""「它记住的事实」必须用第二人称，且喂给 LLM 时必须带消歧说明。

背景（2026-08-09）：事实正文原本是第三人称（"Teague 住在宝山"），而「关于我」页里
同屏的「你答应过的事」「洞察」都是第二人称——一屏之内两种人称，事实那一栏读起来像
别人写的旁观笔记。改成 "你住在宝山"。

这个测试钉两件事，它们**方向相反**，很容易只顾一头：

1. **提取 prompt 要求第二人称**，而且例句本身也得是第二人称——例句是模型最直接的
   模仿对象，留着 "{user_name} lives in Baoshan" 就等于一边下令一边示范违令。

2. **喂给 LLM 的那份必须带消歧说明。** 同一份事实文本会进 chat agent 的
   `{{user_facts}}`、每日一刻、洞察、EIR 的 system prompt。在那个位置裸着的「你」
   会被模型读成指它自己，答出「我住在宝山」这类串主体的话。消歧说明是唯一的闸门。

   ⚠️ 而且说明**不能写在第一行**：`agent_prompt.build_system_prompt` 和
   `chat._get_qa_rag_prompt` 都用 `split('\n')[1:]` 砍掉第一行的 "you already
   know..." 抬头（它们自己带抬头）。写进第一行会被这两条路径一起砍掉，而 chat agent
   恰恰是最需要它的地方。这个坑不会报错，只会静默失效，所以这里显式模拟那两次切片。

用源码级断言而不是真跑 LLM：这里要钉的是「prompt 里有没有这条指令」和「拼装位置对不
对」，都是确定性的。提取质量本身靠 scripts/eval_memories_extract.py 人工过一遍。
"""

import hashlib
import os
import re
import sys
import types
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _stub_database_client() -> None:
    """打桩 database._client，让本测试不碰 Firestore、不碰 GCP 凭证。

    为什么必须打桩：`models.memories` 只为了一个纯函数（document_id_from_seed）就
    import `database._client`，而后者在 import 期就 load_dotenv() + 初始化两个
    Firestore client。而 `.env` 里的 GOOGLE_APPLICATION_CREDENTIALS 指向生产机路径
    `/home/ubuntu/...`（见 CLAUDE.md 的 .env 陷阱），本地 import 直接 OSError。

    这里要测的只是「拼装出来的字符串长什么样」，与取数和凭证无关，所以插一个假模块
    比配环境更诚实——否则这个测试会因为环境而红，变成噪音而不是回归信号。

    只替换 `_client` 这一个子模块，`database` 包本身仍要真 import：同一条链路上的
    `utils.llms.memory` 还要 `import database.developer_data`，把 database 整个换成
    空壳（__path__ = []）会让它变成 ModuleNotFoundError。
    """
    if 'database._client' in sys.modules:
        return
    import database  # 真包，保留它的 __path__

    stub = types.ModuleType('database._client')
    stub.document_id_from_seed = lambda seed: hashlib.sha256(seed.encode()).hexdigest()[:20]
    # database.developer_data 也从这里取 `db` / `fcm_db`。给 None：本测试打桩掉了
    # get_prompt_data，任何真的取数都会 AttributeError 而不是静默连上生产库。
    stub.db = None
    stub.fcm_db = None
    sys.modules['database._client'] = stub
    database._client = stub


sys.path.insert(0, BACKEND_DIR)
_stub_database_client()


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return f.read()


class TestExtractionPromptUsesSecondPerson(unittest.TestCase):
    """utils/prompts.py 的提取 prompt（代码 fallback）。"""

    @classmethod
    def setUpClass(cls):
        from utils.prompts import extract_memories_prompt_text

        cls.prompt = extract_memories_prompt_text

    def test_output_rules_demand_second_person(self):
        self.assertIn('SECOND PERSON', self.prompt)
        self.assertIn('"you" / "your"', self.prompt)

    def test_output_rules_forbid_starting_with_the_name(self):
        """光说"用第二人称"不够——旧规则明写着「starting with {user_name}」，必须撤掉。"""
        self.assertNotIn('starting with {user_name}', self.prompt)
        self.assertIn("Do NOT start the sentence with {user_name}'s name", self.prompt)

    def test_forbids_the_user_phrasing_too(self):
        """存量里大量条目是 "The user ..."，这也是第三人称，要一起挡掉。"""
        self.assertIn('never "The user lives', self.prompt)

    def test_whitelist_examples_are_second_person(self):
        """六类白名单的例句是模型最直接的模仿对象，必须已经是第二人称。

        ⚠️ 只能取**白名单小节**里的 `e.g.`。禁止清单（NEVER extract these）同样用
        `e.g.` 举例，而那些例句本来就该是第三人称——它们是"不是用户画像"的反面教材。
        整篇抓 `e.g.` 会把 "AWS certificates are free and auto-renew" 也判成违规。
        """
        start = self.prompt.index('## ONLY these six kinds of facts')
        end = self.prompt.index('## NEVER extract these')
        whitelist = self.prompt[start:end]

        examples = re.findall(r'e\.g\. "([^"]+)"', whitelist)
        self.assertEqual(len(examples), 6, f'白名单应有 6 条例句，实际 {len(examples)}：{examples}')
        for ex in examples:
            self.assertNotIn(
                '{user_name}', ex, f'白名单例句仍是第三人称（含 {{user_name}}）：{ex}'
            )
            self.assertRegex(ex, r'^(You|Your)\b', f'白名单例句不是第二人称开头：{ex}')

    def test_judgement_context_still_names_the_user(self):
        """反向保险：判定语境（"这是谁的事"）必须仍然指名，不能被一把换成"你"。

        自检第 1 问要区分「用户本人 / 家人」和「同事 / 客户 / 公众人物」——这个判断
        需要一个具体的人名做锚点。把 {user_name} 全局替换成 "you" 会让模型失去
        判断依据，把同事的事也算成用户画像。
        """
        self.assertIn('Whose life is this about?', self.prompt)
        self.assertIn('{user_name}', self.prompt)
        self.assertGreater(
            self.prompt.count('{user_name}'),
            5,
            '判定语境里的 {user_name} 被换掉太多，"这是谁的事"会失去锚点',
        )

    def test_reject_examples_stay_third_person(self):
        """别人的事必须仍以第三人称示范——那正是"不是用户画像"的样子。"""
        self.assertIn('"Kevin is now a Product Manager for Genetic AI"', self.prompt)
        self.assertIn('"The client migrated to microservices"', self.prompt)


class TestTextExtractionPromptUsesSecondPerson(unittest.TestCase):
    """外部集成文本走的是同一个展示列表，人称必须一致。"""

    def test_from_text_prompt_demands_second_person(self):
        from utils.prompts import extract_memories_text_content_prompt_text as prompt

        self.assertIn('Second Person', prompt)
        self.assertIn('“You live in Paris.”', prompt)
        self.assertNotIn('e.g. “{user_name} lives in Paris.”', prompt)


class TestOutputLanguageInstructionKeepsSecondPerson(unittest.TestCase):
    """非英文路径的语言指令必须重申第二人称。

    这是实测出来的坑，不是理论风险：2026-08-09 只改 prompt 主体时，英文路径 6/6 输出
    "You have a young daughter..."，而 zh 路径 0/3 —— 输出的是「Teague 有一个年幼的
    女儿」。语言指令拼在 prompt 最末尾（覆盖力最强），只讲"用中文写"，模型换语言时把
    人称约束一起丢了。

    这类失效是静默的：事实照样生成、语言也对，只有人称退回第三人称，没有任何报错。
    """

    def _build(self, lang):
        from utils.llm.memories import _build_output_language_instruction

        return _build_output_language_instruction(lang)

    def test_specific_language_reminds_second_person(self):
        for lang in ('zh', 'zh-CN', 'ja', 'es'):
            with self.subTest(lang=lang):
                text = self._build(lang)
                self.assertTrue(text, f'{lang} 应该有语言指令')
                self.assertIn('second person', text.lower(), f'{lang} 的语言指令没重申第二人称')

    def test_unspecified_language_reminds_second_person(self):
        """'auto' / 'multi' 走的是另一条分支，同样会覆盖人称约束。"""
        for lang in ('auto', 'multi'):
            with self.subTest(lang=lang):
                text = self._build(lang)
                self.assertTrue(text, f'{lang} 应该有语言指令')
                self.assertIn('second person', text.lower(), f'{lang} 的语言指令没重申第二人称')

    def test_english_stays_empty(self):
        """英文不需要额外指令：prompt 主体就是英文，Output rules 没被覆盖。

        钉住这点是为了不让人"为了对称"给英文也加一句 —— 那会白占 prompt 长度，
        而且英文分支返回空串是 _build_output_language_instruction 的既有契约。
        """
        for lang in ('en', 'en-US', None, ''):
            with self.subTest(lang=lang):
                self.assertEqual(self._build(lang), '')


class TestSeedPromptMatchesCodeFallback(unittest.TestCase):
    """seed json 是 dashboard 的展示源，落后了会让人对着旧版调 prompt。"""

    def test_seed_content_matches_code_fallback(self):
        import json

        from utils.prompts import (
            extract_memories_prompt_text,
            extract_memories_text_content_prompt_text,
        )

        path = os.path.join(BACKEND_DIR, 'scripts/benchmark/seed_prompts/conversation_memories.json')
        with open(path, encoding='utf-8') as f:
            entries = {e['key']: e for e in json.load(f)}

        expected = {
            'memories.extract': extract_memories_prompt_text,
            'memories.extract_from_text': extract_memories_text_content_prompt_text,
        }
        for key, code_text in expected.items():
            self.assertIn(key, entries, f'seed json 缺 {key}')
            # 代码 fallback 用单花括号，注册表用 moustache 双花括号。
            moustache = re.sub(r'\{(\w+)\}', r'{{\1}}', code_text)
            self.assertEqual(
                entries[key]['content'].strip(),
                moustache.strip(),
                f'{key} 的 seed 内容与代码 fallback 不一致，改完 prompt 别忘了同步 seed',
            )


class TestPromptMemoriesDisambiguation(unittest.TestCase):
    """get_prompt_memories 拼装：消歧说明存在，且位置能活过两处 [1:] 切片。"""

    HEADER = 'you already know the following facts about'
    NOTE_MARK = 'never to you the assistant'

    def _build(self, user_name='Teague', facts=('You live in Baoshan, Shanghai.',), user_made=()):
        """绕开 Firestore：只测拼装逻辑，不测取数。

        patch 的是已导入模块的属性，而不是 mock.patch('utils.llms.memory....') 字符串
        路径——`utils.llms` 是普通 package，字符串形式会先 getattr 拿 `memory` 子模块，
        在它还没被 import 时抛 AttributeError。
        """
        from unittest import mock

        import utils.llms.memory as memory_mod
        from models.memories import Memory, MemoryCategory

        generated = [Memory(content=c, category=MemoryCategory.system) for c in facts]
        made = [Memory(content=c, category=MemoryCategory.interesting) for c in user_made]
        with mock.patch.object(
            memory_mod, 'get_prompt_data', return_value=(user_name, made, generated)
        ):
            return memory_mod.get_prompt_memories('uid-under-test')

    def test_note_present_and_names_the_user(self):
        name, memories_str = self._build()
        self.assertIn(self.NOTE_MARK, memories_str)
        self.assertIn(f'"you" / "your" always refers to {name}', memories_str)

    def test_note_survives_first_line_strip(self):
        """两个消费方都砍第一行去掉抬头；说明必须落在第二行才活得下来。"""
        _, memories_str = self._build()
        first_line = memories_str.split('\n')[0]
        self.assertIn(self.HEADER, first_line, '第一行应该还是抬头（消费方靠砍它去抬头）')
        self.assertNotIn(
            self.NOTE_MARK,
            first_line,
            '消歧说明写进了第一行 —— chat agent / qa_rag 的 split("\\n")[1:] 会把它一起砍掉',
        )

        stripped = '\n'.join(memories_str.split('\n')[1:]).strip()
        self.assertIn(self.NOTE_MARK, stripped, '砍掉第一行后消歧说明丢了')
        self.assertIn('You live in Baoshan, Shanghai.', stripped, '砍掉第一行后事实丢了')

    def test_facts_body_still_reaches_consumers(self):
        """手动添加的事实也要在（它们同样展示在「它记住的事实」里）。"""
        _, memories_str = self._build(
            facts=('You live in Baoshan, Shanghai.',), user_made=('You dislike cilantro.',)
        )
        self.assertIn('You dislike cilantro.', memories_str)


class TestChatAgentStripsOnlyTheHeader(unittest.TestCase):
    """钉住消费方的切片行为本身——它变了，上面那条位置约束就失效了。"""

    def test_agent_prompt_strips_first_line_only(self):
        src = _read('utils/retrieval/agent_prompt.py')
        self.assertIn('memories_str.split("\\n")[1:]', src)

    def test_qa_rag_strips_first_line_only(self):
        src = _read('utils/llm/chat.py')
        self.assertIn("memories_str.split('\\n')[1:]", src)


class TestRewriteScriptDetection(unittest.TestCase):
    """迁移脚本的人称探测（scripts/rewrite_memories_second_person.py）。

    它决定「哪些存量条目要送去改写」和「改写结果算不算改干净了」。判错的代价是
    不对称的：漏判 = 那条永远留着第三人称（静默）；误判 = 白花一次 LLM 调用。所以
    5 种真实存量形态都要钉住。
    """

    @classmethod
    def setUpClass(cls):
        import importlib.util

        path = os.path.join(BACKEND_DIR, 'scripts/rewrite_memories_second_person.py')
        spec = importlib.util.spec_from_file_location('_rewrite_second_person', path)
        cls.rw = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.rw)

    def test_detects_all_five_third_person_shapes(self):
        """存量实测存在的 5 种形态，一个都不能漏。"""
        cases = [
            ('Teague正在考虑在香港开公司。', 'Teague'),
            ('用户提到他们的孩子26个月大。', None),
            ('该用户目前在纽约生活和工作。', None),
            ('The User has a child named 刘子航.', None),
            ('【王】认为新疆是文化绿洲。', '【王】'),
        ]
        for content, name in cases:
            with self.subTest(content=content):
                self.assertTrue(
                    self.rw.is_third_person(content, name), f'漏判第三人称：{content}'
                )

    def test_detects_first_person(self):
        """手动添加的事实有第一人称（"I like running"），也要正规化。"""
        self.assertTrue(self.rw.is_third_person('I like running', None))

    def test_second_person_is_not_flagged(self):
        for content in (
            '你住在上海宝山。',
            'You have a young daughter who calls for you.',
            '你的孩子在学习拼音。',
        ):
            with self.subTest(content=content):
                self.assertFalse(self.rw.is_third_person(content, 'Teague'))

    def test_mixed_english_sentence_still_counts_as_third_person(self):
        """「your X」和「the user」混在一句里必须仍判第三人称，否则半改的句子会落库。

        英文刻意不做「用户」那样的两义放宽：产品的客户在英文里是 "users" /
        "your users"，单数定指的 "the user" 在存量 12 条里 100% 指画像主人。放宽它
        只会让改了一半的句子当成合格结果写回 Firestore——静默的数据污染。
        """
        self.assertTrue(
            self.rw.is_third_person("Your child plays with the user's laptop", 'Teague')
        )
        self.assertTrue(self.rw.is_third_person('You told the user about it', 'Teague'))

    def test_name_pattern_escapes_regex_metacharacters(self):
        """实测有个用户叫「【王】」；方括号在正则里是字符类，不 escape 会匹配错。"""
        pattern = self.rw._name_pattern('【王】')
        self.assertIsNotNone(pattern)
        self.assertTrue(pattern.search('【王】认为新疆是文化绿洲。'))
        self.assertFalse(pattern.search('王先生认为新疆是文化绿洲。'))

    def test_name_pattern_ignores_placeholder_names(self):
        """'The User' 是 get_user_name 的默认占位符，不是人名。

        当成人名去匹配会让 "The User has a child" 走名字分支而不是通用分支 —— 结果一样，
        但 'user' / '用户' 这种占位名会把任何含「用户」二字的句子都算成命中人名，
        判据就糊了。
        """
        for name in ('The User', 'user', '用户', '', None):
            with self.subTest(name=name):
                self.assertIsNone(self.rw._name_pattern(name))

    def test_product_users_are_not_the_profile_owner(self):
        """「用户」有两个所指：画像主人 vs **他产品的**用户。混判会让改写永远不合格。

        实测（2026-08-09 全量 dry-run）：224 条里 10 条卡在这上面——改写其实成功了，
        校验器却因为句中还有「用户」判定没改干净 → 重试 → 再失败 → 放弃并写回第三人称
        原文。做 to-C 产品的用户，事实里天然大量出现「吸引广泛用户」「用户体验」
        「付费用户」，正好全踩上。改对判据后成功率 214 → 224。
        """
        already_fine = [
            '你正在开发的硬件产品目标是做成人人都想用的日常记录工具，你希望通过免费模式吸引广泛用户。',
            '你是Claude的忠实用户，但最近切换到了Codex进行编程工作。',
            '你的AI伴侣应用面向宠物用户，主要在海外获得付费订阅用户，国内用户较少。',
            '你的海外儿童硬件产品目标用户年龄段为3到12岁。',
            '你认为国内市场竞争过度，企业通过堆砌功能、牺牲用户体验来压低价格。',
            '你倾向于采用非实时的交互设计方式来降低成本和管理你的用户预期。',
            '你计划举办交流会，向用户介绍核心功能，了解用户对产品场景的诉求。',
        ]
        for content in already_fine:
            with self.subTest(content=content[:30]):
                self.assertFalse(
                    self.rw.is_third_person(content, 'Teague'),
                    f'把产品的用户误判成画像主人：{content}',
                )

    def test_owner_as_bare_subject_is_still_caught(self):
        """反向：「用户」处在裸主语位置时一定指画像主人，不能因为上一条放宽而漏掉。"""
        for content in (
            '用户明天要去北京出差，下午两点到达大兴机场。',
            '用户正在开发一款可穿戴录音设备，目前在进行硬件设计和功能测试。',
            '该用户目前在纽约生活和工作。',
            '接班计划包括用户。',  # 主语不在句首，靠"整句无第二人称"这条兜住
            '中轶正在开发的硬件产品，希望通过免费模式吸引广泛用户。',  # 名字命中
        ):
            with self.subTest(content=content[:30]):
                self.assertTrue(self.rw.is_third_person(content, '中轶'), f'漏判：{content}')

    def test_half_rewritten_sentence_is_still_third_person(self):
        """改了一半的句子必须判 True，否则会当成合格结果落库。"""
        for content in (
            '你的孩子在学拼音，用户很高兴。',
            '用户的孩子在学拼音，你很高兴。',
        ):
            with self.subTest(content=content):
                self.assertTrue(self.rw.is_third_person(content, 'Teague'))

    def test_bare_sentences_are_not_third_person_but_not_second_either(self):
        """裸句（"Runs the riverside trail."）没有第三人称自称，但也不是第二人称。

        两个函数各判一半：is_third_person=False 且 looks_second_person=False，
        rewrite_user 里的 `not is_third_person and looks_second_person` 才会
        把它送去改写而不是当成已合格跳过。少一个条件就会漏掉这批。
        """
        bare = 'Runs the riverside trail to reset after a heavy week.'
        self.assertFalse(self.rw.is_third_person(bare, None))
        self.assertFalse(self.rw.looks_second_person(bare))

    def test_backup_field_is_distinct_from_translation_script(self):
        """留档字段不能和翻译脚本共用，否则两边的 --restore 会互相破坏。"""
        self.assertEqual(self.rw.BACKUP_FIELD, 'content_before_2nd_person')
        self.assertNotEqual(self.rw.BACKUP_FIELD, 'content_original')


if __name__ == '__main__':
    unittest.main()
