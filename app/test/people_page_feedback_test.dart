import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/people_page.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「人物」页的新建 / 重命名：每种结果都要让用户看得到（2026-11-02）。
///
/// 以前这三种情况都是 sheet 照样关、什么都不说：
/// 1. 新建失败——人没建出来，用户以为加上了。
/// 2. 重命名失败——本地先把名字改了，服务器上还是旧的，下次刷新又变回去。
/// 3. 名字不足 2 个字——什么都不建。
///
/// 现在 1、2 弹全 App 统一的浮动 toast（`docs/feedback-audit.md`），重命名失败时列表保持
/// 旧名字；3 留在 sheet 里，提示和标记说话人卡片一样。
///
/// Run: cd app && flutter test test/people_page_feedback_test.dart
void main() {
  final now = DateTime(2026, 11, 2);
  Person person(String id, String name) => Person(id: id, name: name, createdAt: now, updatedAt: now);

  /// 打开人物页（列表里只有「阿宁」），返回收尾函数。toast 宿主与 observer 的挂法照抄 main.dart。
  Future<Future<void> Function()> openPage(WidgetTester tester,
      {PersonCreator? create, PersonRenamer? rename}) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    final people = PeopleProvider(
      fetch: () async => [person('a', '阿宁')],
      fetchPerson: (id, {includeSpeechSamples = false}) async => null,
      create: create,
      rename: rename,
    );
    final undo = UndoDeleteController();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: people),
        ChangeNotifierProvider.value(value: undo),
      ],
      child: MaterialApp(
        navigatorObservers: [UndoDeleteNavigatorObserver(undo)],
        locale: const Locale('zh'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        builder: (_, child) => UndoDeleteHost(child: child!),
        home: const PeoplePage(),
      ),
    ));
    await tester.pumpAndSettle();
    return () async {
      await tester.pumpWidget(const SizedBox());
      people.dispose();
      undo.dispose();
    };
  }

  Finder toast(String text) =>
      find.descendant(of: find.byKey(const ValueKey('feedback_toast')), matching: find.text(text));

  Future<void> submitName(WidgetTester tester, String name, String button) async {
    await tester.enterText(find.byType(TextField).last, name);
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
  }

  testWidgets('新建失败弹统一 toast', (tester) async {
    final close = await openPage(tester, create: (_) async => null);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await submitName(tester, '张三', '添加');

    expect(find.text('添加人物'), findsNothing);
    expect(toast('添加失败，请重试'), findsOneWidget);
    expect(find.text('张三'), findsNothing);
    await close();
  });

  testWidgets('重命名失败弹统一 toast，列表保持旧名字', (tester) async {
    final renames = <String>[];
    final close = await openPage(tester, rename: (id, name) async {
      renames.add('$id:$name');
      return false;
    });
    await tester.tap(find.text('阿宁'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await submitName(tester, '阿宁宁', '保存');

    expect(renames, ['a:阿宁宁']);
    expect(toast('保存失败，请重试'), findsOneWidget);
    expect(find.text('阿宁'), findsOneWidget);
    expect(find.text('阿宁宁'), findsNothing);
    await close();
  });

  testWidgets('名字不足 2 个字：留在 sheet 里提示，改对了才建', (tester) async {
    final created = <String>[];
    final close = await openPage(tester, create: (name) async {
      created.add(name);
      return person('z', name);
    });
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await submitName(tester, '张', '添加');

    expect(find.text('添加人物'), findsOneWidget);
    expect(find.text('姓名需为 2-40 个字符'), findsOneWidget);
    expect(created, isEmpty);

    await submitName(tester, '张三', '添加');
    expect(created, ['张三']);
    expect(find.text('添加人物'), findsNothing);
    expect(find.text('张三'), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback_toast')), findsNothing);
    await close();
  });
}
