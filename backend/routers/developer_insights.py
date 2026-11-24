"""Developer API - Insight cards（洞察卡 / 涌现式里程碑）

后台持续"提名"关于用户值得说的事，经怀疑者对抗验证后进账本，由释放阀
决定何时推一张卡。详见 utils/insights/engine.py 与规格 P-32。

数据落在 developer_data/{developer_id}/users/{external_user_id}/insights/{id}
"""

import asyncio
import os
from datetime import datetime
from typing import List, Optional
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import database.developer_data as dev_db
from dependencies import get_developer_id_from_api_key
from models.insight import InsightEvidence, InsightFeedback
from utils.insights.engine import DEFAULT_WINDOW_DAYS, run_insight_engine
from utils.runtime.credentials import materialize_gcp_credentials_from_env

router = APIRouter()


# ******************************************************
# ****************** MODELS ****************************
# ******************************************************


class InsightRunRequest(BaseModel):
    window_days: int = Field(
        default=DEFAULT_WINDOW_DAYS,
        ge=7,
        le=180,
        description='观察窗口天数（洞察需要跨多天才立得住，故下限 7 天）',
    )
    dry_run: bool = Field(
        default=False,
        description='True 时不写账本、不推送，只返回提名/裁决中间产物（人工审阅与评测用）',
    )
    send_push: bool = Field(default=True, description='释放卡片时是否发 FCM 推送')
    defer: bool = Field(
        default=False,
        description=(
            'True 时不在本次请求里跑引擎：排进队列，回 202 和任务 id，由 journal worker 跑完并发推送'
            '（结果见 Firestore `daily_journal_jobs/{job_id}`）'
        ),
    )


class InsightVerdictOut(BaseModel):
    topic_key: str
    headline: str
    verdict: Optional[str] = None
    reason: Optional[str] = None
    worth: int = 0
    confidence: int = 0
    depth_verdict: Optional[str] = Field(None, description='深读段裁决：keep / revise / drop（与 verdict 独立）')
    evidence_dropped: int = Field(0, description='被证据清洗丢弃的条数（模型伪造原话或引用了摘要）')


class InsightCardOut(BaseModel):
    id: str
    topic_key: str
    headline: str
    body: str
    depth: Optional[str] = Field(
        None,
        description='深读段散文。证据门控只管 headline/body，这一层刻意放松（允许推测与情绪），可能为 null',
    )
    evidence: List[InsightEvidence] = Field(default_factory=list)
    worth: int = 0
    confidence: int = 0
    status: str
    feedback: str = InsightFeedback.NONE.value
    window_start: Optional[str] = None
    window_end: Optional[str] = None
    companion_days: Optional[int] = None
    is_scaffold: bool = False
    released_at: Optional[datetime] = None
    created_at: Optional[datetime] = None


class InsightRunResponse(BaseModel):
    released: Optional[InsightCardOut] = Field(None, description='本轮释放的卡片；无则为 null')
    nominations_count: int = 0
    verdicts: List[InsightVerdictOut] = Field(default_factory=list)
    skipped_reason: Optional[str] = Field(None, description='本轮没有释放卡片的原因')
    companion_days: int = 0
    pushed: bool = False


class InsightListResponse(BaseModel):
    insights: List[InsightCardOut]
    total: int = Field(..., description='符合筛选条件的总条数（不是本页条数），供分页使用')
    has_more: bool = Field(False, description='是否还有更多条目')


class InsightFeedbackRequest(BaseModel):
    feedback: str = Field(
        ...,
        description="用户在卡片上的反馈：accurate（说得准）/ inaccurate（不太准）/ none（撤回）",
    )


# ******************************************************
# ****************** HELPERS ***************************
# ******************************************************

materialize_gcp_credentials_from_env()
_FCM_CRED_PATH = os.environ.get('FCM_GOOGLE_APPLICATION_CREDENTIALS', '')
_fcm_credentials = None


def _get_fcm_access_token() -> str:
    global _fcm_credentials
    import google.auth.transport.requests
    from google.oauth2 import service_account

    if _fcm_credentials is None:
        _fcm_credentials = service_account.Credentials.from_service_account_file(
            _FCM_CRED_PATH,
            scopes=['https://www.googleapis.com/auth/cloud-platform'],
        )
    if not _fcm_credentials.valid:
        _fcm_credentials.refresh(google.auth.transport.requests.Request())
    return _fcm_credentials.token


def _insight_user_local_now(developer_id: str, uid: str) -> Optional[datetime]:
    """用户本地时区的当前时间，用于静默时段判断；拿不到时区返回 None（跳过静默判断）。"""
    try:
        import pytz
        tz_name = dev_db.get_user_timezone(developer_id, uid) if developer_id else None
        if not tz_name:
            return None
        return datetime.now(pytz.timezone(tz_name))
    except Exception:
        return None


