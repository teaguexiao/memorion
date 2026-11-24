import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一次失败的人物拉取会把人物列表**永久**清空（2026-08-12 修复），以及让它不容易失败
/// 的那半边：列表只拿计数、样本 URL 在详情里按人拉（同日）。
///
/// 现场是「刷新一下人物/识别其他人，里面就空了，而且再进来还是空的」。链路：
/// `getAllPeople` 分页时任意一页失败就 `break`，把**已经拿到的那部分**（常常是 0 条）
/// 当成结果返回；`_doLoadPeople` 分不清「这个用户只有 3 个人」和「第一页就超时了」，
/// 于是把它赋值给 `people` **并写进 `cachedPeople`**。缓存本来是唯一的兜底，写坏之后
/// 就只有一次完整成功的拉取能把列表找回来。
///
/// 这条路很好走：那个账号有 833 个人，`include_speech_samples=true` 的一页实测 15.65s
/// （不带样本 2.38s，13 秒差全花在列 GCS 样本上），全量 27s；`makeApiCall` 不设超时，
/// 但 iOS 一锁屏/切后台就挂起网络，而 `makeApiCall` 把任何 throw 都变成 `return null`。
///
/// 不对称是修法的全部理由：**留着旧数据的代价是「可能有点旧」，覆盖掉的代价是「永久
/// 空白」**。所以失败一律保持现状。
///
/// 每条断言对应一个各自静默的失败形态：
/// 1. 失败不动内存里的列表——否则界面当场变空。
/// 2. 失败不动 `cachedPeople`——只做 1 不做 2 的话，本次会话看着好，冷启动照样空。
/// 3. 失败要在 `loadFailed` 上留下痕迹——否则界面是干净的空态，用户分不清「我没标过人」
///    和「刚才那次请求挂了」，只能反复退出重进。
/// 4. 成功当然要替换并写缓存，否则改名/新增永远看不到。
/// 5. 失败也要收工（`loading=false` / `hasLoadedOnce=true`），否则骨架屏永远挂着不落地。
/// 6. 有缓存时 `ensureLoaded` 一发请求都不能发——标记说话人卡片不值得为此再等一轮。
/// 7. 并发只发一次，且失败后能重试（`_loadFuture` 在 finally 里清）。
/// 8. 列表请求必须是 `include_speech_samples=false`——这是 27s→4s 的那一刀，回退它就把
///    「拉取容易失败」这个前提原样带回来了。
/// 9. 条数必须能独立于 URL 存活并往返缓存（`speech_samples_count`），否则列表整页显示
///    「暂无样本」——那正是当初不敢去掉样本的理由。
/// 10. 样本 URL 按需拉、只拉一次、失败可重试，且**绝不写进缓存**（签名 URL 只活 60 分钟，
///    落盘后冷启动拿到的是一批过期链接）。
/// 11. 删样本按 person **id** 定位：详情打开期间列表可能被下拉刷新重排，按下标会删错人。
/// 12. `getAllPeople` 本身必须抛，不能再返回短列表——上面全绿也挡不住这个源头，截断的
///    列表在 Provider 眼里就是「成功」。
///
/// Run: cd app && flutter test test/people_cache_wipe_test.dart
void main() {
  // `PeopleProvider` 的字段初始化里 `new AudioPlayer()` 会去取 `AudioSession.instance`，
  // 那要 MethodChannel 有 binder。跟本文件测的东西无关，只是构造不到 Provider。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  Person person(String id, {int count = 0, List<String> samples = const []}) => Person(
        id: id,
        name: id,
        createdAt: DateTime(2026, 8, 1),
        updatedAt: DateTime(2026, 8, 1),
        speechSamples: samples,
        speechSamplesCount: count == 0 ? samples.length : count,
        speechSamplesDuration: samples.isEmpty ? 0.0 : 12.0,
      );

  /// 记录发了几次列表请求。
  ({List<int> calls, PeopleFetcher fetch}) fetcher(Future<List<Person>> Function() reply) {
    final calls = <int>[];
    Future<List<Person>> fetch() {
      calls.add(calls.length);
      return reply();
    }

    return (calls: calls, fetch: fetch);
  }

  group('列表拉取失败时', () {
    test('内存里的列表保持不动', () async {
      SharedPreferencesUtil().cachedPeople = [person('a'), person('b')];
      final f = fetcher(() async => throw PeopleFetchException('timeout at offset 0'));
      final provider = PeopleProvider(fetch: f.fetch);

      await provider.setPeople();

      expect(provider.people.map((p) => p.id), ['a', 'b'],
          reason: '失败把列表清空 = 用户看到的界面当场变空，而数据在服务端好着');
    });

    test('cachedPeople 保持不动', () async {
      SharedPreferencesUtil().cachedPeople = [person('a'), person('b')];
      final f = fetcher(() async => throw PeopleFetchException('HTTP 502 at offset 0'));

      await PeopleProvider(fetch: f.fetch).setPeople();

      expect(SharedPreferencesUtil().cachedPeople.map((p) => p.id), ['a', 'b'],
          reason: '缓存被失败结果覆盖后就再也回不来了——这才是「再进来还是空的」的原因');
    });

    test('在 loadFailed 上留下痕迹', () async {
      final f = fetcher(() async => throw PeopleFetchException('timeout at offset 0'));
      final provider = PeopleProvider(fetch: f.fetch);

      await provider.setPeople();
      expect(provider.loadFailed, isTrue, reason: '失败只打一行 debugPrint 的话，界面是干净的空态，用户无从判断');

      final ok = PeopleProvider(fetch: fetcher(() async => [person('a')]).fetch);
      await ok.setPeople();
      expect(ok.loadFailed, isFalse, reason: '成功后没清掉，重试成功了还挂着「加载失败」');
    });

    test('照样收工，不把骨架屏挂死', () async {
      final f = fetcher(() async => throw PeopleFetchException('network error at offset 0'));
      final provider = PeopleProvider(fetch: f.fetch);

      await provider.setPeople();

      expect(provider.loading, isFalse, reason: 'loading 留在 true = 一直转圈');
      expect(provider.hasLoadedOnce, isTrue, reason: 'UI 靠它决定出骨架屏还是出空态');
    });

    test('下一次还能重试', () async {
      var shouldFail = true;
      final f = fetcher(() async {
        if (shouldFail) throw PeopleFetchException('timeout at offset 0');
        return [person('a')];
      });
      final provider = PeopleProvider(fetch: f.fetch);

      await provider.setPeople();
      shouldFail = false;
      await provider.setPeople();

      expect(provider.people.map((p) => p.id), ['a'],
          reason: '_loadFuture 没在 finally 里清的话，失败那一发会把后续调用全部短路掉');
    });

    test('只吞 Exception，代码 bug 照样炸出来', () async {
      final f = fetcher(() async => throw ArgumentError('bad json shape'));

      await expectLater(PeopleProvider(fetch: f.fetch).setPeople(), throwsA(isA<Error>()),
          reason: '把 Error 也吞掉，解析写错会伪装成「网络不好」，一直查不到');
    });
  });

  group('列表拉取成功时', () {
    test('替换列表并写缓存', () async {
      SharedPreferencesUtil().cachedPeople = [person('old')];
      final f = fetcher(() async => [person('a', count: 3), person('b')]);
      final provider = PeopleProvider(fetch: f.fetch);

      await provider.setPeople();

      expect(provider.people.map((p) => p.id), ['a', 'b']);
      expect(SharedPreferencesUtil().cachedPeople.map((p) => p.id), ['a', 'b']);
    });

    test('样本条数不依赖 URL，并且能往返缓存', () async {
      final f = fetcher(() async => [person('a', count: 3)]); // 列表版：有条数，没 URL
      final provider = PeopleProvider(fetch: f.fetch);

      await provider.setPeople();

      expect(provider.people.single.speechSamples, isEmpty, reason: '列表接口刻意不返回 URL，这就是省下的 13 秒');
      expect(provider.people.single.speechSamplesCount, 3, reason: '列表行显示「N 段样本」全靠它');
      expect(SharedPreferencesUtil().cachedPeople.single.speechSamplesCount, 3,
          reason: 'toJson 漏了 speech_samples_count → 冷启动整页「暂无样本」');
    });

    test('旧缓存（只有 URL、没有 count 字段）退回数 URL', () {
      final legacy = Person.fromJson({
        'id': 'a',
        'name': 'a',
        'created_at': '2026-08-01T00:00:00Z',
        'updated_at': '2026-08-01T00:00:00Z',
        'speech_samples': ['u1', 'u2'],
        // 刻意没有 speech_samples_count：2026-08-12 之前写下的缓存长这样
      });

      expect(legacy.speechSamplesCount, 2, reason: '没有回退的话，升级后所有存量缓存一夜之间全变「暂无样本」');
    });
  });

  group('ensureLoaded', () {
    test('有缓存就一发请求都不发', () async {
      SharedPreferencesUtil().cachedPeople = [person('a')];
      final f = fetcher(() async => [person('a'), person('b')]);

      await PeopleProvider(fetch: f.fetch).ensureLoaded();

      expect(f.calls, isEmpty, reason: '为一次可能没变化的刷新担失败风险，不值得');
    });

    test('没缓存时会拉一次', () async {
      final f = fetcher(() async => [person('a')]);

      await PeopleProvider(fetch: f.fetch).ensureLoaded();

      expect(f.calls.length, 1, reason: '没进过人物页的用户在标记说话人卡片里只能看到「我」');
    });

    test('和 setPeople 并发时共用同一发请求', () async {
      final f = fetcher(() async => [person('a')]);
      final provider = PeopleProvider(fetch: f.fetch);

      await Future.wait([provider.setPeople(), provider.ensureLoaded()]);

      expect(f.calls.length, 1, reason: '两个入口各打一发 = 833 人的账号上两倍的失败机会');
    });
  });

  group('样本 URL 按需拉', () {
    /// 详情 sheet 用的单人拉取。
    ({List<String> calls, PersonFetcher fetch}) oneFetcher(Future<Person?> Function(String id) reply) {
      final calls = <String>[];
      Future<Person?> fetch(String personId, {bool includeSpeechSamples = false}) {
        calls.add(personId);
        expect(includeSpeechSamples, isTrue, reason: '详情就是为了拿 URL，不带样本等于白打一发');
        return reply(personId);
      }

      return (calls: calls, fetch: fetch);
    }

    test('拉到的 URL 进 samplesUrl，且不写进缓存', () async {
      // ⚠️ 计数刻意跟拉回来的条数**不一致**（5 vs 2），否则 `_syncCount` 提前 return、
      // 一次缓存都不写，这条断言就是空过的（真发生过：URL 泄进缓存的变异测试全绿）。
      final list = fetcher(() async => [person('a', count: 5)]);
      final one = oneFetcher((id) async => person(id, samples: ['u1', 'u2']));
      final provider = PeopleProvider(fetch: list.fetch, fetchPerson: one.fetch);
      await provider.setPeople();

      await provider.loadPersonSamples('a');

      expect(provider.samplesUrl['a'], ['u1', 'u2']);
      expect(SharedPreferencesUtil().cachedPeople.single.speechSamples, isEmpty,
          reason: '签名 URL 只活 60 分钟，落盘后冷启动拿到的是一批过期链接');
    });

    test('同一个人只拉一次，force 才重拉', () async {
      final list = fetcher(() async => [person('a', count: 1)]);
      final one = oneFetcher((id) async => person(id, samples: ['u1']));
      final provider = PeopleProvider(fetch: list.fetch, fetchPerson: one.fetch);
      await provider.setPeople();

      await provider.loadPersonSamples('a');
      await provider.loadPersonSamples('a');
      expect(one.calls.length, 1, reason: '每次开合 sheet 都重拉一次纯属白花时间');

      await provider.loadPersonSamples('a', force: true);
      expect(one.calls.length, 2, reason: '删完一段要能对齐');
    });

    test('失败记在 samplesFailedFor，可以重试', () async {
      var fail = true;
      final list = fetcher(() async => [person('a', count: 1)]);
      final one = oneFetcher((id) async {
        if (fail) return null; // makeApiCall 把任何异常都变成 null
        return person(id, samples: ['u1']);
      });
      final provider = PeopleProvider(fetch: list.fetch, fetchPerson: one.fetch);
      await provider.setPeople();

      await provider.loadPersonSamples('a');
      expect(provider.samplesFailedFor('a'), isTrue, reason: '静默失败 = 详情里永远一个样本都不显示，看着像被删空了');
      expect(provider.people.single.speechSamplesCount, 1, reason: '拉 URL 失败不该把已知的条数抹掉');

      fail = false;
      await provider.loadPersonSamples('a', force: true);
      expect(provider.samplesFailedFor('a'), isFalse);
      expect(provider.samplesUrl['a'], ['u1']);
    });

    test('拉回来的条数会纠正列表里的计数', () async {
      final list = fetcher(() async => [person('a', count: 5)]); // 计数偏大（中途撤销过样本）
      final one = oneFetcher((id) async => person(id, samples: ['u1', 'u2']));
      final provider = PeopleProvider(fetch: list.fetch, fetchPerson: one.fetch);
      await provider.setPeople();

      await provider.loadPersonSamples('a');

      expect(provider.people.single.speechSamplesCount, 2, reason: '详情里明明只有 2 段，列表行还写 5 段');
      expect(SharedPreferencesUtil().cachedPeople.single.speechSamplesCount, 2);
    });
  });

  /// 源头那一半没有行为测试的缝：`Env.apiBaseUrl` 是 envied 的编译期常量，单测里没法
  /// 让真实 `getAllPeople` 的某一页失败、也没法看它拼出来的 URL。而上面全绿也挡不住
  /// 它们——`break` 返回的截断列表在 Provider 眼里是一次**成功**的拉取。
  group('getAllPeople 源码不变式', () {
    String body() {
      final s = File('lib/backend/http/api/users.dart').readAsStringSync();
      final loop = s.substring(s.indexOf('Future<List<Person>> getAllPeople'));
      return loop.substring(0, loop.indexOf('\nFuture<'));
    }

    test('任意一页失败必须抛，不能返回截断的列表', () {
      expect(body().contains('throw PeopleFetchException'), isTrue,
          reason: '分页失败必须抛；`break` 会把「第一页就超时」和「这人只有 3 个联系人」混成一件事');
      expect(RegExp(r'if \(response == null\) throw').hasMatch(body()), isTrue,
          reason: 'makeApiCall 把任何异常都变成 null——这是超时最常见的到达形态');
      expect(RegExp(r'statusCode != 200\) throw').hasMatch(body()), isTrue, reason: '401/502 同样不能当成空列表');
    });

    test('列表请求不带语音样本', () {
      expect(body().contains('include_speech_samples=false'), isTrue,
          reason: '带样本后端要为每人各列一次 GCS 并逐 blob 签名：833 人单页 15.65s vs 2.38s，'
              '而这 27 秒里锁屏/切后台就整次失败——「列表被冲空」的前提就是它');
    });
  });
}
