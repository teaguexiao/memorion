"""
Memorion Daily Summary Cron Job

Runs every hour, finds users whose local time is 22:00,
and calls the Memorion API to generate daily summaries. Users whose local
time is 06:00 get a catch-up call for yesterday (see CATCH_UP_LOCAL_TIME).

All heavy lifting (LLM, image generation, storage) is handled by the backend: the API
queues it and the journal worker does it (`defer`, see call_daily_summary_api). This
cron only handles scheduling and user discovery.
"""
import json
import os
import uuid
import asyncio
import concurrent.futures
from datetime import datetime, timezone
from typing import List, Optional

import requests
from modal import Image, App, Secret, Cron


# ============================================
# Modal App Configuration
# ============================================

app = App(
    name='memorion-daily-summary',
    secrets=[
        Secret.from_name("gcp-credentials"),
        Secret.from_name('envs'),
        Secret.from_name('memorion-cron-api-key'),
        Secret.from_name('memorion-firestore-credentials'),
    ],
)

image = (
    Image.debian_slim()
    .pip_install(
        "pytz",
        "firebase-admin==6.5.0",
        "google-cloud-firestore",
        "google-auth",
        "requests",
    )
)

# ============================================
# Constants
# ============================================

# Official Memorion App developer account. Must stay in sync with
# MEMORION_APP_DEVELOPER_ID in backend/routers/cli_auth.py.
DEFAULT_DEVELOPER_ID = os.environ.get('MEMORION_APP_DEVELOPER_ID', '')

# 评测语料租户不是用户，别给它们生成日报（2026-08-18）。
# `evaluation/chat-agent/golden_corpus.py` 的 `provision` 会把 `time_zone` 写进租户文档，
# 而用户发现只按 `time_zone` 过滤 ⇒ 它们每天都会被扫到、各跑一次完整的 summary LLM。
# ⚠️ 判据与 memorion_insight_engine.py 里那份**必须一致**（两个 cron 是各自独立的 Modal
# runtime，没法共享 import）。为什么用前缀而不是「uid 不像 Firebase uid」、以及为什么不能
# 靠删 `time_zone` 解决，见那边的长注释。
EVAL_TENANT_UID_PREFIXES = ("lme-golden", "golden-")


def is_eval_tenant(uid: str) -> bool:
    """评测语料租户？"""
    return (uid or "").startswith(EVAL_TENANT_UID_PREFIXES)


# 早上补写前一天（2026-10-27）。22:00 那一轮看不到当晚 22:00 以后的对话，失败了也没有重试；
# 这一轮对同一个日期再调一次 `catch_up=True`：缺了就写、漏了对话就重写、齐全就原样返回，
# 从不推送。选 06:00：排在夜里最晚的录音处理完之后、用户醒来打开 App 之前。
CATCH_UP_LOCAL_TIME = "06:00"


def effective_time_zone(user_data: dict):
    """用户的本地时区：先 `timezone`（App 里设的偏好），再 `time_zone`（设备随 FCM token 上报）。

    ⚠️ 与后端 `database/developer_data.get_user_effective_timezone` **必须一致**（独立 Modal
    runtime，没法 import）。cron 用它决定几点算 22:00、问哪一天，后端用它决定哪些对话属于
    那一天；两边不一致时，一天里有一段落在两篇日志之间，谁也不写。以前这里只认 `time_zone`，
    只设了 `timezone` 的用户永远扫不到。
    """
    user_data = user_data or {}
    return user_data.get('timezone') or user_data.get('time_zone')


# ============================================
# Firebase Initialization
# ============================================

def initialize_firebase():
    """Initialize Firebase with the configured credentials for Firestore user data queries."""
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