def _send_insight_push(developer_id: str, uid: str, card: dict) -> bool:
    """推一条洞察卡通知，深链到卡片详情。"""
    import json as _json

    # 尊重用户本地「新发现」开关 + 静默时段（偏好由 App 同步到服务端）
    from utils.notification_gate import should_send_push
    user_local_now = _insight_user_local_now(developer_id, uid)
    if not should_send_push(developer_id, uid, 'milestone', user_local_now):
        print(f'[insights] {uid[:8]} skipped by notification preference')
        return False

    if not os.path.exists(_FCM_CRED_PATH):
        print(f'[insights] {uid[:8]} FCM credentials not found, skipping push')
        return False

    fcm_token = dev_db.get_user_fcm_token(developer_id, uid) if developer_id else None
    if not fcm_token:
        print(f'[insights] {uid[:8]} no FCM token, skipping push')
        return False

    try:
        import requests

        access_token = _get_fcm_access_token()
        with open(_FCM_CRED_PATH) as f:
            project_id = _json.load(f)['project_id']

        # 标题用卡片自己的 headline——推送就是揭晓的第一句话，不套模板
        body = (card.get('body') or '')[:100]
        resp = requests.post(
            f'https://fcm.googleapis.com/v1/projects/{project_id}/messages:send',
            headers={'Authorization': f'Bearer {access_token}', 'Content-Type': 'application/json'},
            json={'message': {
                'token': fcm_token,
                'notification': {'title': card.get('headline') or '', 'body': body},
                'data': {
                    'id': str(uuid.uuid4()),
                    'type': 'insight_card',
                    'notification_type': 'insight_card',
                    'navigate_to': '/insights',
                    'insight_id': card.get('id') or '',
                },
            }},
            timeout=30,
        )
        ok = resp.status_code == 200
        print(f"[insights] {uid[:8]} push sent={'ok' if ok else f'fail({resp.status_code})'}")
        return ok
    except Exception as e:
        print(f'[insights] {uid[:8]} push failed: {e}')
        return False


def _sanitize_stored_evidence(evidence) -> list:
    """读取时兜底：抹掉存量证据里不可用的 conversation_id。

    引擎侧现在已经在落库前核对了（utils/insights/engine.py:_sanitize_evidence），
    但那只管新写入的。生产账本里已经躺着 5 条字面量"未知"和 10 条空值，
    改代码不会回填——而 App 只要看到一个非空字符串就会拿它去跳转，结果是点进
    一个不存在的对话。所以出口再挡一道。
    """
    from utils.insights.engine import _BOGUS_IDS

    out = []
    for item in evidence or []:
        if not isinstance(item, dict):
            continue
        cid = str(item.get('conversation_id') or '').strip()
        if cid.lower() in _BOGUS_IDS:
            item = {**item, 'conversation_id': None}
        out.append(item)
    return out


def _to_card_out(row: dict) -> dict:
    """Firestore doc → API 输出（容忍历史字段缺失）。"""
    return {
        'id': row.get('id') or '',
        'topic_key': row.get('topic_key') or '',
        'headline': row.get('headline') or '',
        'body': row.get('body') or '',
        'depth': row.get('depth') or None,
        'evidence': _sanitize_stored_evidence(row.get('evidence')),
        'worth': row.get('worth') or 0,
        'confidence': row.get('confidence') or 0,
        'status': row.get('status') or 'candidate',
        'feedback': row.get('feedback') or InsightFeedback.NONE.value,
        'window_start': row.get('window_start'),
        'window_end': row.get('window_end'),
        'companion_days': row.get('companion_days'),
        'is_scaffold': bool(row.get('is_scaffold')),
        'released_at': row.get('released_at'),
        'created_at': row.get('created_at'),
    }


# ******************************************************
# ****************** ENDPOINTS *************************
# ******************************************************


