"""Memorion Insight Engine Cron Job（涌现式洞察卡）

每小时运行，找出本地时间为 TARGET_LOCAL_HOUR 的用户，调后端 API 跑一轮洞察引擎。

与「每日一刻」(memorion_daily_summary.py) 的区别：
  - 每日一刻**每天**给每个用户一张（日报，必发），用户本地 22:00
  - 洞察卡**不保证每次都发**——释放阀在疲劳窗口内或没有够格洞察时什么都不
    发，`skipped` 是正常结果而不是错误。所以这个 cron 每天都问一次"今天有
    没有值得说的事"，由后端回答"没有"。

时间点选在**上午** 10:00（2026-08-12 从 20:00 挪过来）：原来 20:00 只比每日一刻的
22:00 早两小时，同一个晚上连着两条推送在体感上就是重复 —— 尽管两者内容源正交
（洞察看 60 天画像、日记看当天）。洞察是"回看"，放在早上读也更合适。

重活（拉数据、提名、审核、账本、推送）全在后端：API 把这一轮排进队列，journal worker
来跑（`defer`，见 call_insight_run_api）。这里只做调度与用户发现。
"""
import asyncio
import concurrent.futures
import json
import os
from datetime import datetime
from typing import List

import requests
from modal import App, Cron, Image, Secret

# ============================================
# Modal App Configuration
# ============================================

app = App(
    name='memorion-insight-engine',
    secrets=[
        Secret.from_name('gcp-credentials'),
        Secret.from_name('envs'),
        Secret.from_name('memorion-cron-api-key'),
        Secret.from_name('memorion-firestore-credentials'),
    ],
)

image = (
    # Pin the image interpreter instead of inheriting the local one: Modal's
    # 2024.10 builder supports 3.10-3.13, so deploying from a 3.14 machine
    # fails unless the version is explicit.
    Image.debian_slim(python_version='3.12')
    .pip_install(
        'pytz',
        'firebase-admin==6.5.0',
        'google-cloud-firestore',
        'google-auth',
        'requests',
    )
)

# Official Memorion App developer account. Must stay in sync with
# MEMORION_APP_DEVELOPER_ID in backend/routers/cli_auth.py.
DEFAULT_DEVELOPER_ID = os.environ.get('MEMORION_APP_DEVELOPER_ID', '')

# 本地触发小时。匹配到小时而非 'HH:MM'，见 get_timezones_at_hour 的说明。
# ⚠️ 别挪回晚间：洞察是「回看 60 天的发现」，跟 22:00 每日一刻（当天日记）虽然
# 内容源正交，但同一个晚上连着两条推送在体感上就是重复。上午 10:00 是刻意跟
# 每日一刻拉开的（2026-08-12 从 20:00 改过来）。
TARGET_LOCAL_HOUR = 10

# 洞察需要跨多天才立得住，观察窗口固定 60 天
WINDOW_DAYS = 60

# 评测语料租户不是用户，别为它们跑引擎（2026-08-18）。
# `evaluation/chat-agent/golden_corpus.py` 的 `provision` 子命令会把 `name` 和
# `time_zone` 一起写进租户文档（uid 见那里的 `DEFAULT_UID`），而用户发现只按
# `time_zone` 过滤 —— 于是这些租户跟真实用户一样每天被扫到，各跑一整轮完整 LLM。
# 实测 `lme-golden-en-001` 就在每天那 5 个跑满 120s 的会话里，按 ~$0.6/轮算约 $18/月，
# 而它既不需要卡也没人看推送。
#
# ⚠️ **别改成「删掉租户的 time_zone」**：那看起来更省事，但 `provision` 会把它写回来，
# 下一次准备语料就静默复发。
# ⚠️ **判据用前缀，不要用「uid 不像 Firebase uid」**：库里还有 UUID 形态的历史 uid，
# 那些可能是真实用户。真实 Firebase uid 是 28 位纯字母数字、没有一个带 `-` 或 `_`
# （2026-08-18 对全部 155 个租户核过），所以带连字符的这两个前缀零误伤。
EVAL_TENANT_UID_PREFIXES = ('lme-golden', 'golden-')


def is_eval_tenant(uid: str) -> bool:
    """评测语料租户？（同一份判据在 memorion_daily_summary.py 里也有一份拷贝——
    两个 cron 是各自独立的 Modal runtime，改一处要记得改另一处。）"""
    return (uid or '').startswith(EVAL_TENANT_UID_PREFIXES)


# ============================================
# Firebase Initialization
# ============================================

