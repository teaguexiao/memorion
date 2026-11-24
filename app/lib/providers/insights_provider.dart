import 'package:flutter/foundation.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/utils/about_me_cache.dart';
import 'package:memorion/backend/http/api/insights.dart';
import 'package:memorion/backend/schema/insight.dart';

typedef InsightsFetcher = Future<List<InsightCard>?> Function({bool releasedOnly, int limit, int offset});

typedef InsightFetcher = Future<InsightCard?> Function(String insightId);

/// 涌现式洞察卡状态（P-13「关于我」/ P-31 画像详情 / 洞察分享页共用）。
///
/// 数据源 `GET /v1/insights`（released_only），由后端引擎审核后释放。
/// 账本可能长期为空（释放阀在证据不够时什么都不发是正常结果），UI 需有空态。
class InsightsProvider extends ChangeNotifier {
  InsightsProvider({InsightFetcher? fetchInsight, InsightsFetcher? fetch})
      : _fetchInsight = fetchInsight ?? getInsight,
        _fetch = fetch ?? getInsights {
    try {
      final cached = SharedPreferencesUtil().getCachedJson('insights_list');
      if (cached is List) {
        insights = cached.map((e) => InsightCard.fromJson(Map<String, dynamic>.from(e))).toList();
        isInitialized = true;
      }
    } catch (e) {
      debugPrint('InsightsProvider: cache load error: $e');
    }
  }

  final InsightsFetcher _fetch;
  final _cache = AboutMeCache('insights_list');
  Future<void>? _refreshing;
  int _epoch = 0;

  Future<void> ensureLoaded() async {
    if (isInitialized && _cache.isFresh) return;
    await loadInsights();
  }

  final InsightFetcher _fetchInsight;
  List<InsightCard> insights = [];
  bool isLoading = false;
  bool isInitialized = false;
  bool isRunningEngine = false;

  /// 最新一条洞察（列表已按释放时间倒序）。
  InsightCard? get latest => insights.isEmpty ? null : insights.first;

  bool get isEmpty => insights.isEmpty && !isLoading && isInitialized;

  /// 命中率：用户反馈里 accurate 的占比（后端不提供，前端按 feedback 统计）。
  /// 无任何反馈时返回 null（UI 不显示命中率，避免造 83% 这种假数据）。
  int? get hitRate {
    var accurate = 0;
    var rated = 0;
    for (final c in insights) {
      if (c.feedback == InsightFeedback.accurate) {
        accurate++;
        rated++;
      } else if (c.feedback == InsightFeedback.inaccurate) {
        rated++;
      }
    }
    if (rated == 0) return null;
    return ((accurate / rated) * 100).round();
  }

  Future<void> loadInsights() {
    if (_refreshing case final running?) return running;
    final request = _loadInsights();
    _refreshing = request;
    return request.whenComplete(() {
      if (identical(_refreshing, request)) _refreshing = null;
    });
  }

