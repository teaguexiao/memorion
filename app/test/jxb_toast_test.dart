import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/widgets/jxb_toast.dart';

void main() {
  setUpAll(() async {
    final font = Platform.environment['TOAST_PREVIEW_FONT'];
    if (font != null) {
      final loader = FontLoader('PingFang SC')
        ..addFont(Future.value(ByteData.sublistView(File(font).readAsBytesSync())));
      await loader.load();
    }
  });

  for (final english in [false, true]) {
    testWidgets('390px ${english ? 'English' : 'Chinese'} deletion matches floating geometry', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = UndoDeleteController();
      final capture = GlobalKey();
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: c,
        child: MaterialApp(
          locale: Locale(english ? 'en' : 'zh'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(bottom: 34)),
            child: UndoDeleteHost(child: child!),
          ),
          home: const Scaffold(backgroundColor: Color(0xFFF6FAFF)),
        ),
      ));
      c.add(UndoDeletion(
        key: 'fact',
        kind: DeleteKind.fact,
        title: english
            ? 'You recently attended a week-long training program in Xi’an to learn how to work as a forward-deployed engineer.'
            : '你最近去西安参加了一周的培训，学习如何做FDE。',
        commit: () async => true,
      ));
      await tester.pump();
      final toast = find.byKey(const ValueKey('undo_delete_toast'));
      expect(tester.getSize(toast), const Size(320, 48));
      expect(tester.getTopLeft(toast).dx, 35);
      expect(tester.getTopLeft(toast).dy, 700);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final action = find.byKey(const ValueKey('undo_delete_action'));
      expect(tester.getSize(action).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
      expect(find.textContaining(english ? 'Deleted: ' : '已删除：', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Optional native Flutter raster output, never part of the app payload.
      final output = Platform.environment['TOAST_PREVIEW_DIR'];
      if (output != null) {
        final widget = tester.widget<JxbToast>(find.byType(JxbToast));
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
          backgroundColor: const Color(0xFFF6FAFF),
          body: Center(
              child: RepaintBoundary(key: capture, child: Padding(padding: const EdgeInsets.all(24), child: widget))),
        )));
        await tester.pump();
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$output/${english ? 'english' : 'chinese'}-toast.png').writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  for (final english in [false, true]) {
    testWidgets('maximum accessibility scale keeps ${english ? 'English' : 'Chinese'} Undo inside surface',
        (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = UndoDeleteController();
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: c,
          child: MaterialApp(
            locale: Locale(english ? 'en' : 'zh'),
            supportedLocales: S.supportedLocales,
            localizationsDelegates: S.localizationsDelegates,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(3.1)),
                child: UndoDeleteHost(child: child!)),
            home: const Scaffold(),
          )));
      for (var i = 0; i < 2; i++) {
        c.add(UndoDeletion(key: '$i', kind: DeleteKind.fact, title: 'Fact', commit: () async => true));
      }
      await tester.pump();
      final surface = tester.getRect(find.byKey(const ValueKey('undo_delete_toast')));
      final action = tester.getRect(find.byKey(const ValueKey('undo_delete_action')));
      expect(surface.contains(action.topLeft), isTrue);
      expect(surface.contains(action.bottomRight), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets('long feedback preserves permission recovery instructions', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const message = 'Reminders access denied — enable it in Settings › Privacy › Reminders';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: JxbToast(message: message)))));
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
    expect(tester.getSize(find.byType(JxbToast)).height, greaterThan(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain feedback is compact, clears after 3 seconds and shares Undo slot', (tester) async {
    final c = UndoDeleteController();
    late BuildContext page;
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: c,
        child: MaterialApp(
          builder: (_, child) => UndoDeleteHost(child: child!),
          home: Builder(builder: (context) {
            page = context;
            return const Scaffold();
          }),
        )));
    UndoDeleteHost.showMessage(page, 'Added to Reminders');
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback_toast')), findsOneWidget);
    expect(tester.getSize(find.byType(JxbToast)).width, lessThan(320));
    expect(tester.getSize(find.byType(JxbToast)).height, 44);
    c.add(UndoDeletion(key: 'x', kind: DeleteKind.fact, title: 'Fact', commit: () async => true));
    await tester.pump();
    UndoDeleteHost.showMessage(page, 'Other feedback');
    await tester.pump();
    expect(find.byType(JxbToast), findsOneWidget);
    expect(find.text('Other feedback'), findsNothing);
    c.undo();
    await tester.pump();
    await tester.pump();
    expect(find.text('Other feedback', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(JxbToast), findsNothing);
    UndoDeleteHost.showMessage(page, 'Added to Reminders');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(JxbToast), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
