"""洞察引擎编排：事实层 → 提名者 → 怀疑者 → 账本 → 释放阀。

一次 run 的流程：
  1. 拉观察窗口内的对话，算出确定性事实清单（facts.py，无 LLM）
  2. 数据充分性闸门——不够就直接返回，绝不发空卡
  3. 提名者开放式提名（不设话题枚举）
  4. 账本去重：已说过/已否决的话题直接丢弃，不浪费怀疑者调用
  5. 怀疑者逐条对抗审核 → pass / reject / material / suppress
  6. 证据清洗（_sanitize_evidence，无 LLM）：拿事实层核对模型填的每条证据，
     溯源字段以池里的真值覆盖；清洗后没有证据的条目即使通过审核也强制降级
  7. 全部裁决结果落账本（包括被毙掉的，防止下轮反复提名同一件事）
  8. 释放阀从成熟池挑最多一张卡释放（疲劳窗口 + worth 决胜）
  9. 冷启动兜底：前几天没攒出真洞察时才发脚手架卡

这里没有"每周至少一张"的配额——见 valve.py 的说明。

卡片内部是两层门控（严格的 headline/body/evidence + 放松的 depth），
分层的理由见 models/insight.py 的模块说明。
"""

import logging
import re
import unicodedata
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional, Tuple

import database.developer_data as dev_db
from models.insight import InsightFeedback, InsightStatus
from utils.insights import facts as facts_mod
from utils.insights import valve as valve_mod
from utils.llm import insight_engine as llm_engine

logger = logging.getLogger(__name__)

DEFAULT_WINDOW_DAYS = 60

# 冷启动脚手架卡：只在前 COLD_START_DAYS 天且真洞察还没攒够时用
_SCAFFOLD = {
    'topic_key': 'first-days-scaffold',
    'headline': '我开始认识你了',
    'body': '这几天我一直在听。还不够我下什么结论，但已经能感觉到你的节奏了——再多陪我几天，我会告诉你我注意到了什么。',
}


# ANSI/VT 转义序列。模型偶尔会吐出终端控制码——生产上真出现过一条 skeptic_reason
# 存成了 ESC/NUL 混着乱码的一串（原文含真 NUL 字节，这里不照抄）。裁决本身解析正常所以没出卡，
# 但 reason 是事后复盘唯一的审计线索，被这么污染等于那条记录白记。
_ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]')

# 模型编造 conversation_id 时最爱填的占位词。这些值会让 App 跳进一个不存在的对话。
_BOGUS_IDS = {
    '未知', '无', '不明', '未提供', '无法确定', '略',
    'unknown', 'n/a', 'na', 'none', 'null', 'nil', '-', '?', '??',
}

# 怀疑者的改写稿（revised_headline / revised_body / revised_depth）不能无条件采纳。
# 生产实测两种坏形态，都会直接顶掉提名者写好的正文：
#   1. **元评论**——它不打算改写时填的不是 null，而是"这段话可以保持现有表述，因其
#      内容与复现型证据相符，措辞已较为克制。"于是卡片正文变成了对正文的评语。
#   2. **未写完的半句**——"讲技术方案或细节的时候，你其实经常停下来问一句"，断在
#      句子中间就落库了（2026-08-13 真出过一张 released 卡）。
# 两种都比"不改写"更糟，所以判据存疑就回退提名者原文。
_META_REVISION_RE = re.compile(
    r'这段话|该表述|原表述|现有表述|保持原|保留原|无需修改|不需(要)?修改|建议(保留|保持)|'
    r'措辞(已|较|尚)|符合.{0,8}证据|证据(充分|不足|相符)|(复现|统计|单次事件)型|'
    r'原文|裁决|该洞察|此洞察'
)

# 句末标点。正文/深读段必须以它们之一收尾，否则视为被截断。
_SENTENCE_END = '。！？…”"』」）)!?.~'

# 正文短于此长度就不像一段说给人听的话，多半是残句
_MIN_BODY_LEN = 25


