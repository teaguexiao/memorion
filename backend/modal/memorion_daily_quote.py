"""
Memorion Daily Mood Quote Cron Job

每小时运行一次，找出本地时间为 20:00 的时区用户，调用 Memorion API
为其生成「今日情绪寄语」并（对有真实情绪信号的用户）发送推送。

与 memorion_daily_summary.py 同构：本 cron 只负责调度与用户发现，
所有重活（情绪聚合、LLM 生成、落库、推送）都由后端 API 完成。

后端入口：POST /v1/mood/daily-quote/generate?external_user_id={uid}
"""
import json
import os
import asyncio
import concurrent.futures
from datetime import datetime
from typing import List

import requests
from modal import Image, App, Secret, Cron


# ============================================
# Modal App Configuration
# ============================================

app = App(
    name='memorion-daily-quote',
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

DEFAULT_DEVELOPER_ID = os.environ.get('MEMORION_APP_DEVELOPER_ID', '')
TARGET_TIME = "20:00"  # 用户本地 8:00 PM


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

def get_timezones_at_time(target_time: str) -> List[str]:
    """Get all timezones currently at the target time (e.g., '20:00')."""
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
        def sync_query():
            results = []
            try:
                users_ref = db.collection('developer_data').document(
                    DEFAULT_DEVELOPER_ID
                ).collection('users')
                query = users_ref.where(filter=FieldFilter('time_zone', 'in', chunk))
                for doc in query.stream():
                    doc_data = doc.to_dict()
                    results.append({
                        "uid": doc.id,
                        "timezone": doc_data.get('time_zone'),
                        "collection": "developer_data",
                    })
            except Exception as e:
                print(f"Error querying developer_data chunk: {e}")
            return results

        return await asyncio.to_thread(sync_query)

    async def query_top_level_users(chunk):
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
                    })
            except Exception as e:
                print(f"Error querying top-level users chunk: {e}")
            return results

        return await asyncio.to_thread(sync_query)

    tasks = []
    for chunk in timezone_chunks:
        tasks.append(query_developer_data(chunk))
        tasks.append(query_top_level_users(chunk))

    results = await asyncio.gather(*tasks)

    # Dedup by uid (prefer developer_data)
    seen_uids = set()
    for result_list in results:
        for user in result_list:
            if user["uid"] not in seen_uids:
                seen_uids.add(user["uid"])
                users.append(user)

    return users


# ============================================
# API Configuration & Call
# ============================================

def _get_api_key() -> str:
    key = os.environ.get("MEMORION_CRON_API_KEY", "")
    if not key:
        print("ERROR: MEMORION_CRON_API_KEY not set in environment")
    return key


def call_generate_mood_quote_api(uid: str, date_str: str, api_key: str) -> dict:
    """
    POST /v1/mood/daily-quote/generate?external_user_id={uid}
    Authorization: {api_key}
    Body: {"date": date_str, "push": true}

    后端：生成寄语 + 落库；仅当含真实情绪信号（非兜底）才推送。
    """
    api_base_url = os.environ.get(
        "MEMORION_CRON_BASE_URL",
        os.environ.get("BASE_API_URL", "https://api.memorion.me")
    ).rstrip("/")
    url = f"{api_base_url}/v1/mood/daily-quote/generate"
    headers = {
        "Authorization": api_key,
        "Content-Type": "application/json",
    }
    payload = {"date": date_str, "push": True, "force_regenerate": False}
    params = {"external_user_id": uid}

    try:
        print(f"  Calling mood-quote API for {uid[:8]}... date={date_str}")
        resp = requests.post(url, headers=headers, json=payload, params=params, timeout=120)
        if resp.status_code == 200:
            data = resp.json()
            print(f"  OK: emotion={data.get('dominant_emotion')} "
                  f"fallback={data.get('is_fallback')} pushed={data.get('pushed')}")
            return {"status": "success", "uid": uid, "data": data}
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

async def process_mood_quotes(users: List[dict], api_key: str):
    """为所有用户生成情绪寄语（调用 API），并发受限。"""
    loop = asyncio.get_running_loop()
    results = {"success": 0, "pushed": 0, "fallback": 0, "error": 0}

    def process_user(user):
        uid = user["uid"]
        tz = user["timezone"]
        date_str = get_today_date_for_timezone(tz)
        return call_generate_mood_quote_api(uid, date_str, api_key)

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        tasks = [loop.run_in_executor(pool, process_user, u) for u in users]
        for result in await asyncio.gather(*tasks):
            status = result.get("status", "error")
            if status == "success":
                results["success"] += 1
                data = result.get("data", {})
                if data.get("pushed"):
                    results["pushed"] += 1
                if data.get("is_fallback"):
                    results["fallback"] += 1
            else:
                results["error"] += 1

    return results


async def send_daily_mood_quotes(api_key: str):
    """Main: find users at 20:00 local time and call the generate API for each."""
    print("Starting daily mood quote generation...")

    timezones = get_timezones_at_time(TARGET_TIME)
    if not timezones:
        print(f"No timezones at {TARGET_TIME} right now")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(timezones)} timezones at {TARGET_TIME}")

    users = await get_users_in_timezones(timezones)
    if not users:
        print("No users found in matching timezones")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(users)} users for daily mood quote")
    for u in users:
        print(f"  - {u['uid'][:8]}... tz={u['timezone']} ({u['collection']})")

    results = await process_mood_quotes(users, api_key)
    print(f"Daily mood quote completed: {results}")
    return {"users_found": len(users), "results": results}


# ============================================
# Cron Job Entry Points
# ============================================

@app.function(
    image=image,
    schedule=Cron('0 * * * *'),  # Every hour at minute 0
    timeout=600,
    memory=256,
)
async def daily_mood_quote_cronjob():
    """Scheduled daily mood quote cron job - runs every hour, fires at users' local 20:00."""
    import pytz

    print(f'Cron job started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    try:
        result = await send_daily_mood_quotes(api_key)
        return {"status": "success", **result, "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e)}


@app.function(image=image, timeout=600, memory=256)
async def manual_mood_quote_trigger():
    """Manual trigger - processes users at 20:00 in their timezone."""
    import pytz

    print(f'Manual trigger started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    try:
        result = await send_daily_mood_quotes(api_key)
        return {"status": "success", **result, "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e)}


@app.function(image=image, timeout=300, memory=256)
async def manual_mood_quote_for_user(uid: str, date: str = ""):
    """
    Manual trigger to generate a mood quote for a specific user.

    Usage:
        modal run memorion_daily_quote.py::manual_mood_quote_for_user --uid <user_id>
        modal run memorion_daily_quote.py::manual_mood_quote_for_user --uid <user_id> --date 2026-06-01
    """
    import pytz

    print(f'Manual mood quote for user {uid} started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    if not date:
        date = datetime.now(pytz.utc).strftime("%Y-%m-%d")

    return call_generate_mood_quote_api(uid, date, api_key)


# ============================================
# Local Testing
# ============================================

if __name__ == "__main__":
    print("Memorion Daily Mood Quote Cron Job (API-based)")
    print()
    print("Deploy:       modal deploy memorion_daily_quote.py")
    print("Manual run:   modal run memorion_daily_quote.py::manual_mood_quote_trigger")
    print("Single user:  modal run memorion_daily_quote.py::manual_mood_quote_for_user --uid <uid>")
    print("With date:    modal run memorion_daily_quote.py::manual_mood_quote_for_user --uid <uid> --date 2026-06-01")
