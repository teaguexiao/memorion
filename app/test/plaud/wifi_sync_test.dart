import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/import_store.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/sync_controller.dart';
import 'package:memorion/services/devices/plaud/wifi_connector.dart';
import 'package:memorion/services/devices/plaud/wifi_protocol.dart';
import 'package:memorion/services/devices/recorder_wifi_activity.dart';
import 'package:memorion/services/devices/soundcore/wifi_activity.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';
import 'fake_device.dart';
import 'fake_wifi.dart';

void main() {
  const id = 1700000000;
  late Directory root;
  late Peer ble;
  late WifiPeer wifi;
  late PlaudImportStore store;
  late PlaudSyncController sync;
  var owner = 'a', onHotspot = false, failLeave = false, truncate = false;
  var joins = 0, uploads = 0, leaves = 0;
  var reconnects = 0, stallBle = false, failJoin = false, allowBleDownload = false;
  final retired = <Peer>[];
  late Completer<void> bleStarted;
  late Completer<void> openingBle;
  Completer<void>? openSessionGate;
  void Function()? duringDownload;
  final raw = Uint8List(24512)..fillRange(0, 24512, 7);

  setUp(() async {
    owner = 'a';
    onHotspot = failLeave = truncate = false;
    joins = uploads = leaves = 0;
    duringDownload = null;
    root = await Directory.systemTemp.createTemp('plaud-wifi-sync');
    reconnects = 0;
    stallBle = failJoin = allowBleDownload = false;
    retired.clear();
    bleStarted = Completer<void>();
    openingBle = Completer<void>();
    openSessionGate = null;
    ble = Peer(transferIdleTimeout: const Duration(seconds: 10));
    wifi = WifiPeer();
    await ble.connect();
    void handleBle(Peer peer, Uint8List p) {
      if (plaudCommandId(p) == 26) {
        final page = base64.decode(peer.data['listPage']);
        ByteData.sublistView(page)
          ..setUint32(11, id, Endian.little)
          ..setUint32(15, raw.length, Endian.little);
        peer.emit(page);
      } else if (plaudCommandId(p) == 28) {
        if (!allowBleDownload) throw StateError('Unexpected BLE download');
        final head = Uint8List(5);
        ByteData.sublistView(head).setUint32(0, id, Endian.little);
        peer.emit(plaudCommand(28, head));
        for (var offset = 0; offset < raw.length; offset += 200) {
          peer.emit(block(id, offset, raw.sublist(offset, (offset + 200).clamp(0, raw.length))));
          if (stallBle) break;
        }
        if (!bleStarted.isCompleted) bleStarted.complete();
        if (!stallBle) peer.emit(block(id, 0xffffffff, []));
      }
    }

    ble.handle = (p) => handleBle(ble, p);
    wifi.handle = (p) {
      if (p.type == 11) {
        final tail = Uint8List(10);
        ByteData.sublistView(tail)
          ..setUint32(0, id, Endian.little)
          ..setUint32(4, raw.length, Endian.little);
        wifi.emit(PlaudWifiPacket(11, {'status': 0, 'uid': 0, 'count': 1, 'offset': 0}, tail));
      } else if (p.type == 12) {
        duringDownload?.call();
        wifi.emit(PlaudWifiPacket(12, {'status': 0, 'session': id, 'crc': 0}));
        final length = truncate ? 1280 : raw.length;
        wifi.emit(PlaudWifiPacket(
            13, {'session': id, 'offset': 0, 'length': length, 'last': truncate ? 0 : 1}, raw.sublist(0, length)));
      }
    };
    store = PlaudImportStore(
        root: root,
        ownerId: 'a',
        deviceId: 'note',
        currentOwner: () => owner,
        upload: (file, time) async {
          expect(onHotspot, isFalse, reason: 'No upload until OS network cleanup succeeds');
          expect(RecorderWifiActivity.isActive('note'), isFalse);
          uploads++;
          return const OfflineImportReceipt('conversation', processing: true);
        });
    sync = PlaudSyncController(
        deviceId: 'note',
        openStore: () async => store,
        openSession: () async {
          if (openSessionGate != null && !openingBle.isCompleted) openingBle.complete();
          await openSessionGate?.future;
          return onHotspot ? null : ble.session;
        },
        reconnectSession: () async {
          reconnects++;
          expect(RecorderWifiActivity.isActive('note'), isTrue);
          expect(ble.session.isClosed, isTrue);
          expect(await store.cachedOriginal(id), isNull);
          expect(uploads, 0);
          retired.add(ble);
          ble = Peer();
          await ble.connect();
          ble.handle = (p) => handleBle(ble, p);
          return ble.session;
        },
        readIdentity: () async => ble.identity,
        isCurrentOwner: () => owner == 'a',
        decodeAudio: (file) async {
          expect(onHotspot, isFalse);
          expect(await file.readAsBytes(), raw);
          return OfflineDownload(Uint8List.fromList([79, 103, 103, 83]), const Duration(seconds: 6));
        },
        connectWifi: (session, {required isActive, onPhase}) async {
          joins++;
          expect(isActive(), isTrue);
          expect(RecorderWifiActivity.isActive('note'), isTrue);
          expect(SoundcoreWifiActivity.isActive('note'), isTrue);
          expect(identical(session, ble.session), isTrue);
          expect(session.isClosed, isFalse);
          if (failJoin) throw const PlaudWifiFailure(PlaudWifiPhase.joining);
          onHotspot = true;
          await wifi.connect();
          return PlaudWifiConnection(wifi.session, () async {
            leaves++;
            if (failLeave) throw StateError('Still on device network');
            onHotspot = false;
          });
        });
  });
  tearDown(() async {
    failLeave = false;
    await sync.restoreWifi();
    await sync.importAll();
    sync.dispose();
    await wifi.dispose();
    await ble.dispose();
    for (final peer in retired) {
      await peer.dispose();
    }
    await root.delete(recursive: true);
    expect(RecorderWifiActivity.isActive('note'), isFalse);
  });

  test('active BLE switches immediately via a fresh session; partial audio never uploads', () async {
    stallBle = allowBleDownload = true;
    await sync.refresh();
    await bleStarted.future;
    expect(sync.busy, isTrue);
    expect(sync.bytes, 200);
    final switching = sync.syncOverWifi();
    expect(identical(sync.syncOverWifi(), switching), isTrue);
    expect(RecorderWifiActivity.isActive('note'), isTrue);
    expect(ble.session.isClosed, isTrue);
    await switching.timeout(const Duration(seconds: 2));
    await sync.importAll();
    expect([reconnects, joins, leaves, uploads], [1, 1, 1, 1]);
    expect(sync.errors[id], isNull);
    expect(sync.wifiError, isNull);
    expect(await (await store.cachedOriginal(id))!.readAsBytes(), raw);
    retired.single.emit(block(id, 200, List.filled(200, 9)));
    await sync.importAll();
    expect(uploads, 1);
  });

  test('Wi-Fi requested before BLE session opens prevents the download from starting', () async {
    await sync.refresh();
    openSessionGate = Completer<void>();
    await openingBle.future;
    final switching = sync.syncOverWifi();
    openSessionGate!.complete();
    await switching;
    await sync.importAll();
    expect(bleStarted.isCompleted, isFalse);
    expect([reconnects, joins, uploads], [0, 1, 1]);
    expect(sync.errors[id], isNull);
  });

  for (final action in ['cancel', 'cancel immediately', 'failed join']) {
    test('$action after interruption resumes BLE without a retry delay', () async {
      final cancel = action != 'failed join';
      stallBle = allowBleDownload = true;
      await sync.refresh();
      await bleStarted.future;
      if (action == 'cancel immediately') {
        sync.addListener(() {
          if (sync.wifiState == PlaudWifiPhase.preparing) sync.cancelWifi();
        });
      }
      final switching = sync.syncOverWifi();
      if (cancel) {
        sync.cancelWifi();
      } else {
        failJoin = true;
      }
      stallBle = false;
      await switching.timeout(const Duration(seconds: 2));
      await sync.importAll();
      expect([reconnects, joins, uploads], [1, cancel ? 0 : 1, 1]);
      expect(sync.errors[id], isNull);
      expect(sync.wifiState, isNull);
      expect(RecorderWifiActivity.isActive('note'), isFalse);
    });
  }

  test('Wi-Fi caches a complete original, leaves the AP, then auto uploads once', () async {
    await sync.syncOverWifi();
    await sync.importAll();
    expect(sync.wifiError, isNull);
    expect([joins, leaves, uploads], [1, 1, 1]);
    expect(await (await store.cachedOriginal(id))!.readAsBytes(), raw);
    expect(sync.stages[id], OfflineImportStage.uploaded);
    await sync.syncOverWifi();
    expect(sync.wifiNothingToDownload, isTrue);
    expect([joins, uploads], [1, 1]);
  });

  test('every cached recording uploads after Wi-Fi even before BLE reconnects', () async {
    sync.recordings = [
      const OfflineRecording(id + 1, 0, 6000),
      const OfflineRecording(id, 0, 6000),
    ];
    for (final recording in sync.recordings) {
      await store.original(recording, (file) async {
        await file.writeAsBytes(raw);
      }, expectedBytes: raw.length);
    }
    ble.session.close();
    await sync.importAll();
    expect(sync.connected, isFalse);
    expect(uploads, 2);
    expect(sync.stages.values, everyElement(OfflineImportStage.uploaded));
  });

  test('failed network cleanup holds queue and reconnect lock until a successful retry', () async {
    failLeave = true;
    await sync.syncOverWifi();
    expect(sync.wifiState, PlaudWifiPhase.restoring);
    expect(RecorderWifiActivity.isActive('note'), isTrue);
    await sync.importAll();
    expect(uploads, 0);
    failLeave = false;
    await sync.restoreWifi();
    await sync.importAll();
    expect(sync.wifiState, isNull);
    expect(uploads, 1);
  });

  test('incomplete Wi-Fi file never becomes a durable original or an upload', () async {
    truncate = true;
    await sync.syncOverWifi();
    await sync.importAll();
    expect(sync.wifiError, isNotNull);
    expect(await store.cachedOriginal(id), isNull);
    expect(uploads, 0);
    expect(onHotspot, isFalse);
  });

  test('account retirement cancels the batch and restores network without promoting audio', () async {
    duringDownload = () {
      owner = 'b';
      sync.retire();
    };
    await sync.syncOverWifi();
    expect(onHotspot, isFalse);
    expect(uploads, 0);
    expect(File('${store.directory.path}/$id.plaud.json').existsSync(), isFalse);
  });

  test('foreground loss cancels transfer and retains only a partial file', () async {
    duringDownload = sync.cancelWifi;
    await sync.syncOverWifi();
    await sync.importAll();
    expect(uploads, 0);
    expect(await store.cachedOriginal(id), isNull);
    expect(onHotspot, isFalse);
  });
}
