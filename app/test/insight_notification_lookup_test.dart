import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/providers/insights_provider.dart';

InsightCard card(String id, {String status = 'released'}) => InsightCard(
      id: id,
      topicKey: 'work',
      headline: 'An observation',
      body: 'Detail',
      status: status,
    );

void main() {
  test('old notification resolves its ID independently of the latest 50 cards', () async {
    final requested = <String>[];
    final provider = InsightsProvider(fetchInsight: (id) async {
      requested.add(id);
      return card(id);
    });
    provider.insights = List.generate(50, (i) => card('new-$i'));
    expect((await provider.getInsightById('older-card'))?.id, 'older-card');
    expect(requested, ['older-card']);
    provider.dispose();
  });

  test('deleted cached card is not opened from stale cache', () async {
    final provider = InsightsProvider(fetchInsight: (_) async => null);
    provider.insights = [card('deleted')];
    expect(await provider.getInsightById('deleted'), isNull);
    provider.dispose();
  });

  test('unreleased or mismatched cards cannot become notification details', () async {
    for (final response in [card('target', status: 'candidate'), card('different')]) {
      final provider = InsightsProvider(fetchInsight: (_) async => response);
      expect(await provider.getInsightById('target'), isNull);
      provider.dispose();
    }
  });

  test('fetch errors resolve to the list fallback', () async {
    final provider = InsightsProvider(fetchInsight: (_) async => throw StateError('offline'));
    expect(await provider.getInsightById('target'), isNull);
    provider.dispose();
  });
}
