import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/providers/moments_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「日记」tab 的缓存策略（stale-while-revalidate）。
///
/// 这个 Provider 里没有一行渲染代码，它全部的复杂度是「什么时候**不**该请求」。
/// 改之前的形态是页面每次切到日记 tab 都判 `isInitialized`，而那个标记只在服务端
/// 拉取成功后才置 true——构造期的 `_loadFromCache()` **刻意**不置它。于是每次冷启动
/// 进日记都必然打一发全量请求，而后端 `/v1/moments`（`routers/moments.py`）是把整个
/// messages 集合 stream 下来、在 Python 里排序再切片的，条数一多就是秒级。
///
/// 更隐蔽的是它**看不出来**：`isLoading` 只在 `moments.isEmpty` 时才置 true，所以
/// 缓存命中时不显示 loading——用户看到的是旧卡片先出现、请求在后台飞、回来再跳一下。
///
/// 每条断言对应一个各自静默的失败形态：
/// 1. **新鲜期内一次请求都不发**。这是「打开就有」的全部来源。
/// 2. **过期了要 revalidate，且期间旧内容不消失**。少了前者日记永远停在旧内容，
///    少了后者列表会先闪一下空白。
/// 3. **坏时间戳不能把缓存钉死**。缺失（老版本升级上来）或落在未来（用户改过系统
///    时间）都必须判成不新鲜——宁可多拉一次。
/// 4. **下拉刷新无条件打服务端**。用户明确要求更新时被新鲜度挡住 = 下拉只有转圈。
/// 5. **深链未命中要绕过新鲜度**。推送里那篇刚落库，尊重新鲜度就永远打不开。
/// 6. **登出要清缓存 + 时间戳**。只清内容不清时间戳，下个账号会被判成「缓存新鲜」
///    而一次都不请求，界面空到时间戳过期为止。
/// 7. **空响应不能续期时间戳**。一次网络抖动否则能让列表停更一整个新鲜期。
/// 8. **缓存命中要按页大小还原 hasMore**，否则滚到底白发一次分页请求。
///
/// Run: cd app && flutter test test/moments_cache_test.dart
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  ServerMessage moment(String id) => ServerMessage(
        id,
        DateTime(2026, 8, 9, 22, 0),
        '今天过得不错。',
        MessageSender.ai,
        MessageType.daySummary,
        null,
        false,
        [],
        summaryImageUrl: 'https://storage.googleapis.com/b/u/2026-08-09_summary.png',
        emotionTitle: '松了一口气的一天',
      );

  /// 记录调用次数的假 fetcher。
  ({List<int> offsets, MomentsFetcher fetch}) fetcher(List<ServerMessage> Function(int offset) reply) {
    final offsets = <int>[];
    Future<List<ServerMessage>> fetch({int limit = 20, int offset = 0}) async {
      offsets.add(offset);
      return reply(offset);
    }

    return (offsets: offsets, fetch: fetch);
  }

  /// 往本地写一份「n 条、写入于 ageAgo 之前」的快照，模拟上次进过日记页。
  Future<void> seedCache(int count, {required Duration ageAgo}) async {
    final list = [for (var i = 0; i < count; i++) moment('m$i')];
    await SharedPreferencesUtil().cacheJson('moments_list', list.map((m) => m.toJson()).toList());
    await SharedPreferencesUtil().saveInt(
      'moments_list_fetched_at',
      DateTime.now().subtract(ageAgo).millisecondsSinceEpoch,
    );
  }

  test('缓存新鲜（1 小时前拉过）→ 进日记 tab 一次请求都不发', () async {
    await seedCache(3, ageAgo: const Duration(hours: 1));
    final f = fetcher((_) => [moment('server')]);
    final p = MomentsProvider(fetch: f.fetch);

    expect(p.moments.length, 3, reason: '构造期就该同步预填缓存，否则首帧是空的');

    await p.ensureLoaded();

    expect(f.offsets, isEmpty, reason: '新鲜期内还请求 = 每次进日记都白等一次全表扫描');
    expect(p.moments.length, 3);
    expect(p.isInitialized, isTrue,
        reason: 'isEmpty 依赖 isInitialized；不置 true 的话空账号永远停在骨架屏');
  });

  test('缓存过期（7 小时前）→ 会 revalidate，且期间保留旧内容', () async {
    await seedCache(3, ageAgo: const Duration(hours: 7));
    final f = fetcher((_) => [moment('a'), moment('b')]);
    final p = MomentsProvider(fetch: f.fetch);

    // 过期但仍要先渲染旧内容：stale-while-revalidate 的「while」那一半。
    expect(p.moments.length, 3);

    await p.ensureLoaded();

    expect(f.offsets, [0], reason: '过期了不刷新，日记就永远停在旧内容');
    expect(p.moments.length, 2);
  });

  test('过期期间旧内容不消失：请求还在飞时列表仍是旧的那几条', () async {
    await seedCache(3, ageAgo: const Duration(hours: 7));
    late MomentsProvider p;
    p = MomentsProvider(fetch: ({int limit = 20, int offset = 0}) async {
      // 请求在飞的这一刻断言：把 moments 先清空再拉，用户会看到列表闪一下空白。
      expect(p.moments.map((m) => m.id), ['m0', 'm1', 'm2']);
      return [moment('fresh')];
    });

    await p.ensureLoaded();
    expect(p.moments.single.id, 'fresh');
  });

  test('完全没缓存 → isCacheFresh 为 false（不能把「无缓存」误判成新鲜）', () async {
    final f = fetcher((_) => [moment('a')]);
    final p = MomentsProvider(fetch: f.fetch);

    expect(p.isCacheFresh, isFalse, reason: '空列表判成新鲜 = 首装用户永远拉不到日记');
    await p.ensureLoaded();
    expect(f.offsets, [0]);
  });

  test('时间戳缺失（老版本装上来的存量缓存）→ 判为不新鲜，仍会拉一次', () async {
    final list = [moment('legacy')];
    await SharedPreferencesUtil().cacheJson('moments_list', list.map((m) => m.toJson()).toList());
    // 刻意不写 moments_list_fetched_at：升级前的用户就是这个状态。
    final f = fetcher((_) => [moment('fresh')]);
    final p = MomentsProvider(fetch: f.fetch);

    expect(p.moments.length, 1, reason: '旧缓存仍要读得出来，升级不该丢内容');
    await p.ensureLoaded();

    expect(f.offsets, [0], reason: '没有时间戳就无从判断新鲜度，必须按不新鲜处理');
    expect(p.isCacheFresh, isTrue, reason: '拉完要把戳补上，下次进来才命中');
  });

  test('系统时间被改到未来 → 判为不新鲜，不会把缓存钉死', () async {
    await seedCache(2, ageAgo: const Duration(hours: -5)); // 时间戳在未来
    final f = fetcher((_) => [moment('x')]);
    final p = MomentsProvider(fetch: f.fetch);

    expect(p.isCacheFresh, isFalse);
    await p.ensureLoaded();
    expect(f.offsets, [0]);
  });

  test('下拉刷新无条件打服务端，即使缓存刚写过', () async {
    await seedCache(3, ageAgo: const Duration(minutes: 1));
    final f = fetcher((_) => [moment('refreshed')]);
    final p = MomentsProvider(fetch: f.fetch);

    await p.ensureLoaded();
    expect(f.offsets, isEmpty);

    await p.refresh();

    expect(f.offsets, [0], reason: '下拉被新鲜度挡住 = 用户下拉只看到转圈，内容一个字不变');
    expect(p.moments.single.id, 'refreshed');
  });

  test('拉取成功会刷新时间戳，于是紧接着的 ensureLoaded 不再请求', () async {
    final f = fetcher((_) => [moment('a')]);
    final p = MomentsProvider(fetch: f.fetch);

    await p.ensureLoaded(); // 无缓存 → 拉一次
    expect(f.offsets, [0]);

    await p.ensureLoaded(); // 刚拉完 → 不该再拉
    expect(f.offsets, [0], reason: '拉完不写时间戳的话新鲜度判定永远失效，等于没有缓存');
  });

  test('服务端返回空但本地有缓存 → 保留缓存，且不续期时间戳', () async {
    await seedCache(3, ageAgo: const Duration(hours: 7));
    final f = fetcher((_) => []);
    final p = MomentsProvider(fetch: f.fetch);

    await p.ensureLoaded();

    expect(f.offsets, [0]);
    expect(p.moments.length, 3, reason: '空响应通常是抖动，覆盖成空 = 用户的日记凭空消失');
    expect(p.isCacheFresh, isFalse,
        reason: '没拿到新数据就续期的话，一次抖动能让日记列表停更整个新鲜期');
  });

  test('缓存命中时按页大小还原 hasMore：不满一页说明到底了', () async {
    await seedCache(3, ageAgo: const Duration(hours: 1)); // 3 < _pageSize(20)
    final p = MomentsProvider(fetch: fetcher((_) => []).fetch);

    await p.ensureLoaded();

    expect(p.hasMore, isFalse, reason: 'hasMore 恒为 true 的话滚到底会白发一次分页请求');
  });

  test('clearCache 同时清内容与时间戳', () async {
    await seedCache(3, ageAgo: const Duration(hours: 1));
    final f = fetcher((_) => [moment('next-account')]);
    final p = MomentsProvider(fetch: f.fetch);

    await p.clearCache();

    expect(p.moments, isEmpty);
    expect(p.isInitialized, isFalse);
    expect(p.isCacheFresh, isFalse);
    expect(SharedPreferencesUtil().getCachedJson('moments_list'), isNull);
    expect(SharedPreferencesUtil().getInt('moments_list_fetched_at'), isNull,
        reason: '时间戳留着 = 下个账号被判成「缓存新鲜」而一次都不请求，界面空到过期为止');

    // 清完之后必须真的会去拉新账号的数据。
    await p.ensureLoaded();
    expect(f.offsets, [0]);
    expect(p.moments.single.id, 'next-account');
  });

  test('登出（clearUserPreferences）会把内容和时间戳一起清掉', () async {
    await seedCache(3, ageAgo: const Duration(minutes: 1));

    await SharedPreferencesUtil().clearUserPreferences();

    expect(SharedPreferencesUtil().getCachedJson('moments_list'), isNull);
    expect(SharedPreferencesUtil().getInt('moments_list_fetched_at'), isNull,
        reason: 'clearCache 与 remove 是两处独立调用，漏掉后者等于给下个账号留一张新鲜期通行证');
  });

  test('深链未命中时绕过新鲜度（推送里那篇刚落库，缓存必然没有）', () async {
    await seedCache(3, ageAgo: const Duration(minutes: 1)); // 刻意很新鲜
    final f = fetcher((_) => [moment('pushed'), moment('m0')]);
    final p = MomentsProvider(fetch: f.fetch);

    final found = await p.getMomentById('pushed');

    expect(f.offsets, [0], reason: '尊重新鲜度的话点推送永远打不开那篇日记');
    expect(found?.id, 'pushed');
  });

  test('深链命中缓存时不请求', () async {
    await seedCache(3, ageAgo: const Duration(hours: 99));
    final f = fetcher((_) => []);
    final p = MomentsProvider(fetch: f.fetch);

    final found = await p.getMomentById('m1');

    expect(found?.id, 'm1');
    expect(f.offsets, isEmpty, reason: '本地已经有了，没有理由为深链打一次网络');
  });

  test('翻页结果也落盘：退出再进来不用重新翻', () async {
    final f = fetcher((offset) => [for (var i = 0; i < 20; i++) moment('p$offset-$i')]);
    final p = MomentsProvider(fetch: f.fetch);

    await p.ensureLoaded();
    expect(p.moments.length, 20);
    await p.loadMoreMoments();
    expect(p.moments.length, 40);

    // 新实例读缓存，应该拿到 40 条而不是 20。
    final reopened = MomentsProvider(fetch: fetcher((_) => []).fetch);
    expect(reopened.moments.length, 40,
        reason: '只存第一页的话，用户翻了几页退出再进来又得重新翻一遍');
  });
}
