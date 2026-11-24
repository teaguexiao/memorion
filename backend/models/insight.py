"""洞察引擎（Insight Engine）数据模型。

产品设计（见 docs/product/Memorion产品定位与功能变更规格-2026-07.md P-32）：
里程碑不再是「Day 2/7/30 固定排期 + 固定模板」，而是**涌现式**——后台持续
"提名"关于这个人值得说的事，经"怀疑者"对抗验证后进入账本，由"释放阀"
（确定性代码，非 LLM）决定何时推一张卡。

四个角色：
  1. 提名者 (nominator)  —— 开放式发现，话题不设枚举，自评 worth/confidence
  2. 怀疑者 (skeptic)    —— 逐条试图反驳，把不够硬的毙掉或降级
  3. 账本 (ledger)       —— 记住说过什么/否决过什么，保证新颖性、防重复
  4. 释放阀 (valve)      —— 只管"多久打扰一次"，不管"能说什么"

之所以把 worth/confidence 交给模型自评、把节流交给代码：智能端要灵活
（不被我们的想象力设限），时机端要可控（不能轰炸用户）。

**卡片内部是两层门控，别把它们混成一层：**

  - `headline` / `body` / `evidence` —— 严格门控。必须挂得住原话或事实清单里的
    数字，怀疑者按 A 统计型 / B 复现型 / C 单次型三类标准逐条反驳。
  - `depth` —— 刻意放松。允许联想、推测动机与情绪、说"我猜"。它只过三条红线
    （编造可核对的硬事实 / 诊断说教 / 冒犯），由 `depth_verdict` 独立裁决。

分层的理由：只靠严格层，卡片就只剩"周五比周日忙"这种正确但无感的判词——
真正让人被理解的那部分（他在意什么、在扛什么）永远拿不出逐句可核对的证据。
所以把"我注意到什么"和"我从中看到一个什么样的人"分开供给：前者不许错，
后者不许假装是事实。两者的裁决互不影响（depth 被 drop 照样出卡）。
"""

from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field


class InsightStatus(str, Enum):
    """洞察在账本里的生命周期。"""

    CANDIDATE = 'candidate'      # 提名者产出，尚未经怀疑者
    MATURE = 'mature'            # 通过怀疑者，等释放阀排期
    RELEASED = 'released'        # 已作为卡片推给用户
    REJECTED = 'rejected'        # 怀疑者毙掉（记账防止反复提名同一件事）
    MATERIAL = 'material'        # 降级为素材（不单独出卡，可供日记/月报叙事引用）
    SUPPRESSED = 'suppressed'    # 事实成立但不适合出卡（如暴露产品缺陷）


class InsightFeedback(str, Enum):
    """用户在卡片上的「说得准 / 不太准」反馈。"""

    NONE = 'none'
    ACCURATE = 'accurate'
    INACCURATE = 'inaccurate'


class InsightEvidence(BaseModel):
    """一条证据。统计型洞察可以没有原话，只有数字。"""

    quote: Optional[str] = Field(None, description='用户的原话引用（逐字，不改写）')
    conversation_id: Optional[str] = Field(None, description='原话所在对话 id，供跳转取证')
    date: Optional[str] = Field(None, description='YYYY-MM-DD，证据发生日期')
    stat: Optional[str] = Field(None, description='统计型证据的可读描述，如「周五 80 段 / 周日 6 段」')


