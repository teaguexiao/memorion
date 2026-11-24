import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/services/wals.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Listener implements IWalSyncListener {
  int updates = 0;
  @override
  void onMissingWalUpdated() => updates++;
  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) {}
}

class _Phone extends Fake implements LocalWalSync {
  final deleted = <Wal>[];
  @override
  Future<void> deleteWal(Wal wal) async => deleted.add(wal);
}

class _Sdcard extends Fake implements SDCardWalSync {
  final deleted = <Wal>[];
  @override
  Future<void> deleteWal(Wal wal) async => deleted.add(wal);
}

Wal _recording(WalStorage storage, {String? path}) => Wal(
      timerStart: 1700000000,
      codec: BleAudioCodec.opus,
      storage: storage,
      status: WalStatus.miss,
      filePath: path,
      device: storage == WalStorage.sdcard ? 'test-device' : 'phone',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('deleting a phone recording never sends an SD card deletion and vice versa', () async {
    final phone = _Phone();
    final sdcard = _Sdcard();
    final syncs = WalSyncs(_Listener(), phone: phone, sdcard: sdcard);
    final memory = _recording(WalStorage.mem);
    final disk = _recording(WalStorage.disk);
    final sd = _recording(WalStorage.sdcard);
    await syncs.deleteWal(memory);
    await syncs.deleteWal(disk);
    expect(phone.deleted, [memory, disk]);
    expect(sdcard.deleted, isEmpty);
    await syncs.deleteWal(sd);
    expect(sdcard.deleted, [sd]);
    expect(phone.deleted, [memory, disk]);
  });

  test('local deletion removes only the selected file and persists the updated queue immediately', () async {
    final temp = await Directory.systemTemp.createTemp('memorion-wal-delete-');
    addTearDown(() => temp.delete(recursive: true));
    final selected = await File('${temp.path}/selected.bin').writeAsBytes([1, 2]);
    final retained = await File('${temp.path}/retained.bin').writeAsBytes([3, 4]);
    SharedPreferencesUtil().wals = [
      _recording(WalStorage.disk, path: selected.path),
      _recording(WalStorage.disk, path: retained.path)..timerStart += 1,
    ];
    final listener = _Listener();
    final sync = LocalWalSync(listener)..start();
    addTearDown(sync.stop);
    await sync.deleteWal((await sync.getMissingWals()).first);
    expect(await selected.exists(), isFalse);
    expect(await retained.readAsBytes(), [3, 4]);
    expect((await sync.getMissingWals()).single.filePath, retained.path);
    expect(SharedPreferencesUtil().wals.single.filePath, retained.path);
    expect(listener.updates, 1);
  });

  test('active local recording is retained', () async {
    SharedPreferencesUtil().wals = [_recording(WalStorage.disk)];
    final listener = _Listener();
    final sync = LocalWalSync(listener)..start();
    addTearDown(sync.stop);
    final wal = (await sync.getMissingWals()).single..isSyncing = true;
    await expectLater(sync.deleteWal(wal), throwsStateError);
    expect((await sync.getMissingWals()).single, wal);
    expect(SharedPreferencesUtil().wals, hasLength(1));
    expect(listener.updates, 0);
  });

  test('SD deletion rejects a stale device recording before issuing commands', () async {
    final listener = _Listener();
    final sync = SDCardWalSync(listener);
    await expectLater(sync.deleteWal(_recording(WalStorage.sdcard)), throwsStateError);
    expect(listener.updates, 0);
  });
}
