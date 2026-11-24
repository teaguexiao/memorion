import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/plaud_connection.dart';

class _Battery extends Fake implements BluetoothCharacteristic {
  final events = StreamController<List<int>>.broadcast(sync: true);
  List<int> initial = [76];
  List<int>? immediateNotification;
  bool failRead = false, failNotify = false, readable = true, notifiable = true;
  @override
  CharacteristicProperties get properties => CharacteristicProperties(read: readable, notify: notifiable);
  @override
  Stream<List<int>> get onValueReceived => events.stream;
  @override
  Future<bool> setNotifyValue(bool notify, {int timeout = 15, bool forceIndications = false}) async {
    if (failNotify) throw StateError('unavailable');
    if (immediateNotification != null) events.add(immediateNotification!);
    return true;
  }

  @override
  Future<List<int>> read({int timeout = 15}) async {
    if (failRead) throw StateError('unavailable');
    // flutter_blue_plus also emits reads on onValueReceived.
    events.add(initial);
    return initial;
  }
}

class _Service extends Fake implements BluetoothService {}

class _Connection extends PlaudDeviceConnection {
  final _Battery battery;
  Completer<BluetoothService?>? pendingService;
  _Connection(this.battery)
      : super(BtDevice(id: 'note', name: 'PLAUD Note', type: DeviceType.plaudNote, rssi: -45),
            BluetoothDevice.fromId('note'));
  @override
  Future<BluetoothService?> getService(String uuid) async {
    final pending = pendingService;
    return pending != null ? await pending.future : _Service();
  }

  @override
  BluetoothCharacteristic? getCharacteristic(BluetoothService service, String uuid) => battery;
}

void main() {
  late _Battery battery;
  late _Connection connection;
  late List<int> values;
  setUp(() {
    battery = _Battery();
    connection = _Connection(battery);
    values = [];
  });
  tearDown(() async => battery.events.close());
  test('steady battery is read immediately; pushes update once and invalid values are ignored', () async {
    final subscription = await connection.performGetBleBatteryLevelListener(onBatteryLevelChange: values.add);
    expect(values, [76]);
    battery.events.add([75]);
    battery.events.add([75]);
    for (final invalid in [
      <int>[],
      [255],
      [1, 2],
      [-1]
    ]) {
      battery.events.add(invalid);
    }
    expect(values, [76, 75]);
    await subscription!.cancel();
    battery.events.add([74]);
    expect(values, [76, 75]);
  });
  test('listener precedes immediate notify; failed initial read keeps notifications alive', () async {
    battery.immediateNotification = [62];
    battery.failRead = true;
    final subscription = await connection.performGetBleBatteryLevelListener(onBatteryLevelChange: values.add);
    expect(values, [62]);
    battery.events.add([61]);
    expect(values, [62, 61]);
    await subscription!.cancel();
  });
  for (final readOnly in [false, true]) {
    test('initial read survives missing or failed notifications (read only: $readOnly)', () async {
      battery.notifiable = !readOnly;
      battery.failNotify = !readOnly;
      final subscription = await connection.performGetBleBatteryLevelListener(onBatteryLevelChange: values.add);
      expect(values, [76]);
      expect(subscription, null);
      expect(battery.events.hasListener, false);
    });
  }
  test('reinitializing replaces the previous subscription', () async {
    await connection.performGetBleBatteryLevelListener(onBatteryLevelChange: values.add);
    final replacement = <int>[];
    final subscription = await connection.performGetBleBatteryLevelListener(onBatteryLevelChange: replacement.add);
    battery.events.add([70]);
    expect(values, [76]);
    expect(replacement, [76, 70]);
    await subscription!.cancel();
  });
  test('a superseded setup cannot replace the new battery listener', () async {
    final pending = Completer<BluetoothService?>();
    connection.pendingService = pending;
    final oldSetup = connection.performGetBleBatteryLevelListener(onBatteryLevelChange: values.add);
    await Future<void>.delayed(Duration.zero);
    connection.pendingService = null;
    final replacement = <int>[];
    final subscription = await connection.performGetBleBatteryLevelListener(onBatteryLevelChange: replacement.add);
    pending.complete(_Service());
    expect(await oldSetup, null);
    battery.events.add([70]);
    expect(values, isEmpty);
    expect(replacement, [76, 70]);
    await subscription!.cancel();
  });
}