def _pick_revised(revised: Any, original: Any, *, require_sentence_end: bool) -> str:
    """在怀疑者改写稿与提名者原文之间选一个，存疑就选原文。

    只在改写稿"看起来真的是一段成品文案"时才采纳。判据故意做得保守：漏采纳一次
    合理的收紧只是措辞没那么严谨，误采纳一次却会把卡片正文换成评语或半句话，而
    那是用户唯一会读的东西。

    Args:
        require_sentence_end: 标题不需要句末标点，正文与深读段需要。
    """
    probe = _clean(revised)  # 只用于判定；返回的仍是原始值，交给调用方按字段做清洗
    if not probe:
        return original or ''
    if _META_REVISION_RE.search(probe):
        return original or ''
    if require_sentence_end and (probe[-1] not in _SENTENCE_END or len(probe) < _MIN_BODY_LEN):
        return original or ''
    return revised


def _new_id() -> str:
    return f'insight_{uuid.uuid4().hex[:16]}'


def _strip_control(text: str) -> str:
    """剔掉 ANSI 转义与不可打印控制字符，保留正常文本与换行。"""
    text = _ANSI_RE.sub('', text)
    return ''.join(
        ch for ch in text
        if ch in '\n\t' or not unicodedata.category(ch).startswith('C')
    )


def _clean(value: Any) -> str:
    """折叠空白 + 剔控制字符。

    折叠空白是因为模型偶尔在文本字段尾部吐大段空行，会把卡片撑出一片空白；
    剔控制字符见 _ANSI_RE 的说明。
    """
    return ' '.join(_strip_control(str(value or '')).split())


def _clean_prose(value: Any) -> str:
    """深读段的清洗：同样剔控制字符，但**保留段内换行**。

    不能直接用 _clean——它会把整段压成一行。depth 是给人读的散文，模型有时会
    分成两三段，那个呼吸感是内容的一部分。这里只折叠每行内部的空白、去掉连续
    空行，并砍掉尾部空白。
    """
    lines = [' '.join(line.split()) for line in _strip_control(str(value or '')).split('\n')]
    out: List[str] = []
    for line in lines:
        if not line and (not out or not out[-1]):
            continue  # 连续空行只留一个
        out.append(line)
    return '\n'.join(out).strip()


def _norm_quote(text: str) -> str:
    """归一化到"能比对"的形态：去空白、去标点、统一大小写。

    模型引用原话时常做无害的微调（补句号、删语气词、全角改半角），逐字比对
    会把这些也判成伪造。只有在剥掉这些噪音后仍对不上，才算真的不在原话池里。
    """
    text = _strip_control(str(text or '')).lower()
    return ''.join(
        ch for ch in text
        if not ch.isspace() and not unicodedata.category(ch).startswith('P')
        and unicodedata.category(ch) != 'Sm'
    )


