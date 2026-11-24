import json
import os
import logging
from datetime import datetime


# Custom filter to ignore noisy ASGI handshake errors
class ASGIHandshakeFilter(logging.Filter):
    def filter(self, record):
        # Filter out "ASGI callable returned without sending handshake" errors
        # These occur when clients disconnect before WebSocket handshake completes
        message = record.getMessage()
        if 'ASGI callable returned without sending handshake' in message:
            return False
        return True


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

# Apply filter to uvicorn error logger to suppress handshake errors
uvicorn_error_logger = logging.getLogger("uvicorn.error")
uvicorn_error_logger.addFilter(ASGIHandshakeFilter())

import firebase_admin
from fastapi import FastAPI

from utils.runtime.credentials import materialize_gcp_credentials_from_env
materialize_gcp_credentials_from_env()

# Chat-agent spans (tool routing, token counts). No-op unless AGENT_TRACING is set;
# records metadata only, never question or memory text. See
# utils/observability/tracing.py and evaluation/TRACING.md.
from utils.observability.tracing import init_tracing
init_tracing()

from routers import (
    firmware,
    notifications,
    users,
    sync,
    discover,
    audio_upload,
    api_keys,
    app_auth,
    cli_auth,
    developer_memories,
    developer_conversations,
    developer_people,
    developer_vocabulary,
    developer_usage,
    developer_chat,
    developer_listen,
    developer_talk,
    developer_transcribe,
    developer_images,
    developer_speech_profile,
    developer_daily_summary,
    developer_insights,
    developer_eir_webhooks,
    developer_users,
    internal_eir_webhook,
    internal_benchmark_webhook,
    vad,
    moments,
    fortune,
    mood_quote,
    mood_pixel,
    weather,
    home_updates,
    pdp,
    calendar,
    timeline,
    conversation_shares,
)

from utils.other.timeout import TimeoutMiddleware
from middleware.api_logging import APILoggingMiddleware
from utils.logging.log_writer import init_log_writer, shutdown_log_writer

if os.environ.get('SERVICE_ACCOUNT_JSON'):
    service_account_info = json.loads(os.environ["SERVICE_ACCOUNT_JSON"])
    credentials = firebase_admin.credentials.Certificate(service_account_info)
    firebase_admin.initialize_app(credentials)
else:
    firebase_admin.initialize_app()

# Initialize secondary Firebase app for user-facing Auth
_fcm_cred_path = os.environ.get('FCM_GOOGLE_APPLICATION_CREDENTIALS', '')
if os.path.exists(_fcm_cred_path):
    _fcm_cred = firebase_admin.credentials.Certificate(_fcm_cred_path)
    firebase_admin.initialize_app(_fcm_cred, name='fcm')
elif os.environ.get('FCM_SERVICE_ACCOUNT_JSON'):
    _fcm_info = json.loads(os.environ['FCM_SERVICE_ACCOUNT_JSON'])
    _fcm_cred = firebase_admin.credentials.Certificate(_fcm_info)
    firebase_admin.initialize_app(_fcm_cred, name='fcm')


app = FastAPI()

@app.get("/health_check")
async def health_check():
    return {"status": "ok"}

@app.get("/health")
async def health():
    return {"status": "ok"}

app.include_router(notifications.router)
app.include_router(users.router)
app.include_router(fortune.router)
app.include_router(discover.router)
app.include_router(mood_quote.router)
app.include_router(mood_pixel.router)
app.include_router(weather.router)
app.include_router(home_updates.router)
app.include_router(pdp.router)
app.include_router(calendar.router)

app.include_router(firmware.router)
app.include_router(sync.router)
app.include_router(audio_upload.router)
from routers import audio_jobs
app.include_router(audio_jobs.router)

app.include_router(api_keys.router)
app.include_router(app_auth.router)
app.include_router(cli_auth.router)
app.include_router(developer_memories.router)
app.include_router(developer_conversations.router)
app.include_router(developer_people.router)
app.include_router(developer_vocabulary.router)
app.include_router(developer_usage.router)
app.include_router(developer_chat.router)
app.include_router(developer_listen.router)
app.include_router(developer_talk.router)
app.include_router(developer_transcribe.router)
app.include_router(developer_images.router)
app.include_router(developer_speech_profile.router)
app.include_router(developer_daily_summary.router)
app.include_router(developer_insights.router)
app.include_router(developer_eir_webhooks.router)
app.include_router(developer_users.router)
app.include_router(internal_eir_webhook.router)
app.include_router(internal_benchmark_webhook.router)
app.include_router(vad.router)
app.include_router(moments.router)
app.include_router(timeline.router)
app.include_router(conversation_shares.router)


