"""
Memorion Morning Quote Push Cron Job

每小时运行一次，找出本地时间为 08:00 的时区用户，推送昨天的「每日情绪寄语」。

与生成任务解耦：
- memorion_daily_quote.py 负责在 20:00 生成当天的寄语（落库）
- 本任务负责在次日 08:00 推送昨天的寄语（从 Firestore 读取）

这样设计的好处：
1. 生成与推送分离，降低耦合
2. 用户早上收到前一天的回顾，时间上更合理
3. 即使昨天生成失败，今早推送也能优雅降级（跳过无数据用户）

后端入口：GET /v1/mood/daily-quote?date={yesterday}&external_user_id={uid}
"""
import json
import os
import asyncio
import concurrent.futures
from datetime import datetime, timedelta
from typing import List

import requests
from modal import Image, App, Secret, Cron


# ============================================
# Modal App Configuration
# ============================================

app = App(
    name='memorion-morning-quote-push',
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
TARGET_TIME = "08:00"  # 用户本地早上 8:00


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
    """Get all timezones currently at the target time (e.g., '08:00')."""
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


def get_yesterday_date_for_timezone(tz_name: str) -> str:
    """Get yesterday's date string (YYYY-MM-DD) in the given timezone."""
    import pytz

    tz = pytz.timezone(tz_name)
    yesterday = datetime.now(tz) - timedelta(days=1)
    return yesterday.strftime("%Y-%m-%d")


async def get_users_in_timezones(timezones: List[str]) -> List[dict]:
    """
    Get user IDs and their timezone for users in specific timezones.
    Searches both developer_data and top-level users collections.

    Returns list of {"uid": str, "timezone": str, "collection": str, "fcm_token": str}
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
        """Query developer_data/{dev_id}/users for matching timezones."""
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
                        "fcm_token": doc_data.get('fcm_token'),
                    })
            except Exception as e:
                print(f"Error querying developer_data chunk: {e}")
            return results

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
    for result_list in results:
        for user in result_list:
            if user["uid"] not in seen_uids:
                seen_uids.add(user["uid"])
                users.append(user)

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
# Note: FCM push is now handled by the backend API
# The /v1/mood/daily-quote/generate endpoint with push=true
# will handle all FCM logic internally
# ============================================


# ============================================
# API Call
# ============================================

def fetch_and_push_yesterday_quote(uid: str, date_str: str, api_key: str) -> dict:
    """
    Fetch yesterday's mood quote and trigger push via API.

    POST /v1/mood/daily-quote/generate?external_user_id={uid}
    Body: {"date": date_str, "push": true, "force_regenerate": false}

    This endpoint will:
    1. Fetch the existing quote from cache/Firestore
    2. Send FCM push if quote has real emotion signal (is_fallback=false)
    3. Return quote data with push status

    Returns:
        dict: {
            "status": "success" | "no_data" | "error",
            "uid": str,
            "data": {...} | None,
            "pushed": bool,
            ...
        }
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
    params = {
        "external_user_id": uid,
    }
    payload = {
        "date": date_str,
        "push": True,  # Enable push notification
        "force_regenerate": False,  # Use cached quote
    }

    try:
        print(f"  Calling API for {uid[:8]}... date={date_str}")
        resp = requests.post(url, headers=headers, params=params, json=payload, timeout=120)

        if resp.status_code == 200:
            data = resp.json()
            pushed = data.get('pushed', False)
            print(f"  OK: emotion={data.get('dominant_emotion')} "
                  f"fallback={data.get('is_fallback')} pushed={pushed}")
            return {"status": "success", "uid": uid, "pushed": pushed, "data": data}
        elif resp.status_code == 404:
            print(f"  No quote found for user {uid[:8]} on {date_str}")
            return {"status": "no_data", "uid": uid, "pushed": False}
        else:
            print(f"  API error {resp.status_code}: {resp.text[:200]}")
            return {"status": "error", "uid": uid, "code": resp.status_code, "detail": resp.text[:200], "pushed": False}

    except requests.Timeout:
        print(f"  Timeout for user {uid[:8]}")
        return {"status": "timeout", "uid": uid, "pushed": False}
    except Exception as e:
        print(f"  Exception for user {uid[:8]}: {e}")
        return {"status": "exception", "uid": uid, "detail": str(e), "pushed": False}


# ============================================
# Core Processing
# ============================================

async def process_morning_quotes(users: List[dict], api_key: str):
    """
    Fetch yesterday's quotes and trigger push via backend API.

    The backend API handles:
    - Fetching quote from cache/Firestore
    - Checking if quote has real emotion signal
    - Sending FCM push notification
    - Returning push status
    """
    loop = asyncio.get_running_loop()

    def process_user(user):
        uid = user["uid"]
        tz = user["timezone"]

        # Get yesterday's date in user's timezone
        date_str = get_yesterday_date_for_timezone(tz)

        # Call API to fetch quote and send push
        # The API will handle FCM push internally
        api_result = fetch_and_push_yesterday_quote(uid, date_str, api_key)
        return api_result

    # Process users concurrently (max 5 at a time)
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        tasks = [loop.run_in_executor(pool, process_user, u) for u in users]
        api_results = await asyncio.gather(*tasks)

    # Aggregate results (thread-safe, after all tasks complete)
    results = {"success": 0, "pushed": 0, "no_data": 0, "error": 0}
    for api_result in api_results:
        status = api_result.get("status", "error")
        if status == "success":
            results["success"] += 1
            if api_result.get("pushed"):
                results["pushed"] += 1
        elif status == "no_data":
            results["no_data"] += 1
        else:
            results["error"] += 1

    return results


async def send_morning_quotes(api_key: str):
    """Main function: find users at 08:00 local time and push yesterday's quotes."""
    print("Starting morning quote push...")

    timezones = get_timezones_at_time(TARGET_TIME)
    if not timezones:
        print(f"No timezones at {TARGET_TIME} right now")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(timezones)} timezones at {TARGET_TIME}")

    users = await get_users_in_timezones(timezones)
    if not users:
        print("No users found in matching timezones")
        return {"users_found": 0, "results": {}}

    print(f"Found {len(users)} users for morning quote push")
    for u in users[:10]:  # Log first 10
        print(f"  - {u['uid'][:8]}... tz={u['timezone']} ({u['collection']})")
    if len(users) > 10:
        print(f"  ... and {len(users) - 10} more users")

    results = await process_morning_quotes(users, api_key)
    print(f"Morning quote push completed: {results}")
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
async def morning_quote_push_cronjob():
    """Scheduled morning quote push cron job - runs every hour, fires at users' local 08:00."""
    import pytz

    print(f'Cron job started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    try:
        result = await send_morning_quotes(api_key)
        return {"status": "success", **result, "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e)}


@app.function(image=image, timeout=600, memory=256)
async def manual_morning_push_trigger():
    """Manual trigger - processes users at 08:00 in their timezone."""
    import pytz

    print(f'Manual trigger started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    try:
        result = await send_morning_quotes(api_key)
        return {"status": "success", **result, "ran_at": str(datetime.now(pytz.utc))}
    except Exception as e:
        print(f'Error: {e}')
        import traceback
        traceback.print_exc()
        return {"status": "error", "message": str(e)}


@app.function(image=image, timeout=300, memory=256)
async def manual_morning_push_for_user(uid: str, date: str = ""):
    """
    Manual trigger to push yesterday's quote for a specific user.

    Usage:
        modal run memorion_morning_quote_push.py::manual_morning_push_for_user --uid <user_id>
        modal run memorion_morning_quote_push.py::manual_morning_push_for_user --uid <user_id> --date 2026-06-04
    """
    import pytz

    print(f'Manual morning push for user {uid} started at {datetime.now(pytz.utc)}')

    if not initialize_firebase():
        return {"status": "error", "message": "Firebase initialization failed"}

    api_key = _get_api_key()
    if not api_key:
        return {"status": "error", "message": "MEMORION_CRON_API_KEY not configured"}

    # Get user timezone from Firestore
    from firebase_admin import firestore
    db = firestore.client()

    print(f'Querying Firestore for user {uid[:8]}...')
    # Try developer_data first
    user_doc = db.collection('developer_data').document(DEFAULT_DEVELOPER_ID).collection('users').document(uid).get()
    if not user_doc.exists:
        print(f'  Not found in developer_data, trying top-level users...')
        # Fallback to top-level users
        user_doc = db.collection('users').document(uid).get()

    if not user_doc.exists:
        print(f'  ERROR: User not found anywhere')
        return {"status": "error", "message": f"User {uid} not found"}

    user_data = user_doc.to_dict()
    tz_name = user_data.get('time_zone', 'UTC')
    print(f'  Found user: timezone={tz_name}')

    # Determine target date
    if not date:
        import pytz
        tz = pytz.timezone(tz_name)
        yesterday = datetime.now(tz) - timedelta(days=1)
        date = yesterday.strftime("%Y-%m-%d")

    print(f'Target date: {date}')

    # Call API to fetch quote and send push
    # The backend API handles FCM push internally
    print(f'Calling backend API...')
    result = fetch_and_push_yesterday_quote(uid, date, api_key)

    # Add date to result
    result["date"] = date
    print(f'Final result: {result}')
    return result


# ============================================
# Local Testing
# ============================================

if __name__ == "__main__":
    print("Memorion Morning Quote Push Cron Job")
    print()
    print("Deploy:       modal deploy memorion_morning_quote_push.py")
    print("Manual run:   modal run memorion_morning_quote_push.py::manual_morning_push_trigger")
    print("Single user:  modal run memorion_morning_quote_push.py::manual_morning_push_for_user --uid <uid>")
    print("With date:    modal run memorion_morning_quote_push.py::manual_morning_push_for_user --uid <uid> --date 2026-06-04")