def initialize_firebase():
    """Initialize Firebase with the configured credentials for Firestore user queries."""
    import firebase_admin

    try:
        firebase_admin.get_app()
        return True
    except ValueError:
        pass

    memorion_sa = os.environ.get('MEMORION_API_PLATFORM_SA')
    if not memorion_sa:
        print('ERROR: MEMORION_API_PLATFORM_SA not set, cannot query Firestore')
        return False

    try:
        sa_info = json.loads(memorion_sa)
        creds = firebase_admin.credentials.Certificate(sa_info)
        firebase_admin.initialize_app(creds)
        print(f'Firestore app initialized: project={sa_info.get("project_id")}')
        return True
    except Exception as e:
        print(f'Firebase initialization error: {e}')
        return False


# ============================================
# Timezone & User Discovery
# ============================================

def get_timezones_at_hour(target_hour: int) -> List[str]:
    """Get all timezones whose current local hour is `target_hour`.

    Matches on the hour only, deliberately. The cron fires at minute 0 of each
    UTC hour, so an exact 'HH:MM' == '20:00' comparison silently excludes every
    half/quarter-hour offset zone (UTC+5:30 India, +5:45 Nepal, +9:30 parts of
    Australia) — their local time at a UTC hour boundary is always HH:30/HH:45,
    so those users would never get a card at all.
    """
    import pytz

    matches = []
    for tz_name in pytz.all_timezones:
        try:
            if datetime.now(pytz.timezone(tz_name)).hour == target_hour:
                matches.append(tz_name)
        except Exception:
            continue
    return matches


async def get_users_in_timezones(timezones: List[str]) -> List[dict]:
    """Get users whose stored timezone is in the given list."""
    from firebase_admin import firestore
    from google.cloud.firestore_v1.base_query import FieldFilter

    if not timezones:
        return []

    db = firestore.client()
    chunks = [timezones[i:i + 30] for i in range(0, len(timezones), 30)]

    async def query_chunk(chunk):
        def sync_query():
            results = []
            try:
                users_ref = (
                    db.collection('developer_data')
                    .document(DEFAULT_DEVELOPER_ID)
                    .collection('users')
                )
                query = users_ref.where(filter=FieldFilter('time_zone', 'in', chunk))
                for doc in query.stream():
                    data = doc.to_dict() or {}
                    results.append({'uid': doc.id, 'timezone': data.get('time_zone')})
            except Exception as e:
                print(f'Error querying developer_data chunk: {e}')
            return results

        return await asyncio.to_thread(sync_query)

    results = await asyncio.gather(*[query_chunk(c) for c in chunks])

    users, seen, skipped = [], set(), []
    for group in results:
        for user in group:
            if user['uid'] in seen:
                continue
            seen.add(user['uid'])
            if is_eval_tenant(user['uid']):
                skipped.append(user['uid'])
                continue
            users.append(user)
    if skipped:
        print(f'  skipped {len(skipped)} eval tenant(s): {", ".join(sorted(skipped))}')
    return users


# ============================================
# API Call
# ============================================

def _get_api_key() -> str:
    key = os.environ.get('MEMORION_CRON_API_KEY', '')
    if not key:
        print('ERROR: MEMORION_CRON_API_KEY not set in environment')
    return key


def call_insight_run_api(uid: str, api_key: str) -> dict:
    """POST /v1/insights/run?external_user_id={uid} with `defer`: the journal worker runs the engine.

    202 means queued. Whether a card comes out today, and its push, is the worker's: the
    outcome is in the job record (Firestore `daily_journal_jobs`), not in this response.
    """
    api_base_url = os.environ.get(
        'MEMORION_CRON_BASE_URL',
        os.environ.get('BASE_API_URL', 'https://api.memorion.me'),
    ).rstrip('/')

    try:
        resp = requests.post(
            f'{api_base_url}/v1/insights/run',
            headers={'Authorization': api_key, 'Content-Type': 'application/json'},
            json={'window_days': WINDOW_DAYS, 'dry_run': False, 'send_push': True, 'defer': True},
            params={'external_user_id': uid},
            # Only the enqueue runs inside this request. Waiting for the engine itself is what
            # used to lose the response past ~6 minutes, while the run went on server-side.
            timeout=120,
        )

        if resp.status_code == 202:
            data = resp.json()
            print(f"  {uid[:8]} queued job {str(data.get('job_id'))[:8]} ({data.get('job_status')})")
            return {'status': 'queued', 'uid': uid}

        if resp.status_code != 200:
            print(f'  {uid[:8]} API error {resp.status_code}: {resp.text[:200]}')
            return {'status': 'error', 'uid': uid}

        data = resp.json()
        released = data.get('released')
        if released:
            print(
                f"  {uid[:8]} RELEASED topic={released.get('topic_key')} "
                f"worth={released.get('worth')} conf={released.get('confidence')} "
                f"pushed={data.get('pushed')}"
            )
            return {'status': 'released', 'uid': uid}

        print(
            f"  {uid[:8]} no card (reason={data.get('skipped_reason')}, "
            f"nominations={data.get('nominations_count')})"
        )
        return {'status': 'skipped', 'uid': uid}

    except requests.Timeout:
        print(f'  {uid[:8]} timeout')
        return {'status': 'timeout', 'uid': uid}
    except Exception as e:
        print(f'  {uid[:8]} exception: {e}')
        return {'status': 'exception', 'uid': uid}