@router.post('/v1/insights/run', response_model=InsightRunResponse, tags=['developer-api-insights'])
async def run_insights(
    request: InsightRunRequest,
    external_user_id: str = Query(..., description='External user identifier'),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """跑一轮洞察引擎（由 Modal cron 定时调用，也可手动触发）。

    一轮最多释放一张卡；释放阀会在疲劳窗口内、或没有够格洞察时什么都不发，
    这是正常结果（`skipped_reason` 会说明原因），不是错误。

    `defer=True`（cron 发的就是它）时引擎由 journal worker 跑。重的一轮要几分钟：同步跑时
    调用方超过约 6 分钟就收不到响应，赶上部署被打断的那一轮还可能卡已释放、推送没发。
    要不要跳过（数据不够、疲劳窗口）仍由引擎判断，所以这里不做预检。
    """
    if request.defer:
        return await asyncio.to_thread(_queue_insight_run, request, developer_id, external_user_id)

    from utils.locales import get_user_effective_language

    language_code, _ = get_user_effective_language(
        developer_id=developer_id,
        uid=external_user_id,
        fallback_conversations=None,
    )

    try:
        # 卸载到线程：引擎是同步的（Firestore 流式读 + 多次 LLM 调用），实测一轮
        # 40s 以上。在 async 端点里直接同步跑会占住事件循环，期间该 worker 无法
        # 处理任何其他请求。
        result = await asyncio.to_thread(
            run_insight_engine,
            developer_id=developer_id,
            external_user_id=external_user_id,
            window_days=request.window_days,
            language_code=language_code or 'en',
            dry_run=request.dry_run,
        )
    except Exception as e:
        # 详情只进日志：异常串可能带内部路径/堆栈，不回传给调用方
        import traceback

        print(f'[insights] {external_user_id[:8]} engine failed: {e}')
        traceback.print_exc()
        raise HTTPException(status_code=500, detail='Insight engine failed')

    released = result.get('released')
    pushed = False
    if released and request.send_push and not request.dry_run:
        # 同上：FCM 走同步 requests，也别占着事件循环
        pushed = await asyncio.to_thread(_send_insight_push, developer_id, external_user_id, released)

    return {
        'released': _to_card_out(released) if released else None,
        'nominations_count': len(result.get('nominations') or []),
        'verdicts': result.get('verdicts') or [],
        'skipped_reason': result.get('skipped_reason'),
        'companion_days': result.get('companion_days') or 0,
        'pushed': pushed,
    }


def _queue_insight_run(request: InsightRunRequest, developer_id: str, external_user_id: str):
    """排进今天这一轮（日期取用户本地日），同一天重复请求拿到的是同一个任务。"""
    from utils.daily_journal_jobs.store import JournalJobStore
    from utils.timeline.day_query import _resolve_tz

    tz = _resolve_tz(dev_db.get_user_effective_timezone(developer_id, external_user_id))
    local_date = datetime.now(tz).date().isoformat()
    job = JournalJobStore().enqueue_insight(
        developer_id, external_user_id, local_date,
        window_days=request.window_days, dry_run=request.dry_run, send_push=request.send_push,
    )
    print(f"[insights] {external_user_id[:8]} queued job={job['id'][:8]} status={job['status']} "
          f"dry_run={request.dry_run}")
    return JSONResponse(status_code=202, content={
        'status': 'queued', 'job_id': job['id'], 'job_status': job['status'], 'date': local_date,
    })


@router.get('/v1/insights', response_model=InsightListResponse, tags=['developer-api-insights'])
async def list_insights(
    external_user_id: str = Query(..., description='External user identifier'),
    released_only: bool = Query(True, description='只返回已推送给用户的卡片'),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """列出洞察卡。客户端默认只该看 released 的——账本里的候选/否决条目是内部状态。"""
    statuses = ['released'] if released_only else None

    if released_only:
        rows = dev_db.get_released_insights(developer_id, external_user_id, limit=limit + offset)
        rows = rows[offset:offset + limit]
    else:
        rows = dev_db.list_insights(developer_id, external_user_id, limit=limit, offset=offset)

    total = dev_db.count_insights(developer_id, external_user_id, statuses=statuses)

    return {
        'insights': [_to_card_out(r) for r in rows],
        'total': total,
        'has_more': (offset + len(rows)) < total,
    }


@router.get('/v1/insights/{insight_id}', response_model=InsightCardOut, tags=['developer-api-insights'])
async def get_insight(
    insight_id: str,
    external_user_id: str = Query(..., description='External user identifier'),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    row = dev_db.get_insight(developer_id, external_user_id, insight_id)
    if not row:
        raise HTTPException(status_code=404, detail='Insight not found')
    return _to_card_out(row)


@router.post('/v1/insights/{insight_id}/feedback', response_model=InsightCardOut, tags=['developer-api-insights'])
async def submit_insight_feedback(
    insight_id: str,
    request: InsightFeedbackRequest,
    external_user_id: str = Query(..., description='External user identifier'),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    """记录卡片上的「说得准 / 不太准」。

    这个反馈是引擎唯一的外部校准信号：它让产品敢说有温度但可能错的话，
    因为用户随手就能否掉。
    """
    allowed = {f.value for f in InsightFeedback}
    if request.feedback not in allowed:
        raise HTTPException(status_code=400, detail=f'feedback must be one of {sorted(allowed)}')

    row = dev_db.set_insight_feedback(developer_id, external_user_id, insight_id, request.feedback)
    if not row:
        raise HTTPException(status_code=404, detail='Insight not found')
    return _to_card_out(row)


@router.delete('/v1/insights/{insight_id}', status_code=204, tags=['developer-api-insights'])
async def delete_insight(
    insight_id: str,
    external_user_id: str = Query(..., description='External user identifier'),
    developer_id: str = Depends(get_developer_id_from_api_key),
):
    existing = dev_db.get_insight(developer_id, external_user_id, insight_id)
    if not existing:
        raise HTTPException(status_code=404, detail='Insight not found')
    dev_db.delete_insight(developer_id, external_user_id, insight_id)
    return None
