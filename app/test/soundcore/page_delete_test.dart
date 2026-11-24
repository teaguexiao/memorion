import 'package:provider/provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/soundcore_recordings_page.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';

class _ListSync extends SoundcoreSyncController {
  final removed = <int>[];
  bool fail = false;
  _ListSync(int count)
      : super(
            openStore: () async => throw StateError('UI only'),
            openSession: () async => null,
            isCurrentOwner: () => true) {
    recordings = List.generate(count, (i) => SoundcoreRecording(1700000000 - i * 60, 1700000030 - i * 60, 0));
  }
  @override
  Future<void> sync() async {}
  @override
  Future<void> commitReservedRemoval(int id) async {
    if (fail) {
      cancelRemoval(id);
      throw StateError('Storage unavailable');
    }
    removed.add(id);
    recordings = recordings.where((r) => r.id != id).toList();
    cancelRemoval(id);
    notifyListeners();
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter-Regular.ttf'))).load();
  });
  for (final language in ['zh', 'en']) {
    Future<void> open(WidgetTester tester, _ListSync sync) async {
      tester.view.physicalSize = const Size(320, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(sync.dispose);
      final undo = UndoDeleteController();
      addTearDown(undo.dispose);
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: undo,
          child: MaterialApp(
            navigatorObservers: [UndoDeleteNavigatorObserver(undo)],
            builder: (context, child) => UndoDeleteHost(child: child!),
            locale: Locale(language),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            home: SoundcoreRecordingsPage(
                device: BtDevice(id: 'bean', name: '', type: DeviceType.soundcore, rssi: -50), controller: sync),
          )));
      await tester.pump(const Duration(milliseconds: 250));
    }

    Future<void> swipeDelete(WidgetTester tester, int id) async {
      final row = find.byKey(ValueKey('soundcore_swipe_$id'));
      await tester.scrollUntilVisible(row, 250);
      await tester.pumpAndSettle();
      await tester.drag(row, const Offset(-130, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.delete_outline_rounded)));
      await tester.pumpAndSettle();
    }

    testWidgets('swipe deletes short and no-speech records only after confirmation ($language)', (tester) async {
      final sync = _ListSync(2);
      final shortId = sync.recordings.first.id;
      final silentId = sync.recordings.last.id;
      sync.failures[shortId] = const SoundcoreImportException(
          400, AudioUploadFailure(AudioUploadIssue.duration, errorCode: SoundcoreImportException.durationTooShort));
      sync.stages[silentId] = SoundcoreImportStage.uploaded;
      sync.processingJobs[silentId] = AudioProcessingJob.fromJson({
        'id': 'job',
        'status': 'failed',
        'error_code': 'no_speech',
        'conversation_id': 'conversation',
        'stage': 'failed',
        'started_at': '2026-10-15T10:00:00Z'
      });
      await open(tester, sync);
      await swipeDelete(tester, shortId);
      expect(find.byKey(const ValueKey('soundcore_delete_confirmation')), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '录音豆上的原文件' : 'original on the recorder'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('soundcore_delete_cancel')));
      await tester.pumpAndSettle();
      expect(sync.removed, isEmpty);
      for (final id in [shortId, silentId]) {
        await swipeDelete(tester, id);
        await tester.tap(find.byKey(const ValueKey('soundcore_delete_confirm')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('soundcore_recording_$id')), findsNothing);
      }
      expect(sync.removed, isEmpty);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(sync.removed, [shortId, silentId]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('deletion failure keeps row and reports an error ($language)', (tester) async {
      final sync = _ListSync(1)..fail = true;
      final id = sync.recordings.single.id;
      await open(tester, sync);
      await swipeDelete(tester, id);
      await tester.tap(find.byKey(const ValueKey('soundcore_delete_confirm')));
      await tester.pumpAndSettle();
      expect(sync.removed, isEmpty);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('soundcore_recording_$id')), findsOneWidget);
      expect(find.textContaining(language == 'zh' ? '删除未成功' : 'deletions failed'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('deleting last item on last page returns to preceding page ($language)', (tester) async {
      final sync = _ListSync(21);
      final id = sync.recordings.last.id;
      await open(tester, sync);
      final next = find.byKey(const ValueKey('soundcore_next_page'));
      await tester.scrollUntilVisible(next, 400);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
      await swipeDelete(tester, id);
      await tester.tap(find.byKey(const ValueKey('soundcore_delete_confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('soundcore_recording_${sync.recordings.first.id}')), findsOneWidget);
      expect(sync.recordings.length, 21);
      await tester.tap(find.byKey(const ValueKey('undo_delete_action')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('soundcore_recording_$id')), findsOneWidget);
      expect(sync.removed, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('active transfer has no swipe delete action ($language)', (tester) async {
      final sync = _ListSync(1);
      sync.activeId = sync.recordings.single.id;
      sync.stages[sync.activeId!] = SoundcoreImportStage.downloading;
      await open(tester, sync);
      await tester.drag(find.byKey(ValueKey('soundcore_swipe_${sync.activeId}')), const Offset(-130, 0));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