def get_timezones_at_time(target_time: str) -> List[str]:
    """Get all timezones currently at the target time (e.g., '22:00')."""
    import pytz

    target_timezones = []
    for tz_name in pytz.all_timezones:
        try:
            tz = pytz.timezone(tz_name)
            current_time = datetime.now(tz).strftime("%H:%M")
            if current_time == target_time:
                target_timezones.append(tz_name)
        except Exception:
            continue
    return target_timezones


def get_today_date_for_timezone(tz_name: str) -> str:
    """Get today's date string (YYYY-MM-DD) in the given timezone."""
    import pytz

    tz = pytz.timezone(tz_name)
    return datetime.now(tz).strftime("%Y-%m-%d")


def get_yesterday_date_for_timezone(tz_name: str) -> str:
    """Get yesterday's date string (YYYY-MM-DD) in the given timezone."""
    import pytz
    from datetime import timedelta

    tz = pytz.timezone(tz_name)
    return (datetime.now(tz) - timedelta(days=1)).strftime("%Y-%m-%d")


async def get_users_in_timezones(timezones: List[str]) -> List[dict]:
    """
    Get user IDs and their timezone for users in specific timezones.
    Searches both developer_data and top-level users collections.

    Returns list of {"uid": str, "timezone": str, "collection": str}
    """
    from firebase_admin import firestore
    from google.cloud.firestore_v1.base_query import FieldFilter

    if not timezones:
        return []

    db = firestore.client()
    users = []

    # Split timezones into chunks of 30 (Firestore 'in' query limit)
    timezone_chunks = [timezones[i:i + 30] for i in range(0, len(timezones), 30)]

    async def query_developer_data(chunk):
        """Query developer_data/{dev_id}/users whose effective timezone is in the chunk.

        Either field can hold it (see `effective_time_zone`), so both are queried. A user whose
        other field names a different timezone is skipped here and found when that one is due.
        """
        def sync_query():
            results = {}
            users_ref = db.collection('developer_data').document(
                DEFAULT_DEVELOPER_ID
            ).collection('users')
            for field in ('timezone', 'time_zone'):
                try:
                    query = users_ref.where(filter=FieldFilter(field, 'in', chunk))
                    for doc in query.stream():
                        doc_data = doc.to_dict()
                        tz_name = effective_time_zone(doc_data)
                        if tz_name not in chunk:
                            continue
                        results[doc.id] = {
                            "uid": doc.id,
                            "timezone": tz_name,
                            "collection": "developer_data",
                            "fcm_token": doc_data.get('fcm_token'),
                        }
                except Exception as e:
                    print(f"Error querying developer_data chunk by {field}: {e}")
            return list(results.values())

        return await asyncio.to_thread(sync_query)

    async def query_top_level_users(chunk):
        """Query top-level users collection for matching timezones."""
        def sync_query():
            results = []
            try:
                users_ref = db.collection('users')
                query = users_ref.where(filter=FieldFilter('time_zone', 'in', chunk))
                for doc in query.stream():
                    doc_data = doc.to_dict()
                    results.append({
                        "uid": doc.id,
                        "timezone": doc_data.get('time_zone'),
                        "collection": "users",
                        "fcm_token": doc_data.get('fcm_token'),
                    })
            except Exception as e:
                print(f"Error querying top-level users chunk: {e}")
            return results

        return await asyncio.to_thread(sync_query)

    # Query both collections in parallel
    tasks = []
    for chunk in timezone_chunks:
        tasks.append(query_developer_data(chunk))
        tasks.append(query_top_level_users(chunk))

    results = await asyncio.gather(*tasks)

    # Dedup by uid (prefer developer_data)
    seen_uids = set()
    skipped_eval = []
    for result_list in results:
        for user in result_list:
            if user["uid"] in seen_uids:
                continue
            seen_uids.add(user["uid"])
            if is_eval_tenant(user["uid"]):
                skipped_eval.append(user["uid"])
                continue
            users.append(user)
    if skipped_eval:
        print(f'  skipped {len(skipped_eval)} eval tenant(s): {", ".join(sorted(skipped_eval))}')

    # Batch-fetch missing FCM tokens from top-level users collection
    users_missing_token = [u for u in users if not u.get("fcm_token")]
    if users_missing_token:
        missing_uids = [u["uid"] for u in users_missing_token]
        uid_to_user = {u["uid"]: u for u in users_missing_token}

        async def fetch_fcm_tokens(uid_batch):
            def sync_fetch():
                tokens = {}
                try:
                    for uid in uid_batch:
                        doc = db.collection('users').document(uid).get()
                        if doc.exists:
                            tokens[uid] = doc.to_dict().get('fcm_token')
                except Exception as e:
                    print(f"Error fetching FCM tokens: {e}")
                return tokens
            return await asyncio.to_thread(sync_fetch)

        # Fetch in batches of 10
        token_batches = [missing_uids[i:i+10] for i in range(0, len(missing_uids), 10)]
        token_results = await asyncio.gather(*[fetch_fcm_tokens(batch) for batch in token_batches])
        for token_map in token_results:
            for uid, token in token_map.items():
                if uid in uid_to_user and token:
                    uid_to_user[uid]["fcm_token"] = token

        fetched_count = sum(1 for u in users_missing_token if u.get("fcm_token"))
        print(f"Fetched {fetched_count}/{len(users_missing_token)} missing FCM tokens")

    return users


