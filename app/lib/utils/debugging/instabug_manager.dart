import 'package:flutter/material.dart';

/// 崩溃上报 + 应用内反馈封装（Instabug）。
///
/// 2026-07：Instabug SDK 已从项目移除，本类保留为 no-op 空壳——所有调用点
/// 无需改动。日志/崩溃上报不再实际发送，`getNavigatorObserver()` 返回 null
/// （main.dart 的 observer 列表会跳过）。未来若恢复，重新引入 SDK 接回即可。
class InstabugManager {
  static final InstabugManager _instance = InstabugManager._internal();
  static InstabugManager get instance => _instance;

  InstabugManager._internal();

  factory InstabugManager() {
    return _instance;
  }

  static Future<void> init({required String token}) async {
    // no-op：Instabug SDK 已移除。
  }

  Future<void> setWelcomeMessageMode(dynamic mode) async {
    // no-op
  }

  void identifyUser(String email, String name, String userId) {
    // no-op
  }

  void setColorTheme(dynamic theme) {
    // no-op
  }

  void logInfo(String message) {
    // no-op
  }

  void logError(String message) {
    // no-op
  }

  void logWarn(String message) {
    // no-op
  }

  void logDebug(String message) {
    // no-op
  }

  void logVerbose(String message) {
    // no-op
  }

  void show() {
    // no-op
  }

  void setUserAttribute(String key, String value) {
    // no-op
  }

  void setEnabled(bool isEnabled) {
    // no-op
  }

  Future<void> reportCrash(Object exception, StackTrace stackTrace, {Map<String, String>? userAttributes}) async {
    // no-op
  }

  /// 已移除 Instabug，无导航观察器。
  NavigatorObserver? getNavigatorObserver() => null;

  bool get isSupported => false;
}
