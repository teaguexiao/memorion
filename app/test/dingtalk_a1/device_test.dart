import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/devices/device_connection.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity.dart';
import 'package:memorion/services/devices/dingtalk_a1/session.dart';
import 'package:memorion/services/devices/dingtalk_a1_connection.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fake_device.dart';

class Connection extends Fake implements A1DeviceConnection {
  @override
  final A1Session session;
  @override
  final BtDevice device;
  Connection(this.session, this.device);
}

class Devices extends Fake implements IDeviceService {
  final Connection connection;
  Devices(this.connection);
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
  @override
  Future<DeviceConnection?> ensureConnection(String deviceId, {bool force = false}) async => connection;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DeviceProvider provider;
  late A1Session session;
  late FakeA1 peer;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    peer = FakeA1(File('test/dingtalk_a1/fixtures/synthetic_tone.dtyj').readAsBytesSync());
    session =
        A1Session(identity: A1Identity('test', 'corp', 'a' * 32), send: peer.send, notifications: peer.inbound.stream);
    await session.authenticate();
    await session.readInfo();
    final device = BtDevice(
        name: 'DingTalk A1',
        id: 'test-a1',
        type: DeviceType.dingtalkA1,
        rssi: -45,
        modelNumber: 'A1',
        firmwareRevision: 'synthetic');
    SharedPreferencesUtil().btDevice = device;
    provider = DeviceProvider(deviceService: Devices(Connection(session, device)))
      ..connectedDevice = device
      ..pairedDevice = device
      ..isConnected = true;
    await provider.initiateBleBatteryListener();
    await provider.initiateChargingStatusListener();
  });
  tearDown(() async {
    provider.dispose();
    session.close();
    await peer.close();
  });
  test('first connection exposes actual battery and excludes the live-audio path', () {
    expect(provider.batteryLevel, 76);
    expect(provider.caseBatteryLevel, -1);
    expect(provider.isCharging, isFalse);
    expect(provider.canStreamAudio, isFalse);
    expect(provider.havingNewFirmware, isFalse);
  });
  for (final locale in ['en', 'zh']) {
    testWidgets('A1 details show one recorder and its recordings route ($locale)', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: provider,
          child: MaterialApp(
              locale: Locale(locale),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: const DeviceDetailPage())));
      await tester.pumpAndSettle();
      expect(find.text('DingTalk A1'), findsWidgets);
      expect(find.byKey(const ValueKey('soundcore_case_battery')), findsNothing);
      expect(find.text(locale == 'zh' ? '设备录音' : 'Device recordings'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
