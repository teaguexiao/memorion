import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';
import 'package:memorion/services/devices/soundcore/wifi_activity.dart';
import 'package:memorion/services/devices/soundcore/wifi_connection.dart';
import 'package:memorion/services/devices/soundcore/protocol_error.dart';

import 'fake_device.dart';
import 'fake_wifi.dart';

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

SoundcorePacket hotspotPacket({int status = 1, List<int> ip = const [1, 4, 168, 192], int port = 80}) {
  final bytes = response(0x1a, 5, [...ip, port & 255, port >> 8]);
  bytes[4] = status;
  bytes.last = bytes.take(bytes.length - 1).fold(0, (a, b) => (a + b) & 255);
  return SoundcorePacketBuffer().add(bytes).single;
}

void main() {
  test('hotspot response validates success, private reversed IP and little-endian port', () {
    final endpoint = SoundcoreWifiEndpoint.fromPacket(hotspotPacket(port: 8765));
    expect(endpoint.host, '192.168.4.1');
    expect(endpoint.port, 8765);
    for (final packet in [
      hotspotPacket(status: 0),
      hotspotPacket(ip: [1, 0, 0, 127]),
      hotspotPacket(ip: [8, 8, 8, 8]),
      hotspotPacket(port: 0),
    ]) {
      expect(() => SoundcoreWifiEndpoint.fromPacket(packet), throwsFormatException);
    }
    expect(soundcoreWifiFileRequest(0x12345678), '08ee0000001a07120000000000785634121b');
  });

  late Directory root;
  late FakeSoundcoreDevice peer;
  late SoundcoreSession session;
  late FakeSoundcoreWifi wifi;
  late SoundcoreImportStore store;
  late SoundcoreSyncController sync;
  late String owner;
  late int uploads;
  late DateTime time;
  int? uploadError;
  Object? joinError;
  Object? reconnectError;
  late int joins;
  late int reconnects;
  Future<void>? wifiDownloadGate;
  final oldPeers = <FakeSoundcoreDevice>[];
  bool switchingFromBle = false;
  bool dropBleOnWifiJoin = false;
  bool failAfterHotspotRestart = false;
  bool changeOwnerOnReconnect = false;
  bool stallSocketRetry = false;

  setUp(() {
    root = Directory.systemTemp.createTempSync('soundcore_wifi_');
    peer = FakeSoundcoreDevice(DateTime.now().subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000)
      ..fileCount = 3;
    session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
    wifi = FakeSoundcoreWifi(peer);
    owner = 'wifi-owner';
    uploads = 0;
    joins = 0;
    reconnects = 0;
    wifiDownloadGate = null;
    oldPeers.clear();
    uploadError = null;
    joinError = null;
    reconnectError = null;
    switchingFromBle = false;
    dropBleOnWifiJoin = false;
    failAfterHotspotRestart = false;
    changeOwnerOnReconnect = false;
    stallSocketRetry = false;
    time = DateTime.now();
    store = SoundcoreImportStore(
      root: root,
      ownerId: owner,
      deviceId: 'wifi-device',
      currentOwner: () => owner,
      upload: (_, __) async {
        if (joinError == null && !switchingFromBle) expect(wifi.closed, isTrue, reason: 'AP must leave before upload');
        uploads++;
        if (uploadError != null) throw SoundcoreImportException(uploadError);
        return SoundcoreImportReceipt('wifi-$uploads', processing: true);
      },
    );
    sync = SoundcoreSyncController(
      deviceId: 'wifi-device',
      openStore: () async => store,
      openSession: () async => session,
      reconnectSession: () async {
        reconnects++;
        if (reconnectError != null) throw reconnectError!;
        expect(session.isClosed, isTrue);
        oldPeers.add(peer);
        peer = FakeSoundcoreDevice(peer.fileId)..fileCount = peer.fileCount;
        session = SoundcoreSession(notifications: peer.inbound.stream, send: peer.send);
        await wifi.close();
        wifi = FakeSoundcoreWifi(peer);
        if (failAfterHotspotRestart) wifi.disconnectAtFile = peer.fileId + 1;
        if (changeOwnerOnReconnect) owner = 'other-owner';
        return session;
      },
      isCurrentOwner: () => owner == 'wifi-owner',
      now: () => time,
      openWifi: (ble, onPhase) async {
        expect(SoundcoreWifiActivity.isActive('wifi-device'), isTrue);
        joins++;
        onPhase(SoundcoreWifiPhase.openingHotspot);
        onPhase(SoundcoreWifiPhase.waitingForHotspot);
        onPhase(SoundcoreWifiPhase.joining);
        onPhase(SoundcoreWifiPhase.connecting);
        if (joinError != null) {
          if (dropBleOnWifiJoin) {
            peer.bleDisconnected = true;
            ble.close();
          }
          throw joinError!;
        }
        wifi.gate = wifiDownloadGate;
        final connection = await openFakeSoundcoreWifi(ble, wifi);
        if (dropBleOnWifiJoin) {
          peer.bleDisconnected = true;
          ble.close();
        }
        if (stallSocketRetry && joins == 1) {
          return SoundcoreWifiConnection(connection.session, wifi, reconnect: (previous) async {
            await previous.close();
            wifi = FakeSoundcoreWifi(peer)..stallBeforeHeader = true;
            return wifi;
          });
        }
        return connection;
      },
    );
  });
  tearDown(() async {
    sync.dispose();
    session.close();
    await peer.inbound.close();
    for (final old in oldPeers) {
      await old.inbound.close();
    }
    await wifi.close();
    root.deleteSync(recursive: true);
    expect(SoundcoreWifiActivity.isActive('wifi-device'), isFalse);
  });

  test('failed hotspot cleanup blocks uploads until a later cleanup succeeds', () async {
    wifi.closeFailures = 1;
    await sync.syncOverWifi();
    expect(uploads, 0);
    expect(sync.wifiState, SoundcoreWifiState.restoring);
    expect(SoundcoreWifiActivity.isActive('wifi-device'), isTrue);
    await sync.sync();
    expect(wifi.closed, isTrue);
    expect(uploads, 3);
    expect(sync.wifiState, isNull);
  });

  test('batch decrypts all files, waits for hotspot exit, then uploads once', () async {
    final leave = Completer<void>();
    wifi.closeGate = leave.future;
    final work = sync.syncOverWifi();
    await until(() => wifi.closeStarted);
    expect(wifi.requested, [peer.fileId, peer.fileId + 1, peer.fileId + 2]);
    expect(wifi.acks, 3);
    expect(uploads, 0);
    expect(sync.wifiState, SoundcoreWifiState.restoring);
    expect(SoundcoreWifiActivity.isActive('wifi-device'), isTrue);
    expect(await store.status(peer.fileId), SoundcoreImportStage.downloaded);
    expect((await store.recordingDetails(peer.fileId))!.duration, const Duration(seconds: 6));
    leave.complete();
    await work;
    expect(uploads, 3);
    expect(sync.wifiError, isNull);
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), isEmpty);
    await sync.syncOverWifi();
    expect(joins, 1); // receipts prevent joining or redownloading
    expect(sync.wifiNothingToDownload, isTrue);
    expect(uploads, 3);
  });

  for (final issue in [
    SoundcoreProtocolIssue.checksum,
    SoundcoreProtocolIssue.sequenceGap,
    SoundcoreProtocolIssue.sequenceDuplicate
  ]) {
    test('Wi-Fi ${issue.name} retains precise diagnostics and refuses incomplete upload', () async {
      peer.fileCount = 1;
      wifi.slicesPerFrame = 32;
      if (issue == SoundcoreProtocolIssue.checksum) {
        // Matches the reported second failure: 43,872 accepted slices = 7,019,520 bytes.
        wifi.sliceCount = 43936;
        wifi.corruptFrameAt = 43872;
      } else if (issue == SoundcoreProtocolIssue.sequenceGap) {
        wifi.missingSequence = 64;
      } else {
        wifi.repeatedSequence = 64;
      }
      await sync.syncOverWifi();
      expect(soundcoreWifiErrorCode(sync.wifiError!), contains('protocol=${issue.name}'));
      expect(sync.diagnostics, contains('protocol=${issue.name}'));
      expect(sync.diagnostics, isNot(contains(peer.fileId.toString())));
      expect(wifi.acks, 0);
      expect(uploads, 0);
      expect(await store.cachedRecordings(), isEmpty);
      expect(wifi.closed, isTrue);
      if (issue == SoundcoreProtocolIssue.checksum) {
        expect(sync.wifiFailedBytes, 7019520);
        expect(sync.diagnostics, contains('payloadBytes=5312'));
      } else {
        expect(sync.diagnostics, contains('expected=64'));
        expect(sync.diagnostics, contains('actual=${issue == SoundcoreProtocolIssue.sequenceGap ? 65 : 63}'));
      }
    });
  }

  test('switch interrupts a stalled large BLE file immediately, then restarts it over Wi-Fi', () async {
    switchingFromBle = true;
    peer.zeroSize = true; // Use the six-second clock duration in this fixture.
    final gate = Completer<void>();
    peer.downloadGate = gate.future;
    final work = sync.sync();
    await until(() => peer.commands.any((c) => c[5] == 0x1a && c[6] == 7));
    time = time.add(const Duration(seconds: 3));
    for (var i = 0; i < 150; i++) {
      peer.emit(response(0x1a, 8, peer.slice(i)));
    }
    expect(sync.downloadEstimate!.fraction, 0.5);
    expect(sync.downloadEstimate!.remaining, const Duration(seconds: 3));
    final wifiGate = Completer<void>();
    wifiDownloadGate = wifiGate.future;
    final switchWork = sync.syncOverWifi();
    expect(sync.wifiState, SoundcoreWifiState.preparing);
    expect(sync.downloadEstimate, isNull);
    await until(() => wifi.requested.isNotEmpty);
    expect(sync.downloadEstimate!.fraction, 0);
    expect(sync.downloadEstimate!.remaining, isNull);
    wifiGate.complete();
    // Do not release the BLE file gate. Switching must never wait for it.
    await Future.wait([work, switchWork]);
    expect(gate.isCompleted, isFalse);
    expect(reconnects, 1);
    expect(uploads, 3);
    expect(wifi.requested, [peer.fileId, peer.fileId + 1, peer.fileId + 2]);
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), isEmpty);
    expect(sync.failures, isEmpty);
    expect(sync.downloadEstimate, isNull);
    // A late completion from the original BLE generation is ignored.
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(uploads, 3);
    expect(session.isClosed, isFalse);
  });

  test('repeated switch taps coalesce; join failure resumes current file on fresh BLE', () async {
    switchingFromBle = true;
    joinError = StateError('join refused');
    peer.stall = true;
    final work = sync.sync();
    await until(() => peer.commands.any((c) => c[5] == 0x1a && c[6] == 7));
    await Future.wait([work, sync.syncOverWifi(), sync.syncOverWifi()]);
    expect(reconnects, 1);
    expect(joins, 1);
    expect(uploads, 3);
    expect(sync.wifiError, same(joinError));
    expect(sync.failures, isEmpty);
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), hasLength(3));
  });

  test('failed BLE reconnection reports an error rather than claiming all files downloaded', () async {
    peer.stall = true;
    reconnectError = StateError('recorder unavailable');
    final work = sync.sync();
    await until(() => peer.commands.any((c) => c[5] == 0x1a && c[6] == 7));
    await Future.wait([work, sync.syncOverWifi()]);
    expect(reconnects, 1);
    expect(joins, 0);
    expect(uploads, 0);
    expect(sync.wifiNothingToDownload, isFalse);
    expect(sync.wifiError, isA<StateError>());
    expect(sync.wifiState, isNull);
  });

  for (final cleanupFails in [false, true]) {
    test('network readiness failure restores closed BLE after cleanup ($cleanupFails)', () async {
      dropBleOnWifiJoin = true;
      var cleanupAttempts = 0;
      joinError = SoundcoreWifiFailure(SoundcoreWifiPhase.verifyingNetwork, TimeoutException('Network not ready'),
          cleanup: cleanupFails
              ? () async {
                  if (++cleanupAttempts == 1) throw StateError('Hotspot still connected');
                }
              : null);
      await sync.syncOverWifi();
      if (cleanupFails) {
        expect(uploads, 0);
        expect(reconnects, 0, reason: 'BLE must not reconnect until hotspot cleanup succeeds');
        expect(SoundcoreWifiActivity.isActive('wifi-device'), isTrue);
        await sync.sync();
      }
      expect(reconnects, 1);
      expect(uploads, 3);
      expect(joins, 1);
      expect(session.isClosed, isFalse);
      expect(sync.activeId, isNull);
      expect(sync.wifiState, isNull);
      expect(sync.diagnostics, contains('BLE sync restored'));
      expect(SoundcoreWifiActivity.isActive('wifi-device'), isFalse);
    });
  }

  test('failed fallback reconnect is attempted once without looping over every pending recording', () async {
    dropBleOnWifiJoin = true;
    joinError = SoundcoreWifiFailure(SoundcoreWifiPhase.verifyingNetwork, TimeoutException('Network not ready'));
    reconnectError = StateError('Recorder unavailable');
    await sync.syncOverWifi();
    expect(reconnects, 1);
    expect(uploads, 0);
    expect(sync.error, same(reconnectError));
    expect(sync.reconnectingBluetooth, isFalse);
    expect(sync.busy, isFalse);
    expect(SoundcoreWifiActivity.isActive('wifi-device'), isFalse);
    await sync.sync();
    expect(reconnects, 1);
  });

  test('stalled batch rebuilds hotspot once and continues without redownloading completed files', () async {
    final first = wifi;
    first.disconnectAtFile = peer.fileId + 1;
    await sync.syncOverWifi();
    expect(joins, 2);
    expect(reconnects, 1);
    expect(first.closed, isTrue);
    expect(first.requested, [peer.fileId, peer.fileId + 1]);
    expect(wifi.requested, [peer.fileId + 1, peer.fileId + 2]);
    expect(uploads, 3);
    expect(sync.wifiError, isNull);
    expect(sync.diagnostics, contains('hotspot rebuilt'));
    expect(peer.commands.where((c) => c[5] == 0x1a && c[6] == 7), isEmpty);
  });

  test('silent fresh socket times out before full hotspot recovery retries the file', () async {
    session.close();
    oldPeers.add(peer);
    peer = FakeSoundcoreDevice(peer.fileId)..fileCount = 3;
    await wifi.close();
    wifi = FakeSoundcoreWifi(peer);
    session = SoundcoreSession(
        notifications: peer.inbound.stream, send: peer.send, transferIdleTimeout: const Duration(milliseconds: 50));
    wifi.disconnectAtFile = peer.fileId + 1;
    stallSocketRetry = true;
    await sync.syncOverWifi();
    expect(joins, 2);
    expect(reconnects, 1);
    expect(uploads, 3);
    expect(sync.wifiError, isNull);
    expect(sync.diagnostics, contains('restarting hotspot step=requestingFile bytes=0 timeout'));
    expect(sync.diagnostics, contains('Wi-Fi fresh socket retry'));
    expect(wifi.requested, [peer.fileId + 1, peer.fileId + 2]);
  });

  test('account change during hotspot recovery prevents rejoin and uploads', () async {
    wifi.disconnectAtFile = peer.fileId + 1;
    changeOwnerOnReconnect = true;
    await sync.syncOverWifi();
    expect(joins, 1);
    expect(reconnects, 1);
    expect(uploads, 0);
  });

  test('failed hotspot restart is bounded and uploads only completed cache', () async {
    wifi.disconnectAtFile = peer.fileId + 1;
    failAfterHotspotRestart = true;
    await sync.syncOverWifi();
    expect(joins, 2);
    expect(reconnects, 1);
    expect(wifi.closed, isTrue);
    expect(sync.wifiError, isA<SoundcoreWifiFailure>().having((e) => e.phase, 'phase', SoundcoreWifiPhase.downloading));
    expect(sync.wifiFailedStep, SoundcoreTransferStep.receiving);
    expect(sync.wifiFailedBytes, 0);
    expect(sync.diagnostics, contains('WebSocket established'));
    expect(sync.diagnostics, contains('download failed step=receiving'));
    expect(session.isClosed, isFalse);
    expect(uploads, 1);
    expect(await store.status(peer.fileId), SoundcoreImportStage.uploaded);
    expect(await store.status(peer.fileId + 1), isNull);
    expect(await store.status(peer.fileId + 2), isNull);
    expect(sync.activeId, isNull);
    final replacement = SoundcoreSession(notifications: const Stream.empty(), send: (_) async {});
    sync.session = replacement;
    expect(sync.diagnostics, contains('Last Wi-Fi failure:'));
    expect(sync.diagnostics, contains('download failed step=receiving'));
    replacement.close();
  });

  test('estimated long recording is skipped before Wi-Fi and manual retry measures real duration', () async {
    peer.durations[peer.fileId] = 32400000;
    await sync.syncOverWifi();
    expect(wifi.requested, [peer.fileId + 1, peer.fileId + 2]);
    expect(uploads, 2);
    expect(sync.wifiError, isNull);
    expect(sync.diagnostics, contains('source=estimate phase=validating reason=too_long'));
    expect(await store.rejectionStatus(peer.fileId), isNull);
    await sync.retry(peer.fileId);
    expect(uploads, 3);
    expect((await store.recordingDetails(peer.fileId))!.duration, const Duration(seconds: 6));
  });

  test('corrected directory duration clears the estimated rejection on the next refresh', () async {
    peer.durations[peer.fileId] = 32400000;
    await sync.syncOverWifi();
    peer.durations[peer.fileId] = 6000;
    wifi = FakeSoundcoreWifi(peer);
    await sync.syncOverWifi();
    expect(wifi.requested, [peer.fileId]);
    expect(uploads, 3);
    expect(sync.failures.containsKey(peer.fileId), isFalse);
  });

  test('all oversized recordings do not open a hotspot or claim all recordings were downloaded', () async {
    peer.fileCount = 1;
    peer.durations[peer.fileId] = 32400000;
    await sync.syncOverWifi();
    expect(joins, 0);
    expect(uploads, 0);
    expect(sync.wifiNothingToDownload, isFalse);
    expect(sync.failures[peer.fileId], isA<SoundcoreImportException>());
  });

  test('complete eight-hour encrypted recording is cached and decoded through its last page', () async {
    peer.fileCount = 1;
    peer.durations[peer.fileId] = 28800000;
    wifi.sliceCounts[peer.fileId] = 1440000;
    wifi.slicesPerFrame = 24;
    await sync.syncOverWifi();
    expect(uploads, 1);
    expect(wifi.acks, 1);
    expect(sync.failures, isEmpty);
    expect((await store.recordingDetails(peer.fileId))!.duration, const Duration(hours: 8));
    final file = File('${store.directory.path}/${peer.fileId}.ogg');
    final input = await file.open();
    try {
      // Fake peer uses three-byte Opus silence packets: last full page is 227 B.
      await input.setPosition(await input.length() - 227);
      final page = await input.read(227);
      expect(page.take(4), [79, 103, 103, 83]);
      expect(page[5], 4);
      expect(ByteData.sublistView(page).getUint64(6, Endian.little), 28800 * 48000);
      expect(ByteData.sublistView(page).getUint32(18, Endian.little), 28801);
    } finally {
      await input.close();
    }
    final decode =
        await Process.run('ffmpeg', ['-nostdin', '-v', 'error', '-xerror', '-i', file.path, '-f', 'null', '-']);
    expect(decode.exitCode, 0, reason: decode.stderr.toString());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('actual duration limit drains current stream and next recording uses the same Wi-Fi connection', () async {
    wifi.sliceCounts[peer.fileId] = 1440001;
    wifi.slicesPerFrame = 24; // Real 04.92 bulk payload: 3984 bytes.
    await sync.syncOverWifi();
    expect(joins, 1);
    expect(reconnects, 0);
    expect(wifi.requested, [peer.fileId, peer.fileId + 1, peer.fileId + 2]);
    expect(wifi.acks, 2);
    expect(uploads, 2);
    expect(sync.wifiError, isNull);
    expect(await store.rejectionStatus(peer.fileId), 400);
    expect((await store.lastUploadFailure(peer.fileId))!.diagnostic,
        'issue=duration source=local phase=validating reason=too_long');
    expect((await store.recordingDetails(peer.fileId))!.duration, const Duration(milliseconds: 28800020));
    expect(await store.status(peer.fileId), isNull);
    expect(await File('${store.directory.path}/${peer.fileId}.ogg').exists(), isFalse);
    await sync.syncOverWifi();
    expect(joins, 1);
    expect(uploads, 2);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('BLE closes with no transfer step during hotspot join; Wi-Fi still downloads every file', () async {
    dropBleOnWifiJoin = true;
    await sync.syncOverWifi();
    expect(session.isClosed, isTrue);
    expect(session.transferStep, isNull);
    expect(sync.wifiError, isNull);
    expect(wifi.requested, hasLength(3));
    expect(uploads, 3);
    expect(wifi.acks, 3);
    expect((await store.recordingDetails(peer.fileId))!.duration, const Duration(seconds: 6));
  });

  test('service disposal cancels the independent Wi-Fi download and closes the hotspot', () async {
    final gate = Completer<void>();
    wifiDownloadGate = gate.future;
    final work = sync.syncOverWifi();
    await until(() => wifi.requested.isNotEmpty);
    sync.dispose();
    await work;
    expect(wifi.closed, isTrue);
    expect(uploads, 0);
    expect(await store.status(peer.fileId), isNull);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    // tearDown still owns/disposes the current controller.
    sync = SoundcoreSyncController(
        openStore: () async => store, openSession: () async => session, isCurrentOwner: () => true);
  });

  test('failed internet restoration upload retries from cache without reopening hotspot', () async {
    uploadError = 503;
    await sync.syncOverWifi();
    expect(uploads, 1);
    expect(wifi.requested, hasLength(3));
    expect(await store.status(peer.fileId + 2), SoundcoreImportStage.downloaded);
    uploadError = null;
    time = time.add(const Duration(minutes: 1));
    session.close();
    await sync.sync();
    expect(uploads, 4);
    expect(joins, 1);
    expect(sync.stages.values.every((s) => s == SoundcoreImportStage.uploaded), isTrue);
  });

  test('join refusal recovers with Bluetooth and a visible Wi-Fi error', () async {
    joinError = StateError('join rejected');
    await sync.syncOverWifi();
    expect(sync.wifiError, same(joinError));
    expect(sync.wifiState, isNull);
    expect(uploads, 3);
    expect(reconnects, 0, reason: 'a healthy BLE connection should be retained');
    expect(wifi.requested, isEmpty);
  });

  test('failed cleanup during setup blocks uploads and is retried without opening a hotspot', () async {
    var cleanupCalls = 0;
    joinError = SoundcoreWifiFailure(SoundcoreWifiPhase.joining, TimeoutException('join'), cleanup: () async {
      if (++cleanupCalls == 1) throw TimeoutException('leave');
    });
    await sync.syncOverWifi();
    expect(uploads, 0);
    expect(sync.wifiState, SoundcoreWifiState.restoring);
    expect((sync.wifiError as SoundcoreWifiFailure).phase, SoundcoreWifiPhase.joining);
    await sync.sync();
    expect(cleanupCalls, 2);
    expect(joins, 1);
    expect(uploads, 3);
    expect(sync.wifiState, isNull);
    expect(sync.wifiError, isNull);
  });

  test('account switch during Wi-Fi download closes hotspot without uploading', () async {
    final gate = Completer<void>();
    wifi.gate = gate.future;
    final work = sync.syncOverWifi();
    await until(() => wifi.requested.isNotEmpty);
    owner = 'other-owner';
    gate.complete();
    await work;
    expect(wifi.closed, isTrue);
    expect(uploads, 0);
    expect(sync.activeId, isNull);
  });
}
