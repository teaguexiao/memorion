import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/main.dart';
import 'package:memorion/pages/today_chapters/diary_detail_page.dart';
import 'package:memorion/pages/today_chapters/first_impression_page.dart';
import 'package:memorion/pages/today_chapters/portrait_detail_page.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/providers/moments_provider.dart';
import 'package:memorion/services/notifications.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const targetCard = InsightCard(
  id: 'pushed-card',
  topicKey: 'work',
  headline: 'A specific observation',
  body: 'The pushed insight detail',
  status: 'released',
);

ServerMessage diary(String id) => ServerMessage(
      id,
      DateTime(2026, 10, 18),
      'The pushed diary detail',
      MessageSender.ai,
      MessageType.daySummary,
      null,
      false,
      [],
    );

Widget testApp(InsightsProvider insights, MomentsProvider moments) => MultiProvider(
      providers: [
        ChangeNotifierProvider<InsightsProvider>.value(value: insights),
        ChangeNotifierProvider<MomentsProvider>.value(value: moments),
      ],
      child: MaterialApp(
        navigatorKey: MyApp.navigatorKey,
        home: const Scaffold(body: Text('Home')),
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  for (final coldStart in [false, true]) {
    testWidgets('insight tap opens specified detail (${coldStart ? 'cold start' : 'running app'})', (tester) async {
      final requested = <String>[];
      final insights = InsightsProvider(fetchInsight: (id) async {
        requested.add(id);
        return targetCard;
      })
        ..isInitialized = true;
      insights.insights = [
        const InsightCard(
          id: 'latest-card',
          topicKey: 'other',
          headline: 'Latest',
          body: 'Different card',
          status: 'released',
        )
      ];
      final moments = MomentsProvider(fetch: ({int limit = 20, int offset = 0}) async => []);
      Future<void>? tap;
      if (coldStart) {
        tap = NotificationUtil.handleRemoteNotificationTap({'navigate_to': '/insights', 'insight_id': targetCard.id});
      }
      await tester.pumpWidget(testApp(insights, moments));
      tap ??= NotificationUtil.handleRemoteNotificationTap({'navigate_to': '/insights', 'insight_id': targetCard.id});
      await tester.pump(const Duration(milliseconds: 100));
      await tap;
      await tester.pumpAndSettle();
      expect(requested, [targetCard.id]);
      expect(tester.widget<FirstImpressionPage>(find.byType(FirstImpressionPage)).card.id, targetCard.id);
      expect(find.byType(PortraitDetailPage), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      insights.dispose();
      moments.dispose();
    });

    testWidgets('diary tap opens specified detail (${coldStart ? 'cold start' : 'running app'})', (tester) async {
      final insights = InsightsProvider()..isInitialized = true;
      final moments = MomentsProvider(fetch: ({int limit = 20, int offset = 0}) async => [diary('pushed-diary')]);
      Future<void>? tap;
      if (coldStart) {
        tap = NotificationUtil.handleRemoteNotificationTap({'navigate_to': '/moments', 'moment_id': 'pushed-diary'});
      }
      await tester.pumpWidget(testApp(insights, moments));
      tap ??= NotificationUtil.handleRemoteNotificationTap({'navigate_to': '/moments', 'moment_id': 'pushed-diary'});
      await tester.pump(const Duration(milliseconds: 100));
      await tap;
      await tester.pumpAndSettle();
      expect(tester.widget<DiaryDetailPage>(find.byType(DiaryDetailPage)).moment.id, 'pushed-diary');
      await tester.pumpWidget(const SizedBox.shrink());
      insights.dispose();
      moments.dispose();
    });
  }

  testWidgets('deleted insight and old payload fall back to insight list', (tester) async {
    final insights = InsightsProvider(fetchInsight: (_) async => null)..isInitialized = true;
    final moments = MomentsProvider(fetch: ({int limit = 20, int offset = 0}) async => []);
    await tester.pumpWidget(testApp(insights, moments));
    for (final payload in [
      {'navigate_to': '/insights', 'insight_id': 'deleted'},
      {'navigate_to': '/insights'},
    ]) {
      await NotificationUtil.handleRemoteNotificationTap(payload);
      await tester.pumpAndSettle();
      expect(find.byType(PortraitDetailPage), findsOneWidget);
      expect(find.byType(FirstImpressionPage), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    insights.dispose();
    moments.dispose();
  });

  testWidgets('navigator removed while fetching does not push into a disposed app', (tester) async {
    final response = Completer<InsightCard?>();
    final insights = InsightsProvider(fetchInsight: (_) => response.future)..isInitialized = true;
    final moments = MomentsProvider(fetch: ({int limit = 20, int offset = 0}) async => []);
    await tester.pumpWidget(testApp(insights, moments));
    final tap = NotificationUtil.handleRemoteNotificationTap({'navigate_to': '/insights', 'insight_id': targetCard.id});
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    response.complete(targetCard);
    await tap;
    expect(tester.takeException(), isNull);
    insights.dispose();
    moments.dispose();
  });
}
