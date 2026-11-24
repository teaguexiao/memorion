import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/http/api/discover.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/promises_page.dart';
import 'package:memorion/pages/today_chapters/widgets/swipe_action_row.dart';
import 'package:memorion/pages/today_chapters/widgets/promise_row_content.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';

class _Env extends Fake implements EnvFields {
  @override
  String get apiBaseUrl => 'https://undo-test.invalid/';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var descriptions = <String>[];
  final deletes = <int>[];
  var reject = false;
  final generation = ValueNotifier<int>(0);
  final patches = <int>[];
  Completer<void>? deleteGate;
  var listReads = 0;
  http.Response respond(Object body, [int code = 200]) =>
      http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json; charset=utf-8'});
  final client = MockClient((request) async {
    final path = request.url.path;
    if (request.method == 'DELETE') {
      final idx = int.parse(path.split('/').last);
      deletes.add(idx);
      if (reject) return respond({}, 500);
      descriptions.removeAt(idx);
      await deleteGate?.future;
      return http.Response('', 204);
    }
    if (request.method == 'PATCH') {
      patches.add((jsonDecode(request.body)['updates'][0]['idx'] as num).toInt());
      return respond({});
    }
    if (path.endsWith('/discover/action-items')) {
      listReads++;
      return respond({
        'items': [
          for (var i = 0; i < descriptions.length; i++)
            {
              'description': descriptions[i],
              'completed': false,
              'conversation_id': 'c',
              'conversation_title': 'Chapter',
              'item_idx': i,
              'due_hint': '',
            }
        ],
        'total_count': descriptions.length,
        'has_more': false
      });
    }
    if (path.endsWith('/conversations/c')) {
      return respond({
        'id': 'c',
        'created_at': '2026-10-22T10:00:00Z',
        'structured': {
          'title': 'Chapter',
          'overview': '',
          'emoji': '',
          'category': 'other',
          'action_items': [
            for (final d in descriptions) {'description': d, 'completed': false, 'due_hint': ''}
          ],
        }
      });
    }
    throw StateError('Unexpected request: ${request.method} $path');
  });
  setUpAll(() async {
    Env.init(_Env());
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    ApiConfig().save('test-key', 'test-owner');
    await http.runWithClient(() => getActionItems(), () => client);
  });
  setUp(() {
    descriptions = ['First task', 'Middle task', 'Last task'];
    deletes.clear();
    reject = false;
    patches.clear();
    deleteGate = null;
    listReads = 0;
  });

  Future<UndoDeleteController> open(WidgetTester tester) async {
    final undo = UndoDeleteController();
    final discover = DiscoverProvider();
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: undo),
          ChangeNotifierProvider.value(value: discover),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          supportedLocales: S.supportedLocales,
          localizationsDelegates: S.localizationsDelegates,
          navigatorObservers: [UndoDeleteNavigatorObserver(undo)],
          builder: (_, child) => UndoDeleteHost(child: child!),
          home: ValueListenableBuilder<int>(
            valueListenable: generation,
            builder: (_, value, __) => PromisesPage(key: ValueKey(value)),
          ),
        )));
    await tester.pumpAndSettle();
    addTearDown(discover.dispose);
    return undo;
  }

  Future<void> remove(WidgetTester tester, String title) async {
    final row = find.ancestor(of: find.text(title).first, matching: find.byType(SwipeActionRow));
    await tester.drag(row, const Offset(-150, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.delete_outline_rounded)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester, UndoDeleteController undo) async {
    await tester.pumpWidget(const SizedBox());
    undo.dispose();
  }

  testWidgets('Undo keeps server data and restores all queued tasks', (tester) async {
    final undo = await open(tester);
    await remove(tester, 'First task');
    await remove(tester, 'Last task');
    expect(deletes, isEmpty);
    expect(descriptions.length, 3);
    await tester.tap(find.byKey(const ValueKey('undo_delete_action')));
    await tester.pumpAndSettle();
    expect(find.text('First task'), findsOneWidget);
    expect(find.text('Last task'), findsOneWidget);
    expect(deletes, isEmpty);
    await close(tester, undo);
  });
  testWidgets('expiry submits descending indices and leaves the middle task intact', (tester) async {
    final undo = await open(tester);
    await remove(tester, 'First task');
    await remove(tester, 'Last task');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(deletes, [2, 0]);
    expect(descriptions, ['Middle task']);
    expect(find.text('Middle task'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, undo);
  });
  testWidgets('changed server indices are refreshed without deleting a different task', (tester) async {
    final undo = await open(tester);
    await remove(tester, 'Last task');
    descriptions.removeAt(0);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(deletes, isEmpty);
    expect(descriptions, ['Middle task', 'Last task']);
    expect(find.text('Last task'), findsOneWidget);
    expect(undo.failed, isTrue);
    await close(tester, undo);
  });
  testWidgets('server rejection restores the row', (tester) async {
    final undo = await open(tester);
    reject = true;
    await remove(tester, 'Last task');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(descriptions.length, 3);
    expect(find.text('Last task'), findsOneWidget);
    expect(undo.failed, isTrue);
    await close(tester, undo);
  });
  testWidgets('reopened page refreshes after expiry and toggles the correct remaining index', (tester) async {
    final undo = await open(tester);
    await remove(tester, 'First task');
    generation.value++;
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('First task'), findsNothing);
    expect(find.text('Middle task'), findsOneWidget);
    final middle = tester
        .widgetList<PromiseRowContent>(find.byType(PromiseRowContent))
        .firstWhere((row) => row.description == 'Middle task');
    middle.onToggle!();
    await tester.pumpAndSettle();
    expect(patches, [0]);
    await close(tester, undo);
  });
  testWidgets('refresh during commit cannot replace the reserved task with its neighbour', (tester) async {
    final undo = await open(tester);
    deleteGate = Completer<void>();
    await remove(tester, 'First task');
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(descriptions, ['Middle task', 'Last task']);
    final reads = listReads;
    await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    expect(listReads, reads);
    deleteGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Middle task'), findsOneWidget);
    expect(find.text('Last task'), findsOneWidget);
    expect(find.text('First task'), findsNothing);
    await close(tester, undo);
  });
}
