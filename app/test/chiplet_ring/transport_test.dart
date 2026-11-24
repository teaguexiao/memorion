import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/chiplet_ring/bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ring-transport-contract');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('failed commands retain the vendor 300ms gap and transport occupancy', () async {
    final started = Completer<void>();
    final times = <DateTime>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      times.add(DateTime.now());
      if (call.method == 'battery') {
        started.complete();
        throw PlatformException(code: 'fixture');
      }
      return 'firmware';
    });
    final peer = NativeRingTransport(channel: channel, eventStream: const Stream.empty());
    final failed = expectLater(peer.battery(), throwsA(isA<PlatformException>()));
    final next = peer.firmware();
    await started.future;
    expect(peer.busy, true);
    await failed;
    expect(await next, 'firmware');
    expect(times[1].difference(times[0]).inMilliseconds, greaterThanOrEqualTo(290));
    expect(peer.busy, false);
  });

  test('disconnect during command spacing cannot resurrect a successful capture', () async {
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startRecording') started.complete();
      return null;
    });
    final peer = NativeRingTransport(channel: channel, eventStream: const Stream.empty());
    final result = expectLater(peer.startRecording(), throwsStateError);
    await started.future;
    await Future<void>.delayed(Duration.zero);
    await peer.disconnect();
    await result;
    expect(peer.busy, false);
  });

  test('active capture occupies transport until a disconnect event', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    final peer = NativeRingTransport(channel: channel, eventStream: events.stream);
    final subscription = peer.events.listen((_) {});
    await peer.startRecording();
    expect(peer.busy, true);
    events.add({'event': 'connection', 'connected': false});
    expect(peer.busy, false);
    await subscription.cancel();
    await events.close();
  });

  test('clock rejects fractional time zones before native writes and requires valid readback', () async {
    var writes = 0;
    Map reply = {'milliseconds': 1794892800000, 'timezoneMinutes': -480};
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'synchronizeClock');
      expect(call.arguments['timezoneMinutes'], -480);
      writes++;
      return reply;
    });
    final peer = NativeRingTransport(channel: channel, eventStream: const Stream.empty());
    await expectLater(peer.synchronizeClock(const Duration(minutes: 330)), throwsFormatException);
    expect(writes, 0);
    final time = await peer.synchronizeClock(const Duration(hours: -8));
    expect(time.millisecondsSinceEpoch, 1794892800000);
    expect(time.isUtc, true);
    reply = {'milliseconds': 1794892800000, 'timezoneMinutes': 480};
    await expectLater(peer.synchronizeClock(const Duration(hours: -8)), throwsFormatException);
    reply = {'milliseconds': -1, 'timezoneMinutes': -480};
    await expectLater(peer.synchronizeClock(const Duration(hours: -8)), throwsFormatException);
  });
}
