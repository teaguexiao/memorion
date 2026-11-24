import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/services/phone_recording_shortcut_service.dart';
import 'package:memorion/utils/enums.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCapture extends ChangeNotifier implements CaptureProvider {
  @override
  RecordingState recordingState = RecordingState.stop;
  @override
  bool isPaused = false;
  @override
  bool isDeviceRecordingStarting = false;
  @override
  bool phoneRecordingShortcutStarting = false;
  int starts = 0;
  int stops = 0;
  int deviceRestores = 0;
  bool Function()? mayStart;
  Future<void> Function()? setup;

  @override
  Future<void> streamRecording({bool Function()? shouldStart}) async {
    starts++;
    mayStart = shouldStart;
    state(RecordingState.initialising);
    try {
      await setup?.call();
      if (shouldStart != null && !shouldStart()) throw StateError('Cancelled');
    } catch (_) {
      await stopStreamRecording();
      rethrow;
    }
  }

  void state(RecordingState state) {
    recordingState = state;
    notifyListeners();
  }

  @override
  Future<void> stopStreamRecording() async {
    stops++;
    state(RecordingState.stop);
  }

  @override
  Future<void> restoreDeferredDeviceRecording() async {
    expect(phoneRecordingShortcutStarting, isFalse);
    deviceRestores++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Matcher failsWith(String code) => throwsA(isA<PlatformException>().having((error) => error.code, 'code', code));

class FailingPreparationCapture extends CaptureProvider {
  int stops = 0;

  @override
  Future<void> changeAudioRecordProfile({
    required BleAudioCodec audioCodec,
    int? sampleRate,
    int? channels,
    bool? isPcm,
  }) async =>
      throw StateError('Audio setup unavailable');

  @override
  Future<void> stopStreamRecording() async {
    stops++;
    updateRecordingState(RecordingState.stop);
  }
}

class DeferredDeviceCapture extends CaptureProvider {
  int deviceStarts = 0;

  @override
  Future<bool> streamDeviceRecording({BtDevice? device}) async {
    if (phoneRecordingShortcutStarting || recordingState == RecordingState.record) {
      return super.streamDeviceRecording(device: device);
    }
    // Model successful device hardware setup when the provider restores it.
    deviceStarts++;
    updateRecordingState(RecordingState.deviceRecord);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCapture capture;
  late PhoneRecordingShortcutController controller;
  late bool signedIn;
  late bool foreground;
  late bool granted;
  late int permissionRequests;

  setUp(() {
    capture = FakeCapture();
    signedIn = foreground = granted = true;
    permissionRequests = 0;
    controller = PhoneRecordingShortcutController(
      capture: capture,
      isAuthenticated: () => signedIn,
      isForeground: () => foreground,
      requestMicrophonePermission: () async {
        permissionRequests++;
        return granted;
      },
      startTimeout: const Duration(milliseconds: 30),
    );
  });

  tearDown(() => capture.dispose());

  test('overlapping triggers start once and wait for actual microphone activation', () async {
    final first = controller.start();
    final second = controller.start();
    var returned = false;
    first.then((_) => returned = true);
    await Future<void>.delayed(Duration.zero);
    expect(capture.starts, 1);
    expect(capture.phoneRecordingShortcutStarting, isTrue);
    expect(returned, isFalse);
    capture.state(RecordingState.record);
    expect(await first, isTrue);
    expect(await second, isFalse); // Only the first caller should open a page.
    expect(capture.phoneRecordingShortcutStarting, isFalse);
    expect(capture.stops, 0);
  });

  test('an active phone recording is preserved on repeated invocation', () async {
    capture.state(RecordingState.record);
    expect(await controller.start(), isFalse);
    expect(capture.starts, 0);
    expect(capture.stops, 0);
    expect(permissionRequests, 0);
  });

  test('permission denial does not start or stop a recorder', () async {
    granted = false;
    await expectLater(controller.start(), failsWith('microphone_permission'));
    expect(capture.starts, 0);
    expect(capture.stops, 0);
    expect(capture.phoneRecordingShortcutStarting, isFalse);
    expect(capture.deviceRestores, 1);
  });

  test('signed out and background requests never reach the microphone', () async {
    signedIn = false;
    await expectLater(controller.start(), failsWith('sign_in_required'));
    signedIn = true;
    foreground = false;
    await expectLater(controller.start(), failsWith('foreground_required'));
    expect(capture.starts, 0);
    expect(permissionRequests, 0);
  });

  test('device recording, paused sessions and pending device setup stay intact', () async {
    for (final state in [RecordingState.deviceRecord, RecordingState.pause, RecordingState.initialising]) {
      capture.recordingState = state;
      await expectLater(controller.start(), failsWith('recording_busy'));
    }
    capture.recordingState = RecordingState.stop;
    capture.isDeviceRecordingStarting = true;
    await expectLater(controller.start(), failsWith('recording_busy'));
    expect(capture.starts, 0);
    expect(capture.stops, 0);
  });

  test('background launch waits for resume before requesting permission', () async {
    foreground = false;
    final resumed = Completer<void>();
    controller = PhoneRecordingShortcutController(
      capture: capture,
      isAuthenticated: () => signedIn,
      isForeground: () => foreground,
      waitForForeground: () => foreground ? Future<void>.value() : resumed.future,
      requestMicrophonePermission: () async {
        permissionRequests++;
        return true;
      },
    );
    final result = controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(permissionRequests, 0);
    expect(capture.starts, 0);
    foreground = true;
    resumed.complete();
    await Future<void>.delayed(Duration.zero);
    expect(permissionRequests, 1);
    expect(capture.starts, 1);
    capture.state(RecordingState.record);
    expect(await result, isTrue);
  });

  test('first permission grant waits for resume after the system sheet closes', () async {
    final resumed = Completer<void>();
    controller = PhoneRecordingShortcutController(
      capture: capture,
      isAuthenticated: () => signedIn,
      isForeground: () => foreground,
      waitForForeground: () => foreground ? Future<void>.value() : resumed.future,
      requestMicrophonePermission: () async {
        foreground = false;
        return true;
      },
    );
    final result = controller.start();
    await Future<void>.delayed(Duration.zero);
    expect(capture.phoneRecordingShortcutStarting, isTrue);
    expect(capture.starts, 0);
    foreground = true;
    resumed.complete();
    await Future<void>.delayed(Duration.zero);
    capture.state(RecordingState.record);
    expect(await result, isTrue);
    expect(capture.starts, 1);
  });

  test('device reconnect records its device without disrupting phone audio', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    final provider = CaptureProvider();
    try {
      final device = BtDevice(id: 'reconnected-device', name: 'Memorion', type: DeviceType.memorion, rssi: -50);
      provider.phoneRecordingShortcutStarting = true;
      provider.hasTranscripts = true;
      expect(await provider.streamDeviceRecording(device: device), isFalse);
      expect(provider.havingRecordingDevice, isTrue);
      expect(provider.hasTranscripts, isTrue);
      expect(provider.isDeviceRecordingStarting, isFalse);
      provider.phoneRecordingShortcutStarting = false;
      provider.updateRecordingState(RecordingState.record);
      expect(await provider.streamDeviceRecording(device: device), isFalse);
      expect(provider.recordingState, RecordingState.record);
    } finally {
      provider.dispose();
    }
  });

  test('phone preparation failure restores a retryable state for ordinary callers', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(permissions, (call) async => {7: 1});
    final provider = FailingPreparationCapture();
    try {
      await expectLater(provider.streamRecording(), throwsStateError);
      expect(provider.recordingState, RecordingState.stop);
      expect(provider.stops, 1);
      await expectLater(provider.streamRecording(), throwsStateError);
      expect(provider.recordingState, RecordingState.stop);
      expect(provider.stops, 2);
    } finally {
      provider.dispose();
      messenger.setMockMethodCallHandler(permissions, null);
    }
  });

  test('a deferred device resumes after failed startup or completed phone recording', () async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    for (final starting in [true, false]) {
      final provider = DeferredDeviceCapture();
      try {
        provider.phoneRecordingShortcutStarting = starting;
        if (!starting) provider.updateRecordingState(RecordingState.record);
        final device = BtDevice(id: 'deferred-device', name: 'Memorion', type: DeviceType.memorion, rssi: -50);
        expect(await provider.streamDeviceRecording(device: device), isFalse);
        await provider.restoreDeferredDeviceRecording();
        expect(provider.deviceStarts, 0);
        provider.phoneRecordingShortcutStarting = false;
        provider.updateRecordingState(RecordingState.stop);
        await provider.restoreDeferredDeviceRecording();
        expect(provider.deviceStarts, 1);
        expect(provider.recordingState, RecordingState.deviceRecord);
        await provider.restoreDeferredDeviceRecording();
        expect(provider.deviceStarts, 1);
      } finally {
        provider.dispose();
      }
    }
  });

  test('recorder failure is reported and setup ownership is released', () async {
    final result = controller.start();
    final expectation = expectLater(result, failsWith('start_failed'));
    await Future<void>.delayed(Duration.zero);
    capture.state(RecordingState.stop);
    await expectation;
    expect(capture.stops, 1);
    expect(capture.phoneRecordingShortcutStarting, isFalse);
  });

  test('startup timeout cancels delayed setup before microphone activation', () async {
    final setup = Completer<void>();
    capture.setup = () => setup.future;
    final result = controller.start();
    final expectation = expectLater(result, failsWith('start_failed'));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(capture.mayStart!(), isFalse);
    expect(capture.phoneRecordingShortcutStarting, isTrue);
    setup.complete();
    await expectation;
    expect(capture.stops, 1);
    expect(capture.recordingState, RecordingState.stop);
    expect(capture.phoneRecordingShortcutStarting, isFalse);
  });

  test('losing foreground during setup prevents a delayed microphone start', () async {
    final setup = Completer<void>();
    capture.setup = () => setup.future;
    final result = controller.start();
    final expectation = expectLater(result, failsWith('start_failed'));
    await Future<void>.delayed(Duration.zero);
    foreground = false;
    expect(capture.mayStart!(), isFalse);
    setup.complete();
    await expectation;
    expect(capture.stops, 1);
  });

  test('a microphone callback after leaving foreground fails and stops recording', () async {
    final result = controller.start();
    final expectation = expectLater(result, failsWith('foreground_required'));
    await Future<void>.delayed(Duration.zero);
    foreground = false;
    capture.state(RecordingState.record);
    await expectation;
    expect(capture.stops, 1);
    expect(capture.recordingState, RecordingState.stop);
  });

  test('native channel handshake and concurrent requests wait for recording', () async {
    final service = PhoneRecordingShortcutService();
    const codec = StandardMethodCodec();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final handshakes = <String>[];
    messenger.setMockMethodCallHandler(PhoneRecordingShortcutService.channel, (call) async {
      handshakes.add(call.method);
      return null;
    });
    var pagesOpened = 0;
    service.attach(() async {
      if (await controller.start()) pagesOpened++;
    });
    Future<Object?> nativeRequest() async {
      final reply = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        PhoneRecordingShortcutService.channel.name,
        codec.encodeMethodCall(const MethodCall('startPhoneRecording')),
        reply.complete,
      );
      return codec.decodeEnvelope((await reply.future)!);
    }

    try {
      await service.markReady();
      expect(handshakes, ['ready']);
      await service.markNotReady();
      await service.markReady();
      final first = nativeRequest();
      final second = nativeRequest();
      await Future<void>.delayed(Duration.zero);
      expect(capture.starts, 1);
      expect(pagesOpened, 0);
      capture.state(RecordingState.record);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(pagesOpened, 1);
      signedIn = false;
      await expectLater(nativeRequest(), failsWith('sign_in_required'));
    } finally {
      service.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(handshakes, ['ready', 'notReady', 'ready', 'notReady']);
      messenger.setMockMethodCallHandler(PhoneRecordingShortcutService.channel, null);
    }
  });
}
