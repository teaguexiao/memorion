import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/speaker_mark_page.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/services/wals.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「标记说话人」卡片里新建的人：排到第一个选项、默认勾上（2026-11-02）。
///
/// 现场：点「添加新人物」建完，看不出加没加上。勾其实已经勾上了，但人物列表按名字排序，
/// 人一多新建的那个就埋在中间，用户得在搜索框里打出它的名字才看得到。
///
/// 每条断言对应一个各自静默的失败形态：
/// 1. 新人物是第一个选项，在「我」和其他所有人之上——否则又埋回按名字排的列表里。
/// 2. 不用再点它，直接按 ✓ 就分配给它（默认勾选）。
/// 3. 建之前搜过别的词也看得到它：搜索词要清掉，否则一个不匹配的关键词就把它滤掉了。
/// 4. 搜索框不能拿回焦点：输入框 sheet 关掉时焦点会还给搜索框，键盘弹回来正好盖住新人物。
/// 5. 同名已存在时后端复用那一条、返回原 id：列表里只能有一行（以前是直接追加，同一个
///    人出现两行，缓存里也是两条），同样提到最前。
/// 6. 创建失败要明说，不能静默；而且走全 App 统一的浮动 toast（`docs/feedback-audit.md`），
///    卡片还开着就看得到——只断言文字在不在，换回 SnackBar 也照样绿（它在卡片底下）。
///
/// Run: cd app && flutter test test/speaker_sheet_created_person_first_test.dart
class _Syncs extends Fake implements WalSyncs {
  @override
  Future<List<Wal>> getMissingWals() async => [];
}

class _Wal extends Fake implements IWalService {
  @override
  void subscribe(IWalServiceListener subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
  @override
  WalSyncs getSyncs() => _Syncs();
}

void main() {
  final now = DateTime(2026, 11, 2);
  Person person(String name) => Person(id: name.toLowerCase(), name: name, createdAt: now, updatedAt: now);

  /// 打开标记卡片，返回收尾函数。名字全排在「Zed」之前：旧逻辑下新建的 Zed 落在列表
  /// 末尾、屏幕之外。
  Future<Future<void> Function()> openSheet(WidgetTester tester,
      {required PersonCreator create, required List<String?> saves}) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    SharedPreferencesUtil().cachedPeople = [
      for (final n in ['Alice', 'Bob', 'Carol', 'Dave', 'Erin', 'Frank', 'Grace', 'Heidi']) person(n),
    ];
    final people = PeopleProvider(create: create);
    final conversations = ConversationProvider(wal: _Wal());
    final undo = UndoDeleteController();
    final conversation = ServerConversation.fromJson({
      'id': 'c',
      'created_at': now.toIso8601String(),
      'structured': {'title': '', 'overview': '', 'emoji': '', 'category': 'other', 'action_items': []},
      'transcript_segments': [
        {'id': 's', 'text': 'Hello', 'speaker': 'SPEAKER_00', 'is_user': false, 'person_id': null, 'start': 0.0, 'end': 1.0},
      ],
    });
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: people),
        ChangeNotifierProvider.value(value: conversations),
        ChangeNotifierProvider.value(value: undo),
      ],
      // toast 宿主与 observer 的挂法照抄 main.dart。
      child: MaterialApp(
        navigatorObservers: [UndoDeleteNavigatorObserver(undo)],
        locale: const Locale('zh'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        builder: (_, child) => UndoDeleteHost(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('打开标记'),
              onPressed: () => showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => SpeakerMarkSheet(
                  conversation: conversation,
                  speakerId: 0,
                  assignSpeaker: (id, ids, {isUser, personId}) async {
                    saves.add(personId);
                    return true;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开标记'));
    await tester.pumpAndSettle();
    return () async {
      await tester.pumpWidget(const SizedBox());
      people.dispose();
      conversations.dispose();
      undo.dispose();
    };
  }

  Future<void> addPerson(WidgetTester tester, String name) async {
    await tester.tap(find.text('添加新人物'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, name);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  testWidgets('新建的人排在第一个选项、默认勾上，搜索词清掉且键盘不弹回', (tester) async {
    final saves = <String?>[];
    final close = await openSheet(tester, create: (name) async => person(name), saves: saves);

    // 先搜一个跟新名字不沾边的词，并让搜索框持有焦点（键盘弹着）。
    await tester.enterText(find.byType(TextField).first, 'Ali');
    await tester.pump();
    expect(find.text('Bob'), findsNothing);

    await addPerson(tester, 'Zed');

    expect(find.text('Zed'), findsOneWidget);
    expect(top(tester, find.text('Zed')), lessThan(top(tester, find.text('我').first)));
    expect(top(tester, find.text('Zed')), lessThan(top(tester, find.text('Alice'))));
    expect(tester.getBottomLeft(find.text('Zed')).dy, lessThan(1000));
    // 搜索词清掉了，整张列表回来。
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, isEmpty);
    expect(find.text('Bob'), findsOneWidget);
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isFalse);

    // 不用再点 Zed，直接 ✓。
    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pumpAndSettle();
    expect(saves, ['zed']);
    expect(find.byType(SpeakerMarkSheet), findsNothing);
    await close();
  });

  testWidgets('同名已存在：后端复用那一条，列表里只有一行且提到最前', (tester) async {
    final saves = <String?>[];
    final close = await openSheet(tester, create: (_) async => person('Bob'), saves: saves);

    await addPerson(tester, 'bob');

    expect(tester.takeException(), isNull);
    expect(find.text('Bob'), findsOneWidget);
    expect(top(tester, find.text('Bob')), lessThan(top(tester, find.text('我').first)));
    expect(top(tester, find.text('Bob')), lessThan(top(tester, find.text('Alice'))));
    final provider = tester.element(find.byType(SpeakerMarkSheet)).read<PeopleProvider>();
    expect(provider.people.where((p) => p.id == 'bob'), hasLength(1));
    expect(SharedPreferencesUtil().cachedPeople.where((p) => p.id == 'bob'), hasLength(1));

    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pumpAndSettle();
    expect(saves, ['bob']);
    await close();
  });

  testWidgets('创建失败要提示，且不改动选择', (tester) async {
    final saves = <String?>[];
    final close = await openSheet(tester, create: (_) async => null, saves: saves);

    await addPerson(tester, 'Zed');

    expect(find.byType(SpeakerMarkSheet), findsOneWidget);
    expect(
        find.descendant(of: find.byKey(const ValueKey('feedback_toast')), matching: find.text('添加失败，请重试')),
        findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Zed'), findsNothing);
    await tester.tap(find.byIcon(Icons.check_rounded).first);
    await tester.pumpAndSettle();
    expect(saves, isEmpty);
    await close();
  });
}
