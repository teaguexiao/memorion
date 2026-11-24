import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/notifications/fcm_token_registration.dart';

void main() {
  late StreamController<String> refresh;
  late FcmTokenRegistration registration;
  late String? account;
  late bool apnsReady;
  late String token;
  late List<String> uploads;
  late int reads;
  late bool uploadFails;
  Future<String?> Function()? readOverride;

  setUp(() {
    refresh = StreamController<String>.broadcast();
    account = 'teague';
    apnsReady = false;
    token = 'token-1';
    uploads = [];
    reads = 0;
    uploadFails = false;
    readOverride = null;
    registration = FcmTokenRegistration(
      currentAccount: () => account,
      isReady: () async => apnsReady,
      getToken: () async {
        reads++;
        return readOverride == null ? token : await readOverride!();
      },
      uploadToken: (value, owner) async {
        if (uploadFails) throw StateError('offline');
        uploads.add('$owner:$value');
      },
      tokenRefresh: refresh.stream,
      log: (_) {},
      retryDelays: const [Duration(seconds: 2), Duration(seconds: 4)],
    );
  });

  tearDown(() async {
    registration.dispose();
    await refresh.close();
  });

  testWidgets('waits for delayed APNs registration before reading/uploading FCM', (tester) async {
    await registration.register();
    expect(reads, 0);
    expect(uploads, isEmpty);
    apnsReady = true;
    await tester.pump(const Duration(seconds: 2));
    expect(uploads, ['teague:token-1']);
  });

  testWidgets('refresh is observed even after the initial registration failed', (tester) async {
    await registration.register();
    apnsReady = true;
    token = 'token-2';
    refresh.add(token);
    await tester.pump();
    expect(uploads, ['teague:token-2']);
    await tester.pump(const Duration(seconds: 10));
    expect(uploads, hasLength(1));
  });

  testWidgets('failed server upload is retried', (tester) async {
    apnsReady = true;
    uploadFails = true;
    await registration.register();
    expect(uploads, isEmpty);
    uploadFails = false;
    await tester.pump(const Duration(seconds: 2));
    expect(uploads, ['teague:token-1']);
  });

  testWidgets('simultaneous calls join one registration and install one listener', (tester) async {
    apnsReady = true;
    registration.start();
    registration.start();
    await Future.wait([registration.register(), registration.register()]);
    expect(reads, 1);
    token = 'token-2';
    refresh.add(token);
    await tester.pump();
    expect(uploads, ['teague:token-1', 'teague:token-2']);
  });

  testWidgets('a refresh arriving during upload is synchronized afterwards', (tester) async {
    apnsReady = true;
    final pending = Completer<String?>();
    readOverride = () => pending.future;
    final first = registration.register();
    await tester.pump();
    token = 'token-2';
    refresh.add(token);
    await tester.pump();
    readOverride = null;
    pending.complete('token-1');
    await first;
    await tester.pump();
    expect(uploads.last, 'teague:token-2');
  });

  testWidgets('logout during token retrieval prevents an upload', (tester) async {
    apnsReady = true;
    final pending = Completer<String?>();
    readOverride = () => pending.future;
    final first = registration.register();
    await tester.pump();
    account = null;
    pending.complete('token-1');
    await first;
    expect(uploads, isEmpty);
  });

  testWidgets('retries stop at the budget; foreground retry can recover', (tester) async {
    await registration.register();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 4));
    apnsReady = true;
    await tester.pump(const Duration(minutes: 5));
    expect(uploads, isEmpty);
    await registration.register();
    expect(uploads, ['teague:token-1']);
  });

  testWidgets('dispose cancels pending retry and token refresh', (tester) async {
    await registration.register();
    registration.dispose();
    apnsReady = true;
    refresh.add('token-2');
    await tester.pump(const Duration(seconds: 10));
    expect(uploads, isEmpty);
  });
}
