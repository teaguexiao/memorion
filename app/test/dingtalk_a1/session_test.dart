import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/dingtalk_a1/identity.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1/session.dart';
import 'fake_device.dart';

void main() {
  late FakeA1 peer;
  late A1Session session;
  setUp(() {
    peer = FakeA1(File('test/dingtalk_a1/fixtures/synthetic_tone.dtyj').readAsBytesSync());
    session = A1Session(
        identity: A1Identity('test-did', 'test-corp', '0123456789abcdef0123456789abcdef'),
        send: peer.send,
        notifications: peer.inbound.stream,
        commandTimeout: const Duration(milliseconds: 100),
        transferTimeout: const Duration(milliseconds: 100));
  });
  tearDown(() async {
    session.close();
    await peer.close();
  });
  test('stock challenge without code proceeds to token authentication', () async {
    await session.authenticate();
    final auth = peer.requests.singleWhere((request) => request['cmd'] == 0x0133);
    expect(auth['token'], '5f72aaf7acfbedde6274dda512510ee2bce64fd1af90ba54becb644e023bcb6a');
    expect((await session.readInfo()).battery, 76);
  });
  test('challenge with an explicit success code remains supported', () async {
    peer.challengeReply['code'] = 200;
    await session.authenticate();
    expect(peer.commands, contains(0x0133));
  });
  final invalidChallenges = <String, Map<String, dynamic>>{
    'missing random': {},
    'wrong random type': {'random': 32},
    'short random': {'random': 'short'},
    'non-ASCII random': {'random': 'é' * 32},
    'explicit rejection': {'code': 501, 'random': 'abcdefghijklmnopqrstuvwxyz012345'},
    'explicit null code': {'code': null, 'random': 'abcdefghijklmnopqrstuvwxyz012345'},
  };
  for (final entry in invalidChallenges.entries) {
    test('${entry.key} stops before a token is sent', () async {
      peer.challengeReply = entry.value;
      await expectLater(
          session.authenticate(), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.authentication)));
      expect(peer.commands, isNot(contains(0x0133)));
      await expectLater(session.recordings(), throwsA(isA<A1Exception>()));
      expect(peer.commands, isNot(contains(0x0110)));
    });
  }
  test('missing code on token response still fails authentication', () async {
    peer.authReply = {};
    await expectLater(
        session.authenticate(), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.authentication)));
    expect(peer.commands, contains(0x0133));
    await expectLater(session.readInfo(), throwsA(isA<A1Exception>()));
    expect(peer.commands, isNot(contains(0x0132)));
  });
  test('auth failure never exposes recordings', () async {
    peer.wrongAuth = true;
    await expectLater(
        session.authenticate(), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.authentication)));
    await expectLater(session.recordings(), throwsA(isA<A1Exception>()));
    expect(peer.commands, isNot(contains(0x0110)));
  });
  test('notifications do not satisfy pending commands; status remains authoritative', () async {
    await session.authenticate();
    peer.unsolicitedBeforeReply = true;
    expect((await session.readInfo()).battery, 76);
  });
  test('multiple directory pages and no-progress detection', () async {
    await session.authenticate();
    peer.fileCount = 245;
    final files = await session.recordings();
    expect(files.length, 245);
    expect(files.last.id, peer.fid - 244);
    peer.repeatPage = true;
    await expectLater(
        session.recordings(), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.incompleteList)));
  });
  test('binary attributes, early push, retransmission and fragmentation download exactly once', () async {
    await session.authenticate();
    peer.binaryAttributes = peer.duplicate = true;
    final progress = <int>[];
    final result = await session.download(peer.fid, onProgress: (received, _) => progress.add(received));
    expect(result, peer.audio);
    expect(progress.toSet().length, progress.length);
    expect(progress.last, peer.audio.length);
    expect(peer.commands, isNot(contains(0x0113))); // Never delete.
  });
  for (final problem in ['gap', 'wrong-file', 'changed-duplicate', 'disconnect', 'stall']) {
    test('$problem fails and retires the transfer generation', () async {
      await session.authenticate();
      peer.gap = problem == 'gap';
      peer.wrongFile = problem == 'wrong-file';
      peer.changedDuplicate = problem == 'changed-duplicate';
      peer.disconnect = problem == 'disconnect';
      peer.stall = problem == 'stall';
      await expectLater(session.download(peer.fid), throwsA(isA<A1Exception>()));
      expect(session.isClosed, isTrue);
      await expectLater(session.download(peer.fid), throwsA(isA<A1Exception>()));
    });
  }
  test('recording controls reread status, and downloads wait until idle', () async {
    await session.authenticate();
    expect((await session.recordingControl('start')).audioStatus, 'recording');
    await expectLater(
        session.download(peer.fid), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.busy)));
    expect(peer.commands, isNot(contains(0x0111)));
    expect((await session.recordingControl('pause')).audioStatus, 'paused');
    expect((await session.recordingControl('resume')).audioStatus, 'recording');
    expect((await session.recordingControl('stop')).audioStatus, 'idle');
  });
  test('command timeout prevents late reply reuse', () async {
    await session.authenticate();
    peer.ignoreCommand = 0x0132;
    await expectLater(session.readInfo(), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.timeout)));
    expect(session.isClosed, isTrue);
  });
  for (final deletion in [1, null]) {
    test('download refuses automatic or unknown device deletion ($deletion)', () async {
      await session.authenticate();
      peer.deleteAfterUpload = deletion;
      await expectLater(
          session.download(peer.fid), throwsA(isA<A1Exception>().having((e) => e.issue, 'issue', A1Issue.retention)));
      expect(peer.commands, isNot(contains(0x0111)));
      expect(peer.requests.where((r) => r['cmd'] == 0x0100).every((r) => r['action'] == 'get'), isTrue);
    });
  }
}
