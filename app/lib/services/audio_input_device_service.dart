import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/utils/revamp_text.dart';

/// 音频输入设备类型
enum AudioInputDeviceType {
  phone,
  bluetooth,
  headphones,
  external_,
}

extension AudioInputDeviceTypeExt on AudioInputDeviceType {
  /// 设备类型对应的 emoji
  String get emoji {
    switch (this) {
      case AudioInputDeviceType.phone:
        return '📱';
      case AudioInputDeviceType.bluetooth:
        return '⌚';
      case AudioInputDeviceType.headphones:
        return '🎧';
      case AudioInputDeviceType.external_:
        return '🎤';
    }
  }

  /// 设备类型中文标签
  String get label {
    switch (this) {
      case AudioInputDeviceType.phone:
        return 'iPhone';
      case AudioInputDeviceType.bluetooth:
        return '蓝牙设备';
      case AudioInputDeviceType.headphones:
        return '耳机';
      case AudioInputDeviceType.external_:
        return '外置麦克风';
    }
  }

  /// 设备类型英文标签
  String get labelEn {
    switch (this) {
      case AudioInputDeviceType.phone:
        return 'iPhone';
      case AudioInputDeviceType.bluetooth:
        return 'Bluetooth device'; // i18n-ignore: bilingual pair for revampText
      case AudioInputDeviceType.headphones:
        return 'Headphones';
      case AudioInputDeviceType.external_:
        return 'External mic';
    }
  }

  /// 连接方式描述
  String get connectionMethod {
    switch (this) {
      case AudioInputDeviceType.phone:
        return '内置';
      case AudioInputDeviceType.bluetooth:
        return '蓝牙';
      case AudioInputDeviceType.headphones:
        return '有线/蓝牙';
      case AudioInputDeviceType.external_:
        return 'USB';
    }
  }

  /// 连接方式描述（英文）
  String get connectionMethodEn {
    switch (this) {
      case AudioInputDeviceType.phone:
        return 'Built-in';
      case AudioInputDeviceType.bluetooth:
        return 'Bluetooth';
      case AudioInputDeviceType.headphones:
        return 'Wired / Bluetooth';
      case AudioInputDeviceType.external_:
        return 'USB';
    }
  }

  /// 音质标签
  String get qualityTag {
    switch (this) {
      case AudioInputDeviceType.phone:
        return '标准';
      case AudioInputDeviceType.bluetooth:
        return '标准';
      case AudioInputDeviceType.headphones:
        return '高清';
      case AudioInputDeviceType.external_:
        return '高清';
    }
  }

  /// 音质标签（英文）
  String get qualityTagEn {
    switch (this) {
      case AudioInputDeviceType.phone:
        return 'Standard';
      case AudioInputDeviceType.bluetooth:
        return 'Standard';
      case AudioInputDeviceType.headphones:
        return 'HD';
      case AudioInputDeviceType.external_:
        return 'HD';
    }
  }

  /// 是否高清音质
  bool get isHighQuality {
    return this == AudioInputDeviceType.headphones || this == AudioInputDeviceType.external_;
  }

  /// 胶囊主题色 — 随设备类型变化
  Color get capsuleColor {
    switch (this) {
      case AudioInputDeviceType.phone:
        return const Color(0xFF6B7280); // 灰色/中性色
      case AudioInputDeviceType.bluetooth:
        return const Color(0xFF7B61FF); // 紫色（品牌色）
      case AudioInputDeviceType.headphones:
        return const Color(0xFF3B82F6); // 蓝色
      case AudioInputDeviceType.external_:
        return const Color(0xFF7B61FF); // 紫色
    }
  }

  /// 胶囊渐变色（麦克风按钮部分）
  List<Color> get capsuleGradient {
    switch (this) {
      case AudioInputDeviceType.phone:
        return const [Color(0xFF6B7280), Color(0xFF9CA3AF)];
      case AudioInputDeviceType.bluetooth:
        return const [Color(0xFF6C4DE6), Color(0xFF8B5CF6)];
      case AudioInputDeviceType.headphones:
        return const [Color(0xFF3B82F6), Color(0xFF6366F1)];
      case AudioInputDeviceType.external_:
        return const [Color(0xFF6C4DE6), Color(0xFF8B5CF6)];
    }
  }

  /// 胶囊文字颜色
  Color get capsuleTextColor {
    switch (this) {
      case AudioInputDeviceType.phone:
        return const Color(0xFFCCCCCC);
      case AudioInputDeviceType.bluetooth:
        return const Color(0xFFC4B5FD);
      case AudioInputDeviceType.headphones:
        return const Color(0xFF93C5FD);
      case AudioInputDeviceType.external_:
        return const Color(0xFFC4B5FD);
    }
  }

  /// 胶囊左侧背景色
  Color get capsuleBgColor {
    switch (this) {
      case AudioInputDeviceType.phone:
        return const Color(0xFF6B7280).withOpacity(0.12);
      case AudioInputDeviceType.bluetooth:
        return const Color(0xFF6C4DE6).withOpacity(0.15);
      case AudioInputDeviceType.headphones:
        return const Color(0xFF3B82F6).withOpacity(0.12);
      case AudioInputDeviceType.external_:
        return const Color(0xFF6C4DE6).withOpacity(0.15);
    }
  }