  Future<void> _loadInsights() async {
    final epoch = _epoch;
    final owner = ApiConfig().externalUserId;
    isLoading = insights.isEmpty;
    notifyListeners();
    try {
      final fetched = await _fetch(releasedOnly: true, limit: 50, offset: 0);
      if (fetched == null || epoch != _epoch || owner != ApiConfig().externalUserId) return;
      insights = fetched;
      isInitialized = true;
      await Future.wait([
        SharedPreferencesUtil().cacheJson('insights_list', insights.map((c) => c.toJson()).toList()),
        _cache.markFetched(owner: owner),
      ]);
      debugPrint('InsightsProvider: loaded ${insights.length} insights');
    } catch (e) {
      debugPrint('InsightsProvider: load error: $e');
    } finally {
      if (epoch == _epoch) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() => loadInsights();

  /// 通知指定的卡片需独立读取，避免打开最新一条或已删除的缓存。
  Future<InsightCard?> getInsightById(String insightId) async {
    try {
      final card = await _fetchInsight(insightId);
      return card?.id == insightId && card?.status == 'released' ? card : null;
    } catch (e) {
      debugPrint('InsightsProvider: detail load error: $e');
      return null;
    }
  }

  /// 退出登录 / 切账号时清空——否则上一个账号的洞察会残留，且 isInitialized
  /// 为 true 会让新账号进「关于我」时不再拉取。
  void clear() {
    _epoch++;
    _refreshing = null;
    SharedPreferencesUtil().clearCache('insights_list');
    _cache.invalidate();
    insights = [];
    isLoading = false;
    isInitialized = false;
    isRunningEngine = false;
    notifyListeners();
  }

  /// 提交「说得准 / 不太准」。乐观更新 + 失败回滚。
  Future<bool> submitFeedback(String insightId, InsightFeedback feedback) async {
    final idx = insights.indexWhere((c) => c.id == insightId);
    if (idx == -1) return false;
    final prev = insights[idx].feedback;
    insights[idx] = insights[idx].copyWith(feedback: feedback);
    notifyListeners();

    final updated = await submitInsightFeedback(insightId, feedback);
    if (updated == null) {
      insights[idx] = insights[idx].copyWith(feedback: prev);
      notifyListeners();
      return false;
    }
    insights[idx] = updated;
    SharedPreferencesUtil().cacheJson('insights_list', insights.map((c) => c.toJson()).toList());
    notifyListeners();
    return true;
  }

  /// 手动跑一轮引擎（一轮 40s+ 且消耗 LLM，仅 debug 入口调用）。
  /// 返回给 UI 提示的文案：释放了卡返回 null，否则返回 skipped_reason。
  ///
  /// 下面的中文提示只出现在 kDebugMode 的「立即生成」按钮里（见
  /// portrait_detail_page / about_me_body），release 构建不可达，故不做双语
  /// （每行单独标了 i18n-ignore）。
  Future<String?> runEngine({int windowDays = 30}) async {
    if (isRunningEngine) return '正在生成中，请稍候'; // i18n-ignore: debug-only 文案
    isRunningEngine = true;
    notifyListeners();
    try {
      final res = await runInsightEngine(windowDays: windowDays);
      if (res == null) return '请求失败，请重试'; // i18n-ignore: debug-only 文案
      final released = res['released'];
      if (released != null) {
        await loadInsights();
        return null;
      }
      return _explainSkip(res['skipped_reason'] as String?, res['nominations_count'] as int?);
    } finally {
      isRunningEngine = false;
      notifyListeners();
    }
  }

  /// 把后端的 skipped_reason 翻成人话（见 backend/utils/insights/engine.py）。
  ///
  /// 「没释放」多数时候是**释放阀在正常工作**，不是错误：疲劳窗口要求两张卡至少
  /// 隔 MIN_DAYS_BETWEEN_CARDS(5) 天，证据不够时也宁可不发。
  String _explainSkip(String? reason, int? nominations) {
    if (reason == null) return '本轮没有够格的洞察'; // i18n-ignore: debug-only 文案

    if (reason == 'fatigue_window') {
      final wait = _daysUntilNextRelease();
      final tail = wait == null ? '' : '，还需约 $wait 天';
      return '刚推过一张，要隔 5 天才会再推$tail'; // i18n-ignore: debug-only 文案
    }
    if (reason == 'nothing_worth_saying') {
      final n = nominations ?? 0;
      return n > 0 ? '提名了 $n 条，但都没通过审核' : '本轮没找到值得说的事'; // i18n-ignore: debug-only 文案
    }
    if (reason == 'no_nominations') return '这段时间的对话里没提名出洞察'; // i18n-ignore: debug-only 文案
    if (reason.startsWith('insufficient_data')) return '对话数据还太少，多聊聊再看'; // i18n-ignore: debug-only 文案
    return '本轮未释放：$reason'; // i18n-ignore: debug-only 文案
  }

  /// 距下一张卡解锁还有几天（基于最近一次释放时间 + 5 天疲劳窗口）。
  int? _daysUntilNextRelease() {
    DateTime? last;
    for (final c in insights) {
      final t = c.releasedAt;
      if (t != null && (last == null || t.isAfter(last))) last = t;
    }
    if (last == null) return null;
    final remaining = last.add(const Duration(days: 5)).difference(DateTime.now());
    if (remaining.isNegative) return 0;
    return remaining.inHours ~/ 24 + (remaining.inHours % 24 > 0 ? 1 : 0);
  }
}