class InsightNomination(BaseModel):
    """提名者的单条产出。

    刻意不定义 `kind` 枚举——话题空间就是用户的人生本身，一旦枚举就把
    天花板焊死在我们的想象力上。呈现契约由 headline/body 的长度约束保证。
    """

    headline: str = Field(description='卡片主标题，一句话，像一句判词或发现；不超过 20 字')
    body: str = Field(description='卡片正文，2-4 句。陈述你注意到什么，不下人格标签，不说教')
    depth: Optional[str] = Field(
        None,
        description=(
            '深读段：600-900 字、分三段的散文，每段各有字数下限（第一段 ≥150 字给情绪命名 → '
            '第二段 ≥250 字往下走一层讲代价与张力，至少两个不同角度 → 第三段 ≥120 字'
            '留一句许可式的话）。允许联想与情绪投射，不要求逐句有证据。'
            '红线三条：不许编造可核对的硬事实（具体事件/人名/地点/日期/数字）、不诊断、不开处方'
        ),
    )
    evidence: List[InsightEvidence] = Field(default_factory=list, description='支撑这条洞察的证据')
    worth: int = Field(ge=0, le=100, description='自评"值不值得为此打扰用户"，0-100')
    confidence: int = Field(ge=0, le=100, description='自评置信度，0-100。证据不足必须给低分')
    topic_key: str = Field(
        description='用于账本去重的稳定短语义键，kebab-case 英文，如 weekend-silence / no-late-night-work'
    )
    reasoning: Optional[str] = Field(None, description='为什么这条值得说（内部用，不展示给用户）')


class NominationBatch(BaseModel):
    """提名者一次运行的全部产出。"""

    nominations: List[InsightNomination] = Field(default_factory=list)


class SkepticVerdict(BaseModel):
    """怀疑者对单条提名的裁决。"""

    verdict: str = Field(
        description="裁决：pass（通过）/ reject（毙掉）/ material（降级为素材）/ suppress（不适合出卡）"
    )
    reason: str = Field(description='裁决理由，一句话。毙掉时必须说明是哪一环不成立')
    # ⚠️ 三个 revised_* 都是「能直接发给用户的成品」，不是给我们看的意见。生产上真出过
    # 两种坏形态（评语、半句话），落库前由 engine._pick_revised 再挡一道。
    revised_headline: Optional[str] = Field(
        None, description='若措辞过度断言，给出更克制的完整标题；不改则留空（不要写评语）')
    revised_body: Optional[str] = Field(
        None, description='若措辞过度断言，给出更克制的完整正文；不改则留空（不要写评语或半句话）')
    confidence_after: int = Field(ge=0, le=100, description='审后置信度，可下调')

    # 深读段单独裁决：它故意不受证据约束，所以不能与主结论共用一个 verdict。
    # 只查三条红线（编造硬事实 / 诊断说教 / 冒犯），且与 verdict 相互独立——
    # depth 被 drop 不影响卡片释放，depth 写得动人也救不了不成立的主结论。
    depth_verdict: str = Field(
        default='keep',
        description='深读段裁决：keep（默认，含大胆但诚实的推测）/ revise（个别句子越线）/ drop（整段建立在编造之上或冒犯）',
    )
    revised_depth: Optional[str] = Field(
        None,
        description=(
            'depth_verdict=revise 时的改写版：必须是完整的整段（同样三段、同样长度、'
            '保留原有温度），只拆掉越线部分。不改则判 keep 并留空'
        ),
    )


class InsightCard(BaseModel):
    """落库并下发给客户端的洞察卡。"""

    id: str
    topic_key: str
    headline: str
    body: str
    depth: Optional[str] = Field(None, description='深读段散文；证据门控只管 headline/body，这一层刻意放松')
    evidence: List[InsightEvidence] = Field(default_factory=list)
    worth: int = 0
    confidence: int = 0
    status: InsightStatus = InsightStatus.CANDIDATE
    feedback: InsightFeedback = InsightFeedback.NONE

    # 溯源与可观测性
    window_start: Optional[str] = Field(None, description='YYYY-MM-DD，本条洞察观察窗口起点')
    window_end: Optional[str] = Field(None, description='YYYY-MM-DD，观察窗口终点')
    companion_days: Optional[int] = Field(None, description='生成时的陪伴天数')
    skeptic_reason: Optional[str] = Field(None, description='怀疑者裁决理由，便于事后复盘')
    is_scaffold: bool = Field(default=False, description='是否为冷启动兜底卡（无真洞察时的地板）')

    released_at: Optional[datetime] = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
