from datetime import datetime

import requests

from database.redis_db import (
    get_user_webhook_db,
    user_webhook_status_db,
    disable_user_webhook_db,
    enable_user_webhook_db,
)
from models.conversation import Conversation
from models.users import WebhookType


def conversation_created_webhook(uid, memory: Conversation):
    toggled = user_webhook_status_db(uid, WebhookType.memory_created)
    if toggled:
        webhook_url = get_user_webhook_db(uid, WebhookType.memory_created)
        if not webhook_url:
            return
        webhook_url += f'?uid={uid}'
        try:
            response = requests.post(
                webhook_url,
                json=memory.as_dict_cleaned_dates(),
                headers={'Content-Type': 'application/json'},
                timeout=30,
            )
            print('memory_created_webhook:', webhook_url, response.status_code)
        except Exception as e:
            print(f"Error sending memory created to developer webhook: {e}")
    else:
        return


def day_summary_webhook(uid, summary: str):
    toggled = user_webhook_status_db(uid, WebhookType.day_summary)
    if toggled:
        webhook_url = get_user_webhook_db(uid, WebhookType.day_summary)
        if not webhook_url:
            return
        webhook_url += f'?uid={uid}'
        try:
            response = requests.post(
                webhook_url,
                json={'summary': summary, 'uid': uid, 'created_at': datetime.now().isoformat()},
                headers={'Content-Type': 'application/json'},
                timeout=30,
            )
            print('day_summary_webhook:', webhook_url, response.status_code)
        except Exception as e:
            print(f"Error sending day summary to developer webhook: {e}")
    else:
        return


def webhook_first_time_setup(uid: str, wType: WebhookType) -> bool:
    res = False
    url = get_user_webhook_db(uid, wType)
    if url == '' or url == ',':
        disable_user_webhook_db(uid, wType)
        res = False
    else:
        enable_user_webhook_db(uid, wType)
        res = True
    return res
