import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:memorion/services/devices.dart';
import 'chiplet_ring/bridge.dart';
import 'device_connection.dart';
import 'offline_device_connection.dart';

/// BluetoothDevice holds identity; the isolated native ring transport owns GATT.
class RingDeviceConnection extends OfflineDeviceConnection with WidgetsBindingObserver {
  final RingTransport transport;
  RingDeviceConnection(super.device, super.bleDevice, {RingTransport? transport})
      : transport = transport ?? NativeRingTransport.instance;
  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  StreamSubscription<Map<String, dynamic>>? _events;
  Function(String, DeviceConnectionState)? _changed;
  int _generation = 0;
  final _batteryEvents = StreamController<List<int>>.broadcast(sync: true);
  int? _batteryLevel;
  DateTime? _batteryReadAt;
  Timer? _batteryPoll;
  Future<int>? _batteryRead;
  bool _observing = false;
  bool _foreground = true;
  @override
  DateTime? get pongAt => _batteryReadAt;
  @override
  DeviceConnectionState get status => _state;
  @override
  DeviceConnectionState get connectionState => _state;
  @override
  Future<bool> isConnected() async => !isDisposed && _state == DeviceConnectionState.connected;
  @override
  Future<void> connect(
      {Function(String, DeviceConnectionState)? onConnectionStateChanged, bool isReconnect = false}) async {
    if (isDisposed) throw DeviceConnectionException('Ring connection retired');
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final epoch = ++_generation;
    _batteryPoll?.cancel();
    _batteryLevel = null;
    _batteryReadAt = null;
    _batteryRead = null;
    _changed = onConnectionStateChanged;
    await _events?.cancel();
    _events = transport.events.listen((event) {
      if (isDisposed || epoch != _generation || event['id'] != device.id) return;
      // Ready is published after native GATT setup and metadata initialization.
      if (event['event'] == 'connection' && event['connected'] == false) {
        _generation++;
        _batteryPoll?.cancel();
        _state = DeviceConnectionState.disconnected;
        _changed?.call(device.id, _state);
      } else if (event['event'] == 'battery' && event['value'] is num) {
        _publishBattery((event['value'] as num).toInt());
      }
    });
    await transport.connect(device.id);
    if (isDisposed || epoch != _generation) throw DeviceConnectionException('Ring connection replaced');
    device.firmwareRevision = await transport.firmware();
    if (isDisposed || epoch != _generation) throw DeviceConnectionException('Ring connection replaced');
    device.hardwareRevision = await transport.hardware();
    if (isDisposed || epoch != _generation) throw DeviceConnectionException('Ring connection replaced');
    if (device.hardwareRevision.toUpperCase().contains('V1.23.')) {
      await transport.configureRecordingFeedback();
      if (isDisposed || epoch != _generation) throw DeviceConnectionException('Ring connection replaced');
    }
    _state = DeviceConnectionState.connected;
    _changed?.call(device.id, _state);
    _batteryPoll = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!isDisposed && _foreground && !transport.busy && _state == DeviceConnectionState.connected) {
        unawaited(_readBattery().catchError((Object _) => -1));
      }
    });
  }

  @override
  Future<void> disconnect() async {
    _generation++;
    _batteryPoll?.cancel();
    _batteryRead = null;
    _state = DeviceConnectionState.disconnected;
    _changed?.call(device.id, _state);
    _changed = null;
    await _events?.cancel();
    _events = null;
    await transport.disconnect();
  }

  @override
  Future<void> retire() async {
    if (isDisposed) return;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
    try {
      await super.retire();
    } finally {
      await _batteryEvents.close();
    }
  }

  @override
  Future<bool> ping() async {
    if (!await isConnected()) return false;
    // Long transfers and live audio already establish transport activity. A
    // routine liveness check must not interrupt them or query in background.
    if (!_foreground || transport.busy) return true;
    try {
      await _readBattery();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> performRetrieveBatteryLevel() => _readBattery();

  void _publishBattery(int value) {
    if (isDisposed || _state != DeviceConnectionState.connected || value < -1 || value > 100) return;
    _batteryLevel = value;
    _batteryReadAt = DateTime.now();
    _batteryEvents.add([value]);
  }

  Future<int> _readBattery() {
    final pending = _batteryRead;
    if (pending != null) return pending;
    if (transport.busy || !_foreground) return Future.value(_batteryLevel ?? -1);
    final epoch = _generation;
    final read = () async {
      final value = await transport.battery();
      if (!isDisposed && epoch == _generation) _publishBattery(value);
      return value;
    }();
    _batteryRead = read;
    unawaited(read.then<void>((_) {
      if (identical(_batteryRead, read)) _batteryRead = null;
    }, onError: (Object _) {
      if (identical(_batteryRead, read)) _batteryRead = null;
    }));
    return read;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !isDisposed && _state == DeviceConnectionState.connected && !transport.busy) {
      unawaited(_readBattery().catchError((Object _) => -1));
    }
  }

  @override
  Future<StreamSubscription<List<int>>?> performGetBleBatteryLevelListener(
      {void Function(int)? onBatteryLevelChange}) async {
    final epoch = _generation;
    final subscription = _batteryEvents.stream.listen((value) {
      if (!isDisposed && epoch == _generation && _state == DeviceConnectionState.connected) {
        onBatteryLevelChange?.call(value.first);
      }
    });
    final cached = _batteryLevel;
    if (cached != null) {
      onBatteryLevelChange?.call(cached);
    } else {
      // Query replies return through MethodChannel; the ring need not push a
      // battery notification before the normal app can show its percentage.
      try {
        await _readBattery();
      } catch (_) {
        // Keep the listener for later push/poll updates if the read fails.
      }
    }
    return subscription;
  }
}
