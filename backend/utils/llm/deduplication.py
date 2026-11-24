"""事实与待办的语义判重：一次独立的 LLM 裁决。

## 为什么是独立的一次调用，而不是在提取 prompt 里多写一条规则

提取 prompt 早就写着 "Anything already known …, including rephrasings and
near-duplicates"，摘要 prompt 也写着 "Merge duplicates"。两条都不生效，而且有直接
证据（2026-08-17 在生产数据上量的）：

    #84 17:50:44  conv 0371fe66  你的孩子喜欢玩宝可梦卡牌游戏，经常和你一起对战。
    #89 17:53:43  conv 2fb302ea  你的孩子喜欢玩宝可梦游戏，经常和你一起进行宝可梦对战。
    #90 17:54:50  conv 7817920d  你的孩子喜欢吃宝可梦卡牌游戏，经常与你一起…
    #97 08-15     conv b4ac73cf  你的孩子非常喜欢宝可梦卡牌游戏，经常和你一起组建卡组…

三条来自三条不同对话、串行写入，间隔 3 分钟。`get_prompt_memories` 每次都重查
Firestore，所以 #89 提取时上下文里**必然**已经有 #84 —— 模型看着它又写了一遍。

失效的不是模型能力：把同一批 141 条事实交给同一代模型、只让它做判重这一件事，
它一次就找齐了全部 6 组重复。失效的是「在 200 行提取指令里顺带判一句重」——判重
在那份 prompt 里只是几十条 bullet 中的一条。所以这里把它拆成独立的一步。

## 为什么不能用字面相似度（那层已经存在，且从未生效）

`memories._filter_profile_facts` 有一道字符 3-gram Jaccard ≥ 0.8 的近似判重。实测
对上面 12 对真重复命中 **0/12**，等于从未生效。而且**没法靠降阈值救**：

    真重复对   min 0.015  median 0.279  max 0.500
    非重复对   「你有一个母亲」×「你有一个婆婆」 = 0.333   ← 高于 8 个真重复对

两个分布完全重叠，不存在任何可用的分界。这类句式模板重复（"你有一个X。"）正是降
阈值时第一批被误杀的真事实。所以那层只留逐字判重的作用，语义判断交给这里。

## 向量不能单独下判决，但正好用来复核 LLM 指认的那一对

同一批数据换 `gemini-embedding-001` 余弦（3072 维）：

    真重复对   min 0.851  median 0.956
    非重复对   「你有一个母亲」×「你有一个婆婆」 = 0.937   ← 高于 4 个真重复对

0.85 卡下去 12/12 命中，但带进 35 对误判。向量**作为召回**很好用（9870 对 → 47
对，筛掉 99.5%），作为判据不行。

所以分工是：**LLM 读全部已有事实做判决，向量只复核它指认的那一对**。这样不需要
向量索引、不需要持久化任何东西——每次判重只对「候选 + 模型点名的那几条」算
embedding，通常是 2 次。今天的量级（单用户可见事实 141 条）整批塞进一次 prompt 只
有几千 token；等单用户事实过千，把 `_MAX_EXISTING_FACTS` 换成向量召回即可，判决和
复核这两步都不用动。

## ⚠️ supersedes 的代价和 duplicate 完全不对称，两道门的高度必须不同

判错 duplicate 只是丢掉一条新候选；判错 supersedes 会**软删一条更丰富的真事实**。
2026-08-17 实测过一版只靠 prompt 的 supersedes：141 条里判出 9 条，其中 4 条是净
信息损失——

    #139「你的孩子小草玩宝可梦卡牌，但是还不认识卡牌上的字。」(25 字)
      取代 #97「…非常喜欢宝可梦卡牌游戏，经常和你一起组建卡组、对战和交流游戏策略。」(37 字)
    #74「你的硬件产品后端架构正在改进，计划从实时 STT 改为…」
      取代 #38「你正在开发一款面向海外市场的儿童硬件产品，计划 7 月众筹…」  ← 压根不是一件事

失败形态是模型把「同一个话题的后续进展」当成了「同一个事实的更好版本」。这个错
**只在 supersedes 方向致命**，所以两道门的阈值刻意不同（0.92 / 0.85），而且拿不到
向量时 supersedes 降级成保留、duplicate 照旧生效——后者不删任何已有数据。

阈值的来历（同一批 13 个样本）：正确取代组余弦 min 0.903，误判组 max 0.891。缝只
有 0.012 宽，卡在缝里就是过拟合，所以 supersedes 取 0.92 留出余量：代价是 #40／#44
这两个本该取代的退化成「都保留」（多一条重复），换来对未见数据的鲁棒。**这个方向
是刻意选的**——宁可让用户多看到一条相似的事实，也不要静默删掉他真实的记忆。

## 待办侧刻意**不跨对话**判重，这是数据逼出来的

实测某账号 384 条待办里 41 条冗余（11%），**13/18 组是同一条对话内部**就重复了；只有
5 组跨对话，而那 5 组全是同一场会议被 120s 静音切成两段、各提取一次。

跨对话比对试过，代价立刻显形。7 天窗口下丢弃 39 条，只有 10/36 命中金标，其余是
误杀：

    #101「与蓝池初级投资人按计划于下周一会谈」      ← 具体的人、具体的时间
    #249「持续在本地和云端进行无人机机械臂模型训练」
    #211「选择美西二区或美东一区作为服务器部署区域」

失败形态是：这类账号的待办本身高度模板化（"注册 AWS 账号"、"提供企业邮箱和域名"
在几个月里为不同客户各走一遍），把不同轮次的同类动作摆在一起，模型就把「同一种事」
读成了「同一件事」。

而事实侧那道向量护栏在这里**救不了场**——待办的真重复对余弦 min 0.798 / median
0.873，误杀条目与其最相似历史条目是 0.849~0.905，两个分布完全重叠。文本模板化正是
向量最无力的情形。

所以待办只做**组内判重**：收益的 72% 在那里，而误杀几乎全部来自跨对话。剩下 5 组的
正确修法不是判重，是别把一场会切成两段——那是切分问题，用判重去补只会把误杀带进来。

⚠️ **待办判重刻意不重写文案，只挑一条保留。** 让模型把「填表 / 注册账号 / 等指导」
三步合成一句，等于给它一个改写待办的授权 —— 而凭空编造待办是这个模块踩过的坑
（见 CLAUDE.md 待办门禁那一节：15141 字的转录里「核数」「预估」0 次命中）。挑选不
会产生新文本，编造就无从发生。
"""

