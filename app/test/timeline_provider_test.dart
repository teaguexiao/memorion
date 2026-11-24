import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/providers/timeline_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `TimelineProvider` 的请求策略（真章节化 Phase 3）。
///
/// 这个 Provider 里没有一行渲染代码，它全部的复杂度是「什么时候该再请求一次」。
/// 四条规则各自的失败形态都是**静默**的——要么每次 build 都打一发请求（用户看不到，
/// 但 LLM 重算成本按天放大），要么该更新时不更新（首页永远少一张卡）：
///
/// 1. **拉失败（null）必须保留缓存**。空响应通常是网络/鉴权抖动，不是「这天真没有
///    章节」。覆盖成空 = 首页整天的卡凭空消失。
/// 2. **stale 每天只重试一次**。「服务端那份缺了本地已知的会话」并不总是意味着未
///    重算——也可能是后端**故意**不收（零 segment / discarded / 整段静音）。无条件
///    重试就是每次 syncDays 都请求一次的死循环。
/// 3. **手动 refresh 要重置那个退避**。用户明确下拉要求重算，不该被上一轮的记账挡住。
/// 4. **命中缓存也算初始化完成**。否则全部命中时 `isInitialized` 永远是 false，
///    页面停在骨架屏。
/// 5. **下拉刷新的扇出要收窄**。曾经对可见的每一天都发 `refresh=true` 并等齐，于是
///    转圈时长 = 最慢那天（单天 p90 3.7s、7.6% 超 5s，6 天里踩中约 38%）。现在只
///    强制最新一天，其余天该补的照补但不许拖着转圈。
///
/// Run: cd app && flutter test test/timeline_provider_test.dart
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  TimelineChapter chapter({required List<String> sourceIds, int hour = 9}) => TimelineChapter(
        start: DateTime(2026, 8, 6, hour, 0),
        end: DateTime(2026, 8, 6, hour + 1, 0),
        durationSeconds: 3600,
        speechSeconds: 3000,
        sourceConversationIds: sourceIds,
        title: '章节 $hour 点',
        overview: '正文',
        emoji: '🧠',
        firstPersonObservation: '',
        rolledUp: sourceIds.length > 1,
      );

  TimelineDay day({
    String date = '2026-08-06',
    required List<String> sourceIds,
    List<TimelineChapter>? chapters,
    String cache = 'computed',
  }) =>
      TimelineDay(
        date: date,
        timezone: 'Asia/Shanghai',
        chapters: chapters ?? [chapter(sourceIds: sourceIds)],
        sourceConversationIds: sourceIds,
        cache: cache,
        computedAt: DateTime(2026, 8, 6, 10, 41),
      );

  /// 记录每次调用的 (date, refresh)，按脚本返回结果。
  ///
  /// 脚本用 `List<TimelineDay?>` 而不是单个值：本文件测的性质全都关于**第二次调用
  /// 与第一次的差别**，只能靠逐次不同的返回值表达。
  ({TimelineDayFetcher fetch, List<({String date, bool refresh})> calls}) recorder(
    List<TimelineDay?> script,
  ) {
    final calls = <({String date, bool refresh})>[];
    var index = 0;
    Future<TimelineDay?> fetch({required String date, bool refresh = false}) async {
      calls.add((date: date, refresh: refresh));
      final result = index < script.length ? script[index] : script.isEmpty ? null : script.last;
      index++;
      return result;
    }

    return (fetch: fetch, calls: calls);
  }

  group('过期章节重新读取', () {
    test('沿用服务端日期，绕过相同 source IDs 的缓存且不强制重算', () async {
      final original = TimelineDay.fromJson(
        day(date: '2026-08-05', sourceIds: ['a', 'b']).toJson(),
        fallbackDate: 'wrong',
      );
      final updated = TimelineChapter.fromJson({
        ...original.chapters.single.toJson(),
        'title': '服务端最新内容',
        'source_conversation_ids': ['b', 'a'],
      })!;
      final rec = recorder([
        day(date: original.date, sourceIds: ['a', 'b'], chapters: [updated])
      ]);
      final provider = TimelineProvider(fetch: rec.fetch)..seedDay(original);
      addTearDown(provider.dispose);

      expect(await provider.reloadChapter(original.chapters.single), same(updated));
      expect(rec.calls, [(date: '2026-08-05', refresh: false)]);
      final restored = TimelineProvider();
      addTearDown(restored.dispose);
      expect(restored.chaptersFor(original.date).single.title, '服务端最新内容');
    });

    test('章节拆分合并后不按名字或位置猜测新目标', () async {
      final original = day(sourceIds: ['a', 'b']);
      final rec = recorder([
        day(sourceIds: [
          'a',
          'b'
        ], chapters: [
          chapter(sourceIds: ['a']),
          chapter(sourceIds: ['b'], hour: 10)
        ]),
        day(sourceIds: [
          'a',
          'b'
        ], chapters: [
          chapter(sourceIds: ['a', 'b'], hour: 10)
        ]),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch)..seedDay(original);
      addTearDown(provider.dispose);

      expect(await provider.reloadChapter(original.chapters.single), isNull);
      expect(provider.chaptersFor(original.date), hasLength(2));
      expect(await provider.reloadChapter(original.chapters.single), isNull);
      expect(provider.chaptersFor(original.date).single.start.hour, 10);
    });

    test('等已有读取完成后取最新值，较早响应不能覆盖已保存编辑', () async {
      final inFlight = Completer<TimelineDay?>();
      final reloading = Completer<TimelineDay?>();
      final original = day(sourceIds: ['a']);
      var calls = 0;
      final provider = TimelineProvider(
        fetch: ({required date, refresh = false}) => ++calls == 1 ? inFlight.future : reloading.future,
        updateChapter: ({required chapter, title, overview}) async =>
            TimelineChapter.fromJson({...chapter.toJson(), 'title': title}),
      )..seedDay(original);
      addTearDown(provider.dispose);
      final sync = provider.syncDays({
        original.date: {'a'}
      }, refresh: true);
      final reload = provider.reloadChapter(original.chapters.single);
      expect(calls, 1);
      inFlight.complete(original);
      await sync;
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      await provider.saveChapter(original.chapters.single, title: '已保存编辑');
      reloading.complete(original);

      expect((await reload)?.title, '已保存编辑');
      expect(provider.chaptersFor(original.date).single.title, '已保存编辑');
    });

    test('重新读取中切账号，旧章节不会返回或回填缓存', () async {
      final pending = Completer<TimelineDay?>();
      final original = day(sourceIds: ['a']);
      final provider = TimelineProvider(fetch: ({required date, refresh = false}) => pending.future)..seedDay(original);
      addTearDown(provider.dispose);
      final reload = provider.reloadChapter(original.chapters.single);
      provider.clear();
      pending.complete(original);

      expect(await reload, isNull);
      expect(provider.hasDay(original.date), isFalse);
      final restored = TimelineProvider();
      addTearDown(restored.dispose);
      expect(restored.hasDay(original.date), isFalse);
    });
  });

  group('首次拉取', () {
    test('保存后的章节不被更早发出的刷新响应覆盖', () async {
      final pending = Completer<TimelineDay?>();
      final original = day(sourceIds: ['a', 'b']);
      final provider = TimelineProvider(
        fetch: ({required date, refresh = false}) => pending.future,
        updateChapter: ({required chapter, title, overview}) async =>
            TimelineChapter.fromJson({...chapter.toJson(), 'title': title}, date: original.date),
      );
      addTearDown(provider.dispose);
      provider.seedDay(original);
      final refresh = provider.syncDays({
        original.date: {'a', 'b'}
      }, refresh: true);
      await provider.saveChapter(original.chapters.single, title: '已修正');
      pending.complete(original);
      await refresh;
      expect(provider.chaptersFor(original.date).single.title, '已修正');
      expect(TimelineProvider().chaptersFor(original.date).single.title, '已修正');
    });

    test('保存过程中切账号，旧响应不会回填缓存', () async {
      final pending = Completer<TimelineChapter?>();
      final original = day(sourceIds: ['a', 'b']);
      final provider = TimelineProvider(updateChapter: ({required chapter, title, overview}) => pending.future);
      addTearDown(provider.dispose);
      provider.seedDay(original);
      final saving = provider.saveChapter(original.chapters.single, title: '旧账号');
      provider.clear();
      pending.complete(original.chapters.single);
      expect(await saving, isNull);
      expect(provider.hasDay(original.date), isFalse);
      expect(TimelineProvider().hasDay(original.date), isFalse);
    });

    test('服务端归属日期不会因手机时区不同而丢失', () async {
      final original = day(sourceIds: ['a', 'b']);
      final parsed = TimelineDay.fromJson({...original.toJson(), 'date': '2026-08-05'}, fallbackDate: 'wrong');
      expect(parsed.chapters.single.date, '2026-08-05');
      expect(TimelineChapter.fromJson(parsed.chapters.single.toJson())!.date, '2026-08-05');
    });

    test('没缓存的天必请求一次，且不带 refresh', () async {
      final rec = recorder([day(sourceIds: ['a'])]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}});

      expect(rec.calls, [(date: '2026-08-06', refresh: false)]);
      expect(provider.chaptersFor('2026-08-06'), hasLength(1));
      expect(provider.hasDay('2026-08-06'), isTrue);
      expect(provider.isInitialized, isTrue);
    });

    test('拉到 0 章也算「拉到过」（区分空态与还没拉）', () async {
      final rec = recorder([day(sourceIds: const [], chapters: const [])]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}});

      expect(provider.hasDay('2026-08-06'), isTrue);
      expect(provider.chaptersFor('2026-08-06'), isEmpty);
    });

    test('多天并发各请求一次', () async {
      final rec = recorder([
        day(date: '2026-08-06', sourceIds: ['a']),
        day(date: '2026-08-05', sourceIds: ['b']),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({
        '2026-08-06': {'a'},
        '2026-08-05': {'b'},
      });

      expect(rec.calls.map((c) => c.date).toSet(), {'2026-08-06', '2026-08-05'});
      expect(rec.calls, hasLength(2));
    });
  });

  group('拉失败保留缓存', () {
    test('第二次返回 null 时，上一次的章节仍在', () async {
      final good = day(sourceIds: ['a']);
      final rec = recorder([good, null]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}});
      expect(provider.chaptersFor('2026-08-06'), hasLength(1));

      // 再来一发（带 refresh 绕过退避），这次网络失败。
      await provider.syncDays({'2026-08-06': {'a'}}, refresh: true);

      expect(rec.calls, hasLength(2));
      // 覆盖成空 = 首页整天的卡凭空消失。
      expect(provider.chaptersFor('2026-08-06'), hasLength(1),
          reason: 'null 是「没拉到」，不是「这天没有章节」');
      expect(provider.isInitialized, isTrue);
    });

    test('首次就失败：不留空文档，下次仍会重新请求', () async {
      final rec = recorder([null, day(sourceIds: ['a'])]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}});
      expect(provider.hasDay('2026-08-06'), isFalse, reason: '拉失败不该伪造一份空文档挡住重试');

      await provider.syncDays({'2026-08-06': {'a'}});
      expect(rec.calls, hasLength(2));
      expect(provider.chaptersFor('2026-08-06'), hasLength(1));
    });

    test('fetch 抛异常不冒泡，isInitialized 仍然置位（页面不卡在骨架屏）', () async {
      Future<TimelineDay?> boom({required String date, bool refresh = false}) async {
        throw StateError('network down');
      }

      final provider = TimelineProvider(fetch: boom);
      await provider.syncDays({'2026-08-06': {'a'}});

      expect(provider.isInitialized, isTrue);
      expect(provider.isLoading, isFalse, reason: 'finally 必须清掉 in-flight，否则 loading 永久悬挂');
    });
  });

  group('stale 退避', () {
    test('缓存齐全时不请求（不是每次 build 都打一发）', () async {
      final rec = recorder([day(sourceIds: ['a', 'b'])]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a', 'b'}});
      expect(rec.calls, hasLength(1));

      // 同样的 id 集合再来两次：服务端那份已经覆盖了它们，没有理由再请求。
      await provider.syncDays({'2026-08-06': {'a', 'b'}});
      await provider.syncDays({'2026-08-06': {'a'}});
      expect(rec.calls, hasLength(1));
    });

    test('服务端缺了本地已知的会话 → 带 refresh 重试，但只重试一次', () async {
      // 服务端两次都只知道 'a'，本地已经有 'b' 了（后端可能故意不收它）。
      final stale = day(sourceIds: ['a']);
      final rec = recorder([stale, stale, stale]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}}); // 首次，不带 refresh
      await provider.syncDays({'2026-08-06': {'a', 'b'}}); // 发现缺 b → refresh 重试
      await provider.syncDays({'2026-08-06': {'a', 'b'}}); // 仍然缺 b → 不该再打

      expect(rec.calls, [
        (date: '2026-08-06', refresh: false),
        (date: '2026-08-06', refresh: true),
      ], reason: '无条件重试就是每次 syncDays 都请求一次的死循环');
    });

    test('重试真的补上了缺的会话 → 之后回到静默', () async {
      final rec = recorder([day(sourceIds: ['a']), day(sourceIds: ['a', 'b'])]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}});
      await provider.syncDays({'2026-08-06': {'a', 'b'}});
      expect(rec.calls, hasLength(2));

      await provider.syncDays({'2026-08-06': {'a', 'b'}});
      expect(rec.calls, hasLength(2), reason: '缺口补上后没有任何再请求的理由');
    });

    test('退避是按天记账的：另一天缺会话仍会重试', () async {
      final rec = recorder([
        day(date: '2026-08-06', sourceIds: ['a']),
        day(date: '2026-08-05', sourceIds: ['x']),
        day(date: '2026-08-06', sourceIds: ['a']),
        day(date: '2026-08-05', sourceIds: ['x']),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({
        '2026-08-06': {'a'},
        '2026-08-05': {'x'},
      });
      // 两天各缺一条 → 两天各重试一次。
      await provider.syncDays({
        '2026-08-06': {'a', 'b'},
        '2026-08-05': {'x', 'y'},
      });

      final retries = rec.calls.where((c) => c.refresh).map((c) => c.date).toSet();
      expect(retries, {'2026-08-06', '2026-08-05'});
    });

    test('手动 refresh 重置退避：下拉刷新不被上一轮记账挡住', () async {
      final stale = day(sourceIds: ['a']);
      final rec = recorder([stale, stale, stale, stale]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({'2026-08-06': {'a'}});
      await provider.syncDays({'2026-08-06': {'a', 'b'}}); // 用掉那一次重试
      await provider.syncDays({'2026-08-06': {'a', 'b'}}); // 被退避挡住
      expect(rec.calls, hasLength(2));

      // 用户下拉刷新：必须真的发请求。
      await provider.syncDays({'2026-08-06': {'a', 'b'}}, refresh: true);
      expect(rec.calls, hasLength(3));
      expect(rec.calls.last.refresh, isTrue);

      // 并且重置了记账——下一次发现缺口还能再重试一次。
      await provider.syncDays({'2026-08-06': {'a', 'b'}});
      expect(rec.calls, hasLength(4));
    });

  });

  group('下拉刷新的扇出', () {
    test('只强制最新一天：其余天缓存齐全就一个请求都不发', () async {
      final rec = recorder([
        day(date: '2026-08-06', sourceIds: ['a']),
        day(date: '2026-08-05', sourceIds: ['x']),
        day(date: '2026-08-06', sourceIds: ['a']),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);

      // 先把两天都拉进缓存。
      await provider.syncDays({
        '2026-08-06': {'a'},
        '2026-08-05': {'x'},
      });
      expect(rec.calls, hasLength(2));

      await provider.syncDays({
        '2026-08-06': {'a'},
        '2026-08-05': {'x'},
      }, refresh: true);

      expect(rec.calls.skip(2), [(date: '2026-08-06', refresh: true)],
          reason: '每天都带 refresh 时转圈要等最慢那天：单天 p90 3.7s，6 天里踩中长尾约 38%');
    });

    test('老天缺会话仍会补拉，但卡住也不拖着转圈', () async {
      final calls = <({String date, bool refresh})>[];
      final stuck = Completer<TimelineDay?>();
      Future<TimelineDay?> fetch({required String date, bool refresh = false}) {
        calls.add((date: date, refresh: refresh));
        // 老那天永不返回，模拟一次 8s+ 的重算。
        return date == '2026-08-05' ? stuck.future : Future.value(day(date: date, sourceIds: ['a']));
      }

      final provider = TimelineProvider(fetch: fetch);
      provider.seedDay(day(date: '2026-08-06', sourceIds: ['a']));
      provider.seedDay(day(date: '2026-08-05', sourceIds: ['x']));

      // 老那天缺了本地已知的 'y' → 该补拉，但只能在后台补。
      await provider.syncDays({
        '2026-08-06': {'a'},
        '2026-08-05': {'x', 'y'},
      }, refresh: true).timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('前台等了后台那批：下拉刷新的时长又变回「最慢那天」'),
      );

      expect(calls.map((c) => c.date).toSet(), {'2026-08-06', '2026-08-05'},
          reason: '不阻塞 ≠ 不请求：缺的会话仍要补回来');
      expect(provider.chaptersFor('2026-08-06'), hasLength(1));
      // 后台那天还在飞——它落地后自己 notify。
      expect(provider.isLoading, isTrue);
      stuck.complete(null);
    });

    test('还没拉过的天仍在前台等（否则先闪一下空态）', () async {
      final rec = recorder([
        day(date: '2026-08-06', sourceIds: ['a']),
        day(date: '2026-08-04', sourceIds: ['z']),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);
      provider.seedDay(day(date: '2026-08-06', sourceIds: ['a']));

      // 08-04 一次都没拉过：它在界面上是个空洞，不能等收起转圈之后再填。
      await provider.syncDays({
        '2026-08-06': {'a'},
        '2026-08-04': {'z'},
      }, refresh: true);

      expect(rec.calls.map((c) => c.date).toSet(), {'2026-08-06', '2026-08-04'});
      expect(provider.hasDay('2026-08-04'), isTrue, reason: '前台等过它，返回时数据就该在手');
      expect(provider.isLoading, isFalse);
    });
  });

  group('初始化态', () {
    test('全部命中缓存也置 isInitialized（否则页面停在骨架屏）', () async {
      final rec = recorder([day(sourceIds: ['a'])]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({'2026-08-06': {'a'}});

      // 第二次全命中，pending 为空，直接返回——但 isInitialized 不能被它清掉。
      await provider.syncDays({'2026-08-06': {'a'}});
      expect(provider.isInitialized, isTrue);
    });

    test('空的日期集合不请求，但也算初始化完成（新用户零录音）', () async {
      final rec = recorder([day(sourceIds: ['a'])]);
      final provider = TimelineProvider(fetch: rec.fetch);

      await provider.syncDays({});

      expect(rec.calls, isEmpty);
      expect(provider.isInitialized, isTrue, reason: '零录音的新用户不该永远 loading');
    });
  });

  group('forgetConversations（删除的乐观更新）', () {
    test('删掉一章的全部源 → 整章立刻消失', () async {
      final rec = recorder([
        day(sourceIds: ['a', 'b', 'z'], chapters: [
          chapter(sourceIds: ['a', 'b'], hour: 9),
          chapter(sourceIds: ['z'], hour: 14),
        ]),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({'2026-08-06': {'a', 'b', 'z'}});
      expect(provider.chaptersFor('2026-08-06'), hasLength(2));

      // 「删一个合并章节」= 删它的 N 条源。
      provider.forgetConversations({'a', 'b'});

      final left = provider.chaptersFor('2026-08-06');
      expect(left, hasLength(1), reason: '留着一张指向已删数据的卡，点进去就是 404');
      expect(left.single.sourceConversationIds, ['z']);
    });

    test('只删一部分源 → 章节保留，少那一条', () async {
      final rec = recorder([day(sourceIds: ['a', 'b', 'c'], chapters: [chapter(sourceIds: ['a', 'b', 'c'])])]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({'2026-08-06': {'a', 'b', 'c'}});

      provider.forgetConversations({'b'});

      expect(provider.chaptersFor('2026-08-06').single.sourceConversationIds, ['a', 'c']);
    });

    test('删完之后那天要重新拉（本地这份已是近似值）', () async {
      final rec = recorder([
        day(sourceIds: ['a', 'b'], chapters: [chapter(sourceIds: ['a', 'b'])]),
        day(sourceIds: ['b'], chapters: [chapter(sourceIds: ['b'])]),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({'2026-08-06': {'a', 'b'}});

      provider.forgetConversations({'a'});
      // 删除清空了退避记账，所以「服务端还知道 a」这个缺口能再触发一次重算。
      await provider.syncDays({'2026-08-06': {'b'}});

      expect(rec.calls, hasLength(1), reason: '本地已经不缺任何会话，没有 stale 信号');
      // 但用户下拉时必须打得出去。
      await provider.syncDays({'2026-08-06': {'b'}}, refresh: true);
      expect(rec.calls, hasLength(2));
    });

    test('删的是不认识的 id → 不动、不通知', () async {
      final rec = recorder([day(sourceIds: ['a'], chapters: [chapter(sourceIds: ['a'])])]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({'2026-08-06': {'a'}});

      var notified = 0;
      provider.addListener(() => notified++);
      provider.forgetConversations({'someone-elses-id'});
      provider.forgetConversations({});

      expect(notified, 0);
      expect(provider.chaptersFor('2026-08-06'), hasLength(1));
    });
  });

  group('chapterContaining（深链还原）', () {
    test('按源 id 找到所在章节，跨天也能找到', () async {
      final rec = recorder([
        day(date: '2026-08-06', sourceIds: ['a', 'b'], chapters: [chapter(sourceIds: ['a', 'b'])]),
        day(date: '2026-08-05', sourceIds: ['old'], chapters: [chapter(sourceIds: ['old'], hour: 20)]),
      ]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({
        '2026-08-06': {'a', 'b'},
        '2026-08-05': {'old'},
      });

      // 通知点进来只有一个 conversation id，要还原成整章。
      expect(provider.chapterContaining('b')!.sourceConversationIds, ['a', 'b']);
      expect(provider.chapterContaining('old')!.sourceConversationIds, ['old']);
      expect(provider.chapterContaining('never-seen'), isNull);
    });
  });

  group('缓存往返与清空', () {
    test('新实例从 shared_preferences 恢复章节（冷启动不空屏）', () async {
      final rec = recorder([day(sourceIds: ['a', 'b'], chapters: [chapter(sourceIds: ['a', 'b'])])]);
      final first = TimelineProvider(fetch: rec.fetch);
      await first.syncDays({'2026-08-06': {'a', 'b'}});

      // 同一份 SharedPreferences mock，模拟杀进程重开。
      final reborn = TimelineProvider(fetch: rec.fetch);

      expect(reborn.chaptersFor('2026-08-06'), hasLength(1));
      expect(reborn.chaptersFor('2026-08-06').single.sourceConversationIds, ['a', 'b']);
      // 缓存有内容但还没拉过服务端——页面首帧仍要触发 syncDays。
      expect(reborn.isInitialized, isFalse);
    });

    test('clear() 之后新实例读不到任何章节（切账号不串数据）', () async {
      final rec = recorder([day(sourceIds: ['a'], chapters: [chapter(sourceIds: ['a'])])]);
      final provider = TimelineProvider(fetch: rec.fetch);
      await provider.syncDays({'2026-08-06': {'a'}});

      provider.clear();

      expect(provider.chaptersFor('2026-08-06'), isEmpty);
      expect(provider.isInitialized, isFalse);
      // 章节正文是上一个用户的摘要，绝不能留给下一个。
      expect(TimelineProvider(fetch: rec.fetch).chaptersFor('2026-08-06'), isEmpty);
    });

    test('缓存最多留 14 天，且留的是最近的', () async {
      // 造 20 天：2026-07-20 ~ 2026-08-08。
      final days = [
        for (var d = 20; d <= 31; d++) '2026-07-${d.toString().padLeft(2, '0')}',
        for (var d = 1; d <= 8; d++) '2026-08-0$d',
      ];
      var index = 0;
      Future<TimelineDay?> fetch({required String date, bool refresh = false}) async {
        index++;
        return day(date: date, sourceIds: ['c$index'], chapters: [chapter(sourceIds: ['c$index'])]);
      }

      final provider = TimelineProvider(fetch: fetch);
      for (final d in days) {
        await provider.syncDays({d: {'c-$d'}});
      }

      final reborn = TimelineProvider(fetch: fetch);
      final restored = days.where((d) => reborn.hasDay(d)).toList();

      expect(restored, hasLength(14), reason: '整份缓存是一个 prefs key，不设上限会随使用时间单调增长');
      // 留下的是最近 14 天（7-26 ~ 8-08），最老的被丢掉。
      expect(reborn.hasDay('2026-08-08'), isTrue);
      expect(reborn.hasDay('2026-07-20'), isFalse);
    });
  });
}
