import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:memorion/models/calendar_event.dart';
import 'package:memorion/utils/platform/platform_service.dart';

/// 只读访问系统日历。写入能力**故意不提供** —— 授权页与隐私页对用户的承诺是
/// "不会新增、修改或删除"，约束落在代码而不只是文案（对应
/// `ios/Runner/AppleCalendarService.swift`）。
class AppleCalendarService {
  static const _channel = MethodChannel('me.memorion.api/apple_calendar');

  static final AppleCalendarService _instance = AppleCalendarService._internal();
  factory AppleCalendarService() => _instance;
  AppleCalendarService._internal();

  bool get isAvailable => PlatformService.isApple;

  /// 是否已拿到读日历的权限（iOS 17+ 要求 full access，原生侧已兼容）。
  Future<bool> hasPermission() async {
    if (!isAvailable) return false;
    try {
      return await _channel.invokeMethod('hasPermission') == true;
    } catch (e) {
      debugPrint('[calendar] hasPermission failed: $e');
      return false;
    }
  }

  /// 请求权限。已被永久拒绝时系统不再弹框，这里直接返回 false，由调用方引导去设置。
  Future<bool> requestPermission() async {
    if (!isAvailable) return false;
    try {
      return await _channel.invokeMethod('requestPermission') == true;
    } catch (e) {
      debugPrint('[calendar] requestPermission failed: $e');
      return false;
    }
  }

  /// 读取 [start, end) 窗口内的行程，按开始时间升序。
  ///
  /// 无权限或读取失败时返回空列表——调用方（同步器）据此跳过本轮，
  /// 不区分"真的没有日程"和"读不到"，因为两种情况下都不该改动服务端数据。
  Future<List<DeviceCalendarEvent>> getEvents({
    required DateTime start,
    required DateTime end,
  }) async {
    if (!isAvailable) return [];
    try {
      final result = await _channel.invokeMethod('getEvents', {
        'startMs': start.millisecondsSinceEpoch,
        'endMs': end.millisecondsSinceEpoch,
      });
      if (result is! List) return [];
      return result.map(DeviceCalendarEvent.fromNative).whereType<DeviceCalendarEvent>().toList();
    } on PlatformException catch (e) {
      debugPrint('[calendar] getEvents failed: ${e.code} ${e.message}');
      return [];
    } catch (e) {
      debugPrint('[calendar] getEvents unexpected error: $e');
      return [];
    }
  }
}
