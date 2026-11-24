import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/vocabulary.dart';
import 'package:memorion/backend/schema/vocabulary_word.dart';
import 'package:memorion/providers/vocabulary_provider.dart';

/// 一次失败的词库拉取会让词库页停在空态、**而且退出重进也回不来**（2026-08-12 修复）。
///
/// 现场是「设置里的词库列表在手机上刷不出来」，和同日修的人物页/识别其他人同源：
/// `getAllVocabulary` 失败时 `return []`，`_doLoad` 分不清「这个用户一个词都没加过」和
/// 「刚才那次请求挂了」，于是把空列表赋给 `words` 并置位 `_hasLoaded`。
///
/// 比人物页更难自救的是后半句：`VocabularyProvider` 是 App 根上的**全局单例**
/// （`main.dart` 的 MultiProvider），`_hasLoaded` 一旦置位，`initialize()` 就直接
/// return——退出页面重进不会再发请求，用户唯一的出路是杀掉 App。而词库页此前既没有
/// 下拉刷新（空态是个 `Center`，压根没有可滚容器，下拉手势无处可去），也没有任何失败
/// 痕迹（失败连一行日志都没有）。
///
/// 失败很好走：`makeApiCall` 不设超时，但 iOS 一锁屏/切后台就挂起网络，而它把任何
/// throw 都变成 `return null`；后端 `list_vocabulary` 是 `async def` 里跑同步 Firestore
/// 读，别的慢请求会让它一起排队。
///
/// 不对称是修法的全部理由：**留着旧数据的代价是「可能有点旧」，覆盖掉的代价是「看起来
/// 一条都没有」。** 所以失败一律保持现状 + 留痕 + 让下一次进页面重新拉。
///
/// 每条断言对应一个各自静默的失败形态：
/// 1. 失败不动内存里的列表——否则界面当场变空。
/// 2. 失败要在 `loadFailed` 上留下痕迹——否则界面是干净的「还没有添加词条」，用户分不清
///    是自己没加过还是没拉到（词库**没有**本地缓存兜底，横幅是唯一的解药）。
/// 3. 失败**不置 `_hasLoaded`**——只做 1、2 不做这条，退出重进依然不发请求，只能杀 App。
/// 4. 失败也要收工（`loading=false` / `hasLoadedOnce=true`），否则骨架屏永远挂着不落地。
/// 5. 下一次还能重试（`_loadFuture` 在 finally 里清）。
/// 6. 只吞 Exception，`Error` 那类是代码 bug，该炸出来。
/// 7. 成功当然要替换列表，否则新增/删除永远看不到。
/// 8. 成功后 `initialize()` 不再重复发请求——每次进页都等一轮不值得。
/// 9. `reload()` 不看 `_hasLoaded`：下拉刷新必须真的刷。
/// 10. `getAllVocabulary` 本身必须抛，不能再返回空列表——上面全绿也挡不住这个源头，
///     空列表在 Provider 眼里就是一次**成功**的拉取。
/// 11. 一页拉不完要继续翻：后端单页硬上限 500，只取第一页 = 第 501 个词起静默消失。
/// 12. 空态必须待在可滚容器里、且有 RefreshIndicator——改回 `Center` 后界面看起来一模
///     一样，只是下拉手势静默失效，而那恰好是拉取失败后用户停在的界面。
///
/// Run: cd app && flutter test test/vocabulary_load_failure_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VocabularyWord word(String id) => VocabularyWord(
        id: id,
        term: id,
        createdAt: DateTime(2026, 8, 1),
        updatedAt: DateTime(2026, 8, 1),
      );

  /// 记录发了几次列表请求。
  ({List<int> calls, VocabularyFetcher fetch}) fetcher(Future<List<VocabularyWord>> Function() reply) {
    final calls = <int>[];
    Future<List<VocabularyWord>> fetch() {
      calls.add(calls.length);
      return reply();
    }

    return (calls: calls, fetch: fetch);
  }

  /// 先成功拉到一份，再让后续请求按 [thenFail] 决定成败——用来验「失败不能把已经在
  /// 屏幕上的词条冲掉」。
  Future<VocabularyProvider> loadedThen(List<VocabularyWord> first, {required bool thenFail}) async {
    var firstCall = true;
    final provider = VocabularyProvider(fetch: () async {
      if (firstCall) {
        firstCall = false;
        return first;
      }
      if (thenFail) throw VocabularyFetchException('timeout at offset 0');
      return [];
    });
    await provider.initialize();
    return provider;
  }

  group('拉取失败时', () {
    test('内存里的列表保持不动', () async {
      final provider = await loadedThen([word('a'), word('b')], thenFail: true);

      await provider.reload();

      expect(provider.words.map((w) => w.id), ['a', 'b'],
          reason: '失败把列表清空 = 用户看到的界面当场变空，而数据在服务端好着');
    });

    test('在 loadFailed 上留下痕迹', () async {
      final provider = VocabularyProvider(fetch: fetcher(() async => throw VocabularyFetchException('HTTP 502')).fetch);

      await provider.initialize();
      expect(provider.loadFailed, isTrue,
          reason: '失败没有界面痕迹的话，用户看到的是干净的「还没有添加词条」，无从判断');

      final ok = VocabularyProvider(fetch: fetcher(() async => [word('a')]).fetch);
      await ok.initialize();
      expect(ok.loadFailed, isFalse, reason: '成功后没清掉，重试成功了还挂着「加载失败」');
    });

    test('再进页面会重新拉（失败不算「加载过了」）', () async {
      var shouldFail = true;
      final f = fetcher(() async {
        if (shouldFail) throw VocabularyFetchException('network error at offset 0');
        return [word('a')];
      });
      final provider = VocabularyProvider(fetch: f.fetch);

      await provider.initialize(); // 第一次进页面：失败
      shouldFail = false;
      await provider.initialize(); // 退出重进

      expect(f.calls.length, 2,
          reason: '这个 Provider 是全局单例：失败也置位 _hasLoaded 的话，重进页面直接 return，只能杀 App');
      expect(provider.words.map((w) => w.id), ['a']);
    });

    test('照样收工，不把骨架屏挂死', () async {
      final provider =
          VocabularyProvider(fetch: fetcher(() async => throw VocabularyFetchException('timeout')).fetch);

      await provider.initialize();

      expect(provider.loading, isFalse, reason: 'loading 留在 true = 一直转圈');
      expect(provider.hasLoadedOnce, isTrue, reason: 'UI 靠它决定出骨架屏还是出空态');
    });

    test('下一次还能重试', () async {
      var shouldFail = true;
      final provider = VocabularyProvider(fetch: () async {
        if (shouldFail) throw VocabularyFetchException('timeout at offset 0');
        return [word('a')];
      });

      await provider.reload();
      shouldFail = false;
      await provider.reload();

      expect(provider.words.map((w) => w.id), ['a'],
          reason: '_loadFuture 没在 finally 里清的话，失败那一发会把后续调用全部短路掉');
    });

    test('只吞 Exception，代码 bug 照样炸出来', () async {
      final provider = VocabularyProvider(fetch: () async => throw ArgumentError('bad json shape'));

      await expectLater(provider.initialize(), throwsA(isA<Error>()),
          reason: '把 Error 也吞掉，解析写错会伪装成「网络不好」，一直查不到');
    });
  });

  group('拉取成功时', () {
    test('替换列表', () async {
      final provider = await loadedThen([word('old')], thenFail: false);

      await provider.reload();

      expect(provider.words, isEmpty, reason: '成功结果必须生效，否则在别处删掉的词条这里永远还在');
    });

    test('initialize 不再重复发请求', () async {
      final f = fetcher(() async => [word('a')]);
      final provider = VocabularyProvider(fetch: f.fetch);

      await provider.initialize();
      await provider.initialize();

      expect(f.calls.length, 1, reason: '每次进页面都等一轮网络，而词库几乎不变');
    });
  });

  group('reload（下拉刷新 / 点重试）', () {
    test('成功过也一定发请求', () async {
      final f = fetcher(() async => [word('a')]);
      final provider = VocabularyProvider(fetch: f.fetch);

      await provider.initialize();
      await provider.reload();

      expect(f.calls.length, 2, reason: 'reload 看 _hasLoaded 的话，下拉刷新就是个只会转圈的假动作');
    });

    test('并发只发一次', () async {
      final f = fetcher(() async => [word('a')]);
      final provider = VocabularyProvider(fetch: f.fetch);

      await Future.wait([provider.reload(), provider.reload(), provider.initialize()]);

      expect(f.calls.length, 1, reason: '下拉时页面 initState 也可能在拉，两发请求互相覆盖');
    });
  });

  /// 源头那一半没有行为测试的缝：`Env.apiBaseUrl` 是 envied 的编译期常量，单测里没法让
  /// 真实 `getAllVocabulary` 失败、也没法看它拼出来的 URL。而上面全绿也挡不住它——
  /// `return []` 在 Provider 眼里就是一次**成功**的拉取。
  group('getAllVocabulary 源码不变式', () {
    String body() {
      final s = File('lib/backend/http/api/vocabulary.dart').readAsStringSync();
      final fn = s.substring(s.indexOf('Future<List<VocabularyWord>> getAllVocabulary'));
      return fn.substring(0, fn.indexOf('\n/// 新增词条'));
    }

    test('失败必须抛，不能返回空列表', () {
      expect(RegExp(r'if \(response == null\) throw').hasMatch(body()), isTrue,
          reason: 'makeApiCall 把任何异常都变成 null——这是超时最常见的到达形态');
      expect(RegExp(r'statusCode != 200\) throw').hasMatch(body()), isTrue,
          reason: '401/502 同样不能当成「这个用户没有词条」');
      expect(body().contains('return []'), isFalse, reason: '任何一条 return [] 都会被 Provider 当成成功');
    });

    test('一页拉不完要继续翻', () {
      expect(body().contains('offset=\$offset'), isTrue, reason: '后端单页硬上限 500，只取第一页 = 第 501 个词起静默消失');
      expect(body().contains('if (json.length < pageSize) break'), isTrue, reason: '短页才是终止条件；不 break 会一直空转到 maxPages');
    });
  });

  /// 页面那一半同样没有行为测试的缝：`Center` 换成可滚容器在截图上看不出任何区别，
  /// 只是下拉手势静默失效——而那恰好是拉取失败后用户停在的那个界面。
  group('词库页源码不变式', () {
    String page() => File('lib/pages/today_chapters/vocabulary_page.dart').readAsStringSync();

    // 匹配的是**代码形态**而不是词：这两个词在同一段解释性注释里也出现，只 contains
    // 词的话，把 `physics:` 那行删掉照样全绿（第一版就是这么空过的）。
    test('空态待在可滚容器里，且能下拉刷新', () {
      expect(RegExp(r'onRefresh: \(\) => p\.reload\(\)').hasMatch(page()), isTrue,
          reason: '失败后没有刷新入口，只能杀掉 App 重进');
      expect(RegExp(r'physics: const AlwaysScrollableScrollPhysics\(\)').hasMatch(page()), isTrue,
          reason: '内容不足一屏（尤其是空态）时，ListView 默认不响应下拉');
      expect(RegExp(r'Widget _empty\(\) \{\s*\n\s*//[^\n]*\n\s*return Center').hasMatch(page()), isFalse,
          reason: '空态回到 Center 就又被挪出可滚容器了，下拉刷新静默失效');
    });

    test('失败横幅带重试按钮', () {
      expect(RegExp(r'if \(p\.loadFailed\) _retryBanner\(').hasMatch(page()), isTrue,
          reason: '光有下拉是隐性手势，等于让用户猜；只留 _retryBanner 定义、不在 _body 里挂上去也是白写');
    });
  });
}
