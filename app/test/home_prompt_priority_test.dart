import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/today_chapters_page.dart';
import 'package:memorion/pages/today_chapters/widgets/task_bubble_card.dart';
import 'package:memorion/pages/today_chapters/widgets/task_reminder_card.dart';
import 'package:memorion/providers/capture_provider.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:memorion/services/wals.dart';
import 'package:memorion/utils/task_confirm_rotation.dart';
import 'package:memorion/utils/task_reminder_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

// Keep the real prompt selection and actions; isolate unrelated cloud polling.
class _Conversations extends ConversationProvider {
  _Conversations() : super(wal: _Wal());
  @override
  void startCloudProcessingWatch() {}
  @override
  void stopCloudProcessingWatch() {}
}

class _Device extends ChangeNotifier implements DeviceProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
  @override
  bool get isConnected => false;
  @override
  int get batteryLevel => 0;
  @override
  bool get isCharging => false;
}

class _Capture extends ChangeNotifier implements CaptureProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
  @override
  bool get isRecording => false;
}

ActionItem _reminder(String description, {int overdueHours = 1}) => ActionItem(
      description,
      dueDate: DateTime.now().subtract(Duration(hours: overdueHours)),
    );

_Conversations _provider(List<ActionItem> items) => _Conversations()
  ..conversations = [
    ServerConversation(
      id: 'conversation',
      createdAt: DateTime.now(),
      structured: Structured('A conversation', '')..actionItems = items,
    ),
  ];

Future<void> _open(WidgetTester tester, ConversationProvider provider) async {
  final timeline = TimelineProvider(
    fetch: ({String date = '', bool refresh = false}) async =>
        TimelineDay.fromJson({'date': date, 'chapters': []}, fallbackDate: date),
  );
  addTearDown(timeline.dispose);
  addTearDown(provider.dispose);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<ConversationProvider>.value(value: provider),
      ChangeNotifierProvider<TimelineProvider>.value(value: timeline),
      ChangeNotifierProvider<DeviceProvider>(create: (_) => _Device()),
      ChangeNotifierProvider<CaptureProvider>(create: (_) => _Capture()),
    ],
    child: const MaterialApp(
      locale: Locale('zh'),
      supportedLocales: S.supportedLocales,
      localizationsDelegates: S.localizationsDelegates,
      home: TodayChaptersPage(),
    ),
  ));
  await tester.pump();
}

void _expectPrompt(Type type) {
  for (final candidate in [TaskReminderCard, TaskReminderAckCard, TaskBubbleCard]) {
    expect(find.byType(candidate), candidate == type ? findsOneWidget : findsNothing);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({'notifTaskReminder': false});
    await SharedPreferencesUtil.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('awesome_notifications'),
      (_) async => true,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('awesome_notifications'), null);
  });

  testWidgets('all due reminders precede unheard tasks, one card at a time', (tester) async {
    final task = ActionItem('New task', confirmed: false);
    final provider = _provider([
      _reminder('Later reminder'),
      task,
      _reminder('Oldest reminder', overdueHours: 2),
    ]);
    await _open(tester, provider);

    _expectPrompt(TaskReminderCard);
    expect(find.text('Oldest reminder'), findsOneWidget);
    expect(TaskConfirmRotation.lastAskedAt('conversation', task.description), isNull);

    await tester.tap(find.text('OK'));
    await tester.pump();
    _expectPrompt(TaskReminderCard);
    expect(find.text('Later reminder'), findsOneWidget);
    expect(TaskConfirmRotation.lastAskedAt('conversation', task.description), isNull);

    await tester.tap(find.text('OK'));
    await tester.pump();
    _expectPrompt(TaskBubbleCard);
    expect(find.text(task.description), findsOneWidget);
    expect(TaskConfirmRotation.lastAskedAt('conversation', task.description), isNotNull);
    expect(task.confirmed, isFalse);
    expect(provider.conversations.single.structured.actionItems, hasLength(3));
  });

  testWidgets('snooze receipt yields to the next reminder, then the deferred task', (tester) async {
    final task = ActionItem('Deferred task', confirmed: false);
    final provider = _provider([_reminder('First', overdueHours: 2), _reminder('Second'), task]);
    await _open(tester, provider);

    await tester.tap(find.text('稍后提醒我'));
    await tester.pump();
    _expectPrompt(TaskReminderAckCard);
    expect(TaskReminderState.isSnoozed('conversation', 'First'), isTrue);
    expect(TaskConfirmRotation.lastAskedAt('conversation', task.description), isNull);

    await tester.pump(const Duration(seconds: 2));
    _expectPrompt(TaskReminderAckCard);
    await tester.pump(const Duration(seconds: 1));
    _expectPrompt(TaskReminderCard);
    expect(find.text('Second'), findsOneWidget);
    expect(TaskConfirmRotation.lastAskedAt('conversation', task.description), isNull);

    await tester.tap(find.text('OK'));
    await tester.pump();
    _expectPrompt(TaskBubbleCard);
    expect(find.text(task.description), findsOneWidget);
  });

  testWidgets('a new reminder interrupts a task and the same task resumes after snoozing', (tester) async {
    final task = ActionItem('Keep this task', confirmed: false);
    final provider = _provider([task]);
    await _open(tester, provider);
    _expectPrompt(TaskBubbleCard);

    provider.conversations.single.structured.actionItems.add(_reminder('Just arrived'));
    provider.resetGroupedConvos();
    await tester.pump();
    _expectPrompt(TaskReminderCard);
    expect(find.text(task.description), findsNothing);

    await tester.tap(find.text('稍后提醒我'));
    await tester.pump();
    _expectPrompt(TaskReminderAckCard);
    await tester.pump(const Duration(seconds: 3));
    _expectPrompt(TaskBubbleCard);
    expect(tester.widget<TaskBubbleCard>(find.byType(TaskBubbleCard)).body, task.description);
    expect(task.confirmed, isFalse);
    expect(task.deleted, isFalse);
  });

  testWidgets('no prompt is displayed without an eligible reminder or task', (tester) async {
    final provider = _provider([
      _reminder('Completed')..completed = true,
      _reminder('Deleted')..deleted = true,
      _reminder('Future', overdueHours: -1),
    ]);
    await _open(tester, provider);
    expect(find.byType(TaskReminderCard), findsNothing);
    expect(find.byType(TaskReminderAckCard), findsNothing);
    expect(find.byType(TaskBubbleCard), findsNothing);
  });

  testWidgets('dismissing a receipt cancels its timer before a new snooze', (tester) async {
    final provider = _provider([_reminder('First'), _reminder('Second')]);
    await _open(tester, provider);
    provider.snoozeReminder('conversation', 'First');
    await tester.pump(const Duration(seconds: 1));
    provider.dismissReminderAck();
    provider.snoozeReminder('conversation', 'Second');
    await tester.pump(const Duration(seconds: 2));
    _expectPrompt(TaskReminderAckCard);
    expect(provider.reminderAckShowing?.description, 'Second');
    await tester.pump(const Duration(seconds: 1));
    expect(provider.reminderAckShowing, isNull);
    expect(find.byType(TaskReminderAckCard), findsNothing);
  });

  testWidgets('disposing during a snooze receipt cancels its callback', (tester) async {
    final provider = _provider([]);
    await tester.pump(); // Finish WAL preload before disposal.
    provider.snoozeReminder('conversation', 'A reminder');
    provider.dispose();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}
