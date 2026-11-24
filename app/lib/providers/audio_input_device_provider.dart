import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/services/audio_input_device_service.dart';

/// 音频输入设备管理 Provider
/// 管理可用设备列表、选中设备、持久化偏好
class AudioInputDeviceProvider extends ChangeNotifier {
  final AudioInputDeviceService _service = AudioInputDeviceService();

  List<AudioInputDevice> _availableDevices = [];
  AudioInputDevice? _selectedDevice;
  bool _isScanning = false;
  bool _initialized = false;
  Timer? _debounceTimer;  // 防抖：路由变化可能短时间内连续触发

  List<AudioInputDevice> get availableDevices => _availableDevices;
  AudioInputDevice? get selectedDevice => _selectedDevice;
  bool get isScanning => _isScanning;

  /// 当前选中设备（保证非 null，降级到默认）
  AudioInputDevice get currentDevice => _selectedDevice ?? AudioInputDevice.defaultDevice;

  AudioInputDeviceProvider() {
    _service.onRouteChanged = _onRouteChanged;
    // 延迟到 widget 绑定就绪后初始化，避免 MethodChannel 未准备好时卡死
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    if (_initialized) return;
    try {
      final devices = await _service.getAvailableInputs();
      _availableDevices = devices;
      _restorePreference();
      _initialized = true;
    } catch (e) {
      debugPrint('AudioInputDeviceProvider: init failed: $e');
      // 初始化失败时使用默认设备，不阻塞 UI
      _availableDevices = [AudioInputDevice.defaultDevice];
      _selectedDevice = AudioInputDevice.defaultDevice;
      _initialized = true;
      notifyListeners();
    }
  }

  /// 路由变化时防抖刷新（500ms 内多次变化只触发一次）
  void _onRouteChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      refreshDevices();
    });
  }

  /// 刷新可用设备列表
  Future<void> refreshDevices() async {
    _isScanning = true;
    notifyListeners();

    try {
      final devices = await _service.getAvailableInputs();
      _availableDevices = devices;

      // 检查当前选中设备是否仍然可用
      if (_selectedDevice != null) {
        final stillAvailable = devices.any((d) => d.id == _selectedDevice!.id);
        if (!stillAvailable) {
          debugPrint('AudioInputDeviceProvider: preferred device offline, falling back to default');
          _selectedDevice = _findDefaultDevice(devices);
        }
      }
    } catch (e) {
      debugPrint('AudioInputDeviceProvider: refreshDevices failed: $e');
    }

    _isScanning = false;
    notifyListeners();
  }

  /// 恢复持久化的偏好设备
  void _restorePreference() {
    final preferredId = SharedPreferencesUtil().preferredAudioInputId;
    if (preferredId.isEmpty) {
      _selectedDevice = _findDefaultDevice(_availableDevices);
    } else {
      final match = _availableDevices.where((d) => d.id == preferredId).firstOrNull;
      if (match != null) {
        _selectedDevice = match;
      } else {
        // 偏好设备不在线，降级
        _selectedDevice = _findDefaultDevice(_availableDevices);
      }
    }
    notifyListeners();
  }

  /// 切换设备
  Future<void> switchDevice(AudioInputDevice device) async {
    if (device.id == _selectedDevice?.id) return;

    final success = await _service.setPreferredInput(device.id);
    if (success) {
      _selectedDevice = device;
      SharedPreferencesUtil().preferredAudioInputId = device.id;
      notifyListeners();
    }
  }

  /// 录音前确保首选输入设备已设置
  Future<void> ensurePreferredInput() async {
    if (_selectedDevice != null) {
      await _service.setPreferredInput(_selectedDevice!.id);
    }
  }

  /// 查找默认设备（优先内置麦克风）
  AudioInputDevice _findDefaultDevice(List<AudioInputDevice> devices) {
    return devices.firstWhere(
      (d) => d.type == AudioInputDeviceType.phone,
      orElse: () => devices.isNotEmpty ? devices.first : AudioInputDevice.defaultDevice,
    );
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _service.onRouteChanged = null;
    super.dispose();
  }
}
