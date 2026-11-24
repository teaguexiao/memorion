import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/soundcore_recordings_page.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';

class _ListSync extends SoundcoreSyncController {
  int requests = 0;
  bool transferring = false;
  List<SoundcoreRecording>? replacement;
  Completer<void>? transferGate;

  _ListSync(int count)
      : super(
            openStore: () async => throw StateError('UI only'),
            openSession: () async => null,
            isCurrentOwner: () => true) {
    recordings = files(count);
    deviceFileCount = count;
  }

  static List<SoundcoreRecording> files(int count) =>
      List.generate(count, (i) => SoundcoreRecording(1700000000 - i * 60, 1700000030 - i * 60, 0));

  @override
  bool get busy => transferring;

  @override
  Future<void> sync() async {
    requests++;
    if (transferring) return;
    if (replacement != null) {
      recordings = replacement!;
      replacement = null;
    }
    deviceFileCount = recordings.length;
    lastRefresh = DateTime(2026, 9, 19).add(Duration(seconds: requests));
    notifyListeners();
    if (transferGate != null) {
      transferring = true;
      await transferGate!.future;
      transferring = false;
    }
  }

  void updateFiles(int count) {
    recordings = files(count);
    notifyListeners();
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
  });
  for (final language in ['zh', 'en']) {
    Future<void> open(WidgetTester tester, _ListSync sync) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(sync.dispose);
      final feedback = UndoDeleteController();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        feedback.dispose();
      });
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: feedback,
          child: MaterialApp(
            builder: (_, child) => UndoDeleteHost(child: child!),
            locale: Locale(language),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: SoundcoreRecordingsPage(
              device: BtDevice(name: 'Soundcore Work', id: 'pagination-test', type: DeviceType.soundcore, rssi: -50),
              controller: sync,
            ),
          )));
      await tester.pumpAndSettle();
    }

    Future<void> pager(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.byKey(const ValueKey('soundcore_page_range')), 400);
      await tester.pumpAndSettle();
    }

    testWidgets('active older recording has progress at the top even on another page ($language)', (tester) async {
      final sync = _ListSync(25);
      final oldest = sync.recordings.last;
      sync.activeId = oldest.id;
      sync.stages[oldest.id] = SoundcoreImportStage.downloading;
      sync.bytes = 2048;
      await open(tester, sync);
      expect(find.byKey(ValueKey('soundcore_recording_${oldest.id}')), findsNothing);
      final summary = find.byKey(const ValueKey('soundcore_active_sync'));
      expect(summary, findsOneWidget);
      expect(tester.getTopLeft(summary).dy, lessThan(350));
      expect(find.descendant(of: summary, matching: find.textContaining('2 KB')), findsOneWidget);
      sync.stages[oldest.id] = SoundcoreImportStage.uploading;
      sync.uploadBytes = 4096;
      sync.notifyListeners();
      await tester.pump();
      expect(find.descendant(of: summary, matching: find.textContaining('4 KB')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('20-file pages navigate, keep sync state and clamp after removal ($language)', (tester) async {
      final sync = _ListSync(45);
      await open(tester, sync);
      await pager(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('soundcore_previous_page'))).onPressed, isNull);
      expect(find.byKey(ValueKey('soundcore_recording_${sync.recordings[20].id}')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('soundcore_next_page')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(ValueKey('soundcore_recording_${sync.recordings[20].id}')), 200);
      await pager(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      sync.transferring = true;
      sync.notifyListeners();
      await tester.pump();
      expect(find.text('2 / 3'), findsOneWidget);
      expect(sync.requests, 1); // Navigation/progress notifications never start transfers.
      await tester.tap(find.byKey(const ValueKey('soundcore_next_page')));
      await tester.pumpAndSettle();
      await pager(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('soundcore_next_page'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('soundcore_previous_page')));
      await tester.pumpAndSettle();
      await pager(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      sync.updateFiles(20);
      await tester.pumpAndSettle();
      await pager(tester);
      expect(find.byKey(const ValueKey('soundcore_next_page')), findsNothing);
      expect(find.text(language == 'zh' ? '1–20 条，共 20 条' : '1–20 of 20'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pull refresh resets page and ends when discovery finishes before download ($language)',
        (tester) async {
      final sync = _ListSync(21);
      await open(tester, sync);
      await pager(tester);
      await tester.tap(find.byKey(const ValueKey('soundcore_next_page')));
      await tester.pumpAndSettle();
      const fresh = SoundcoreRecording(1800000000, 1800000030, 0);
      sync.replacement = [fresh, ...sync.recordings];
      final gate = sync.transferGate = Completer<void>();
      final refresh = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
      await refresh; // Must finish while the download gate remains closed.
      await tester.pumpAndSettle();
      expect(gate.isCompleted, isFalse);
      expect(sync.transferring, isTrue);
      await tester.scrollUntilVisible(find.byKey(ValueKey('soundcore_recording_${fresh.id}')), 200);
      await pager(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text(language == 'zh' ? '1–20 条，共 22 条' : '1–20 of 22'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('toolbar refresh returns a scrolled later page to the top ($language)', (tester) async {
      final sync = _ListSync(45);
      await open(tester, sync);
      await pager(tester);
      await tester.tap(find.byKey(const ValueKey('soundcore_next_page')));
      await tester.pumpAndSettle();
      await pager(tester);
      expect(tester.widget<ListView>(find.byType(ListView)).controller!.offset, greaterThan(0));
      await tester.tap(find.byTooltip(language == 'zh' ? '刷新' : 'Refresh'));
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(find.byType(ListView)).controller!.offset, 0);
      await pager(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty list accepts pull gesture and active sync queues refresh ($language)', (tester) async {
      final sync = _ListSync(0);
      await open(tester, sync);
      sync.replacement = _ListSync.files(1);
      await tester.drag(find.byType(ListView), const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(sync.requests, 2);
      expect(sync.recordings, hasLength(1));
      sync.transferring = true;
      await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
      await tester.pump();
      expect(sync.requests, 3);
      expect(sync.transferring, isTrue);
      expect(find.textContaining(language == 'zh' ? '刷新已排队' : 'Refresh queued'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
