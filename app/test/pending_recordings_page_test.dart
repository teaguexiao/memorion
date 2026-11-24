import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/pages/today_chapters/settings_page.dart';
import 'package:memorion/pages/today_chapters/sync_status_page.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/services/devices.dart';
import 'package:memorion/services/wals.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Syncs extends Fake implements WalSyncs {
  final List<Wal> recordings = [];
  final List<Wal> deleted = [];
  bool fail = false;

  @override
  Future<List<Wal>> getMissingWals() async => [...recordings];

  @override
  Future<void> deleteWal(Wal wal) async {
    if (fail) throw StateError('Deletion failed');
    deleted.add(wal);
    recordings.remove(wal);
  }
}

class _WalService extends Fake implements IWalService {
  final _Syncs syncs;
  _WalService(this.syncs);
  @override
  void subscribe(IWalServiceListener subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
  @override
  WalSyncs getSyncs() => syncs;
}

class _Devices extends Fake implements IDeviceService {
  @override
  void subscribe(IDeviceServiceSubsciption subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
}

class _DeviceState extends DeviceProvider {
  _DeviceState() : super(deviceService: _Devices());
  @override
  Future<void> getDeviceInfo({bool forceRefresh = false}) async {}
  @override
  Future<void> readLedMode() async {}

  void connect(DeviceType type, {bool connected = true}) {
    connectedDevice = BtDevice(id: 'device', name: 'test', type: type, rssi: -45);
    pairedDevice = connectedDevice;
    isConnected = connected;
    notifyListeners();
  }
}

Wal _recording(int start, {WalStorage storage = WalStorage.disk}) => Wal(
      timerStart: start,
      codec: BleAudioCodec.opus,
      storage: storage,
      device: storage == WalStorage.sdcard ? 'device' : 'phone',
      status: WalStatus.miss,
    );

void main() {
  late _Syncs syncs;
  late ConversationProvider conversations;
  late _DeviceState devices;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    PackageInfo.setMockInitialValues(
        appName: 'Memorion', packageName: 'test', version: '1.0', buildNumber: '1', buildSignature: '');
    syncs = _Syncs();
    conversations = ConversationProvider(wal: _WalService(syncs));
    devices = _DeviceState()..connect(DeviceType.memorion);
  });

  tearDown(() {
    conversations.dispose();
    devices.dispose();
  });