import json
import math
from typing import Dict, List, Optional, Sequence, Tuple

from pydantic import BaseModel, Field

from .clients import coerce_llm_text_content, llm_medium
from .prompt_registry import get_prompt, resolve_llm, PromptSpec

# 复核门槛，见模块 docstring「两道门的高度必须不同」。
# supersedes 会软删已有事实，所以留足余量；duplicate 只丢弃新候选，取真重复对的下界。
_SUPERSEDE_MIN_COSINE = 0.92
_DUPLICATE_MIN_COSINE = 0.85

# 一次判决里最多带多少条已有事实。141 条（生产上最多的账号）约 5k token，塞得下；
# 设上限只是为了让 token 成本有个天花板，而不是判据的一部分。超出时取最近的。
_MAX_EXISTING_FACTS = 400

_MAX_ACTION_ITEMS_PER_CALL = 40


class FactVerdict(BaseModel):
    candidate: str = Field(description="The candidate label, e.g. 'C1'")
    verdict: str = Field(description="duplicate | supersedes | distinct")
    existing: List[str] = Field(default=[], description="Existing labels, e.g. ['E3']")
    reason: str = Field(default='')


class FactVerdicts(BaseModel):
    verdicts: List[FactVerdict] = Field(default=[])


class ActionItemVerdict(BaseModel):
    keep: str = Field(description="The label kept, e.g. 'C2'")
    drop: List[str] = Field(default=[], description="Labels folded into `keep`")
    reason: str = Field(default='')


class ActionItemVerdicts(BaseModel):
    groups: List[ActionItemVerdict] = Field(default=[])


# ─── Fact deduplication ───