async def process_insights(users: List[dict], api_key: str) -> dict:
    loop = asyncio.get_running_loop()
    tally = {'queued': 0, 'released': 0, 'skipped': 0, 'error': 0}

    # 并发 3：每次调用现在只是排队，几秒就回
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        tasks = [loop.run_in_executor(pool, call_insight_run_api, u['uid'], api_key) for u in users]
        for result in await asyncio.gather(*tasks):
            status = result.get('status')
            if status == 'queued':
                tally['queued'] += 1
            elif status == 'released':
                tally['released'] += 1
            elif status == 'skipped':
                tally['skipped'] += 1
            else:
                tally['error'] += 1
    return tally


async def run_for_due_users(api_key: str) -> dict:
    print(f'Looking for users at local hour {TARGET_LOCAL_HOUR}...')

    timezones = get_timezones_at_hour(TARGET_LOCAL_HOUR)
    if not timezones:
        print(f'No timezones at local hour {TARGET_LOCAL_HOUR} right now')
        return {'users_found': 0, 'results': {}}

    users = await get_users_in_timezones(timezones)
    if not users:
        print('No users found in matching timezones')
        return {'users_found': 0, 'results': {}}

    print(f'Found {len(users)} users to evaluate')
    results = await process_insights(users, api_key)
    print(f'Insight engine run completed: {results}')
    return {'users_found': len(users), 'results': results}


# ============================================
# Cron Job Entry Points
# ============================================

# 一小时的用户按并发 3 分批调 `call_insight_run_api`。2026-10-28 起那只是排队、几秒就回，
# 引擎在 journal worker 里跑，所以这个上限远远够用。没收紧是因为 timeout 只是上限、按实际
# 运行时间计费：之前同步等引擎时，一批最多要 20 分钟，这里才留到 4800s（4 批）。
@app.function(
    image=image,
    schedule=Cron('0 * * * *'),  # Every hour at minute 0
    timeout=4800,
    memory=512,
)
async def insight_engine_cronjob():
    """Scheduled insight engine run - runs every hour, acts on users at 20:00 local."""
    import pytz

    print(f'Insight engine cron started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {'status': 'error', 'message': 'Firebase initialization failed'}

    api_key = _get_api_key()
    if not api_key:
        return {'status': 'error', 'message': 'MEMORION_CRON_API_KEY not configured'}

    try:
        result = await run_for_due_users(api_key)
        return {'status': 'success', **result, 'ran_at': str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error: {e}')
        import traceback

        traceback.print_exc()
        return {'status': 'error', 'message': str(e)}


# function timeout 要留在 requests timeout 之上，否则 Modal 先把我们杀掉，
# 而那次调用的推送要到 handler 末尾才发。
@app.function(image=image, timeout=1800, memory=512)
async def manual_insight_for_user(uid: str, dry_run: bool = False):
    """Manual trigger for one user, ignoring the local-time gate.

    Unlike the cron this waits for the engine (no `defer`), so a dry run prints its verdicts.
    A run past ~6 minutes may lose its response here although it finished server-side.

    Usage:
        modal run memorion_insight_engine.py::manual_insight_for_user --uid <user_id>
        modal run memorion_insight_engine.py::manual_insight_for_user --uid <user_id> --dry-run
    """
    import pytz

    print(f'Manual insight run for {uid[:8]} at {datetime.now(pytz.utc)} (dry_run={dry_run})')

    api_key = _get_api_key()
    if not api_key:
        return {'status': 'error', 'message': 'MEMORION_CRON_API_KEY not configured'}

    api_base_url = os.environ.get(
        'MEMORION_CRON_BASE_URL',
        os.environ.get('BASE_API_URL', 'https://api.memorion.me'),
    ).rstrip('/')

    resp = requests.post(
        f'{api_base_url}/v1/insights/run',
        headers={'Authorization': api_key, 'Content-Type': 'application/json'},
        json={'window_days': WINDOW_DAYS, 'dry_run': dry_run, 'send_push': not dry_run},
        params={'external_user_id': uid},
        timeout=20 * 60,  # 同 call_insight_run_api：不小于服务端 cap
    )
    print(f'status={resp.status_code} body={resp.text[:1500]}')
    return {'status': resp.status_code, 'body': resp.json() if resp.status_code == 200 else resp.text[:500]}