  Future<void> open(WidgetTester tester, String language, {Widget page = const SyncStatusPage()}) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    conversations.onMissingWalUpdated();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<ConversationProvider>.value(value: conversations),
        ChangeNotifierProvider<DeviceProvider>.value(value: devices),
      ],
      child: MaterialApp(
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)), child: child!),
        home: page,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  for (final language in ['zh', 'en']) {
    testWidgets('connected, pending and active sync labels reflect real state ($language)', (tester) async {
      await open(tester, language);
      expect(
          find.text(language == 'zh' ? '设备已连接 · 暂无待同步录音' : 'Device connected · No pending recordings'), findsOneWidget);
      final wal = _recording(1700000000);
      syncs.recordings.add(wal);
      conversations.onMissingWalUpdated();
      await tester.pumpAndSettle();
      expect(find.text(language == 'zh' ? '设备已连接 · 有待同步录音' : 'Device connected · Pending recordings'), findsOneWidget);
      wal.isSyncing = true;
      conversations.onMissingWalUpdated();
      await tester.pumpAndSettle();
      expect(find.text(language == 'zh' ? '正在同步录音' : 'Syncing recordings'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(ValueKey('delete_pending_${wal.id}'))).onPressed, isNull);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('delete_all_pending_recordings'))).onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deletion requires confirmation and removes only the selected recording ($language)', (tester) async {
      final selected = _recording(1700000000);
      final retained = _recording(1700000001);
      syncs.recordings.addAll([selected, retained]);
      await open(tester, language);
      final delete = find.byKey(ValueKey('delete_pending_${selected.id}'));
      await tapVisible(tester, delete);
      expect(find.text(language == 'zh' ? '删除待同步录音？' : 'Delete pending recording?'), findsOneWidget);
      expect(
          find.text(language == 'zh'
              ? '将从手机或设备中删除这 1 段录音，未同步的内容将无法恢复。'
              : 'Delete this recording from phone or device storage? Unsynced content cannot be recovered.'),
          findsOneWidget);
      expect(syncs.deleted, isEmpty);
      await tester.tap(find.text(language == 'zh' ? '取消' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(syncs.deleted, isEmpty);
      await tapVisible(tester, delete);
      await tester.tap(find.byKey(const ValueKey('confirm_delete_pending_recordings')));
      await tester.pumpAndSettle();
      expect(syncs.deleted, [selected]);
      expect(conversations.missingWals, [retained]);
      expect(find.byKey(ValueKey('pending_recording_${selected.id}')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failed deletion retains recordings and shows a readable error ($language)', (tester) async {
      final wal = _recording(1700000000);
      syncs.recordings.add(wal);
      syncs.fail = true;
      await open(tester, language);
      await tapVisible(tester, find.byKey(ValueKey('delete_pending_${wal.id}')));
      await tester.tap(find.byKey(const ValueKey('confirm_delete_pending_recordings')));
      await tester.pumpAndSettle();
      expect(conversations.missingWals, [wal]);
      expect(syncs.deleted, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(ValueKey('delete_pending_${wal.id}'))).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('bulk confirmation excludes recordings that arrive while the dialog is open', (tester) async {
    final first = _recording(1700000000);
    final second = _recording(1700000001);
    final arrived = _recording(1700000002);
    syncs.recordings.addAll([first, second]);
    await open(tester, 'zh');
    await tapVisible(tester, find.byKey(const ValueKey('delete_all_pending_recordings')));
    syncs.recordings.add(arrived);
    conversations.onMissingWalUpdated();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm_delete_pending_recordings')));
    await tester.pumpAndSettle();
    expect(syncs.deleted, [first, second]);
    expect(conversations.missingWals, [arrived]);
  });

  testWidgets('sync starting during confirmation prevents deletion', (tester) async {
    final wal = _recording(1700000000);
    syncs.recordings.add(wal);
    await open(tester, 'zh');
    await tapVisible(tester, find.byKey(ValueKey('delete_pending_${wal.id}')));
    wal.isSyncing = true;
    await tester.tap(find.byKey(const ValueKey('confirm_delete_pending_recordings')));
    await tester.pumpAndSettle();
    expect(syncs.deleted, isEmpty);
    expect(conversations.missingWals, [wal]);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('completed recordings are not deleted after a stale confirmation', (tester) async {
    final wal = _recording(1700000000);
    syncs.recordings.add(wal);
    await open(tester, 'zh');
    await tapVisible(tester, find.byKey(ValueKey('delete_pending_${wal.id}')));
    wal.status = WalStatus.synced;
    syncs.recordings.clear();
    conversations.onMissingWalUpdated();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm_delete_pending_recordings')));
    await tester.pumpAndSettle();
    expect(syncs.deleted, isEmpty);
    expect(find.text('暂无待同步录音'), findsOneWidget);
  });

  testWidgets('disconnected or different devices cannot delete SD recordings, phone recordings remain manageable',
      (tester) async {
    final phone = _recording(1700000000);
    final sd = _recording(1700000001, storage: WalStorage.sdcard);
    syncs.recordings.addAll([phone, sd]);
    devices.connect(DeviceType.memorion, connected: false);
    await open(tester, 'en');
    expect(tester.widget<IconButton>(find.byKey(ValueKey('delete_pending_${phone.id}'))).onPressed, isNotNull);
    expect(tester.widget<IconButton>(find.byKey(ValueKey('delete_pending_${sd.id}'))).onPressed, isNull);
    devices.connect(DeviceType.soundcore);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(ValueKey('delete_pending_${sd.id}'))).onPressed, isNull);
    devices.connect(DeviceType.memorion);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(ValueKey('delete_pending_${sd.id}'))).onPressed, isNotNull);
  });

  testWidgets('settings leads to traditional device sync management without a local storage entry', (tester) async {
    await open(tester, 'zh', page: const SettingsPage());
    await tester.scrollUntilVisible(find.text('授权设置'), 220);
    expect(find.text('本地存储'), findsNothing);
    await tester.scrollUntilVisible(find.text('设备与固件'), -220);
    await tapVisible(tester, find.text('设备与固件'));
    expect(find.byType(DeviceDetailPage), findsOneWidget);
    await tester.scrollUntilVisible(find.text('同步状态'), 220);
    await tapVisible(tester, find.text('同步状态'));
    expect(find.byType(SyncStatusPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final type in [DeviceType.soundcore, DeviceType.dingtalkA1]) {
    testWidgets('$type retains its own device recordings entry', (tester) async {
      devices.connect(type);
      await open(tester, 'zh', page: const DeviceDetailPage());
      await tester.scrollUntilVisible(find.text('设备录音'), 160);
      expect(find.text('设备录音'), findsOneWidget);
      expect(find.text('同步状态'), findsNothing);
      expect(find.text('本地存储'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