methods_timeout = {
    "GET": os.environ.get('HTTP_GET_TIMEOUT'),
    "PUT": os.environ.get('HTTP_PUT_TIMEOUT'),
    "PATCH": os.environ.get('HTTP_PATCH_TIMEOUT'),
    "DELETE": os.environ.get('HTTP_DELETE_TIMEOUT'),
}

# 🚨 **上传端点的预算必须大于它自己的内部预算**，否则它在结构上不可能成功。
# `upload-audio` 是同步端点：ffmpeg 转码 + Silero VAD + 一次最长轮询 300s 的 Soniox
# 离线任务 + 可选的 LLM 处理，实测长录音要 2~4 分钟。而 POST **不在**上面那张
# `methods_timeout` 里，走的是 `HTTP_DEFAULT_TIMEOUT` 的 120s 默认值 —— 于是
# 2026-08-15 一段 30 分钟的手表录音连传四次、每次都在 120s 整被砍成 504，而被放弃的
# 请求照样跑完并各自写了一条对话（4 条重复 + 4 次 Soniox 额度）。详见
# `TimeoutMiddleware` 的类注释和 `get_conversation_id_by_source_started_at`。
#
# ⚠️ **`insights/run` 是同一个坑的第二个实例，但它的失败形态更难发现（2026-08-18 修）。**
# 内部预算是 1 次提名 + 最多 6 路并发审核；提名的 prompt 里带 60 天的全量原话与对话
# 摘要（实测最活跃用户 114k 字符 ≈ 57k tokens），2026-08-14 深读段扩成三段 400-600 字
# 之后一轮要好几分钟。于是数据最多的那 4 个用户 + 评测租户**每天准时**在 120s 整被砍成
# 504（8/14 起连续 5 天，`response_time_ms` 精确落在 120001~120059）。
#
# ⚠️ **cap 别按「504 时刻与卡片落库时刻之差」去估，那个数字小得多。** 那样估出来是
# 约 220s，而放开 cap 之后实测**一次 466 秒**（`mcaK5709`，2026-08-18 11:02 那次
# dry run），且 CloudWatch 显示 466s 几乎全花在**单次 nominate** 上 —— 那轮的
# `judge` 一次都没跑（唯一那条提名被账本去重拦掉了）。也就是说提名条数一多还会更慢，
# 所以这里给的是 20 分钟而不是刚好够用的值。
#
# 反直觉的地方在于**它看起来没坏**：handler 用 `asyncio.to_thread` 卸载引擎，而
# `asyncio.wait_for` 只停止 await、线程照样跑完，`released_at` 由引擎自己写进 Firestore
# （`utils/insights/engine.py` 的 `chosen['released_at'] = now`）——所以卡片照样出现、
# 钱照样花，只有 HTTP 那一层是 504。
#
# 真正丢掉的是**推送**：`_send_insight_push` 排在那个被取消的 `await` 之后，永远执行不到。
# 而卡已经标成 `released`、吃掉了 5 天疲劳窗口，下一轮 `released_topics` 还会把它拦掉 ⇒
# 每次撞上超时就**净损失一次触达**，且两头都静默（cron 只看到 504、以为失败）。
paths_timeout = {
    # Diary text, evidence selection and bounded image generation/review are synchronous.
    "/v1/daily-summary": os.environ.get('HTTP_DAILY_SUMMARY_TIMEOUT', 10 * 60),
    "/v1/conversations/upload-audio": os.environ.get('HTTP_UPLOAD_AUDIO_TIMEOUT', 10 * 60),
    "/v1/insights/run": os.environ.get('HTTP_INSIGHTS_RUN_TIMEOUT', 20 * 60),
    "/v1/timeline/": os.environ.get('HTTP_TIMELINE_TIMEOUT', 20 * 60),
}

app.add_middleware(TimeoutMiddleware, methods_timeout=methods_timeout, paths_timeout=paths_timeout)

# API Logging Middleware for Developer API (/v1/*)
# This middleware logs all requests to the Developer API for billing and analytics
app.add_middleware(APILoggingMiddleware, api_prefix="/v1/")
from middleware.share_privacy import SharePrivacyMiddleware
app.add_middleware(SharePrivacyMiddleware)


# Startup/Shutdown events for log writer
@app.on_event("startup")
async def startup_event():
    """Initialize the log batch writer on application startup."""
    log_writer = init_log_writer(
        batch_size=50,
        flush_interval_seconds=5.0,
        max_retries=3,
    )
    await log_writer.start()
    logging.info("API Log writer initialized")


@app.on_event("shutdown")
async def shutdown_event():
    """Shutdown the log batch writer and flush remaining logs."""
    await shutdown_log_writer()
    logging.info("API Log writer shutdown complete")


paths = ['_temp', '_samples', '_segments', '_speech_profiles']
for path in paths:
    if not os.path.exists(path):
        os.makedirs(path)
