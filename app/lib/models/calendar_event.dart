/// 一条从系统日历读出的行程（只读快照）。
///
/// 字段刻意保持"骨架"级：标题/时间/地点/所属日历。原生侧不返回备注、参会人、
/// 会议链接——那些内容会上传到服务端，而备注里常有会议密码和私人细节，
/// agent 判断"我什么时候有空、要去哪"用不到（见 AppleCalendarService.serialize）。
class DeviceCalendarEvent {
  /// 稳定唯一键：重复日程每个实例共用同一个 eventIdentifier，
  /// 所以原生侧拼了实例起始时刻。用它做后端文档 id 与本地去重。
  final String instanceId;
  final String title;
  final DateTime startsAt;
  final DateTime? endsAt;
  final bool allDay;
  final bool isRecurring;

  /// 浮动日程：不绑任何时区，按当地墙上时间解读（全天日程都是浮动的）。
  ///
  /// 这类日程的 [startsAt] 会随设备时区变化——用户飞一趟就整体平移，即使日历
  /// 一条没改。所以判"变没变"时必须改用 [localStart]，见 [fingerprint]。
  final bool isFloating;

  /// 当地表示：全天是 `2026-08-06`，其余是 `2026-08-06T14:30:00`。
  final String? localStart;
  final String? localEnd;

  /// 绑定的 IANA 时区；浮动日程为 null。
  final String? timeZone;

  /// EventKit 的 EKEventStatus：confirmed / tentative / canceled / none。
  final String status;
  final String? location;
  final String? calendarTitle;
  final DateTime? lastModifiedAt;

  const DeviceCalendarEvent({
    required this.instanceId,
    required this.title,
    required this.startsAt,
    this.endsAt,
    this.allDay = false,
    this.isFloating = false,
    this.localStart,
    this.localEnd,
    this.timeZone,
    this.isRecurring = false,
    this.status = 'confirmed',
    this.location,
    this.calendarTitle,
    this.lastModifiedAt,
  });

  static DateTime? _msToDate(Object? value) {
    if (value is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  /// 解析原生 method channel 的返回值。字段缺失或类型不符时返回 null 由调用方丢弃，
  /// 而不是抛错——一条脏数据不该让整次同步失败。
  static DeviceCalendarEvent? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<Object?, Object?>.from(raw);
    final instanceId = map['instance_id'];
    final startsAt = _msToDate(map['start_ms']);
    if (instanceId is! String || instanceId.isEmpty || startsAt == null) return null;

    return DeviceCalendarEvent(
      instanceId: instanceId,
      title: (map['title'] as String?) ?? '',
      startsAt: startsAt,
      endsAt: _msToDate(map['end_ms']),
      allDay: map['all_day'] == true,
      isFloating: map['is_floating'] == true,
      localStart: map['local_start'] as String?,
      localEnd: map['local_end'] as String?,
      timeZone: map['time_zone'] as String?,
      isRecurring: map['is_recurring'] == true,
      status: (map['status'] as String?) ?? 'confirmed',
      location: map['location'] as String?,
      calendarTitle: map['calendar_title'] as String?,
      lastModifiedAt: _msToDate(map['last_modified_ms']),
    );
  }

  /// 解析后端返回的 JSON（时间是 ISO-8601 字符串，不是原生的毫秒数）。
  static DeviceCalendarEvent? fromServerJson(Map<String, dynamic> json) {
    final instanceId = json['instance_id'];
    final startsAt = DateTime.tryParse((json['starts_at'] as String?) ?? '');
    if (instanceId is! String || instanceId.isEmpty || startsAt == null) return null;

    DateTime? parse(String key) {
      final raw = json[key] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    return DeviceCalendarEvent(
      instanceId: instanceId,
      title: (json['title'] as String?) ?? '',
      startsAt: startsAt,
      endsAt: parse('ends_at'),
      allDay: json['all_day'] == true,
      isFloating: json['is_floating'] == true,
      localStart: json['local_start'] as String?,
      localEnd: json['local_end'] as String?,
      timeZone: json['time_zone'] as String?,
      isRecurring: json['is_recurring'] == true,
      status: (json['status'] as String?) ?? 'confirmed',
      location: json['location'] as String?,
      calendarTitle: json['calendar_title'] as String?,
      lastModifiedAt: parse('last_modified_at'),
    );
  }

  Map<String, dynamic> toJson() => {
        'instance_id': instanceId,
        'title': title,
        'starts_at': startsAt.toUtc().toIso8601String(),
        if (endsAt != null) 'ends_at': endsAt!.toUtc().toIso8601String(),
        'all_day': allDay,
        'is_floating': isFloating,
        if (localStart != null) 'local_start': localStart,
        if (localEnd != null) 'local_end': localEnd,
        if (timeZone != null) 'time_zone': timeZone,
        'is_recurring': isRecurring,
        'status': status,
        if (location != null && location!.isNotEmpty) 'location': location,
        if (calendarTitle != null && calendarTitle!.isNotEmpty) 'calendar_title': calendarTitle,
        if (lastModifiedAt != null) 'last_modified_at': lastModifiedAt!.toUtc().toIso8601String(),
      };

  /// 内容指纹，用来判断这条行程相对上次同步有没有实质变化。
  ///
  /// 不用 lastModifiedAt：订阅日历里它常年为 null，而重复日程改单个实例时
  /// 父事件的该字段也未必更新。直接比对我们上传的字段最可靠。
  ///
  /// **浮动日程（含全天）用当地表示而非 UTC**：它们的绝对时刻会随设备时区漂移，
  /// 用 UTC 会让一次跨时区飞行把整窗指纹全部作废、白重传一次。见 [isFloating]。
  String get fingerprint => [
        title,
        isFloating ? (localStart ?? startsAt.toIso8601String()) : startsAt.toUtc().toIso8601String(),
        isFloating ? (localEnd ?? '') : (endsAt?.toUtc().toIso8601String() ?? ''),
        allDay,
        timeZone ?? '',
        status,
        location ?? '',
        calendarTitle ?? '',
      ].join('');

  @override
  String toString() => 'DeviceCalendarEvent($title @ $startsAt)';
}