def _sanitize_evidence(
    evidence: List[Dict[str, Any]],
    quotes: List[Dict[str, Any]],
    digest: List[Dict[str, Any]],
) -> Tuple[List[Dict[str, Any]], List[str]]:
    """以事实层为准核对每条证据，返回 (清洗后的证据, 丢弃原因列表)。

    这一层存在的理由是**模型填的溯源字段不可信，而它们恰恰是用户会点的东西**。
    生产账本实测（82 条）：139 条原话证据里 5 条 conversation_id 是字面量"未知"、
    10 条为空；还有把对话摘要（我们生成的第三人称概述）当成用户原话引用的。
    prompt 里已经写了禁令，但禁令挡不住概率——所以真值以这里为准：

      1. `quote` 必须在原话池里找得到（归一化后互为子串），否则丢弃这条证据。
      2. 若 quote 反而命中了对话摘要，说明 digest 泄漏进了 quote 槽 —— 同样丢弃。
      3. 命中之后，`conversation_id` 和 `date` **一律用池里的真值覆盖模型填的**，
         而不是"校验后保留"。校验只能挡住明显的假值，覆盖才能同时修掉张冠李戴
         （引对了话但配错了对话 id）。
      4. 纯统计证据（只有 stat、没有 quote）不做原话核对，但 conversation_id
         必须是真实存在的 id，否则置空。
    """
    by_norm: Dict[str, Dict[str, Any]] = {}
    for q in quotes:
        norm = _norm_quote(q.get('text'))
        if norm:
            by_norm.setdefault(norm, q)

    digest_norms = {
        _norm_quote(f"{d.get('title') or ''}{d.get('overview') or ''}"): d
        for d in digest
    }
    digest_norms.pop('', None)

    known_ids = {str(q.get('conversation_id')) for q in quotes if q.get('conversation_id')}
    known_ids |= {str(d.get('conversation_id')) for d in digest if d.get('conversation_id')}

    kept: List[Dict[str, Any]] = []
    dropped: List[str] = []

    for raw in evidence or []:
        if not isinstance(raw, dict):
            continue
        quote = _clean(raw.get('quote'))
        stat = _clean(raw.get('stat'))
        cid = _clean(raw.get('conversation_id'))
        date = _clean(raw.get('date'))

        if cid.lower() in _BOGUS_IDS or cid not in known_ids:
            cid = ''

        if quote:
            norm = _norm_quote(quote)
            hit = by_norm.get(norm)
            if hit is None:
                # 子串匹配：模型常引用一句话的片段，或反过来把上下文一起带上
                for cand_norm, cand in by_norm.items():
                    if norm and (norm in cand_norm or cand_norm in norm):
                        hit = cand
                        break
            if hit is None:
                which = 'digest_leaked_into_quote' if any(
                    norm and (norm in dn or dn in norm) for dn in digest_norms
                ) else 'quote_not_in_transcript'
                dropped.append(f'{which}:{quote[:40]}')
                continue
            # 溯源字段以池里的真值为准
            cid = str(hit.get('conversation_id') or '')
            date = str(hit.get('date') or '')

        if not quote and not stat:
            continue

        kept.append({
            'quote': quote or None,
            'conversation_id': cid or None,
            'date': date or None,
            'stat': stat or None,
        })

    return kept, dropped


def _clean_depth(nomination: Dict[str, Any], verdict: Dict[str, Any]) -> Optional[str]:
    """按 depth_verdict 决定深读段的去留。

    刻意与主裁决解耦：depth 被 drop 只是少一段，卡片照出（见
    models/insight.py 的两层门控说明）。未知取值按 keep 处理——这一层的
    失败模式是"少一段散文"，不是"发出错的结论"，没有 fail-closed 的必要。
    """
    decision = str(verdict.get('depth_verdict') or 'keep').strip().lower()
    if decision == 'drop':
        return None
    if decision == 'revise' and verdict.get('revised_depth'):
        # 改写稿同样可能是元评论或半句话（见 _pick_revised），存疑就回退原文——
        # 这一层判了 revise 却拿不到可用改写时，宁可保留原段也不该静默变成 drop
        picked = _pick_revised(
            verdict['revised_depth'], nomination.get('depth'), require_sentence_end=True)
        return _clean_prose(picked) or None
    return _clean_prose(nomination.get('depth')) or None


def _verdict_to_status(verdict: str) -> str:
    return {
        'pass': InsightStatus.MATURE.value,
        'reject': InsightStatus.REJECTED.value,
        'material': InsightStatus.MATERIAL.value,
        'suppress': InsightStatus.SUPPRESSED.value,
    }.get(verdict, InsightStatus.REJECTED.value)


