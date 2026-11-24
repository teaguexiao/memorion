import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:memorion/backend/http/api/conversation_shares.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/pages/today_chapters/conversation_share_sheet.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';

class FakeShares extends ConversationSharingApi {
  ConversationShare? value;
  String? chosenMode;
  int creates = 0, revokes = 0;
  Completer<void>? pending;
  @override
  Future<ConversationShare?> load(String id) async => value;
  @override
  Future<ConversationShare> create(String id, String mode, String requestId) async {
    creates++;
    chosenMode = mode;
    await pending?.future;
    return value = ConversationShare(id: 'share', expiryMode: mode, active: true, url: 'https://memorion.me/s#test');
  }

  @override
  Future<ConversationShare> rotate(String id, String requestId) async => create('conv', 'never', requestId);
  @override
  Future<void> revoke(String id) async {
    revokes++;
    value = null;
  }
}

void main() {
  final conversation =
      ServerConversation(id: 'conv', createdAt: DateTime(2026), structured: Structured('Title', 'Full summary'));

  Future<void> mount(WidgetTester tester, FakeShares api) async {
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: ConversationShareSheet(conversation: conversation, api: api))));
    await tester.pumpAndSettle();
  }

  testWidgets('exactly two expiry choices, default seven days; create once, revoke', (tester) async {
    final api = FakeShares()..pending = Completer<void>();
    await mount(tester, api);
    final picker = tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>));
    expect(picker.segments.map((s) => s.value), ['seven_days', 'never']);
    expect(picker.selected, {'seven_days'});
    await tester.tap(find.text('Permanent'));
    await tester.pump();
    await tester.ensureVisible(find.text('Create share link'));
    await tester.tap(find.text('Create share link'));
    await tester.pump();
    expect(api.chosenMode, 'never');
    expect(api.creates, 1);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Creating…')).onPressed, isNull);
    api.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Copy link'), findsOneWidget);
    await tester.ensureVisible(find.text('Stop sharing'));
    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();
    expect(api.revokes, 1);
    expect(find.text('Create share link'), findsOneWidget);
  });

  testWidgets('copy and system share include the chapter title and full fragment URL', (tester) async {
    const url = 'https://memorion.me/s#test-token.secret';
    final api = FakeShares()
      ..value = const ConversationShare(id: 'existing', expiryMode: 'never', active: true, url: url);
    String? copied;
    MethodCall? shared;
    final messenger = tester.binding.defaultBinaryMessenger;
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared = call;
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(shareChannel, null);
    });
    final titled =
        ServerConversation(id: 'conv', createdAt: DateTime(2026), structured: Structured('  家长会：学习安排  ', 'Summary'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConversationShareSheet(conversation: titled, api: api))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Copy link'));
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, '家长会：学习安排\n$url');
    expect(find.text('Title and link copied'), findsOneWidget);
    await tester.ensureVisible(find.text('Share'));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(shared?.method, 'share');
    expect(shared?.arguments['text'], copied);
    expect(shared?.arguments['subject'], '家长会：学习安排');
  });

  testWidgets('empty chapter title uses a fallback when copying', (tester) async {
    const url = 'https://memorion.me/s#test-token.secret';
    final api = FakeShares()
      ..value = const ConversationShare(id: 'existing', expiryMode: 'never', active: true, url: url);
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final untitled =
        ServerConversation(id: 'conv', createdAt: DateTime(2026), structured: Structured('   ', 'Summary'));
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: ConversationShareSheet(conversation: untitled, api: api))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Copy link'));
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, 'Shared conversation · Memorion\n$url');
  });

  testWidgets('missing finite expiry fails closed without a null assertion crash', (tester) async {
    final api = FakeShares()..value = const ConversationShare(id: 'malformed', expiryMode: 'seven_days', active: true);
    await mount(tester, api);
    expect(tester.takeException(), isNull);
    expect(find.text('Copy link'), findsNothing);
    expect(find.text('Create share link'), findsOneWidget);
  });

  testWidgets('small screens scroll without overflow; existing links require explicit regeneration', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeShares()..value = const ConversationShare(id: 'existing', expiryMode: 'never', active: true);
    await mount(tester, api);
    expect(tester.takeException(), isNull);
    expect(find.text('Copy link'), findsNothing);
    await tester.ensureVisible(find.text('Replace link'));
    await tester.tap(find.text('Replace link'));
    await tester.pumpAndSettle();
    expect(find.text('Replace this link?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.creates, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact chapter menu keeps sharing reachable and requires source selection', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final other = ServerConversation(
        id: 'other', createdAt: DateTime(2026), structured: Structured('Other recording', 'Other summary'));
    final chapter = TimelineChapter(
        start: DateTime(2026),
        end: DateTime(2026, 1, 1, 1),
        durationSeconds: 3600,
        speechSeconds: 60,
        sourceConversationIds: ['conv', 'other'],
        title: 'Merged chapter',
        overview: 'Merged summary',
        emoji: '',
        firstPersonObservation: '',
        rolledUp: true);
    await tester.pumpWidget(MaterialApp(
        home: ChapterDetailPage(conversation: conversation, sources: [conversation, other], chapter: chapter)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Share a recording link'));
    await tester.tap(find.text('Share a recording link'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a recording to share'), findsOneWidget);
    expect(find.text('Shares that recording’s summary and transcript, not the merged chapter.'), findsOneWidget);
    expect(find.text('Other recording'), findsOneWidget);
    expect(find.byType(ConversationShareSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('transport uses Firebase Bearer only and never sends external_user_id or summary', () async {
    late http.Request sent;
    final api = HttpConversationSharingApi(
        baseUrl: 'https://api.example.test/',
        tokenProvider: () async => 'firebase-token',
        client: MockClient((r) async {
          sent = r;
          return http.Response(
              jsonEncode({'id': 'share', 'expiry_mode': 'never', 'active': true, 'url': 'https://memorion.me/s#token'}),
              201);
        }));
    final result = await api.create('conv', 'never', 'request');
    expect(sent.headers['Authorization'], 'Bearer firebase-token');
    expect(sent.url.query, isEmpty);
    expect(jsonDecode(sent.body), {'conversation_id': 'conv', 'expiry_mode': 'never', 'request_id': 'request'});
    expect(result.url, 'https://memorion.me/s#token');
    api.close();
  });

  test('missing Firebase identity fails before any network call; API errors stay typed', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('secret must not be logged', 401);
    });
    final missing = HttpConversationSharingApi(
        client: client, baseUrl: 'https://api.example.test', tokenProvider: () async => null);
    await expectLater(missing.load('conv'), throwsA(isA<ShareFailure>().having((e) => e.status, 'status', 401)));
    expect(calls, 0);
    final invalid = HttpConversationSharingApi(
        client: client, baseUrl: 'https://api.example.test', tokenProvider: () async => 'invalid');
    await expectLater(invalid.load('conv'), throwsA(isA<ShareFailure>().having((e) => e.status, 'status', 401)));
    expect(calls, 1);
    invalid.close();
  });
}