  /// 胶囊左侧边框色
  Color get capsuleBorderColor {
    switch (this) {
      case AudioInputDeviceType.phone:
        return const Color(0xFF6B7280).withOpacity(0.18);
      case AudioInputDeviceType.bluetooth:
        return const Color(0xFF6C4DE6).withOpacity(0.25);
      case AudioInputDeviceType.headphones:
        return const Color(0xFF3B82F6).withOpacity(0.25);
      case AudioInputDeviceType.external_:
        return const Color(0xFF6C4DE6).withOpacity(0.25);
    }
  }

  /// 设备短名（用于胶囊显示）
  String get shortName {
    switch (this) {
      case AudioInputDeviceType.phone:
        return 'iPhone';
      case AudioInputDeviceType.bluetooth:
        return 'Watch';
      case AudioInputDeviceType.headphones:
        return 'AirPods';
      case AudioInputDeviceType.external_:
        return 'Mic';
    }
  }

  /// 估算延迟描述
  String get latencyLabel {
    switch (this) {
      case AudioInputDeviceType.phone:
        return '延迟 <1ms';
      case AudioInputDeviceType.bluetooth:
        return '延迟 12ms';
      case AudioInputDeviceType.headphones:
        return '延迟 <1ms';
      case AudioInputDeviceType.external_:
        return '延迟 <1ms';
    }
  }

  /// 估算延迟描述（英文）
  String get latencyLabelEn {
    switch (this) {
      case AudioInputDeviceType.phone:
        return 'Latency <1ms';
      case AudioInputDeviceType.bluetooth:
        return 'Latency 12ms';
      case AudioInputDeviceType.headphones:
        return 'Latency <1ms';
      case AudioInputDeviceType.external_:
        return 'Latency <1ms';
    }
  }
}

/// 音频输入设备模型
class AudioInputDevice {
  final String id;
  final String name;
  final AudioInputDeviceType type;
  final bool isConnected;

  const AudioInputDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isConnected,
  });

  factory AudioInputDevice.fromMap(Map<dynamic, dynamic> map) {
    return AudioInputDevice(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      type: _parseType(map['type'] as String? ?? 'phone'),
      isConnected: map['isConnected'] as bool? ?? false,
    );
  }

  static AudioInputDeviceType _parseType(String type) {
    switch (type) {
      case 'phone':
        return AudioInputDeviceType.phone;
      case 'bluetooth':
        return AudioInputDeviceType.bluetooth;
      case 'headphones':
        return AudioInputDeviceType.headphones;
      case 'external':
        return AudioInputDeviceType.external_;
      default:
        return AudioInputDeviceType.phone;
    }
  }

  /// Stable id for the built-in mic default instance, used to localize its name.
  static const String builtInMicId = 'built_in_mic';

  /// iPhone 内置麦克风的默认实例
  static const AudioInputDevice defaultDevice = AudioInputDevice(
    id: builtInMicId,
    name: 'iPhone 麦克风', // i18n-ignore: 占位常量，渲染走 displayName() 的 revampText
    type: AudioInputDeviceType.phone,
    isConnected: true,
  );

  /// Localized display name. The built-in mic carries a hardcoded Chinese name,
  /// so swap it for the user's language; real devices keep their system name.
  String displayName(BuildContext context) {
    if (id == builtInMicId) {
      return revampText(context, en: 'iPhone Mic', zh: 'iPhone 麦克风'); // i18n-ignore: revampText handles both languages
    }
    return name;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AudioInputDevice && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AudioInputDevice($name, $type, connected=$isConnected)';
}

/// 音频输入设备服务 — 封装 iOS MethodChannel 调用（单例）
class AudioInputDeviceService {
  static const _channel = MethodChannel('com.memorion.ios/audio_input');
  static final AudioInputDeviceService _instance = AudioInputDeviceService._internal();

  factory AudioInputDeviceService() => _instance;

  /// 路由变化回调
  VoidCallback? onRouteChanged;

  AudioInputDeviceService._internal() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onRouteChange') {
      debugPrint('AudioInputDeviceService: route changed');
      onRouteChanged?.call();
    }
  }

  /// 获取所有可用输入设备
  Future<List<AudioInputDevice>> getAvailableInputs() async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('getAvailableInputs');
      return result
          .cast<Map<dynamic, dynamic>>()
          .map((m) => AudioInputDevice.fromMap(m))
          .toList();
    } catch (e) {
      debugPrint('AudioInputDeviceService: getAvailableInputs failed: $e');
      return [AudioInputDevice.defaultDevice];
    }
  }

  /// 设置首选输入设备
  Future<bool> setPreferredInput(String deviceId) async {
    try {
      final result = await _channel.invokeMethod('setPreferredInput', {'id': deviceId});
      return result == true;
    } catch (e) {
      debugPrint('AudioInputDeviceService: setPreferredInput failed: $e');
      return false;
    }
  }

  /// 获取当前输入设备
  Future<AudioInputDevice?> getCurrentInput() async {
    try {
      final result = await _channel.invokeMethod('getCurrentInput');
      if (result == null) return null;
      return AudioInputDevice.fromMap(result as Map<dynamic, dynamic>);
    } catch (e) {
      debugPrint('AudioInputDeviceService: getCurrentInput failed: $e');
      return null;
    }
  }
}
