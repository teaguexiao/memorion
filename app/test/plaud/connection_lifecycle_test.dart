import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ble extends Fake implements BluetoothDevice {
  final events = StreamController<BluetoothConnectionState>.broadcast(sync: true);
  BluetoothConnectionState currentState = BluetoothConnectionState.disconnected;
  Completer<List<BluetoothService>>? discovery;
  bool failConnect = false;
  int disconnects = 0;

  void emit(BluetoothConnectionState value) {
    currentState = value;
    events.add(value);
  }

  @override
  Stream<BluetoothConnectionState> get connectionState async* {
    yield currentState;
    yield* events.stream;
  }

  @override
  Future<void> connect(
      {Duration timeout = const Duration(seconds: 35), int? mtu = 512, bool autoConnect = false}) async {
    if (failConnect) throw DeviceConnectionException('synthetic connect failure');
    emit(BluetoothConnectionState.connected);
  }

  @override
  Future<void> disconnect({int timeout = 35, bool queue = true, int androidDelay = 2000}) async {
    disconnects++;
    emit(BluetoothConnectionState.disconnected);
  }

  @override
  Future<List<BluetoothService>> discoverServices({bool subscribeToServicesChanged = true, int timeout = 15}) async =>
      discovery == null ? [] : await discovery!.future;

  @override
  Future<int> readRssi({int timeout = 15}) async => -45;
}

// Exercise the real base lifecycle and service replacement; unrelated GATT APIs
// are never invoked in these tests.
class _Connection extends DeviceConnection {
  _Connection(_Ble ble) : super(BtDevice(id: 'note', name: 'PLAUD Note', type: DeviceType.plaudNote, rssi: -45), ble);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_blue_plus/methods');
  late _Ble ble;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAdapterState') return {'adapter_state': 4};
      return 0;
    });
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    ble = _Ble();
  });
  tearDown(() async => ble.events.close());

  test('replacement retires disconnected observer before a new connection starts', () async {
    final connections = <_Connection>[];
    final service = DeviceService(createConnection: (_, __) {
      if (connections.isNotEmpty) expect(connections.last.isDisposed, true);
      final connection = _Connection(ble);
      connections.add(connection);
      return connection;
    });
    await service.ensureConnection('note', force: true);
    await _flush();
    ble.emit(BluetoothConnectionState.disconnected);
    await _flush();
    expect(connections.single.status, DeviceConnectionState.disconnected);
    final replacement = await service.ensureConnection('note', force: true);
    await _flush();
    expect(replacement, same(connections.last));
    expect(connections.first.status, DeviceConnectionState.disconnected);
    expect(connections.last.status, DeviceConnectionState.connected);
    await service.forceDisconnect('note');
    expect(ble.events.hasListener, false);
  });

  test('failed known-device connect cancels its observer before retry', () async {
    final connections = <_Connection>[];
    final service = DeviceService(createConnection: (_, __) {
      final connection = _Connection(ble);
      connections.add(connection);
      return connection;
    });
    ble.failConnect = true;
    expect(await service.ensureConnection('note', force: true), null);
    expect(connections.single.isDisposed, true);
    expect(ble.events.hasListener, false);
    ble.failConnect = false;
    expect(await service.ensureConnection('note', force: true), same(connections.last));
    await _flush();
    expect(connections.first.status, DeviceConnectionState.disconnected);
    await service.forceDisconnect('note');
  });

  test('late service discovery after retirement cannot publish reconnect', () async {
    final connection = _Connection(ble);
    final states = <DeviceConnectionState>[];
    await connection.connect(onConnectionStateChanged: (_, state) => states.add(state));
    await _flush();
    ble.emit(BluetoothConnectionState.disconnected);
    await _flush();
    final pending = Completer<List<BluetoothService>>();
    ble.discovery = pending;
    ble.emit(BluetoothConnectionState.connected);
    await _flush();
    await connection.retire();
    states.clear();
    pending.complete([]);
    await _flush();
    expect(states, isEmpty);
    expect(connection.status, DeviceConnectionState.disconnected);
    expect(ble.events.hasListener, false);
  });

  test('the active object continues to observe OS reconnects', () async {
    final connection = _Connection(ble);
    final states = <DeviceConnectionState>[];
    await connection.connect(onConnectionStateChanged: (_, state) => states.add(state));
    await _flush();
    states.clear();
    ble.emit(BluetoothConnectionState.disconnected);
    await _flush();
    ble.emit(BluetoothConnectionState.connected);
    await _flush();
    expect(states, [DeviceConnectionState.disconnected, DeviceConnectionState.connected]);
    await connection.retire();
  });
}
