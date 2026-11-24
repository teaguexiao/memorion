import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/main.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/utils/alerts/app_snackbar.dart';
import 'package:memorion/widgets/jxb_toast.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:provider/provider.dart';

Future<UndoDeleteController> mountHost(WidgetTester tester, {bool accessible = false}) async {
  final c = UndoDeleteController();
  addTearDown(c.dispose);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: c,
    child: MaterialApp(
      navigatorKey: MyApp.navigatorKey,
      navigatorObservers: [UndoDeleteNavigatorObserver(c)],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(accessibleNavigation: accessible),
        child: UndoDeleteHost(child: child!),
      ),
      home: const Scaffold(),
    ),
  ));
  await tester.pump();
  return c;
}

void main() {
  testWidgets('provider feedback uses the same dark surface and lasts three seconds', (tester) async {
    await mountHost(tester);
    AppSnackbar.showSnackbarError('Could not connect');
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.widget<Material>(find.byKey(const ValueKey('feedback_toast'))).color, JxbToast.background);
    expect(tester.getSize(find.byKey(const ValueKey('feedback_toast'))).height, 44);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(JxbToast), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('deletion and dialogs pause speaker Undo; incidental feedback stays queued', (tester) async {
    final c = await mountHost(tester);
    var undone = 0;
    UndoDeleteHost.showMessage(MyApp.navigatorKey.currentContext!, 'Chapter updated',
        duration: const Duration(seconds: 10), actionLabel: 'Undo', showProgress: true, onAction: () => undone++);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    c.add(UndoDeletion(key: 'fact', kind: DeleteKind.fact, title: 'Fact', commit: () async => true));
    await tester.pump();
    UndoDeleteHost.showMessage(MyApp.navigatorKey.currentContext!, 'Copied once');
    UndoDeleteHost.showMessage(MyApp.navigatorKey.currentContext!, 'Copied latest');
    expect(find.byType(JxbToast), findsOneWidget);
    expect(find.byKey(const ValueKey('undo_delete_toast')), findsOneWidget);
    // A modal must not consume either Undo window.
    showDialog<void>(context: MyApp.navigatorKey.currentContext!, builder: (_) => const AlertDialog());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 15));
    expect(find.byType(JxbToast), findsNothing);
    MyApp.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    c.undo();
    await tester.pump();
    await tester.pump();
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Chapter updated', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(undone, 1);
    expect(find.text('Copied latest', findRichText: true), findsOneWidget);
    expect(find.text('Copied once', findRichText: true), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ordinary feedback receives its full duration after a dialog closes', (tester) async {
    await mountHost(tester);
    showDialog<void>(context: MyApp.navigatorKey.currentContext!, builder: (_) => const AlertDialog());
    await tester.pumpAndSettle();
    AppSnackbar.showSnackbarSuccess('Saved');
    await tester.pump(const Duration(seconds: 12));
    expect(find.byType(JxbToast), findsNothing);
    MyApp.navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saved', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Saved', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(JxbToast), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('screen readers retain actionable feedback until the action is used', (tester) async {
    await mountHost(tester, accessible: true);
    var retried = 0;
    UndoDeleteHost.showMessage(MyApp.navigatorKey.currentContext!, 'Could not save',
        actionLabel: 'Retry', onAction: () => retried++);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retried, 1);
    expect(find.byType(JxbToast), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('async page feedback survives navigation but stale page actions are removed', (tester) async {
    await mountHost(tester);
    late BuildContext page;
    MyApp.navigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (context) {
      page = context;
      return const Scaffold();
    }));
    await tester.pumpAndSettle();
    final sink = UndoDeleteHost.messageSink(page);
    UndoDeleteHost.showMessage(page, 'Updated', actionLabel: 'Undo', onAction: () => fail('Disposed page action'));
    await tester.pump();
    MyApp.navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(page.mounted, isFalse);
    expect(find.text('Undo'), findsNothing);
    sink('Export failed');
    await tester.pump();
    expect(find.text('Export failed', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    sink('Host disposed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('route replacement removes page actions even with a paused screen reader clock', (tester) async {
    await mountHost(tester, accessible: true);
    final page = tester.element(find.byType(Scaffold));
    UndoDeleteHost.showMessage(page, 'Updated', actionLabel: 'Undo', onAction: () => fail('Replaced page action'));
    await tester.pump();
    MyApp.navigatorKey.currentState!.pushReplacement(MaterialPageRoute<void>(builder: (_) => const Scaffold()));
    await tester.pumpAndSettle();
    expect(page.mounted, isFalse);
    expect(find.byType(JxbToast), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
