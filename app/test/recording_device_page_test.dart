import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/recording_device_page.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/recording_source_provider.dart';
import 'package:memorion/services/devices.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Devices extends Fake implements IDeviceService {
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
}

class _DeviceState extends DeviceProvider {
  _DeviceState() : super(deviceService: _Devices());
  void connect(DeviceType? type) {
    // Preserve a cached device when disconnected, as the real provider can.
    if (type != null) connectedDevice = BtDevice(id: 'test', name: 'test', type: type, rssi: -45);
    isConnected = type != null;
    notifyListeners();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  for (final language in ['zh', 'en']) {
    testWidgets('all supported devices stay visible through connection changes ($language)', (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final devices = _DeviceState();
      final source = RecordingSourceProvider();
      addTearDown(devices.dispose);
      addTearDown(source.dispose);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<DeviceProvider>.value(value: devices),
          ChangeNotifierProvider.value(value: source),
        ],
        child: MaterialApp(
          locale: Locale(language),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const RecordingDevicePage(),
        ),
      ));
      for (final connected in <DeviceType?>[null, ...DeviceType.values, null]) {
        devices.connect(connected);
        await tester.pumpAndSettle();
        for (final type in [DeviceType.memorion, DeviceType.soundcore, DeviceType.dingtalkA1, DeviceType.plaudNote, DeviceType.chipletRing]) {
          final id = type == DeviceType.memorion ? 'recording_source_ble' : 'recording_source_${type.name}';
          final row = find.byKey(ValueKey(id));
          expect(row, findsOneWidget);
          expect(
            find.descendant(
              of: row,
              matching: find.text((type == DeviceType.memorion ? devices.canStreamAudio : type == connected)
                  ? (language == 'zh' ? '已连接' : 'Connected')
                  : (language == 'zh' ? '未连接' : 'Not connected')),
            ),
            findsOneWidget,
          );
        }
        expect(find.byKey(const ValueKey('recording_source_phone')), findsOneWidget);
        expect(find.byKey(const ValueKey('recording_source_watch')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
