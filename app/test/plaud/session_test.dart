import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/session.dart';

import 'fake_device.dart';

void main() {
  late Peer peer;
  setUp(() => peer = Peer());
  tearDown(() => peer.dispose());
  for (final phase in ['opening file', 'native write', 'header', 'audio']) {
    test('Wi-Fi interrupts BLE during $phase without waiting for timeout or accepting late blocks', () async {
      await peer.dispose();
      peer = Peer(timeout: const Duration(seconds: 10), transferIdleTimeout: const Duration(seconds: 10));
      await peer.connect();
      final started = Completer<void>(), write = Completer<void>();
      final dir = await Directory.systemTemp.createTemp('plaud-interrupt');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/recording.part');
      peer.handle = (packet) async {
        if (plaudCommandId(packet) != 28) return;
        if (phase == 'audio') {
          peer.emit(plaudCommand(28, [123, 0, 0, 0, 0]));
          peer.emit(block(123, 0, List.filled(200, 7)));
        }
        started.complete();
        if (phase == 'native write') await write.future;
      };
      expect(peer.session.interruptBluetoothDownload(), isFalse);
      final download = peer.session.downloadTo(const PlaudRecording(123, 800), file);
      final interrupted = expectLater(download, throwsA(isA<PlaudBluetoothInterrupted>()));
      if (phase != 'opening file') await started.future;
      expect(peer.session.interruptBluetoothDownload(), isTrue);
      expect(peer.session.interruptBluetoothDownload(), isFalse);
      await interrupted.timeout(const Duration(seconds: 1));
      expect(peer.session.busy, isFalse);
      expect(peer.session.isClosed, isTrue);
      final partial = await file.readAsBytes();
      expect(partial.length, phase == 'audio' ? 200 : 0);
      peer.emit(block(123, 200, List.filled(200, 9)));
      peer.emit(block(123, 0xffffffff, []));
      write.complete();
      await Future<void>.delayed(Duration.zero);
      expect(await file.readAsBytes(), partial);
    });
  }
  test('firmware comes from the authenticated handshake in major.minor.patch order', () async {
    peer.handshakeBody = [0, 20, 0, 0, 0, 1, 0, 0, 0, 0x56, 8, 2, 2];
    expect(peer.session.firmwareVersion, null);
    await peer.connect();
    expect(peer.session.firmwareVersion, '2.2.8');
  });
  test('short handshake does not invent firmware metadata', () async {
    await peer.connect();
    expect(peer.session.firmwareVersion, null);
  });
  test('encrypted auth, bounded complete list, event ACK and byte-exact transfer', () async {
    await peer.connect();
    var acknowledged = false;
    peer.handle = (packet) {
      if (plaudCommandId(packet) == 26) {
        peer.emit(plaudCommand(19, [1, 2, 3, 4, 1, 0, 0, 0]));
        peer.emit(base64.decode(peer.data['listPage']));
      } else if (plaudCommandId(packet) == 19) {
        expect(packet.sublist(3), [1, 2, 3, 4]);
        acknowledged = true;
      } else if (plaudCommandId(packet) == 28) {
        peer.emit(plaudCommand(28, [123, 0, 0, 0, 0]));
        for (var i = 0; i < 800; i += 200) {
          peer.emit(block(123, i, List.generate(200, (j) => (i + j) % 256)));
        }
        peer.emit(block(123, 0xffffffff, []));
      }
    };
    final list = await peer.session.recordings();
    expect(list.single.byteSize, 24512);
    final result = await peer.session.download(const PlaudRecording(123, 800));
    expect(acknowledged, true);
    expect(result, List.generate(800, (i) => i % 256));
    expect(peer.session.isClosed, false);
  });
  test('file-backed transfer preserves exact bytes and leaves a failed partial for inspection', () async {
    final dir = await Directory.systemTemp.createTemp('plaud-transfer-');
    addTearDown(() => dir.delete(recursive: true));
    final target = File('${dir.path}/audio.part');
    await peer.connect();
    var fail = false;
    peer.handle = (packet) {
      if (plaudCommandId(packet) != 28) return;
      peer.emit(plaudCommand(28, [123, 0, 0, 0, 0]));
      peer.emit(block(123, 0, List.filled(200, 7)));
      if (!fail) {
        for (var i = 200; i < 800; i += 200) {
          peer.emit(block(123, i, List.filled(200, 7)));
        }
      }
      peer.emit(block(123, 0xffffffff, []));
    };
    await peer.session.downloadTo(const PlaudRecording(123, 800), target);
    expect(await target.readAsBytes(), List.filled(800, 7));
    fail = true;
    await expectLater(peer.session.downloadTo(const PlaudRecording(123, 800), target), throwsA(isA<PlaudException>()));
    expect(await target.readAsBytes(), List.filled(200, 7));
    expect(peer.session.isClosed, true);
  });
  test('healthy progressing transfer can outlive command timeout', () async {
    await peer.connect();
    peer.handle = (packet) {
      if (plaudCommandId(packet) == 28) peer.emit(plaudCommand(28, [123, 0, 0, 0, 0]));
    };
    final download = peer.session.download(const PlaudRecording(123, 800));
    for (var i = 0; i < 800; i += 200) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      peer.emit(block(123, i, List.filled(200, 1)));
    }
    peer.emit(block(123, 0xffffffff, []));
    expect((await download).length, 800);
    expect(peer.session.isClosed, false);
  });
  test('serial mismatch sends no credentials and first-binding request never installs a key', () async {
    await expectLater(peer.session.authenticate('888000000000000002'), throwsA(isA<PlaudException>()));
    expect(peer.sent, isEmpty);
    expect(peer.session.isClosed, true);
    final other = Peer()..firstBinding = true;
    try {
      await expectLater(
          other.connect(), throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.identityRequired)));
      expect(other.sent.every((p) => p[0] == 0x10 && p[1] == 0xfe), true);
    } finally {
      await other.dispose();
    }
  });
  test('list timeout retires connection; late reply cannot satisfy another operation', () async {
    await peer.connect();
    await expectLater(peer.session.recordings(), throwsA(isA<PlaudException>()));
    expect(peer.session.isClosed, true);
    peer.emit(base64.decode(peer.data['listPage']));
    await expectLater(peer.session.recordings(), throwsA(isA<PlaudException>()));
  });
  test('concurrent operations fail busy without invalidating the active request', () async {
    await peer.connect();
    final listing = peer.session.recordings();
    await expectLater(
        peer.session.recordings(), throwsA(isA<PlaudException>().having((e) => e.issue, 'issue', PlaudIssue.busy)));
    await Future<void>.delayed(Duration.zero);
    peer.emit(base64.decode(peer.data['listPage']));
    expect((await listing).length, 1);
    expect(peer.session.isClosed, false);
  });
  test('list gap and duplicates are not accepted as a complete list', () async {
    await peer.connect();
    peer.handle = (_) {
      final page = base64.decode(peer.data['listPage']);
      ByteData.sublistView(page).setUint16(9, 1, Endian.little);
      peer.emit(page);
    };
    await expectLater(peer.session.recordings(), throwsA(isA<PlaudException>()));
    expect(peer.session.isClosed, true);
  });
  for (final failure in ['gap', 'wrong file', 'truncated tail', 'idle timeout', 'duplicate after tail']) {
    test('transfer rejects $failure and requires reconnect', () async {
      await peer.connect();
      peer.handle = (packet) {
        if (plaudCommandId(packet) != 28) return;
        peer.emit(plaudCommand(28, [123, 0, 0, 0, 0]));
        if (failure == 'idle timeout') return;
        if (failure == 'gap') {
          peer.emit(block(123, 1, List.filled(200, 0)));
        } else if (failure == 'wrong file') {
          peer.emit(block(124, 0, List.filled(200, 0)));
        } else if (failure == 'truncated tail') {
          peer.emit(block(123, 0xffffffff, []));
        } else {
          for (var i = 0; i < 800; i += 200) {
            peer.emit(block(123, i, List.filled(200, 0)));
          }
          peer.emit(block(123, 0xffffffff, []));
          peer.emit(block(123, 0xffffffff, []));
        }
      };
      await expectLater(peer.session.download(const PlaudRecording(123, 800)), throwsA(isA<PlaudException>()));
      expect(peer.session.isClosed, true);
    });
  }
  test('disconnect completes waiting operations and never exposes transport errors', () async {
    await peer.connect();
    final listing = peer.session.recordings();
    peer.notifications.addError(StateError('secret transport detail'));
    await expectLater(listing,
        throwsA(isA<PlaudException>().having((e) => e.toString(), 'safe error', 'PlaudException(disconnected)')));
  });
}