# ============================================
# API Configuration
# ============================================

def _get_api_key() -> str:
    """Get API key from environment (only available at runtime inside Modal)."""
    key = os.environ.get("MEMORION_CRON_API_KEY", "")
    if not key:
        print("ERROR: MEMORION_CRON_API_KEY not set in environment")
    return key


# ============================================
# API Call
# ============================================

def call_daily_summary_api(uid: str, date_str: str, api_key: str, catch_up: bool = False) -> dict:
    """
    Ask the Memorion API for a user's daily summary.

    POST /v1/daily-summary?external_user_id={uid}
    Authorization: {api_key}
    Body: {"date": date_str, "include_image": true, "force_regenerate": false, "defer": true}
          plus "catch_up": true for the morning catch-up (never pushes)

    `defer` queues the writing for the journal worker (202), so this waits only for the
    API's cheap checks. Waiting for the writing itself (8-10 minutes on a long day) used to
    end in a timeout here although the entry was written (2026-10-27).
    """
    # MEMORION_CRON_BASE_URL takes priority, then BASE_API_URL from envs
    api_base_url = os.environ.get(
        "MEMORION_CRON_BASE_URL",
        os.environ.get("BASE_API_URL", "https://api.memorion.me")
    ).rstrip("/")
    url = f"{api_base_url}/v1/daily-summary"
    headers = {
        "Authorization": api_key,
        "Content-Type": "application/json",
    }
    payload = {
        "date": date_str,
        "include_image": True,
        "force_regenerate": False,
        "defer": True,
    }
    if catch_up:
        payload["catch_up"] = True
    params = {"external_user_id": uid}

    try:
        print(f"  Calling API for user {uid[:8]}... date={date_str} catch_up={catch_up}")
        # Only the cheap checks and the enqueue run inside this request.
        resp = requests.post(url, headers=headers, json=payload, params=params, timeout=120)

        if resp.status_code == 200:
            data = resp.json()
            print(f"  Already written: {data.get('conversations_count', 0)} conversations, "
                  f"image={'yes' if data.get('image_url') else 'no'}")
            return {"status": "success", "uid": uid, "data": data}
        elif resp.status_code == 202:
            data = resp.json()
            print(f"  Queued: job {str(data.get('job_id'))[:8]} ({data.get('job_status')})")
            return {"status": "queued", "uid": uid, "data": data}
        elif resp.status_code == 404:
            print(f"  No conversations for user {uid[:8]} on {date_str}")
            return {"status": "no_data", "uid": uid}
        else:
            print(f"  API error {resp.status_code}: {resp.text[:200]}")
            return {"status": "error", "uid": uid, "code": resp.status_code, "detail": resp.text[:200]}

    except requests.Timeout:
        print(f"  Timeout for user {uid[:8]}")
        return {"status": "timeout", "uid": uid}
    except Exception as e:
        print(f"  Exception for user {uid[:8]}: {e}")
        return {"status": "exception", "uid": uid, "detail": str(e)}


