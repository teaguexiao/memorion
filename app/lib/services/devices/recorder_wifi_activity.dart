/// A manual Wi-Fi handoff temporarily owns a recorder, including when its BLE
/// link disappears. Keep this independent of BLE connection/session lifetime.
class RecorderWifiActivity {
  static final _owners = <String, Set<Object>>{};

  static bool isActive(String? deviceId) => _owners[deviceId]?.isNotEmpty ?? false;

  static void Function() acquire(String deviceId) {
    final token = Object();
    (_owners[deviceId] ??= {}).add(token);
    return () {
      final owners = _owners[deviceId];
      owners?.remove(token);
      if (owners?.isEmpty ?? false) _owners.remove(deviceId);
    };
  }
}
