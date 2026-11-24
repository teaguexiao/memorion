import 'package:flutter/foundation.dart';

/// 录音来源：这段音频**从哪个设备的麦克风来**。
///
/// ⚠️ 与 `AudioInputDeviceType`（`services/audio_input_device_service.dart`）是正交的两个
/// 维度，别合并：那个枚举是 AVAudioSession 的**输入路由**（内置麦 / 蓝牙耳机 / 有线耳机 /
/// 外接），走 `setPreferredInput`，只在本枚举取 `phone` 时才有意义。
///
/// 两种来源走两条不同的链路：
/// - `phone`：`CaptureProvider.streamRecording()` → WS `/v1/listen`，实时转录。
/// - `bleDevice`：`CaptureProvider.streamDeviceRecording()` → 同一个 WS，实时转录。
///
/// 🚫 **`watch` 曾经是这里的第三个值，2026-08-19 删掉。** 手表录音是在**手表上**按开始的
/// （watchOS 不允许 iPhone 唤起手表 App 采音），手机这边既给不了选择、也无法阻止它 ——
/// 把它列成一个「可选来源」是在假装手机管得着，而实际后果是用户在这里点了「Apple Watch」
/// 之后什么都不会发生。手表的配对状态与待同步条数仍在「设置 → 录音设备」显示，但那是
/// **告知**，不是**控件**。
enum RecordingSource {
  phone,
  bleDevice,
}

/// 这一次录音走哪条链路。
///
/// ## 为什么不再有「用户选的录音来源」这个持久化偏好（2026-08-19 取消）
///
/// 以前这里存一个三选一、并写进 `SharedPreferencesUtil().recordingSource`。那个单选把
/// **三个不同性质的东西**并列在了一起：
///
/// | 选项 | 谁发起 | 怎么触发 | 持续性 |
/// |---|---|---|---|
/// | `bleDevice` | 系统（被动） | 设备连着就在录 | 连续 |
/// | `phone` | 用户（主动） | 点「开始录音」 | 一次 |
/// | `watch` | 用户（**在另一台设备上**） | 手表上按开始 | 一次 |
///
/// 三者不是「同一个问题的三个答案」，所以单选框在语义上就是错的 —— 这才是它令人困惑的
/// 原因，**不是「藏得太深」**（把它挪到首页只会让一个语义错误的控件更显眼）。而且
/// **每一条的触发动作本身已经表达了选择**：在 App 里点开始 = 手机（或 BLE，如果连着）、
/// 在手表上按 = 手表、设备连着 = 它在录。所以「选择」这一步是多余的。
///
/// 详见 `docs/architecture/录音源与转录路径设计.md` §3.2。
///
/// ⚠️ prefs 里存量的 `recordingSource` 键**被刻意忽略而不是迁移**：它的值只可能是三个
/// 来源之一，而新模型里没有任何一个字段能承接「我一直想用手机录」这个意思 —— 那恰恰是
/// 被判定为不该持久化的东西。
class RecordingSourceProvider extends ChangeNotifier {
  bool _forcePhoneOnce = false;

  /// 「这一次用手机麦克风录」—— 设备连着、但落在包里没戴上时要的就是这个。
  ///
  /// 这是原来那个选择器唯一真正解决的问题（见它最初的注释：「BLE 硬件连着的时候用户
  /// **无法**选择用手机麦克风，而设备就在包里没戴上时这恰恰是想要的行为」）。它被保留
  /// 下来了，只是降级成一次性的。
  ///
  /// ⚠️ **刻意只对下一次录音生效，且不写盘。** 它表达的是**当下的临时状态**，不是偏好。
  /// 用持久化的选择去表达它，代价是「改了忘记改回来」：用户某天忘带设备改成手机，之后
  /// 每次戴着设备录音都在用手机麦克风，而且**没有任何提示**。
  bool get forcePhoneOnce => _forcePhoneOnce;

  void setForcePhoneOnce(bool value) {
    if (_forcePhoneOnce == value) return;
    _forcePhoneOnce = value;
    notifyListeners();
  }

  /// 这一次录音走哪条链路。**纯函数，只看当下** —— 没有偏好可读。
  ///
  /// [bleConnected] 由调用方从 `DeviceProvider` 取。
  RecordingSource resolve({required bool bleConnected}) {
    if (_forcePhoneOnce) return RecordingSource.phone;
    return bleConnected ? RecordingSource.bleDevice : RecordingSource.phone;
  }

  /// 采集真的启动之后调用，让一次性覆盖复位。
  ///
  /// ⚠️ **必须在「真的开始采集」之后调，不能在用户拨开关时就清。** 用户拨完开关很可能先
  /// 去别处逛一圈再回来录，那期间开关必须还在 —— 否则他会以为拨了没生效。
  void consumeForcePhoneOnce() {
    if (!_forcePhoneOnce) return;
    _forcePhoneOnce = false;
    notifyListeners();
  }
}
