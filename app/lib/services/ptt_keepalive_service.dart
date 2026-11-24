import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// PTT 后台保活桥接服务（单例）
///
/// 封装对 iOS 原生 `com.memorion.ios/ptt_keepalive` MethodChannel 的调用。
/// BLE 长按 Push-to-Talk 期间,整条转写链路(按钮事件、转发音频、Talk API
/// WebSocket)都跑在 Dart 层,app 进入后台后会被 iOS 冻结。原生侧用一段静音
/// 音频 + `audio` background mode 把 app 撑在活跃态,使后台长按也能完成转写。
///
/// 用法:`_startPttSession` 时 `begin()`,`_endPttSession` 时 `end()`。
/// Android 走的是 flutter_background_service 前台服务,无需本桥接;非 iOS 平台
/// 所有方法都是安全的 no-op。
class PttKeepAliveService {
  PttKeepAliveService._();
  static final PttKeepAliveService instance = PttKeepAliveService._();

  static const MethodChannel _channel = MethodChannel('com.memorion.ios/ptt_keepalive');

  bool get _supported => Platform.isIOS;

  /// 开始后台音频保活。失败不抛异常(前台场景下保活非必需),仅记录日志。
  Future<bool> begin() async {
    if (!_supported) return false;
    try {
      final result = await _channel.invokeMethod<bool>('begin');
      debugPrint('[PttKeepAlive] begin → $result');
      return result ?? false;
    } catch (e) {
      debugPrint('[PttKeepAlive] begin failed: $e');
      return false;
    }
  }

  /// 结束后台音频保活,释放音频焦点。
  Future<void> end() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('end');
      debugPrint('[PttKeepAlive] end');
    } catch (e) {
      debugPrint('[PttKeepAlive] end failed: $e');
    }
  }
}