_FACT_PROMPT = '''You are deduplicating a personal-profile fact list. Each fact is
one short sentence shown back to the user under "what it remembers about you".

You get EXISTING facts (already stored, labelled E1, E2, …) and CANDIDATE facts
(just extracted, labelled C1, C2, …). For every candidate, return exactly one
verdict:

- **duplicate** — the same thing is already stored, and the candidate adds no
  information. List the existing label(s) it duplicates.
- **supersedes** — the same thing is already stored, but the candidate is a
  strictly better version of it: more specific, more complete, or more current.
  List the existing label(s) it should replace.
- **distinct** — a different thing. Also the answer whenever you are unsure.

Judge whether it is **the same thing about the same subject**, not whether the
sentences look alike. Two rules do most of the work:

1. **A different person, object, time, or activity makes it distinct** — however
   similar the wording. "You have a mother." and "You have a mother-in-law." are
   two different people: distinct. "Your child likes pineapple." and "Your child
   dislikes carrots." are two different foods: distinct. "Your child is called
   Xiaocao." and "You have a daughter younger than Xiaocao." are two different
   children: distinct. Sharing a sentence template is not sharing a subject.

2. **Same subject and same claim ⇒ not distinct** — however differently worded.
   Near-synonyms for one activity, one hobby, or one problem do NOT make two
   facts: "Your child likes the Pokémon game and often battles with you." and
   "Your child likes the Pokémon card game and often battles with you." are the
   same pastime under two names — duplicate. "Your child likes the Pokémon card
   game and often battles with you." and "Your child loves the Pokémon card game,
   often builds decks with you, battles, and discusses strategy." are one fact
   where the second is fuller: supersedes. "Your child is about to start primary
   school. You moved here so they could attend a nearby school." and "Your child
   is about to start primary school, and you moved here so they could go to school
   nearby." are one fact with no added information: duplicate.

Two things that are *related* but separately true are distinct — a person's job
title and the company they work for, two different projects, two different
habits. Only fold a candidate in when the stored fact already tells you the
candidate's content.

When the candidate makes the **same claim** and only elaborates on it — more
detail about the same trait, the same relationship, the same product, the same
shortcoming — that is **supersedes**, not distinct: extra adjectives, examples, or
consequences describing one claim are not a second fact. "The emotion-recognition
feature in the app you're building is shallow and inaccurate." and "The
emotion-recognition feature in the AI companion app you're building is inaccurate
and lacks detail — you can't see which period produced which emotion." are one
complaint about one feature: supersedes. Reserve **distinct** for a candidate
whose new content would still be worth stating on its own once the stored fact is
already known.

Return one verdict per candidate, referring to labels exactly as given.

EXISTING FACTS:
{{existing_block}}

CANDIDATE FACTS:
{{candidate_block}}

{{format_instructions}}'''


def _label_block(items: Sequence[str], prefix: str) -> str:
    if not items:
        return '(none)'
    return '\n'.join(f'{prefix}{i + 1}. {t}' for i, t in enumerate(items))


def _parse_json_object(raw: str) -> Optional[dict]:
    """宽松解析：模型偶尔用 ```json 包一层，或在 JSON 前后带一句话。"""
    if not raw:
        return None
    text = raw.strip()
    if text.startswith('```'):
        text = text.split('\n', 1)[-1].rsplit('```', 1)[0].strip()
        text = text.removeprefix('json').strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    start, end = text.find('{'), text.rfind('}')
    if start != -1 and end > start:
        try:
            return json.loads(text[start : end + 1])
        except Exception:
            return None
    return None


class FactDedupeResult:
    """判重结果。

    `kept` 是应当写入的候选（原始下标），`superseded_ids` 是应当软删的已有事实 id。
    两者一起返回而不是就地写库：写入方（`extract_memories_from_segments` /
    `_extract_memories_developer`）才知道 developer_id 和该往哪写。
    """

    def __init__(self, kept_indexes: List[int], superseded_ids: List[str], notes: List[str]):
        self.kept_indexes = kept_indexes
        self.superseded_ids = superseded_ids
        self.notes = notes