# ============================================
# Core Processing
# ============================================

async def process_daily_summaries(users: List[dict], api_key: str, catch_up: bool = False):
    """Process daily summaries for all users by calling the API.

    The evening run asks for today; the catch-up asks for yesterday, which has just ended.
    """
    loop = asyncio.get_running_loop()
    results = {"success": 0, "queued": 0, "no_data": 0, "error": 0}

    def process_user(user):
        uid = user["uid"]
        tz = user["timezone"]
        date_str = get_yesterday_date_for_timezone(tz) if catch_up else get_today_date_for_timezone(tz)
        api_result = call_daily_summary_api(uid, date_str, api_key, catch_up=catch_up)
        # FCM notification is sent by the API endpoint itself — no need to send again here
        return api_result

    # Process users concurrently (max 5 at a time to avoid overwhelming the API)
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        tasks = [loop.run_in_executor(pool, process_user, u) for u in users]
        for result in await asyncio.gather(*tasks):
            status = result.get("status", "error")
            if status == "success":
                results["success"] += 1
            elif status == "queued":
                results["queued"] += 1
            elif status == "no_data":
                results["no_data"] += 1
            else:
                results["error"] += 1

    return results


async def send_daily_summary(api_key: str):
    """Main function: find users at 22:00 local time and call API for each."""
    print("Starting daily summary generation...")
    target_time = "22:00"

    timezones = get_timezones_at_time(target_time)
    if not timezones:
        print("No timezones at 22:00 right now")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(timezones)} timezones at {target_time}")

    users = await get_users_in_timezones(timezones)
    if not users:
        print("No users found in matching timezones")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(users)} users for daily summary")
    for u in users:
        print(f"  - {u['uid'][:8]}... tz={u['timezone']} ({u['collection']})")

    results = await process_daily_summaries(users, api_key)
    print(f"Daily summary completed: {results}")
    return {"users_found": len(users), "results": results}


async def send_catch_up_summaries(api_key: str, timezones: Optional[List[str]] = None):
    """Find users at CATCH_UP_LOCAL_TIME and catch up yesterday's entry for each.

    Pass `timezones` when resolving them later than the top of the hour (see the cron job).
    """
    print("Starting daily summary catch-up...")
    if timezones is None:
        timezones = get_timezones_at_time(CATCH_UP_LOCAL_TIME)
    if not timezones:
        print(f"No timezones at {CATCH_UP_LOCAL_TIME} right now")
        return {"users_found": 0, "results": {}}

    users = await get_users_in_timezones(timezones)
    if not users:
        print("No users found in matching timezones")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(users)} users for daily summary catch-up")
    results = await process_daily_summaries(users, api_key, catch_up=True)
    print(f"Daily summary catch-up completed: {results}")
    return {"users_found": len(users), "results": results}


# ============================================
# Cron Job Entry Points
# ============================================

