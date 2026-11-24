import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/widgets/jxb_toast.dart';

void main() {
  testWidgets('detail toast matches Figma and returning home clears navigation', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UndoDeleteController();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: c,
      child: MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [UndoDeleteNavigatorObserver(c)],
        locale: const Locale('zh'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(bottom: 34)),
          child: UndoDeleteHost(child: child!),
        ),
        home: const Scaffold(),
      ),
    ));
    await tester.pump();
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
    await tester.pumpAndSettle();
    c.add(UndoDeletion(key: 'a', kind: DeleteKind.fact, title: 'Fact', commit: () async => true));
    await tester.pump();
    final toast = find.byKey(const ValueKey('undo_delete_toast'));
    expect(tester.getTopLeft(toast), const Offset(35, 700));
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toast), const Offset(35, 682));
    c.undo();
    await tester.pump();
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
    await tester.pumpAndSettle();
    UndoDeleteHost.showMessage(nav.currentContext!, '已加入提醒事项');
    await tester.pump();
    final feedback = find.byKey(const ValueKey('feedback_toast'));
    expect(tester.getSize(feedback).height, 44);
    expect(tester.getRect(feedback).center.dx, 195);
    expect(tester.getTopLeft(feedback).dy, 700);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('floating undo toast supports aggregation, long titles and large type', (tester) async {
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UndoDeleteController();
    addTearDown(c.dispose);
    var commits = 0;
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: c,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
              child: UndoDeleteHost(child: child!)),
          home: const Scaffold(),
        )));
    for (final key in ['a', 'b']) {
      c.add(UndoDeletion(
          key: key,
          kind: DeleteKind.chapter,
          title: '一段很长的章节标题用于检查窄屏大字布局',
          commit: () async {
            commits++;
            return true;
          }));
    }
    await tester.pump();
    expect(find.textContaining('2 个章节', findRichText: true), findsOneWidget);
    expect(find.text('全部撤销'), findsOneWidget);
    expect(tester.widget<Material>(find.byKey(const ValueKey('undo_delete_toast'))).color, JxbToast.background);
    expect(tester.getSize(find.byKey(const ValueKey('undo_delete_action'))).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('全部撤销'));
    await tester.pump();
    expect(c.pending, isEmpty);
    expect(commits, 0);
  });
  testWidgets('dialogs hide the toast and preserve remaining time', (tester) async {
    final c = UndoDeleteController();
    final nav = GlobalKey<NavigatorState>();
    var commits = 0;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: c,
      child: MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [UndoDeleteNavigatorObserver(c)],
        builder: (_, child) => UndoDeleteHost(child: child!),
        home: const Scaffold(),
      ),
    ));
    c.add(UndoDeletion(
        key: 'a',
        kind: DeleteKind.fact,
        title: 'Fact',
        commit: () async {
          commits++;
          return true;
        }));
    await tester.pump(const Duration(seconds: 2));
    showDialog<void>(context: nav.currentContext!, builder: (_) => const AlertDialog(content: Text('Dialog')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('undo_delete_toast')), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(commits, 0);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('undo_delete_toast')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(commits, 1);
    showModalBottomSheet<void>(context: nav.currentContext!, builder: (_) => const SizedBox(height: 350));
    await tester.pumpAndSettle();
    c.add(UndoDeletion(key: 'contact', kind: DeleteKind.contact, title: 'Contact', commit: () async => true));
    await tester.pump();
    expect(find.byKey(const ValueKey('undo_delete_toast')), findsOneWidget);
    c.undo();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('screen reader has explicit confirmation and background cancels reservations', (tester) async {
    final c = UndoDeleteController();
    var commits = 0, cancels = 0;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: c,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
          child: UndoDeleteHost(child: child!),
        ),
        home: const Scaffold(),
      ),
    ));
    UndoDeletion entry() => UndoDeletion(
        key: 'a',
        kind: DeleteKind.fact,
        title: 'Fact',
        cancel: () => cancels++,
        commit: () async {
          commits++;
          return true;
        });
    c.add(entry());
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(commits, 0);
    await tester.tap(find.text('Confirm deletion'));
    await tester.pump();
    expect(commits, 1);
    c.add(entry());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(c.pending, isEmpty);
    expect(cancels, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
