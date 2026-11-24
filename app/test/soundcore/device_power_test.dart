import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore_connection.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_device.dart';
import 'package:memorion/services/devices/soundcore/wifi_activity.dart';

class _Connection extends Fake implements SoundcoreDeviceConnection {
  @override
  final SoundcoreSession session;
  @override
  final BtDevice device;
  _Connection(this.session, this.device);
}

class _Devices extends Fake implements IDeviceService {
  final _Connection connection;
  _Devices(this.connection);
  int ensures = 0;
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false}) async {
    ensures++;
    return connection;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeSoundcoreDevice peer;
  late SoundcoreSession session;
  late DeviceProvider provider;
  late BtDevice device;
  late _Devices devices;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    peer = FakeSoundcoreDevice(1767225600);
    session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
    // Device info arrives during connection setup, before the provider listens.
    await session.readInfo();
    device = BtDevice(
      name: '',
      id: 'test-soundcore',
      type: DeviceType.soundcore,
      rssi: -45,
      modelNumber: 'D3200',
      firmwareRevision: '04.92',
    );
    SharedPreferencesUtil().btDevice = device;
    devices = _Devices(_Connection(session, device));
    provider = DeviceProvider(deviceService: devices)
      ..connectedDevice = device
      ..pairedDevice = device
      ..isConnected = true;
    await provider.initiateBleBatteryListener();
  });

  tearDown(() async {
    provider.dispose();
    session.close();
    await peer.inbound.close();
  });

  test('refresh keeps an offline pairing and clears it after unpairing', () async {
    provider.setConnectedDevice(null);
    await provider.getDeviceInfo();
    expect(provider.pairedDevice?.id, device.id);

    await SharedPreferencesUtil().btDeviceSet(BtDevice.empty());
    provider.setConnectedDevice(null);
    await provider.getDeviceInfo();
    expect(provider.pairedDevice, isNull);
  });

  test('foreground and scan leave active Wi-Fi alone, normal device verification resumes after release', () async {
    final release = SoundcoreWifiActivity.acquire(device.id);
    final before = devices.ensures;
    try {
      await provider.verifyConnectionAfterResume();
      await provider.scanAndConnectToDevice();
      expect(devices.ensures, before);
      expect(provider.isConnecting, isFalse);
    } finally {
      release();
    }
    await provider.verifyConnectionAfterResume();
    expect(devices.ensures, greaterThan(before));
  });

  test('first connection immediately exposes both cached batteries and later pushes', () async {
    expect(provider.batteryLevel, 80);
    expect(provider.caseBatteryLevel, 100);
    expect(provider.isCaseCharging, isTrue);
    peer.emit(response(1, 3, [9, 7]));
    peer.emit(response(1, 4, [1, 0]));
    await Future<void>.delayed(Duration.zero);
    expect(provider.batteryLevel, 100);
    expect(provider.caseBatteryLevel, 80);
    expect(provider.isCharging, isTrue);
    expect(provider.isCaseCharging, isFalse);

    provider.setConnectedDevice(null);
    await Future<void>.delayed(Duration.zero);
    peer.emit(response(1, 3, [6, 5]));
    await Future<void>.delayed(Duration.zero);
    expect(provider.batteryLevel, -1);
    expect(provider.caseBatteryLevel, -1);
    expect(provider.isCharging, isFalse);
  });

  for (final language in ['en', 'zh']) {
    testWidgets('charging indicators remain independent after notifications and polling in $language', (tester) async {
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const DeviceDetailPage(),
        ),
      ));
      await tester.pumpAndSettle();

      Finder bolt(String batteryKey) => find.descendant(
            of: find.ancestor(of: find.byKey(ValueKey(batteryKey)), matching: find.byType(Semantics)).first,
            matching: find.byIcon(Icons.bolt_rounded),
          );

      // Includes a docked recorder powered by an unplugged case, and the
      // reverse state when only the case is charging. Polling must preserve it.
      for (final state in [(true, false), (false, true), (true, true), (false, false)]) {
        peer.charging = state.$1;
        peer.caseCharging = state.$2;
        await tester.runAsync(() async {
          peer.emit(response(1, 4, [state.$1 ? 1 : 0, state.$2 ? 1 : 0]));
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect(bolt('soundcore_recorder_battery'), state.$1 ? findsOneWidget : findsNothing);
        expect(bolt('soundcore_case_battery'), state.$2 ? findsOneWidget : findsNothing);
        await tester.runAsync(() async {
          await session.readInfo();
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pumpAndSettle();
        expect(provider.isCharging, state.$1);
        expect(provider.isCaseCharging, state.$2);
        expect(bolt('soundcore_recorder_battery'), state.$1 ? findsOneWidget : findsNothing);
        expect(bolt('soundcore_case_battery'), state.$2 ? findsOneWidget : findsNothing);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('Soundcore details show distinct live batteries and correct identity at 320px in $language',
        (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const DeviceDetailPage(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('soundcore_recorder_battery'))).data, '80%');
      expect(tester.widget<Text>(find.byKey(const ValueKey('soundcore_case_battery'))).data, '100%');
      expect(find.text(language == 'zh' ? '录音豆' : 'Recorder'), findsOneWidget);
      expect(find.text(language == 'zh' ? '充电仓' : 'Charging case'), findsOneWidget);
      await tester.runAsync(() async {
        peer.emit(response(1, 3, [9, 7]));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('soundcore_recorder_battery'))).data, '100%');
      expect(tester.widget<Text>(find.byKey(const ValueKey('soundcore_case_battery'))).data, '80%');
      await tester.scrollUntilVisible(find.text('Soundcore Work'), 150);
      expect(find.text('SOUNDCORE'), findsWidgets);
      expect(find.text('Memorion-v1'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
