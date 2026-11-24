import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/pages/today_chapters/plaud_setup_page.dart';
import 'package:memorion/services/devices/plaud/identity.dart';
import 'package:memorion/services/devices/plaud/identity_store.dart';

void main() {
  final data = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync());
  final identity = PlaudIdentity.fromJson(jsonEncode(data['identity']));
  final device =
      BtDevice(id: 'note', name: 'PLAUD_NOTE', type: DeviceType.plaudNote, rssi: -45, plaudSerial: identity.serial);
  const store = PlaudIdentityStore();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  Future<void> open(WidgetTester tester,
      {required Future<PlaudIdentity?> Function() pick,
      String Function()? owner,
      String language = 'zh',
      Future<bool> Function(Uri)? openGuide}) async {
    await tester.pumpWidget(MaterialApp(
        locale: Locale(language),
        localizationsDelegates: S.localizationsDelegates,
        supportedLocales: S.supportedLocales,
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PlaudSetupPage(
                            device: device,
                            currentOwner: owner ?? () => 'a',
                            pickIdentity: pick,
                            openGuide: openGuide))),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  test('secure identity is scoped to owner and device', () async {
    await store.save('a', 'note', identity);
    expect((await store.read('a', 'note'))!.serial, identity.serial);
    expect(await store.read('b', 'note'), null);
    expect(await store.read('a', 'other'), null);
  });
  testWidgets('setup explains automatic sync and imports credentials without a text field', (tester) async {
    await open(tester, pick: () async => identity);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('已完成的录音会自动同步到 Memorion'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plaud_import_credentials')));
    await tester.pumpAndSettle();
    expect((await store.read('a', 'note'))!.serial, identity.serial);
    expect(find.byType(PlaudSetupPage), findsNothing);
  });
  for (final language in ['zh', 'en']) {
    testWidgets('localized website fallback still allows local import ($language)', (tester) async {
      Uri? opened;
      await open(tester,
          language: language,
          pick: () async => identity,
          openGuide: (uri) async {
            opened = uri;
            return false;
          });
      await tester.tap(find.byKey(const ValueKey('plaud_setup_guide')));
      await tester.pumpAndSettle();
      expect(opened.toString(), 'https://memorion.me/$language/docs/plaud-note');
      expect(find.text(opened.toString()), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('plaud_import_credentials')));
      await tester.tap(find.byKey(const ValueKey('plaud_import_credentials')));
      await tester.pumpAndSettle();
      expect((await store.read('a', 'note'))!.serial, identity.serial);
      expect(find.byType(PlaudSetupPage), findsNothing);
    });
  }
  testWidgets('wrong device identity does not change stored authorization', (tester) async {
    final mismatch = PlaudIdentity.fromJson(jsonEncode({...data['identity'], 'serial': '888000000000000002'}));
    await open(tester, pick: () async => mismatch);
    await tester.tap(find.byKey(const ValueKey('plaud_import_credentials')));
    await tester.pumpAndSettle();
    expect(await store.read('a', 'note'), null);
    expect(find.textContaining('授权与这台 Note 不匹配'), findsOneWidget);
  });
  testWidgets('account switch while file picker is open cannot save either owner credentials', (tester) async {
    var owner = 'a';
    final gate = Completer<PlaudIdentity?>();
    await open(tester, pick: () => gate.future, owner: () => owner);
    await tester.tap(find.byKey(const ValueKey('plaud_import_credentials')));
    await tester.pump();
    owner = 'b';
    gate.complete(identity);
    await tester.pumpAndSettle();
    expect(await store.read('a', 'note'), null);
    expect(await store.read('b', 'note'), null);
    expect(find.textContaining('请登录 Memorion'), findsOneWidget);
  });
}
