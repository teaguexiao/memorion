import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:memorion/providers/onboarding_provider.dart';
import 'package:memorion/pages/today_chapters/device_pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/pages/today_chapters/widgets/ring_storage_card.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fake_ring.dart';
import 'fake_device_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RingHarness h;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    h = RingHarness(Directory.systemTemp.createTempSync('ring-management-'));
    h.peer.directory = [fixtureRecording(0)];
  });
  tearDown(() => h.close());

  test('inspection never downloads or uploads recordings', () async {
    final snapshot = await h.sync.inspectDevice();
    expect(snapshot.files.length, 1);
    expect(snapshot.total, 16777216);
    expect(h.peer.downloads, 0);
    expect(h.uploads, 0);
  });
  test('unconfirmed or unknown-content erase never reaches peripheral', () async {
    await expectLater(h.sync.inspectDevice(clear: true), throwsArgumentError);
    h.peer.directory = [fixtureRecording(1, type: 'F')];
    await expectLater(h.sync.inspectDevice(clear: true, confirmed: true), throwsFormatException);
    expect(h.peer.erases, 0);
  });
  test('clear verifies remote storage and preserves saved audio and receipts', () async {
    final recording = h.peer.directory.first;
    await h.sync.sync();
    final result = await h.sync.inspectDevice(clear: true, confirmed: true);
    expect(result.files, isEmpty);
    expect(result.free, result.total);
    expect(h.peer.erases, 1);
    expect(h.sync.deviceFileCount, 0);
    expect(h.sync.receipts[recording.id], isNotNull);
    expect(await h.store.audio(recording.id).exists(), isTrue);
    await h.sync.sync();
    expect(h.peer.downloads, 1);
    expect(h.uploads, 1);
  });
  test('failed erase is not retried automatically or reported as empty', () async {
    h.peer.ineffectiveErase = true;
    await expectLater(h.sync.inspectDevice(clear: true, confirmed: true), throwsFormatException);
    expect(h.peer.erases, 1);
    expect(h.peer.directory.length, 1);
    expect(h.sync.deviceFileCount, isNot(0));
    expect(h.sync.maintenanceBusy, isFalse);
  });
  test('storage failure blocks erase and permits a later read', () async {
    h.peer.failStorage = true;
    await expectLater(h.sync.inspectDevice(clear: true, confirmed: true), throwsStateError);
    expect(h.peer.erases, 0);
    h.peer.failStorage = false;
    expect((await h.sync.inspectDevice()).files.length, 1);
  });
  test('maintenance excludes background sync and recording', () async {
    h.peer.storageGate = Completer();
    final read = h.sync.inspectDevice();
    await Future<void>.delayed(Duration.zero);
    await h.sync.sync();
    await h.sync.startRecording();
    expect(h.peer.starts, 0);
    expect(h.peer.downloads, 0);
    await expectLater(h.sync.inspectDevice(clear: true, confirmed: true), throwsStateError);
    h.peer.storageGate!.complete();
    await read;
    expect(h.peer.erases, 0);
  });
  test('account or BLE loss during inspection cannot start erase', () async {
    for (final loseAccount in [true, false]) {
      h.owner = 'alice';
      h.peer.storageGate = Completer();
      final read = h.sync.inspectDevice(clear: true, confirmed: true);
      final check = expectLater(read, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      if (loseAccount) {
        h.owner = 'bob';
        await h.sync.cancelForAccount();
      } else {
        h.peer.stream.add({'event': 'connection', 'connected': false});
      }
      h.peer.storageGate!.complete();
      await check;
    }
    expect(h.peer.erases, 0);
  });
  test('recording and active transfer block device erase', () async {
    await h.sync.startRecording();
    expect(h.sync.connected, isTrue);
    await expectLater(h.sync.inspectDevice(clear: true, confirmed: true), throwsStateError);
    await h.sync.cancelForAccount();
    h.peer.downloadGate = Completer();
    final importing = h.sync.sync();
    while (h.peer.downloads == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await expectLater(h.sync.inspectDevice(clear: true, confirmed: true), throwsStateError);
    h.peer.downloadGate!.complete();
    await importing;
    expect(h.peer.erases, 0);
  });

  test('stopping capture imports audio before automatic management refresh', () async {
    h.peer.directory = [];
    await h.sync.startRecording();
    Future<void>? refresh;
    void readWhenIdle() {
      if (!h.sync.busy && refresh == null) {
        // Assign before inspectDevice synchronously notifies its listeners.
        final done = Completer<void>();
        refresh = done.future;
        h.sync.inspectDevice().then((_) => done.complete(), onError: done.completeError);
      }
    }

    h.sync.addListener(readWhenIdle);
    await h.sync.stopRecording();
    await refresh;
    h.sync.removeListener(readWhenIdle);
    expect(h.uploads, 1);
    expect(h.sync.recordings.single.type, 'LOCAL');
    expect(h.sync.localAudio, contains(h.sync.recordings.single.id));
    expect(h.peer.erases, 0);
  });

  Future<void> openCard(WidgetTester tester, String language, {bool connected = true}) async {
    await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: Scaffold(body: RingStorageCard(controller: h.sync, connected: connected))));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  Future<void> finishRead(WidgetTester tester) async {
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }

  for (final language in ['zh', 'en']) {
    testWidgets('confirmation cancel keeps audio; confirmed clear refreshes capacity ($language)', (tester) async {
      await openCard(tester, language);
      await tester.tap(find.byKey(const ValueKey('ring_clear_recordings')));
      await tester.pumpAndSettle();
      expect(find.textContaining(language == 'zh' ? '尚未导入' : 'not been imported'), findsOneWidget);
      await tester.tap(find.text(language == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(h.peer.erases, 0);
      await tester.tap(find.byKey(const ValueKey('ring_clear_recordings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ring_confirm_erase')));
      await tester.pumpAndSettle();
      await finishRead(tester);
      expect(h.peer.erases, 1);
      expect(find.textContaining(language == 'zh' ? '戒指内 0 条' : '0 recordings on ring'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_clear_recordings'))).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('ring details show metadata, battery, recordings and disconnect ($language)', (tester) async {
      final device = BtDevice(id: 'ring-fixture', name: 'BCL603B2C8', type: DeviceType.chipletRing, rssi: -45)
        ..hardwareRevision = '603V1.23.2'
        ..firmwareRevision = '6.0.1.8Z62';
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final provider = ManagementDeviceProvider(device);
      addTearDown(provider.dispose);
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ChangeNotifierProvider<DeviceProvider>.value(
          value: provider,
          child: MaterialApp(
              locale: Locale(language),
              localizationsDelegates: S.localizationsDelegates,
              supportedLocales: S.supportedLocales,
              home: DeviceDetailPage(ringController: h.sync))));
      await tester.pumpAndSettle();
      await finishRead(tester);
      expect(find.text('76%'), findsWidgets);
      expect(find.text(language == 'zh' ? '设备录音' : 'Device recordings'), findsOneWidget);
      final firmware = find.text(language == 'zh' ? '更新固件' : 'Firmware Update');
      await tester.ensureVisible(firmware);
      await tester.tap(firmware);
      await tester.pumpAndSettle();
      expect(find.textContaining(language == 'zh' ? 'OTA 尚未接入，也尚未检查' : 'OTA is not integrated yet'), findsOneWidget);
      await tester.tap(find.text(language == 'zh' ? '知道了' : 'OK'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('603V1.23.2'), 200);
      expect(find.text('BCL603B2C8'), findsOneWidget);
      expect(find.text('6.0.1.8Z62'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('603V1.23.2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('603V1.23.2'));
      await tester.pump();
      expect(copied, '603V1.23.2');
      final disconnect = find.text(language == 'zh' ? '断开设备' : 'Disconnect');
      await tester.scrollUntilVisible(disconnect, 120);
      await tester.tap(disconnect);
      await tester.pumpAndSettle();
      expect(find.text(language == 'zh' ? '确定断开与设备的连接吗？' : 'Disconnect from this device?'), findsOneWidget);
      await tester.tap(find.text(language == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(provider.isConnected, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('confirmed offline unpair forgets ring and opens pairing without erasing audio', (tester) async {
    final device = BtDevice(id: 'ring-fixture', name: 'BCL603B2C8', type: DeviceType.chipletRing, rssi: -45);
    await SharedPreferencesUtil().btDeviceSet(device);
    final provider = ManagementDeviceProvider(device, connected: false);
    final onboarding = ManagementOnboarding();
    addTearDown(provider.dispose);
    addTearDown(onboarding.dispose);
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<DeviceProvider>.value(value: provider),
          ChangeNotifierProvider<OnboardingProvider>.value(value: onboarding),
        ],
        child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: DeviceDetailPage(ringController: h.sync))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('device_disconnect')), 200);
    await tester.tap(find.text('Unpair'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(SharedPreferencesUtil().btDevice.id, isEmpty);
    expect(provider.isConnected, isFalse);
    expect(provider.connectedDevice, isNull);
    expect(provider.pairedDevice, isNull);
    expect(find.byType(DevicePairingPage), findsOneWidget);
    expect(onboarding.scans, 1);
    expect(h.peer.erases, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('ring disconnect stays locked while storage is being queried', (tester) async {
    h.peer.storageGate = Completer();
    final device = BtDevice(id: 'ring-fixture', name: 'BCL603B2C8', type: DeviceType.chipletRing, rssi: -45);
    final provider = ManagementDeviceProvider(device);
    addTearDown(provider.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<DeviceProvider>.value(
        value: provider,
        child: MaterialApp(
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: DeviceDetailPage(ringController: h.sync))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('device_disconnect')), 200);
    expect(tester.widget<GestureDetector>(find.byKey(const ValueKey('device_disconnect'))).onTap, isNull);
    h.peer.storageGate!.complete();
    await finishRead(tester);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('device_disconnect')), 200);
    expect(tester.widget<GestureDetector>(find.byKey(const ValueKey('device_disconnect'))).onTap, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('unknown files explain why clearing storage is unavailable', (tester) async {
    h.peer.directory = [fixtureRecording(0, type: 'F')];
    await openCard(tester, 'en');
    expect(find.textContaining('Other file types'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_clear_recordings'))).onPressed, isNull);
    expect(h.peer.erases, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('storage failure is recoverable and never enables erase', (tester) async {
    h.peer.failStorage = true;
    await openCard(tester, 'en');
    expect(find.textContaining('Could not verify'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_clear_recordings'))).onPressed, isNull);
    h.peer.failStorage = false;
    await tester.tap(find.byKey(const ValueKey('ring_refresh_storage')));
    await tester.pumpAndSettle();
    await finishRead(tester);
    expect(find.textContaining('1 recordings on ring'), findsOneWidget);
    expect(h.peer.erases, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('disconnected ring offers reconnect and cannot erase', (tester) async {
    h.connected = false;
    await openCard(tester, 'zh', connected: false);
    expect(find.text('连接戒指后可查看存储'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('ring_clear_recordings'))).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('ring_reconnect')));
    await finishRead(tester);
    expect(h.connected, isTrue);
    expect(h.peer.erases, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