def resolve_fact_duplicates(
    candidate_contents: Sequence[str],
    existing: Sequence[dict],
) -> FactDedupeResult:
    """判定候选事实里哪些是已有事实的重复 / 更好版本。

    `existing` 是 `[{'id': ..., 'content': ...}]`（`dev_db.get_all_memories` 的形状）。

    **fail-open**：任何异常都退化成「全部保留、不软删任何东西」。判重是质量改进，
    不是安全门禁——判重挂掉的代价是多一条重复，而 fail-closed 的代价是丢掉真事实。
    """
    if not candidate_contents:
        return FactDedupeResult([], [], [])

    existing = [e for e in existing if (e.get('content') or '').strip()][:_MAX_EXISTING_FACTS]
    if not existing:
        return FactDedupeResult(list(range(len(candidate_contents))), [], [])

    try:
        resolved = get_prompt(
            'memories.dedupe',
            fallback=PromptSpec(content=_FACT_PROMPT),
        )
        llm = resolve_llm(resolved, llm_medium)
        prompt = resolved.render(
            existing_block=_label_block([e['content'].strip() for e in existing], 'E'),
            candidate_block=_label_block([c.strip() for c in candidate_contents], 'C'),
            format_instructions=(
                'Respond with JSON only, no prose and no code fence:\n'
                '{"verdicts": [{"candidate": "C1", "verdict": "duplicate|supersedes|distinct", '
                '"existing": ["E3"], "reason": "one short clause"}]}'
            ),
        )
        data = _parse_json_object(coerce_llm_text_content(llm.invoke(prompt)))
        if not data:
            print('[dedupe] facts: unparseable response, keeping all candidates')
            return FactDedupeResult(list(range(len(candidate_contents))), [], [])

        parsed = FactVerdicts(**data)
    except Exception as e:
        print(f'[dedupe] facts: failed ({e}) — keeping all candidates')
        return FactDedupeResult(list(range(len(candidate_contents))), [], [])

    by_candidate = {}
    for v in parsed.verdicts:
        idx = _label_index(v.candidate, 'C', len(candidate_contents))
        if idx is not None:
            by_candidate[idx] = v

    # 先把待复核的 (候选, 目标) 对收齐，一次算完全部余弦——每条 embedding 都是一次
    # 网络往返，逐对去算会把这一步变成判重里最慢的部分。
    pending = []  # (candidate_index, verdict, target, pair_slot)
    pairs: List[Tuple[str, str]] = []
    for i, content in enumerate(candidate_contents):
        v = by_candidate.get(i)
        verdict = (v.verdict or '').strip().lower() if v else 'distinct'
        if verdict not in ('duplicate', 'supersedes'):
            continue
        targets = _resolve_existing(v.existing, existing)
        # 「说是重复但指不出重复了哪一条」不足以丢掉一条事实——那更像是模型没答
        # 完整，而不是真判重。要求它指认，是这个裁决唯一可核对的部分。
        if not targets:
            print(f'[dedupe] facts: {verdict} without a target, keeping: {content[:60]}')
            continue
        for t in targets:
            pending.append((i, verdict, t, len(pairs)))
            pairs.append((content.strip(), t['content'].strip()))

    sims = _pair_similarities(pairs)

    kept, superseded, notes = [], [], []
    dropped = set()
    # duplicate 先判：一个被丢弃的候选不该再去软删它「取代」的东西——它压根没进库。
    # 模型偶尔会对同一个候选同时给出两种关系，两轮处理让那种情形有确定的结果。
    for i, verdict, target, slot in sorted(pending, key=lambda p: p[1] != 'duplicate'):
        if i in dropped:
            continue
        sim = None if sims is None else sims.get(slot)
        floor = _SUPERSEDE_MIN_COSINE if verdict == 'supersedes' else _DUPLICATE_MIN_COSINE
        shown = f'{sim:.3f}' if sim is not None else 'n/a'

        if sim is None:
            # 向量不可用：duplicate 照旧生效（只丢新候选，不动已有数据），supersedes
            # 降级成「都保留」——没有复核就不允许删已有事实。
            if verdict == 'supersedes':
                print(
                    '[dedupe] facts: no similarity check, keeping both instead of superseding: '
                    f'{candidate_contents[i][:60]}'
                )
                continue
        elif sim < floor:
            print(
                f'[dedupe] facts: {verdict} rejected by similarity {shown} < {floor}: '
                f'{candidate_contents[i][:50]} ⟂ {target["content"][:50]}'
            )
            continue

        if verdict == 'duplicate':
            dropped.add(i)
            notes.append(f'duplicate ({shown}) of {target["content"][:40]}: {candidate_contents[i][:40]}')
        else:
            if target.get('id'):
                superseded.append(target['id'])
            notes.append(f'supersedes ({shown}) {target["content"][:40]}: {candidate_contents[i][:40]}')

    for i in range(len(candidate_contents)):
        if i not in dropped:
            kept.append(i)

    superseded = list(dict.fromkeys(superseded))
    for n in notes:
        print(f'[dedupe] facts: {n}')
    return FactDedupeResult(kept, superseded, notes)