# 🚨 `modal run memorion_daily_summary.py::<any function>` 起的临时 app 也会启用下面这个
# schedule（2026-10-27 实测：一个回填用的 `modal run` 活过了 17:00 UTC，它自己的日志里出现了
# `Cron job started`）。只要临时 app 跨过整点，cron 就和已部署的那份并发再跑一轮：两轮晚上
# 的 pass 抢同一个用户时，可能都写日志、都发推送。调用这些函数要走已部署的 app
# （`modal.Function.from_name(...).remote(...)`；补写见 `scripts/catch_up_daily_journals.py`）。
@app.function(
    image=image,
    schedule=Cron('0 * * * *'),  # Every hour at minute 0
    timeout=4800,
    memory=256,
)
async def daily_summary_cronjob():
    """Scheduled daily summary cron job - runs every hour."""
    import pytz

    print(f'Cron job started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    # `get_timezones_at_time` matches the current minute, and the evening pass runs for
    # minutes: resolve the catch-up zones before it starts. Resolved after it, 06:00 has
    # become 06:0X and the catch-up silently finds nobody whenever anyone was at 22:00.
    catch_up_zones = get_timezones_at_time(CATCH_UP_LOCAL_TIME)

    # The two passes reach different timezones (none is at 22:00 and 06:00 at once), and
    # one failing must not cost the other its run.
    outcome = {"status": "success"}
    passes = (
        ("evening", lambda: send_daily_summary(api_key)),
        ("catch_up", lambda: send_catch_up_summaries(api_key, catch_up_zones)),
    )
    for name, run in passes:
        try:
            outcome[name] = await run()
        except Exception as e:
            print(f'Error in {name} pass: {e}')
            import traceback
            traceback.print_exc()
            outcome["status"] = "error"
            outcome[name] = {"error": str(e)}
    outcome["ran_at"] = str(datetime.now(pytz.utc))
    return outcome


@app.function(image=image, timeout=4800, memory=256)
async def manual_summary_trigger():
    """Manual trigger - processes users at 22:00 in their timezone."""
    import pytz

    print(f'Manual trigger started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    try:
        result = await send_daily_summary(api_key)
        return {"status": "success", **result, "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e)}


@app.function(image=image, timeout=720, memory=256)
async def manual_summary_for_user(uid: str, date: str = ""):
    """
    Manual trigger to generate summary for a specific user.
    FCM push notification is handled by the API endpoint.

    Usage:
        modal run memorion_daily_summary.py::manual_summary_for_user --uid <user_id>
        modal run memorion_daily_summary.py::manual_summary_for_user --uid <user_id> --date 2026-03-02
    """
    import pytz

    print(f'Manual summary for user {uid} started at {datetime.now(pytz.utc)}')

    # Initialize Firebase (needed for Firestore FCM token lookup and messaging)
    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    if not date:
        date = datetime.now(pytz.utc).strftime("%Y-%m-%d")

    result = call_daily_summary_api(uid, date, api_key)
    # FCM notification is sent by the API endpoint itself
    result["notification"] = "handled_by_backend" if result.get("status") in ("success", "queued") else "skipped"

    return result


@app.function(image=image, timeout=720, memory=256)
async def manual_catch_up_for_user(uid: str, date: str):
    """
    Catch up one user's entry for a day that has ended — the cron's morning pass for a single
    date: written if missing, rewritten if it leaves out conversations of that day, unchanged
    otherwise. Never sends a push, so it is the way to backfill.

    Usage (calls the deployed function; see the warning above `daily_summary_cronjob`):
        python3 backend/scripts/catch_up_daily_journals.py <user_id> 2026-10-25 [2026-10-26 ...]
    """
    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}
    return call_daily_summary_api(uid, date, api_key, catch_up=True)


# ============================================
# Local Testing
# ============================================

if __name__ == "__main__":
    print("Memorion Daily Summary Cron Job (API-based)")
    print()
    print("Deploy:       modal deploy memorion_daily_summary.py")
    print("Manual run:   modal run memorion_daily_summary.py::manual_summary_trigger")
    print("Single user:  modal run memorion_daily_summary.py::manual_summary_for_user --uid <uid>")
    print("With date:    modal run memorion_daily_summary.py::manual_summary_for_user --uid <uid> --date 2026-03-02")
    print("Backfill:     python3 backend/scripts/catch_up_daily_journals.py <uid> 2026-03-02 [...]")
    print("⚠️  `modal run` also starts this file's hourly cron while it lives; see daily_summary_cronjob.")