def run_insight_engine(
    developer_id: str,
    external_user_id: str,
    window_days: int = DEFAULT_WINDOW_DAYS,
    language_code: str = 'zh',
    dry_run: bool = False,
    now: Optional[datetime] = None,
    before_write: Optional[Callable[[], None]] = None,
    released_by_job: Optional[str] = None,
) -> Dict[str, Any]:
    """跑一轮洞察引擎。

    Args:
        dry_run: True 时不写账本、不释放卡片，只返回四个角色的中间产物
                 （给 benchmark / 人工审阅用）。
        before_write: 第一次写账本之前调用一次；它抛出的异常原样传出，此时什么都还没写。
                 队列里的任务用它确认租约还在（`utils/daily_journal_jobs/insight_processor.py`）。
        released_by_job: 写在释放的那张卡上，让这个任务重试时认得出「卡已经发过了」。

    Returns:
        {
          'released': InsightCard dict | None,   # 本轮真正该推的卡（可能没有）
          'nominations': [...],                  # 提名者原始产出
          'verdicts': [...],                     # 怀疑者逐条裁决
          'fact_sheet': {...},
          'skipped_reason': str | None,
        }
    """
    now = now or datetime.now(timezone.utc)
    start, end = facts_mod.default_window(window_days)

    conversations = dev_db.get_conversations(
        developer_id=developer_id,
        external_user_id=external_user_id,
        limit=1000,
        offset=0,
        statuses=['completed'],
        start_date=start,
        end_date=end,
        include_photos=False,
        include_discarded=False,
        include_transcript_segments=True,
    )

    tz_name = dev_db.get_user_timezone(developer_id, external_user_id)
    fact_sheet = facts_mod.build_fact_sheet(conversations, tz_name)

    first_at = dev_db.get_first_conversation_date(developer_id, external_user_id)
    companion_days = facts_mod.companion_days(first_at, now=now)

    ledger = dev_db.list_insights(developer_id, external_user_id, limit=200)
    known_topics = dev_db.get_known_topic_keys(developer_id, external_user_id)

    result: Dict[str, Any] = {
        'released': None,
        'nominations': [],
        'verdicts': [],
        'fact_sheet': fact_sheet,
        'companion_days': companion_days,
        'skipped_reason': None,
    }

    # 数据充分性闸门：装了但几乎没戴的用户，宁可不发也不发空卡
    if not facts_mod.has_enough_data(fact_sheet):
        result['skipped_reason'] = (
            f"insufficient_data(days={fact_sheet.get('days_with_data')},"
            f"convos={fact_sheet.get('conversation_count')})"
        )
        logger.info('[insight_engine] %s skipped: %s', external_user_id[:8], result['skipped_reason'])
        return result

    # 疲劳窗口闸门：今天本来就发不了卡，那就别花钱提名（2026-08-18）。
    #
    # 这个判断原来只埋在最后的 `pick_next` 里，于是顺序是「先花几分钟提名、再检查今天
    # 能不能发」。实测一次 dry run 跑满 **466 秒**、烧掉一整轮 LLM，返回的却是
    # `skipped_reason=fatigue_window`。窗口是 5 天 ⇒ 5 天里有 4 天的提名注定不会释放，
    # 而账本实测已积压 22~44 条成熟候选（按每 5~6 天释放一张算是半年以上的存货），
    # 也就是说那 4 天产出的不是「更多选择」，只是更长的队列。
    #
    # **前移零信息损失**：观察窗口是 60 天滑动，而提名间隔变成 5 天 —— 跳过的那几天产生
    # 的数据，下次提名时仍然落在窗口内、照样会被看到。省掉的是「对同一批数据重复提名
    # 5 次」，不是少看了什么。（同理，别为了省钱去缩 `WINDOW_DAYS`：那才是真的丢信息，
    # 提名 prompt 要靠跨多个日期的复现来立论。）
    #
    # ⚠️ 位置必须在 `has_enough_data` 之后、`collect_user_quotes`/`collect_conversation_digest`
    # 之前：那两步要遍历整个窗口的对话拼出十万量级的字符串（实测 quotes 66k + digest
    # 40k 字符），在窗口内同样是白干。
    # ⚠️ 不会误挡冷启动脚手架卡：`in_fatigue_window` 为真的前提是账本里**有** released 卡，
    # 而 `should_use_scaffold` 要求「从没发过卡」，两个条件互斥。
    if valve_mod.in_fatigue_window(ledger, now=now):
        result['skipped_reason'] = 'fatigue_window'
        logger.info('[insight_engine] %s skipped: fatigue_window', external_user_id[:8])
        return result

    quotes = facts_mod.collect_user_quotes(conversations, tz_name)
    digest = facts_mod.collect_conversation_digest(conversations, tz_name)

    nominations = llm_engine.nominate(
        fact_sheet=fact_sheet,
        quotes=quotes,
        digest=digest,
        known_topics=known_topics,
        companion_days=companion_days,
        language_code=language_code,
    )
    result['nominations'] = nominations

    if not nominations:
        result['skipped_reason'] = 'no_nominations'

    # 账本去重先行——省下怀疑者的 LLM 调用。
    # 同时防同批内重复：模型偶尔会用同一个 topic_key 提名两条近似洞察，
    # 若不拦会在账本里生成两条同话题记录，之后互相"撞车"占卡位。
    fresh: List[Dict[str, Any]] = []
    seen_in_batch = set()
    for nomination in nominations:
        topic = nomination.get('topic_key') or ''
        if valve_mod.is_duplicate(topic, known_topics) or topic in seen_in_batch:
            continue
        seen_in_batch.add(topic)
        fresh.append(nomination)

    duplicates = len(nominations) - len(fresh)
    if duplicates:
        logger.info('[insight_engine] %s dropped %d duplicate nominations', external_user_id[:8], duplicates)

    # 逐条审核是彼此独立的，并发跑。串行时耗时随提名数线性增长（实测 4 条约
    # 43s），提名上限是 8 条，会逼近 REST 的 120s 默认超时；并发后总耗时接近
    # 单次审核，不随提名数增长。
    def _judge_one(nomination: Dict[str, Any]) -> Dict[str, Any]:
        verdict = llm_engine.judge(nomination, fact_sheet, language_code=language_code)
        if not verdict:
            # 审核失败按"未通过"处理——宁可漏发，不可错发
            verdict = {
                'verdict': 'reject',
                'reason': 'skeptic_unavailable',
                'confidence_after': 0,
            }
        return verdict

    if fresh:
        with ThreadPoolExecutor(max_workers=min(len(fresh), 8)) as pool:
            verdicts = list(pool.map(_judge_one, fresh))
    else:
        verdicts = []

    # 到这里为止只读了数据、问了模型；下面开始写账本和释放的卡。被顶替的那一份任务必须停在
    # 这里：它写下的条目会和接班的那份重复，两份都释放还会发两次推送。
    if before_write and not dry_run:
        before_write()

    mature: List[Dict[str, Any]] = []
    for nomination, verdict in zip(fresh, verdicts):
        evidence, dropped = _sanitize_evidence(nomination.get('evidence') or [], quotes, digest)
        status = _verdict_to_status(verdict.get('verdict', 'reject'))
        skeptic_reason = _clean(verdict.get('reason'))[:400] or None

        if dropped:
            logger.info(
                '[insight_engine] %s topic=%s dropped %d unverifiable evidence: %s',
                external_user_id[:8], nomination.get('topic_key'), len(dropped), '; '.join(dropped),
            )

        # 通过审核但清洗后一条证据都不剩 → 强制降级。怀疑者看到的证据里可能就有
        # 那条伪造的原话，它是照着假证据放行的，所以不能相信这次 pass。
        if status == InsightStatus.MATURE.value and not evidence:
            status = InsightStatus.REJECTED.value
            skeptic_reason = f'evidence_unverifiable({len(dropped)} dropped): {skeptic_reason or ""}'[:400]
            logger.warning(
                '[insight_engine] %s topic=%s passed skeptic but has no verifiable evidence, demoted',
                external_user_id[:8], nomination.get('topic_key'),
            )

        entry = {
            'id': _new_id(),
            'topic_key': nomination.get('topic_key') or '',
            'headline': _clean(_pick_revised(
                verdict.get('revised_headline'), nomination.get('headline'),
                require_sentence_end=False)),
            'body': _clean(_pick_revised(
                verdict.get('revised_body'), nomination.get('body'),
                require_sentence_end=True)),
            'depth': _clean_depth(nomination, verdict),
            'evidence': evidence,
            'worth': nomination.get('worth', 0),
            'confidence': verdict.get('confidence_after', nomination.get('confidence', 0)),
            'status': status,
            'feedback': InsightFeedback.NONE.value,
            'window_start': fact_sheet.get('window_start'),
            'window_end': fact_sheet.get('window_end'),
            'companion_days': companion_days,
            'skeptic_reason': skeptic_reason,
            'is_scaffold': False,
            'released_at': None,
        }

        result['verdicts'].append({
            'topic_key': entry['topic_key'],
            'headline': entry['headline'],
            'verdict': verdict.get('verdict'),
            'reason': skeptic_reason,
            'worth': entry['worth'],
            'confidence': entry['confidence'],
            'depth_verdict': str(verdict.get('depth_verdict') or 'keep'),
            'evidence_dropped': len(dropped),
        })

        if not dry_run:
            dev_db.upsert_insight(developer_id, external_user_id, entry)

        if entry['status'] == InsightStatus.MATURE.value:
            mature.append(entry)

    # 之前轮次留下、还没释放的成熟条目也参与竞争（高 worth 的先出，其余不丢）
    carried = [
        row for row in ledger
        if row.get('status') == InsightStatus.MATURE.value
    ]

    # 同一 topic_key 可能在多轮里各留下一条成熟条目（两轮之间都没轮到释放），
    # 只保留 worth 最高的那条，避免同一件事占掉多个卡位。
    pool_by_topic: Dict[str, Dict[str, Any]] = {}
    for row in mature + carried:
        key = row.get('topic_key') or row.get('id') or ''
        current = pool_by_topic.get(key)
        if current is None or (row.get('worth', 0) > current.get('worth', 0)):
            pool_by_topic[key] = row
    pool = list(pool_by_topic.values())

    # 已释放过的话题绝不重复出卡（成熟池里的条目本身未释放，故只拦 released）
    released_topics = {
        row.get('topic_key'): 'released'
        for row in ledger
        if row.get('status') == InsightStatus.RELEASED.value and row.get('topic_key')
    }

    chosen = valve_mod.pick_next(pool, ledger, known_topics=released_topics, now=now)

    if chosen is None and valve_mod.should_use_scaffold(companion_days, ledger, bool(pool)):
        chosen = {
            'id': _new_id(),
            **_SCAFFOLD,
            # 脚手架卡刻意没有 depth：那一层是"从录音里看到一个什么样的人"，
            # 而此刻还没攒够录音——硬写一段就是编的，正是 depth 唯一的红线。
            'depth': None,
            'evidence': [],
            'worth': 50,
            'confidence': 100,
            'status': InsightStatus.MATURE.value,
            'feedback': InsightFeedback.NONE.value,
            'window_start': fact_sheet.get('window_start'),
            'window_end': fact_sheet.get('window_end'),
            'companion_days': companion_days,
            'skeptic_reason': 'cold_start_scaffold',
            'is_scaffold': True,
            'released_at': None,
        }

    if chosen is None:
        if not result['skipped_reason']:
            result['skipped_reason'] = (
                'fatigue_window' if valve_mod.in_fatigue_window(ledger, now=now) else 'nothing_worth_saying'
            )
        return result

    chosen = dict(chosen)
    chosen['status'] = InsightStatus.RELEASED.value
    chosen['released_at'] = now
    if released_by_job:
        chosen['released_by_job'] = released_by_job

    if not dry_run:
        dev_db.upsert_insight(developer_id, external_user_id, chosen)

    result['released'] = chosen
    logger.info(
        '[insight_engine] %s released topic=%s worth=%s conf=%s',
        external_user_id[:8], chosen.get('topic_key'), chosen.get('worth'), chosen.get('confidence'),
    )
    return result