def _cosine(a: Sequence[float], b: Sequence[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na and nb else 0.0


def _pair_similarities(pairs: Sequence[Tuple[str, str]]) -> Optional[Dict[int, float]]:
    """算每一对 (候选, 已有事实) 的余弦。

    只 embed 模型点名的那几条，不是整个事实列表——这是这道复核便宜的原因。
    返回 None 表示 embedding 不可用，由调用方决定怎么降级（见 docstring）。
    """
    if not pairs:
        return {}
    try:
        from .embeddings import generate_embeddings_documents

        texts: List[str] = []
        for left, right in pairs:
            texts.extend([left, right])
        vectors = [list(v) for v in generate_embeddings_documents(texts)]
        if len(vectors) != len(texts):
            print('[dedupe] similarity check: unexpected vector count, treating as unavailable')
            return None
        return {i: _cosine(vectors[2 * i], vectors[2 * i + 1]) for i in range(len(pairs))}
    except Exception as e:
        print(f'[dedupe] similarity check unavailable ({e})')
        return None


def _label_index(label: Optional[str], prefix: str, count: int) -> Optional[int]:
    """'C2' → 1。模型偶尔回 'c2' 或 '2'，都接受。"""
    if not label:
        return None
    s = str(label).strip().upper().removeprefix(prefix.upper()).strip().rstrip('.')
    if not s.isdigit():
        return None
    n = int(s)
    return n - 1 if 1 <= n <= count else None


def _resolve_existing(labels: Sequence[str], existing: Sequence[dict]) -> List[dict]:
    out = []
    for lab in labels or []:
        idx = _label_index(lab, 'E', len(existing))
        if idx is not None:
            out.append(existing[idx])
    return out


# ─── Action-item deduplication ───

_ACTION_ITEM_PROMPT = '''You are deduplicating the to-do items extracted from ONE
conversation. Each entry is a commitment the user made, shown to them under "what
you promised to do".

The entries are labelled C1, C2, … Group entries that are **the same commitment**
— the user would be annoyed to see them as two separate rows.

Group them only when **doing one of them means the other is done too.** That is
the whole test. Apply it literally: imagine the user has just finished C1 and is
looking at C2. Is there still something left to do? If yes, they are not one
commitment.

Group these:
- Same commitment reworded, or described from the other party's side. "The cloud
  provider will introduce the e-commerce advisory team for Japan/Korea category
  advice." and "The partner will refer the product team to their e-commerce
  colleagues to get Japan and Korea market advice." are one referral.
- The same commitment stated once broadly and once specifically, where the broad
  one contains nothing extra to do.

Do NOT group these — this is where the mistakes happen:
- **Separate steps of one process.** "Fill in the AWS credit application form.",
  "Register the enterprise account using the company's main domain." and "Wait for
  AWS's guidance to finish registration." are three things done separately: leave
  all three. A shared goal is not a shared commitment.
- **Two instances of the same kind of action.** "Add the Sequoia contact on
  WeChat and set up a call." and "Meet the Lanchi junior investor next Monday."
  are the same *kind* of task for two different people: leave both. Same for the
  same paperwork done for two different clients or accounts.
- **Different deliverables in one area.** "Register the cloud account with the
  company domain." and "Pick us-west-2 or us-east-1 and finish the configuration."
  both concern the same cloud setup, but neither one gets done by doing the other:
  leave both.
- Different deadlines, different people, or different deliverables ⇒ never one
  commitment.

For each group, pick the ONE entry to keep and list the others as dropped. Prefer
the entry that describes what the USER does over one written from the other
party's side, then the one that is most specific and actionable.

**Do not write new text.** Only choose among the entries given. Never merge two
descriptions into a new sentence, and never reword the one you keep.

Leave anything you are unsure about ungrouped — an ungrouped duplicate costs the
user one extra row, a wrong group loses a promise they made. Most conversations
have no duplicates at all; returning an empty list is the normal answer. Entries
with no duplicate must not appear in the output.

TO-DO ITEMS FROM THIS CONVERSATION:
{{candidate_block}}

{{format_instructions}}'''


_PAIR_CONFIRM_PROMPT = '''Two to-do items from one conversation. Decide whether they
are ONE commitment or TWO.

Test: suppose the user has just finished A. Look at B. Is there still anything left
for them to do? If yes, they are TWO commitments.

A: {{a}}
B: {{b}}

Two separate steps of the same process are TWO commitments. The same action done
for two different people, clients or accounts is TWO commitments. Only answer ONE
when finishing either one leaves nothing of the other undone — i.e. they are the
same act described twice.

Answer with exactly one word: ONE or TWO.'''


def _confirm_same_commitment(dropped: str, kept: str) -> bool:
    """逐对复核：只有确认「做完一个另一个就不剩事」才允许真删。

    为什么要第二次调用——第一次那个分组调用**系统性地**把「同一话题下的多个条目」
    压成一条，prompt 里明令禁止也拦不住。实测（2026-08-17，那个 384 条待办的账号）
    分组阶段丢的 20 条里 13 条是误杀，形态包括：

        「下周测试 cloud 接口和输出限制功能」被并进「10 月完成 agent 版本并发布」
        「各位创业者分享每月 AI 订阅消费」被并进「在不同城市举行线下社区活动」

    换成逐对提问后，同一个模型对这 15 个误杀对 **15/15 判 TWO**，而对真重复只
    3/5 判 ONE。这个不对称正是要的：漏一条重复的代价是用户多看到一行，删错一条的
    代价是他答应过的事凭空消失。

    fail-closed：任何异常都当作「不是同一件事」，也就是不删。
    """
    try:
        resolved = get_prompt(
            'conversation.action_items_dedupe_confirm',
            fallback=PromptSpec(content=_PAIR_CONFIRM_PROMPT),
        )
        llm = resolve_llm(resolved, llm_medium)
        answer = coerce_llm_text_content(
            llm.invoke(resolved.render(a=dropped, b=kept))
        ).strip().upper()
    except Exception as e:
        print(f'[dedupe] action items: pair check failed ({e}) — keeping both')
        return False

    # 只认干净的 ONE。模型偶尔回一整句，"ONE" 出现在解释里也算——但 TWO 优先，
    # 因为「保留」是安全方向。
    if 'TWO' in answer:
        print(f'[dedupe] action items: pair check says TWO, keeping: {dropped[:60]}')
        return False
    if 'ONE' in answer:
        return True
    print(f'[dedupe] action items: unclear pair check {answer[:30]!r} — keeping both')
    return False


def resolve_action_item_duplicates(candidate_descriptions: Sequence[str]) -> List[int]:
    """返回同一条对话里**应当丢弃**的待办下标。

    ⚠️ **只在一条对话内部判重，刻意不接受历史待办。** 理由和实测代价见模块 docstring
    「待办侧刻意不跨对话判重」那一节——跨对话比对贡献 5/18 的收益，却带来几乎全部
    误杀。这个函数没有 `existing` 参数不是漏了，是结论。

    fail-open：异常一律返回空列表（不丢任何东西）。
    """
    candidates = [(d or '').strip() for d in candidate_descriptions]
    # 一条待办不可能跟自己重复。绝大多数对话都落在这里，省掉一次 LLM 调用。
    if len(candidates) < 2 or len(candidates) > _MAX_ACTION_ITEMS_PER_CALL:
        return []
    if any(not c for c in candidates):
        return []

    try:
        resolved = get_prompt(
            'conversation.action_items_dedupe',
            fallback=PromptSpec(content=_ACTION_ITEM_PROMPT),
        )
        llm = resolve_llm(resolved, llm_medium)
        prompt = resolved.render(
            candidate_block=_label_block(candidates, 'C'),
            format_instructions=(
                'Respond with JSON only, no prose and no code fence:\n'
                '{"groups": [{"keep": "C2", "drop": ["C1", "C3"], '
                '"reason": "one short clause"}]}'
            ),
        )
        data = _parse_json_object(coerce_llm_text_content(llm.invoke(prompt)))
        if not data:
            print('[dedupe] action items: unparseable response, keeping all')
            return []
        parsed = ActionItemVerdicts(**data)
    except Exception as e:
        print(f'[dedupe] action items: failed ({e}) — keeping all')
        return []

    proposed = []  # (drop_index, keep_index)
    for g in parsed.groups:
        keep = _label_index(g.keep, 'C', len(candidates))
        # 保留项必须能解析出来，否则整组不处理：「keep 打错了」会让一组里每一条都
        # 被丢掉，那件事就彻底消失了。
        if keep is None:
            print(f'[dedupe] action items: unresolvable keep={g.keep!r}, skipping group')
            continue
        for lab in g.drop or []:
            idx = _label_index(lab, 'C', len(candidates))
            if idx is not None and idx != keep:
                proposed.append((idx, keep))

    drop = {
        i
        for i, keep in proposed
        if _confirm_same_commitment(candidates[i], candidates[keep])
    }

    # 兜底不变式：不能把一条对话的待办丢空。真发生时说明模型把整个流程的几个步骤
    # 当成了一件事——那正是上面 prompt 明令禁止的形态，此时按原样全留更安全。
    if drop and len(drop) >= len(candidates):
        print('[dedupe] action items: refused to drop every item, keeping all')
        return []

    for idx in sorted(drop):
        print(f'[dedupe] action items: dropped duplicate: {candidates[idx][:60]}')
    return sorted(drop)
