import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/vocabulary.dart';
import 'package:memorion/backend/schema/vocabulary_word.dart';
import 'package:memorion/providers/base_provider.dart';

typedef VocabularyFetcher = Future<List<VocabularyWord>> Function();

/// 词库管理 Provider（Phase 0：增 / 删 / 查，不做改）。
/// 模式同 PeopleProvider：loading + notifyListeners + 本地 list 维护。
class VocabularyProvider extends BaseProvider {
  /// 注入点只为测试存在：`Env.apiBaseUrl` 是编译期常量，真实 `getAllVocabulary` 在
  /// 单测里没有别的办法制造「这次请求失败了」。而失败分支正是这个 Provider 最贵的
  /// 分支（见 [_doLoad]）。
  final VocabularyFetcher _fetch;

  VocabularyProvider({VocabularyFetcher? fetch}) : _fetch = fetch ?? getAllVocabulary;

  List<VocabularyWord> words = [];
  bool _hasLoaded = false;
  bool _creating = false;
  Future<void>? _loadFuture;

  /// 最近一次拉取是否失败了。UI 拿它出「加载失败，下拉可刷新」——以前失败连一行日志
  /// 都没有（`getAllVocabulary` 直接 `return []`），用户看到的是干净的空态，分不清
  /// 「我一个词都没加过」和「刚才那次请求挂了」。
  ///
  /// ⚠️ 词库**没有**本地缓存兜底（不像 `people` 有 `cachedPeople` 预填），所以失败时
  /// 界面上确实是空的——这正是重试入口必须显式可见的理由，横幅是唯一的解药。
  bool _loadFailed = false;
  bool get loadFailed => _loadFailed;

  /// 首次加载是否已经收工（成功或失败都算）。
  ///
  /// 和 `_hasLoaded`（只在成功时置位，决定要不要复用缓存/重试）分开：这个只回答
  /// 「还有没有数据可能要来」，给 UI 决定出骨架屏还是出空态。
  ///
  /// `loading` 初值是 false，而拉取要等页面 postFrame 才发起 —— 光看它，首帧会
  /// 命中「列表空 + 不在加载」而闪一下空态，明明马上就有词条。
  bool _hasLoadedOnce = false;
  bool get hasLoadedOnce => _hasLoadedOnce;

  /// 进页加载；已经成功拉到过就直接用内存里的那份（除非 force）。
  ///
  /// `_hasLoaded` **只在成功时置位**：失败以后再进这个页面必须重新拉。这个 Provider 是
  /// App 根上的全局单例，以前失败也置位（空列表被当成成功结果），于是退出重进照样是
  /// 空的，用户唯一的出路是杀掉 App 重开。
  Future<void> initialize({bool force = false}) {
    if (_loadFuture != null) return _loadFuture!;
    if (_hasLoaded && !force) return Future.value();
    return _load();
  }

  /// 下拉刷新 / 点「重试」的入口：不看 `_hasLoaded`，一定发请求。
  Future<void> reload() => _load();

  Future<void> _load() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    final future = _doLoad();
    _loadFuture = future;
    return future;
  }

  Future<void> _doLoad() async {
    loading = true;
    _loadFailed = false;
    notifyListeners();
    try {
      words = await _fetch();
      _hasLoaded = true;
    } on Exception catch (e) {
      // 拉取失败（超时 / 非 200 / 响应体坏掉）→ 保持现有列表不动，并在 `loadFailed`
      // 上留下痕迹。以前 `getAllVocabulary` 失败返回 `[]`，这里把它当成成功赋值给
      // `words` 且置位 `_hasLoaded`，一次超时就让词库页永久停在空态。
      // 只吞 Exception 不吞 Error：`TypeError` 那类是代码 bug，该炸出来。
      _loadFailed = true;
      debugPrint('vocabulary load failed, keeping ${words.length} entries: $e');
    } finally {
      // 放在 finally：拉取抛异常（断网 / 401）时也要收工，否则骨架屏一直挂着不落地。
      _hasLoadedOnce = true;
      loading = false;
      _loadFuture = null;
      notifyListeners();
    }
  }

  /// 新增词条。返回 null 表示失败；成功（含后端去重命中已有条目）则合并进本地列表。
  Future<VocabularyWord?> createWord(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return null;
    // 防重入用独立标志：不要复用 `loading`（那个还兼管首次加载，
    // 进页时列表在拉取，若用 loading 守护会把新增误判成失败）。
    if (_creating) return null;
    _creating = true;
    // 若首次加载仍在进行，先等它完成，避免与列表刷新竞态。
    if (_loadFuture != null) {
      await _loadFuture;
    }
    notifyListeners();

    try {
      final VocabularyWord? word = await createVocabulary(trimmed);
      if (word != null) {
        // 去重：后端命中已有条目会返回同 id，避免本地重复插入。
        final exists = words.any((w) => w.id == word.id);
        if (!exists) {
          words.insert(0, word);
        }
      }
      return word;
    } finally {
      _creating = false;
      notifyListeners();
    }
  }

  /// 删除词条：先本地移除并刷新，失败再回滚。
  Future<bool> deleteWord(VocabularyWord word) async {
    final index = words.indexWhere((w) => w.id == word.id);
    if (index != -1) {
      words.removeAt(index);
      notifyListeners();
    }
    final ok = await deleteVocabulary(word.id);
    if (!ok && index != -1) {
      words.insert(index, word); // 回滚
      notifyListeners();
    }
    return ok;
  }
}
