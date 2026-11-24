"""服务端推送偏好闸门。

App 端本地有一组通知开关（每日一刻 / 待办提醒 / 暂停提醒 / 新发现 / 静默时段），
过去这些开关只对本地通知生效，服务端 FCM 推送无视它们。这里做一个统一入口：
任何服务端推送在发之前先过 `should_send_push`，读取用户同步上来的偏好决定放行与否。

偏好存储在 developer_data/{developer_id}/users/{uid} 文档的 notification_preferences map，
由 POST /v1/users/notification-preferences 同步（见 routers/notifications.py）。
老用户没有记录时按默认放行（见 developer_data.NOTIFICATION_PREFERENCES_DEFAULTS）。
"""

from datetime import datetime
from typing import Optional

import database.developer_data as dev_db

# 推送种类 → 对应的偏好开关字段
_KIND_TO_PREF = {
    'daily_moment': 'daily_moment',   # 每日一刻（日记）day_summary
    'milestone': 'milestone',         # 新发现 insight_card
    'task_reminder': 'task_reminder',
    'pause_reminder': 'pause_reminder',
}


def _in_quiet_hours(prefs: dict, now_minutes: int) -> bool:
    """now_minutes = 用户本地时间自午夜起的分钟数。区间跨午夜时取补集。

    ⚠️ 起点是**闭区间**（now >= start 即静默），所以默认起点不能压在某条推送的
    整点上。每日一刻在本地 22:00 整点推，默认起点因此定在 23:00 —— 别在这里
    另写 fallback 数字，直接引用 defaults，否则两份默认值会悄悄分叉。
    """
    defaults = dev_db.NOTIFICATION_PREFERENCES_DEFAULTS
    start = prefs.get('quiet_hours_start_minutes', defaults['quiet_hours_start_minutes'])
    end = prefs.get('quiet_hours_end_minutes', defaults['quiet_hours_end_minutes'])
    if start == end:
        return False
    if start < end:
        return start <= now_minutes < end
    # 跨午夜，例如 23:00→08:00
    return now_minutes >= start or now_minutes < end


def should_send_push(
    developer_id: str,
    uid: str,
    kind: str,
    user_local_now: Optional[datetime] = None,
) -> bool:
    """服务端推送闸门。

    Args:
        kind: 推送种类，见 _KIND_TO_PREF；未知种类默认放行（不误伤新推送）。
        user_local_now: 用户本地时区的当前时间；提供时才做静默时段判断。
                        拿不到用户时区的调用方可以不传，则跳过静默时段判断。

    Returns:
        True = 允许推送。
    """
    pref_key = _KIND_TO_PREF.get(kind)
    if pref_key is None:
        # 未纳入偏好体系的推送种类，保持原行为（放行）
        return True

    try:
        prefs = dev_db.get_notification_preferences(developer_id, uid)
    except Exception as e:
        # 读偏好失败不该阻断推送——按放行处理，只记日志
        print(f'[notif_gate] {uid[:8]} read prefs failed, defaulting to allow: {e}')
        return True

    if not prefs.get(pref_key, True):
        print(f'[notif_gate] {uid[:8]} kind={kind} blocked by user preference')
        return False

    if prefs.get('quiet_hours_enabled') and user_local_now is not None:
        now_minutes = user_local_now.hour * 60 + user_local_now.minute
        if _in_quiet_hours(prefs, now_minutes):
            print(f'[notif_gate] {uid[:8]} kind={kind} blocked by quiet hours')
            return False

    return True
