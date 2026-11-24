import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/providers/discover_provider.dart';
import 'package:memorion/providers/insights_provider.dart';
import 'package:memorion/providers/memories_provider.dart';
import 'package:memorion/utils/about_me_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'externalUserId': 'account-a'});
    await SharedPreferencesUtil.init();
  });

  final keys = ['memories_list', 'insights_list', 'discover_actions'];
  Future<void> seed(String key, {Duration age = Duration.zero, bool populated = true}) async {
    final prefs = SharedPreferencesUtil();
    final memory = {
      'id': 'fact',
      'content': 'A fact',
      'created_at': '2026-10-20T00:00:00Z',
      'updated_at': '2026-10-20T00:00:00Z',
      'reviewed': true,
    };
    final data = switch (key) {
      'memories_list' => populated ? [memory] : [],
      'insights_list' => populated
          ? [
              const InsightCard(
                      id: 'card', topicKey: 'work', headline: 'Observation', body: 'Detail', status: 'released')
                  .toJson()
            ]
          : [],
      _ => {
          'items': populated
              ? [
                  {'description': 'A task', 'conversation_id': 'c', 'item_idx': 0}
                ]
              : [],
          'total_count': populated ? 1 : 0,
          'completed_count': 0,
          'has_more': false
        },
    };
    await prefs.cacheJson(key, data);
    if (key == 'memories_list') await prefs.cacheJson('memories_pending', []);
    await prefs.cacheJson('${key}_fetched_at', {
      'owner': 'account-a',
      'at': DateTime.now().subtract(age).millisecondsSinceEpoch,
    });
  }

  for (final key in keys) {
    group(key, () {
      late ChangeNotifier provider;
      late Future<void> Function() ensure;
      late Future<void> Function() refresh;
      late bool Function() hasData;
      late bool Function() loading;
      var calls = 0;
      var fail = false;
      Completer<void>? blocked;

      void create() {
        calls = 0;
        fail = false;
        blocked = null;
        if (key == 'memories_list') {
          final p = MemoriesProvider(fetch: ({int limit = 100, int offset = 0, String status = 'confirmed'}) async {
            calls++;
            await blocked?.future;
            return fail ? null : [];
          });
          provider = p;
          ensure = p.ensureLoaded;
          refresh = p.refresh;
          hasData = () => p.memories.isNotEmpty;
          loading = () => p.loading;
        } else if (key == 'insights_list') {
          final p = InsightsProvider(fetch: ({bool releasedOnly = true, int limit = 50, int offset = 0}) async {
            calls++;
            await blocked?.future;
            return fail ? null : [];
          });
          provider = p;
          ensure = p.ensureLoaded;
          refresh = p.refresh;
          hasData = () => p.insights.isNotEmpty;
          loading = () => p.isLoading;
        } else {
          final p = DiscoverProvider(fetchActions: ({String status = 'all', int limit = 50, int offset = 0}) async {
            calls++;
            await blocked?.future;
            return fail ? {'ok': false} : {'items': [], 'total_count': 0, 'completed_count': 0, 'has_more': false};
          })
            ..loadFromCache();
          provider = p;
          ensure = p.ensureActionItemsLoaded;
          refresh = p.loadActionItems;
          hasData = () => p.actionItems.isNotEmpty;
          loading = () => p.isLoadingActions;
        }
        addTearDown(provider.dispose);
      }

      test('cold startup renders fresh cache without requests; pull refresh still fetches', () async {
        await seed(key);
        create();
        expect(hasData(), isTrue);
        await ensure();
        await ensure();
        expect(calls, 0);
        await refresh();
        expect(calls, key == 'memories_list' ? 2 : 1);
        expect(hasData(), isFalse); // Authoritative empty removes deleted data.
      });

      test('stale cache stays visible and overlapping entries share one refresh', () async {
        await seed(key, age: const Duration(minutes: 6));
        create();
        blocked = Completer<void>();
        final first = ensure();
        final second = ensure();
        expect(hasData(), isTrue);
        expect(loading(), isFalse);
        expect(calls, key == 'memories_list' ? 2 : 1);
        blocked!.complete();
        await Future.wait([first, second]);
        await ensure();
        expect(calls, key == 'memories_list' ? 2 : 1);
      });

      test('failed refresh preserves data and remains retryable', () async {
        await seed(key, age: const Duration(minutes: 6));
        create();
        fail = true;
        await ensure();
        expect(hasData(), isTrue);
        expect(AboutMeCache(key).isFresh, isFalse);
        fail = false;
        await ensure();
        expect(calls, key == 'memories_list' ? 4 : 2);
        expect(AboutMeCache(key).isFresh, isTrue);
      });

      test('valid empty cache does not request on every entry', () async {
        await seed(key, populated: false);
        create();
        await ensure();
        expect(calls, 0);
      });
    });
  }

  test('post-mutation action reload waits for the older read and preserves status', () async {
    final old = Completer<Map<String, dynamic>>();
    final requested = <String>[];
    final p = DiscoverProvider(fetchActions: ({String status = 'all', int limit = 50, int offset = 0}) {
      requested.add(status);
      return requested.length == 1 ? old.future : Future.value({'items': [], 'has_more': false});
    });
    final first = p.ensureActionItemsLoaded();
    final afterMutation = p.loadActionItems(status: 'pending');
    expect(requested, ['all']);
    old.complete({
      'items': [
        {'description': 'Old task', 'item_idx': 1}
      ],
      'has_more': false
    });
    await Future.wait([first, afterMutation]);
    expect(requested, ['all', 'pending']);
    expect(p.actionItems, isEmpty);
    expect(AboutMeCache('discover_actions').isFresh, isFalse);
    p.dispose();
  });

  for (final confirm in [true, false]) {
    test('fact ${confirm ? 'confirmation' : 'rejection'} cannot be undone by an older refresh', () async {
      final fact = Memory(
          id: 'pending-fact',
          uid: '',
          content: 'A fact',
          category: MemoryCategory.interesting,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          visibility: MemoryVisibility.private);
      await SharedPreferencesUtil().cacheJson('memories_list', []);
      await SharedPreferencesUtil().cacheJson('memories_pending', [fact.toJson()]);
      final oldConfirmed = Completer<List<Memory>?>();
      final oldPending = Completer<List<Memory>?>();
      final p = MemoriesProvider(
        fetch: ({int limit = 100, int offset = 0, String status = 'confirmed'}) =>
            status == 'confirmed' ? oldConfirmed.future : oldPending.future,
        review: (id, confirmed) async => true,
      );
      final reload = p.ensureLoaded();
      final picked = p.pendingFacts.single;
      if (confirm) {
        await p.confirmFact(picked);
      } else {
        await p.rejectFact(picked);
      }
      oldConfirmed.complete([]);
      oldPending.complete([fact]);
      await reload;
      expect(p.pendingFacts, isEmpty);
      expect(p.memories.map((m) => m.id), confirm ? ['pending-fact'] : isEmpty);
      expect(AboutMeCache('memories_list').isFresh, isFalse);
      expect(SharedPreferencesUtil().getCachedJson('memories_pending'), isEmpty);
      p.dispose();
    });
  }

  test('future timestamps and another account cannot suppress refresh', () async {
    await seed('insights_list', age: const Duration(minutes: -10));
    expect(AboutMeCache('insights_list').isFresh, isFalse);
    await seed('insights_list');
    await SharedPreferencesUtil().saveString('externalUserId', 'account-b');
    expect(AboutMeCache('insights_list').isFresh, isFalse);
  });

  test('sign-out discards in-flight insight response and clears disk snapshot', () async {
    final response = Completer<List<InsightCard>?>();
    final p = InsightsProvider(fetch: ({bool releasedOnly = true, int limit = 50, int offset = 0}) => response.future);
    final pending = p.loadInsights();
    p.clear();
    response
        .complete([const InsightCard(id: 'old', topicKey: 'work', headline: 'Old', body: 'Old', status: 'released')]);
    await pending;
    expect(p.insights, isEmpty);
    expect(SharedPreferencesUtil().getCachedJson('insights_list'), isNull);
    expect(AboutMeCache('insights_list').isFresh, isFalse);
    p.dispose();
  });
}
