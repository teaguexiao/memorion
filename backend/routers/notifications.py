import os
import secrets

from fastapi import APIRouter, Depends, Header, HTTPException

import database.developer_data as dev_db
from models.other import SaveFcmTokenRequest, SaveNotificationPreferencesRequest
from utils.notifications import send_notification
from utils.other import endpoints as auth


router = APIRouter()


@router.post('/v1/users/fcm-token')
def save_token(data: SaveFcmTokenRequest, ctx: tuple = Depends(auth.get_current_user_context)):
    developer_id, uid = ctx
    if developer_id:
        dev_db.set_user_fcm_token(developer_id, uid, data.fcm_token)
        if data.time_zone:
            dev_db.set_user_time_zone(developer_id, uid, data.time_zone)
        dev_db.get_user_subscription(developer_id, uid)
    return {'status': 'Ok'}


@router.post('/v1/users/notification-preferences')
def save_notification_preferences(
    data: SaveNotificationPreferencesRequest,
    ctx: tuple = Depends(auth.get_current_user_context),
):
    """同步 App 端通知开关到服务端，让服务端 FCM 推送 honor 这些偏好。

    与 /v1/users/fcm-token 同款鉴权。字段全部可选，只更新传入的（合并写入）。
    """
    developer_id, uid = ctx
    if not developer_id:
        return {'status': 'Ok', 'preferences': None}
    prefs = dev_db.set_notification_preferences(
        developer_id, uid, data.model_dump(exclude_none=True),
    )
    return {'status': 'Ok', 'preferences': prefs}


@router.get('/v1/users/notification-preferences')
def read_notification_preferences(ctx: tuple = Depends(auth.get_current_user_context)):
    """App 启动时回读通知偏好，修「重装/换机后设置页显示的与服务端实际执行的不一致」。

    在这个端点之前同步是单向的（只有上面那个 POST），本地一清就回到默认值，而云端
    仍是用户上次设的值 —— 设置页显示开着、服务端其实不推，用户无从自查。

    ⚠️ **`stored_keys` 是这个端点的重点，别为了「响应干净」把它删掉。**
    `preferences` 总是全字段（缺的按默认补齐），因此「用户显式设成 True」和「从没设过、
    默认 True」在值上一模一样。客户端必须只覆盖 `stored_keys` 里的字段，否则回读会把
    服务端此刻的默认值固化成用户设置，此后改默认值对这批用户永久无效。
    详见 dev_db.get_notification_preferences_detailed 的注释。
    """
    developer_id, uid = ctx
    prefs, stored_keys = dev_db.get_notification_preferences_detailed(developer_id, uid)
    return {'status': 'Ok', 'preferences': prefs, 'stored_keys': stored_keys}


# ******************************************************
# ******************* TEAM ENDPOINTS *******************
# ******************************************************


@router.post('/v1/notification')
def send_notification_to_user(data: dict, secret_key: str = Header(...)):
    """给指定 uid 手动发一条 FCM 推送。运维/客服用，无业务副作用。

    鉴权用 OPS_NOTIFICATION_KEY，**不再复用 ADMIN_KEY** —— 后者是那个自报 uid
    的后门密钥，2026-08-08 已置空拆除，不能让这个端点把它绑活。

    `not ops_key` 那半个判断不能省：空串等于空串，只写 `!=` 的话密钥一旦缺失，
    传个空的 secret-key 头就能给任意 uid 发推送。ADMIN_KEY 置空时这里真这么漏过
    一次（见 tests/test_admin_key_neutralized.py）。
    """
    ops_key = os.getenv('OPS_NOTIFICATION_KEY')
    # 比 bytes 而不是 str：compare_digest 对非 ASCII 的 str 会抛 TypeError，
    # 而 header 值是 latin-1 解出来的，塞个非 ASCII 字符就能把 403 变成 500。
    if not ops_key or not secrets.compare_digest(secret_key.encode('utf-8', 'replace'), ops_key.encode()):
        raise HTTPException(status_code=403, detail='You are not authorized to perform this action')
    if not data.get('uid'):
        raise HTTPException(status_code=400, detail='uid is required')
    if not data.get('title') or not data.get('body'):
        # 原来缺这俩会 KeyError 冒成 500（审计报告 L18）。
        raise HTTPException(status_code=400, detail='title and body are required')
    uid = data['uid']
    # 这个端点能给任意用户发推送，调用必须留痕 —— 之前一条日志都没有，
    # 排查「谁发的」只能靠猜。
    print(f'[ops-notification] uid={uid} title={str(data["title"])[:60]!r}')
    developer_id = data.get('developer_id')
    token = None
    if developer_id:
        token = dev_db.get_user_fcm_token(developer_id, uid)
    if not token and uid:
        from utils.people import get_platform_developer_id
        fallback_dev_id = get_platform_developer_id()
        if fallback_dev_id:
            token = dev_db.get_user_fcm_token(fallback_dev_id, uid)
    send_notification(token, data['title'], data['body'], data.get('data', {}))
    return {'status': 'Ok'}
