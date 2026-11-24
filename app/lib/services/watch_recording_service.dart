import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/audio_upload.dart';
import 'package:memorion/backend/http/shared.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:memorion/services/watch_moment_service.dart';

typedef WatchAudioUploader = Future<UploadAudioResponse?> Function(
  WatchSyncItem item,
  void Function(int code, String body) onHttpError,
);

/// Apple Watch 录音的 Flutter 侧：从原生取待上传队列 → 走
/// `POST /v1/conversations/upload-audio` → 成功才让原生删文件。
///
/// 对应的原生实现是 `ios/Runner/WatchSessionService.swift`（那边有为什么必须落盘排队的
/// 长注释）。这里只做三件事：拉队列、串行上传、回报删除。
///
/// ⚠️ **上传必须串行。** Soniox 的离线转录是账号级 rate limit，而这个额度是**跟实时
/// 转录链路共享**的（`backend/utils/stt/pre_recorded.py` / `routers/sync.py:170` 的注释
/// 写明了这一点）。手表攒了十几段一起并发打上去，会把正在录音的用户的实时转录挤掉。
class WatchRecordingService {
  WatchRecordingService._({
    bool Function()? isIOS,
    String Function()? authHeader,
    String Function()? account,
    WatchAudioUploader? upload,
    WatchMomentService? moments,
  })  : _isIOS = isIOS ?? (() => Platform.isIOS),
        _authHeader = authHeader ?? getAuthHeader,
        _account = account ?? getExternalUserId,
        _uploadOverride = upload,
        _momentsOverride = moments;

  @visibleForTesting
  WatchRecordingService.forTesting({
    required String Function() authHeader,
    required String Function() account,
    required WatchAudioUploader upload,
    required WatchMomentService moments,
  }) : this._(isIOS: () => true, authHeader: authHeader, account: account, upload: upload, moments: moments);

  final bool Function() _isIOS;
  final String Function() _authHeader;
  final String Function() _account;
  final WatchAudioUploader? _uploadOverride;
  final WatchMomentService? _momentsOverride;
  WatchMomentService get _moments => _momentsOverride ?? WatchMomentService.instance;

  static final WatchRecordingService instance = WatchRecordingService._();

  /// 与 `AppDelegate.swift` 里的 channel 名一字不差。
  static const MethodChannel _channel = MethodChannel('com.memorion.ios/watch');
  static const String _quotaPausePrefix = 'watch_cloud_quota_pause_until_';
  static const String _oversizedItemsPrefix = 'watch_cloud_oversized_items_';
  static const String _monthlyQuotaErrorCode = 'monthly_cloud_transcription_allowance_exceeded';
  static const String _monthlyUploadTooLargeErrorCode = 'monthly_cloud_transcription_upload_exceeds_remaining';

  /// 原生投递「刚收到一段录音」时的回调。**只是提速用的**，不是数据来源 ——
  /// 真相在磁盘上，App 每次启动/回前台都会重新 `syncPending()`。
  VoidCallback? onRecordingReceived;
  VoidCallback? onOpenWatchMoment;

  /// 队列状态发生变化（传成功、被拒、自动重试跑完）时的回调。给 UI 刷新用。
  VoidCallback? onQueueChanged;

  /// 逐段进度有变化时的回调（每条录音开始上传、成功、被拒都会来一次）。
  ///
  /// ⚠️ **跟 `onQueueChanged` 分开是刻意的。** 后者的语义是「去重新查一遍原生状态」，
  /// 调用方接的是一整套带重试的轮询；进度变化每段要来两三次，拿它去触发轮询就是几十次
  /// 多余的 channel 调用。这个回调只是「重画一下」。
  VoidCallback? onItemsChanged;

  bool _syncing = false;
  bool _syncAgain = false;
  bool _repeatIgnoreQuota = false;
  bool _repeatIgnoreOversized = false;

  /// 是否正在上传。UI 拿它显示进度，别用它做去重（去重靠 `_syncing` 自己）。
  bool get isSyncing => _syncing;

  /// 逐段的状态，key 是文件名（不是完整路径 —— 路径里含容器 UUID，重装后会变）。
  ///
  /// ⚠️ **这是纯内存的展示层，不是队列的真相源。** 真相在原生的磁盘目录里
  /// （`WatchSessionService.swift` 顶部有为什么）。这里存在的唯一理由是：上传成功后原生
  /// 立刻删文件，那条录音就从 `getPendingRecordings` 里消失了 —— 只看原生队列的 UI 只能
  /// 从「3 段待上传」跳到「全部已同步」，用户完全看不到中间发生过什么，也不知道后端到底
  /// 处理完没有。这正是用户报的那个「点击之后响应很久，我也不知道音频处理了没有」。
  ///
  /// 进程重启就没了，这是可以接受的：真没传完的那些还在磁盘上，下一轮会重新登记。
  final Map<String, WatchSyncItem> _items = {};

  /// 展示上限。只防无限膨胀 —— 超了先扔最老的**终局**条目，绝不扔还没传完的。
  static const int _itemHistoryLimit = 20;

  /// 逐段状态，按录制时间从早到晚。
  List<WatchSyncItem> get syncItems {
    final list = _items.values.toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return List.unmodifiable(list);
  }

  /// 清掉已经终局的展示条目（用户点「知道了」时用）。未完成的一条不动。
  void clearFinishedItems() {
    _items.removeWhere((_, item) => item.state.isFinal);
    onItemsChanged?.call();
  }

  void _pruneItems() {
    if (_items.length <= _itemHistoryLimit) return;
    final finished = _items.entries.where((e) => e.value.state.isFinal).toList()
      ..sort((a, b) => a.value.startedAt.compareTo(b.value.startedAt));
    for (final entry in finished) {
      if (_items.length <= _itemHistoryLimit) break;
      _items.remove(entry.key);
    }
  }

  /// 从原生拉一遍待上传队列，登记进 `_items`（不上传）。UI 打开时调，好让列表在用户
  /// 点「立即同步」之前就有内容。
  ///
  /// ⚠️ **只补、不降级。** 正在上传或已完成的条目状态由 `syncPending` 写，这里不能覆盖
  /// —— 两者可以并发（用户在同步过程中下拉刷新），覆盖会让一条正在传的录音显示回「待上传」。
  Future<void> refreshItems() async {
    if (!_isIOS()) return;
    try {
      final raw = await _channel.invokeListMethod<dynamic>('getPendingRecordings') ?? [];
      final seen = <String>{};
      for (final entry in raw) {
        final item = _parseNativeItem(entry);
        if (item == null) continue;
        seen.add(item.key);
        final existing = _items[item.key];
        if (existing == null) {
          _items[item.key] = item;
        } else {
          existing.duration ??= item.duration;
        }
      }
      // 磁盘上没了、这边又不是终局的条目 —— 只可能是被别处清掉了（或者上一次进程留下的
      // 幻影）。留着会显示成永远「待上传」的一条不存在的录音。
      _items.removeWhere((key, item) => !item.state.isFinal && !seen.contains(key));
      _pruneItems();
      onItemsChanged?.call();
    } catch (e) {
      // 拉不到就保持现状。**刻意不清空** —— 「拉取失败当成空集合」是本仓库反复踩的假空态。
      debugPrint('[Watch] refreshItems failed: $e');
    }
  }

  WatchSyncItem? _parseNativeItem(dynamic entry) {
    final map = (entry as Map).cast<String, dynamic>();
    final path = map['path'] as String?;
    final startedAtMs = (map['startedAtMs'] as num?)?.toInt();
    if (path == null || startedAtMs == null) return null;
    final seconds = (map['durationSeconds'] as num?)?.toDouble();
    return WatchSyncItem(
      path: path,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs),
      // 原生解不出时长时**不带这个 key**（不是 0），所以 null 在这里的含义是「不知道」。
      duration: seconds == null ? null : Duration(milliseconds: (seconds * 1000).round()),
      recordingMetadata: map['watchRecordingMetadata'] as String?,
      accountId: map['watchRecordingMetadata'] is String
          ? (jsonDecode(map['watchRecordingMetadata'] as String) as Map)['accountId'] as String?
          : null,
    );
  }

  void _setItemState(WatchSyncItem item, WatchItemState state, {String? conversationId, int? statusCode}) {
    item.state = state;
    if (conversationId != null) item.conversationId = conversationId;
    if (statusCode != null) item.statusCode = statusCode;
    onItemsChanged?.call();
  }

  Timer? _retryTimer;
  Timer? _quotaTimer;

  /// 本次「醒着」期间已经自动重试了几轮。回前台或成功一次就归零。
  int _retryAttempt = 0;

  /// 自动重试的退避间隔。
  ///
  /// ⚠️ **必须有上限、而且必须是有限次。** 离线转录吃的是账号级、**与实时转录链路共享**的
  /// Soniox 额度（见类注释），无限频繁重试会把正在录音的用户的实时转录挤掉。用完这几轮就
  /// 停下等下一次回前台/收到新录音 —— 队列在磁盘上，什么都不会丢。
  static const List<Duration> _retryBackoff = [
    Duration(seconds: 5),
    Duration(seconds: 20),
    Duration(seconds: 60),
    Duration(minutes: 3),
    Duration(minutes: 10),
  ];

  void init() {
    if (!_isIOS()) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onRecordingReceived') {
        onRecordingReceived?.call();
        // 🚨 **原生一送到就自己传，不等 UI。** 这条回调在 App 被系统唤到后台收文件时也会来
        // （`transferFile` 是系统排队式的，iOS 会为了投递把 App 拉起来），所以「手表停止录制
        //  → 自动同步 → 自动转录」在用户根本没打开 App 的情况下也走得通。
        //
        // ⚠️ 不能只依赖调用方接了这个回调就完事：`onRecordingReceived` 是给 UI 的通知，
        // 而同步是这个类自己的职责。以前两者绑在一起，谁忘了接就等于没有自动同步。
        syncPending(reason: 'file received');
      }
      if (call.method == 'onOpenWatchMoment') onOpenWatchMoment?.call();
      return null;
    });
  }

  /// 取消挂起的自动重试。回前台时先清掉，避免叠加出多条重试链。
  void cancelScheduledRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _quotaTimer?.cancel();
    _quotaTimer = null;
  }

  /// 外部触发点（冷启动、回前台、收到新录音）统一走这里：重置退避、立刻试一次。
  ///
  /// ⚠️ **冷启动不再用「延后 8 秒」那种写法。** 那是在猜鉴权什么时候就绪，猜早了这一次
  /// 就白跑（`syncPending` 判定未登录直接返回），而下一次机会要等到用户把 App 切走再切回来。
  /// 现在改成立刻试 + 判定「未登录」时自动排下一轮 —— 鉴权几秒后就绪，第二轮就成了。
  Future<WatchSyncResult> syncNow({
    required String reason,
    bool ignoreQuotaPause = false,
    bool ignoreOversizedPause = false,
  }) {
    cancelScheduledRetry();
    unawaited(_moments.refresh());
    _retryAttempt = 0;
    return syncPending(
      reason: reason,
      ignoreQuotaPause: ignoreQuotaPause,
      ignoreOversizedPause: ignoreOversizedPause,
    );
  }

  void _scheduleRetry(WatchSyncResult result) {
    if (_retryAttempt >= _retryBackoff.length) {
      // i18n-ignore: debugPrint 日志
      debugPrint('[Watch] retry budget exhausted (${result.outcome.name}), '
          'waiting for the next foreground / incoming recording');
      return;
    }
    final delay = _retryBackoff[_retryAttempt];
    _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = null;
    debugPrint('[Watch] ${result.outcome.name} — auto-retry #$_retryAttempt in ${delay.inSeconds}s');
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      syncPending(reason: 'auto-retry #$_retryAttempt'); // i18n-ignore: 日志用的触发原因，不进 UI
    });
  }

  void _scheduleQuotaRecheck({required Duration delay}) {
    _quotaTimer?.cancel();
    _quotaTimer = Timer(delay, () {
      _quotaTimer = null;
      syncPending(reason: 'quota recheck'); // i18n-ignore: 日志用的触发原因，不进 UI
    });
  }

  /// 手表可用性。四个布尔各自独立 —— 用户需要分得清「没配表」「没装 App」「只是此刻
  /// 不可达」。不可达**完全不影响**传输：`transferFile` 是系统排队式的。
  Future<WatchStatus> getStatus() async {
    if (!_isIOS()) return const WatchStatus.unsupported();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (raw == null) return const WatchStatus.unsupported();
      return WatchStatus(
        supported: raw['supported'] == true,
        activated: raw['activated'] == true,
        paired: raw['paired'] == true,
        appInstalled: raw['appInstalled'] == true,
        reachable: raw['reachable'] == true,
        pendingCount: (raw['pendingCount'] as num?)?.toInt() ?? 0,
        rejectedCount: (raw['rejectedCount'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      debugPrint('[Watch] getStatus failed: $e');
      // ⚠️ 失败返回 unsupported 是**刻意**的降级，但注意它跟「真的不支持」在 UI 上
      // 长得一样。这里只影响一块状态文案，不影响上传（上传自己会重试），所以可以接受。
      return const WatchStatus.unsupported();
    }
  }

  /// 把原生队列里的录音逐个上传。
  ///
  /// 幂等且可重入安全：并发调用时后来的直接返回 `busy`。
  ///
  /// ⚠️ **返回的是「为什么」而不只是「几条」。** 以前只返回条数，于是「已经在传了」
  /// 「还没登录」「传失败了」「本来就没有」四种情况在调用方看来一模一样（都是 0）——
  /// 设置页把它们全渲染成「同步失败，稍后会自动重试」，其中三种是谎话。而这四种里有两种
  /// 需要自动排下一轮，另外两种不需要，光看条数也分不出来。
  Future<WatchSyncResult> syncPending({
    String reason = 'automatic',
    bool ignoreQuotaPause = false,
    bool ignoreOversizedPause = false,
  }) async {
    if (!_isIOS()) return const WatchSyncResult(WatchSyncOutcome.unsupported);
    if (_syncing) {
      _syncAgain = true;
      _repeatIgnoreQuota |= ignoreQuotaPause;
      _repeatIgnoreOversized |= ignoreOversizedPause;
      debugPrint('[Watch] sync already running, queueing another check ($reason)');
      return const WatchSyncResult(WatchSyncOutcome.busy);
    }
    // Own the batch before the first async quota read. Concurrent incoming files
    // request one follow-up snapshot instead of starting overlapping uploads.
    _syncing = true;
    try {
      return await _syncPendingBatch(
        reason: reason,
        ignoreQuotaPause: ignoreQuotaPause,
        ignoreOversizedPause: ignoreOversizedPause,
      );
    } finally {
      _syncing = false;
      if (_syncAgain) {
        final forceQuota = _repeatIgnoreQuota;
        final forceOversized = _repeatIgnoreOversized;
        _syncAgain = _repeatIgnoreQuota = _repeatIgnoreOversized = false;
        unawaited(syncPending(
          reason: 'queued sync trigger',
          ignoreQuotaPause: forceQuota,
          ignoreOversizedPause: forceOversized,
        ));
      }
    }
  }

  Future<WatchSyncResult> _syncPendingBatch({
    required String reason,
    required bool ignoreQuotaPause,
    required bool ignoreOversizedPause,
  }) async {
    // ⚠️ 没登录就不要试。`uploadAudioForConversation` 会照样发出去、拿 401、返回 null，
    // 而 null 的处理是「保留文件、下次重试」—— 表现上跟网络故障一模一样，日志里也是同一句。
    // 冷启动时 App 常常先于鉴权就绪，所以这一条不是理论情况。
    if (_authHeader().isEmpty || _account().isEmpty) {
      debugPrint('[Watch] not authenticated yet, keeping queue for later ($reason)');
      const result = WatchSyncResult(WatchSyncOutcome.notAuthenticated);
      // 鉴权只是「还没就绪」，不是「不会就绪」—— 自己排下一轮，别把这次机会浪费掉。
      _scheduleRetry(result);
      return result;
    }
    final quotaPauseUntil = await _quotaPauseUntil();
    if (!ignoreQuotaPause && quotaPauseUntil?.isAfter(DateTime.now().toUtc()) == true) {
      try {
        final raw = await _channel.invokeListMethod<dynamic>('getPendingRecordings') ?? [];
        if (raw.isEmpty) return const WatchSyncResult(WatchSyncOutcome.empty);
        final remaining = quotaPauseUntil!.difference(DateTime.now().toUtc()) + const Duration(seconds: 5);
        _scheduleQuotaRecheck(delay: remaining);
        debugPrint('[Watch] cloud quota paused until $quotaPauseUntil, keeping queue ($reason)');
        return WatchSyncResult(WatchSyncOutcome.quotaBlocked, quotaBlocked: raw.length);
      } catch (e) {
        debugPrint('[Watch] could not inspect paused queue: $e');
        const result = WatchSyncResult(WatchSyncOutcome.retryable, retryable: 1);
        _scheduleRetry(result);
        return result;
      }
    }
    debugPrint('[Watch] syncPending start ($reason)');
    var uploaded = 0;
    var rejected = 0;
    var retryable = 0;
    var quotaBlocked = 0;
    var allowanceExhausted = false;
    try {
      final preparationFailures = (await _channel.invokeListMethod<String>('prepareLongRecordings') ?? []).toSet();
      final raw = await _channel.invokeListMethod<dynamic>('getPendingRecordings') ?? [];
      final oversizedItems = await _pausedOversizedItems();
      for (final entry in raw) {
        // 原生侧已经把「文件名里没有时间锚点」的过滤掉了，这里再挡一次：没有锚点
        // 就上传等于把整段录音落在错误的日期上，而后端不会报错（它只会拒绝缺参数）。
        final parsed = _parseNativeItem(entry);
        if (parsed == null) continue;
        final uploadAccount = _account();
        if (parsed.accountId != null && parsed.accountId != uploadAccount) {
          retryable++;
          continue; // Keep the original for its recording account; never upload it to a different user.
        }
        final path = parsed.path;
        final file = File(path);
        if (!file.existsSync()) continue;
        final preparingItem = _items.putIfAbsent(parsed.key, () => parsed)..duration ??= parsed.duration;
        preparingItem.preparationFailed = preparationFailures.contains(path);
        if (preparingItem.preparationFailed) {
          retryable++;
          _setItemState(preparingItem, WatchItemState.waiting);
          continue; // Keep this source, but upload the other prepared recordings.
        }

        // The backend already decoded this file and confirmed that this specific
        // recording is larger than the remaining monthly allowance. Do not send
        // the same multi-MB body on every foreground transition. Other (shorter)
        // recordings still continue through the queue, and a purchase-triggered
        // force sync deliberately bypasses this marker.
        if (!ignoreOversizedPause && oversizedItems.contains(parsed.key)) {
          final item = _items.putIfAbsent(parsed.key, () => parsed)..duration ??= parsed.duration;
          quotaBlocked++;
          _setItemState(item, WatchItemState.waiting, statusCode: 429);
          continue;
        }

        // 同一段录音可能在上一轮就登记过了（重试）—— 复用那条，别新建一条重复显示。
        final item = _items.putIfAbsent(parsed.key, () => parsed)..duration ??= parsed.duration;
        _setItemState(item, WatchItemState.uploading);

        try {
          int? failureCode;
          var monthlyQuotaExceeded = false;
          var monthlyUploadTooLarge = false;
          final resp = await (_uploadOverride?.call(parsed, (code, body) {
                failureCode = code;
                monthlyQuotaExceeded = isMonthlyQuotaResponse(code, body);
                monthlyUploadTooLarge = isMonthlyUploadTooLargeResponse(code, body);
              }) ??
              uploadAudioForConversation(
                audioFile: file,
                startedAt: parsed.startedAt,
                // 手表端录的是 AAC，语言让后端自动判（Soniox 支持中英混说）。
                // ⚠️ 这里曾经传 `'multi'` —— 那是**实时**链路的 Soniox 模型名，不是语言码，
                // 离线 API 直接 400 → 后端映射成 502 → 无限重试 →「同步失败」。详见
                // `uploadAudioForConversation` 的 `language` 注释。
                language: 'auto',
                // 🚨 **这个 true 不是「顺便留一份音频」，它是 `is_user` 的前提。**
                // 声纹匹配要从 GCS 把录音取回来才能分辨佩戴者的声音；不存音频，这条链路上
                // `is_user` 结构上永远是 false，于是摘要从旁人视角写、待办被门禁清空、
                // discard 判据也把「没有 User 标签」当成媒体播放的证据 —— 2026-08-15 十三段
                // 手表录音有十一段就是这么被丢掉的（含一段 39 分钟的家庭对话）。
                // 后端默认 false 是为了不让第三方上传悄悄开始留存音频，所以必须由我们显式传。
                saveRecording: true,
                // 🚨 **验完就返回，转录和摘要在服务端后台跑。** 这个端点原来是同步的：
                // 2026-08-16 实测 p50 69.3s、25 次里 4 次跑满 600s 被砍成 504，而队列串行、
                // `syncNow` 每次回前台都触发 ⇒ 用户报的「同步转很久」就是这条。
                // ⚠️ **504 之前不是白重试而是「白等」**：被放弃的那个请求照样跑完并写了对话，
                // 下一次重试拿到 `200 already processed`（幂等段）—— 那十分钟纯属干等。
                // 依赖上面那行 `saveRecording: true`（后端不认没有云端副本的提前返回），
                // 两行是一体的，别只留一行。
                deferProcessing: true,
                allowShortRecording: true,
                // Backend job identity survives a crash or journal failure after upload acceptance.
                recordingKey: parsed.recordingMetadata == null ? null : 'watch-${parsed.key}',
                onHttpError: (code, body) {
                  failureCode = code;
                  monthlyQuotaExceeded = isMonthlyQuotaResponse(code, body);
                  monthlyUploadTooLarge = isMonthlyUploadTooLargeResponse(code, body);
                },
              ));
          if (_account() != uploadAccount) {
            throw StateError('Watch upload account changed; original retained');
          }
          if (resp != null) {
            // The bookmark processing journal must be durable before deleting phone audio.
            await _moments.registerUpload(parsed.key, parsed.recordingMetadata, resp, accountId: uploadAccount);
            // ⚠️ 只有确认成功才让原生删文件。失败必须留着 —— 删掉就是永久丢录音。
            final removed = await _channel.invokeMethod<bool>('markUploaded', {'path': path});
            uploaded++;
            // 走的是哪条路只能问后端要 `status`，不能从我们传了 `deferProcessing: true`
            // 去推断 —— 后端在 `save_recording=false` 或 GCS 落盘失败时会**静默降级成同步**，
            // 那时返回里是有完整转录稿的。老后端不认这个参数，也落在这一支（`created`）。
            _setItemState(
              item,
              resp.status == 'processing' ? WatchItemState.uploaded : WatchItemState.processed,
              conversationId: resp.conversationId,
            );
            if (removed != true) {
              // 上传本身是成功的（所以照样计数），只是原生没能把文件删掉。原生侧**先**把它
              // 记进 `handledNames` 才去删，所以 `getPendingRecordings` 下次会跳过它并再试
              // 删一次 —— 不会重复上传。这行日志是这条路径唯一的痕迹。
              debugPrint('[Watch] uploaded but file not deleted: $path (native marked it handled)');
            }
          } else if (monthlyQuotaExceeded) {
            // Keep the only local copy and wait for the UTC month boundary.
            // A successful purchase clears this pause and retries immediately.
            final pauseUntil = await _pauseQuotaUntilNextMonth();
            _scheduleQuotaRecheck(
              delay: pauseUntil.difference(DateTime.now().toUtc()) + const Duration(seconds: 5),
            );
            quotaBlocked++;
            allowanceExhausted = true;
            _setItemState(item, WatchItemState.waiting, statusCode: failureCode);
            break;
          } else if (monthlyUploadTooLarge) {
            // This file does not fit in the remaining allowance, but a later
            // shorter recording still might. Keep it and continue the queue.
            // Persist the filename so foreground syncs do not upload the same
            // large audio body again before the UTC month boundary.
            oversizedItems.add(parsed.key);
            await _pauseOversizedItemUntilNextMonth(parsed.key);
            quotaBlocked++;
            _setItemState(item, WatchItemState.waiting, statusCode: failureCode);
            continue;
          } else if (failureCode != null && _isPermanentRejection(failureCode!)) {
            // 后端永久拒绝：重传一万次也还是这个结果。留在队列里的代价不只是 UI 一直显示
            // 「待上传」—— 每次冷启动和回前台都会真的再传一遍，而离线转录吃的是**账号级、
            // 与实时转录链路共享**的 Soniox 额度。
            //
            // 移出队列但**不删文件**（原生侧搬到 `rejected/`）：这种 400 也可能来自我们
            // 自己（比如哪天把 `started_at` 拼错了），那时会是**所有**文件一起被拒 ——
            // 删掉就是把用户的录音全丢了，而搬走还能捞回来。
            debugPrint('[Watch] permanently rejected ($failureCode) for $path, moving out of queue');
            await _moments.registerFailure(parsed.key, parsed.recordingMetadata, accountId: uploadAccount);
            await _channel.invokeMethod('markRejected', {'path': path, 'statusCode': failureCode});
            rejected++;
            _setItemState(item, WatchItemState.rejected, statusCode: failureCode);
          } else {
            debugPrint('[Watch] upload returned null for $path (code=$failureCode), keeping file');
            retryable++;
            _setItemState(item, WatchItemState.waiting, statusCode: failureCode);
          }
        } catch (e) {
          // 单条失败不影响后面几条；文件留在队列里下次再试。
          debugPrint('[Watch] upload failed for $path: $e');
          retryable++;
          _setItemState(item, WatchItemState.waiting);
        }
      }
    } catch (e) {
      debugPrint('[Watch] syncPending failed: $e');
      retryable++;
    } finally {
      _pruneItems();
      onItemsChanged?.call();
    }

    final WatchSyncOutcome outcome;
    if (uploaded > 0) {
      outcome = WatchSyncOutcome.uploaded;
    } else if (allowanceExhausted) {
      outcome = WatchSyncOutcome.quotaBlocked;
    } else if (retryable > 0) {
      outcome = WatchSyncOutcome.retryable;
    } else if (quotaBlocked > 0) {
      outcome = WatchSyncOutcome.uploadTooLarge;
    } else if (rejected > 0) {
      outcome = WatchSyncOutcome.rejected;
    } else {
      outcome = WatchSyncOutcome.empty;
    }
    final result = WatchSyncResult(
      outcome,
      uploaded: uploaded,
      rejected: rejected,
      retryable: retryable,
      quotaBlocked: quotaBlocked,
    );
    debugPrint('[Watch] syncPending done ($reason): $result');

    // 真正耗尽的分支已持久化并排好月初复查；单文件放不下只排一次非持久月初复查。
    if (retryable > 0) {
      // Scheduling follows the counters, not the display outcome: a partial
      // success is still shown as uploaded while its failed sibling retries.
      _scheduleRetry(result);
    } else {
      _retryAttempt = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    if (allowanceExhausted) {
      // Scheduled where the persistent exhaustion boundary was written. This
      // also covers a partially successful batch whose outcome is `uploaded`.
    } else if (quotaBlocked > 0) {
      final nextMonth = _nextUtcMonth(DateTime.now().toUtc());
      _scheduleQuotaRecheck(delay: nextMonth.difference(DateTime.now().toUtc()) + const Duration(seconds: 5));
    } else if (retryable == 0) {
      _quotaTimer?.cancel();
      _quotaTimer = null;
    }
    if (uploaded > 0 && !allowanceExhausted) await _clearExhaustionPause();
    if (uploaded > 0 || rejected > 0) onQueueChanged?.call();
    unawaited(_moments.refresh());

    return result;
  }

  /// 这个状态码是否意味着「这个文件永远不会被接受」。
  ///
  /// ⚠️ **401/403/409/5xx 刻意不在里面。** 它们都是会自己好的：key 会自愈换发、限流会
  /// 过去、服务端会恢复。月度额度的 429 在上游按稳定错误码单独处理：文件仍留在队列，
  /// 自动重试暂停到下一个 UTC 月初；其他短时 429 仍走普通重试。
  ///
  /// 409 是「后端已经在转录同一个时间锚点了」（`audio_upload.py` 的幂等段）—— 重试**必须**
  /// 发生，而且下一次重试大概率直接拿到 200：那一次转录落库之后，查重会把已存的对话回给
  /// 我们。退避总预算约 14 分钟，长于实测最慢的一次转录（~4 分钟）。
  ///
  /// 401 尤其要小心：本仓库的 bound key 在第二台设备登录时会被硬删，App 有 401 自愈，
  /// 所以 401 之后重试是**正确**的（`syncPending` 开头还额外挡了未登录）。
  static bool _isPermanentRejection(int code) {
    // 400 音频校验不过（时长 <5s / >7200s、格式不对、VAD 判定无人说话）
    // 413 文件太大  415 媒体类型不支持  422 参数校验不过
    return code == 400 || code == 413 || code == 415 || code == 422;
  }

  @visibleForTesting
  static bool isMonthlyQuotaResponse(int statusCode, String body) {
    if (statusCode != 429) return false;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['detail'] is Map && (decoded['detail'] as Map)['code'] == _monthlyQuotaErrorCode;
    } on FormatException {
      return false;
    }
  }

  @visibleForTesting
  static bool isMonthlyUploadTooLargeResponse(int statusCode, String body) {
    if (statusCode != 429) return false;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map &&
          decoded['detail'] is Map &&
          (decoded['detail'] as Map)['code'] == _monthlyUploadTooLargeErrorCode;
    } on FormatException {
      return false;
    }
  }

  String get _quotaPauseKey => '$_quotaPausePrefix${_account()}';
  String get _oversizedItemsKey => '$_oversizedItemsPrefix${_account()}';

  Future<DateTime?> _quotaPauseUntil() async {
    final milliseconds = (await SharedPreferences.getInstance()).getInt(_quotaPauseKey);
    return milliseconds == null ? null : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  Future<DateTime> _pauseQuotaUntilNextMonth() async {
    final now = DateTime.now().toUtc();
    final nextMonth = _nextUtcMonth(now);
    await (await SharedPreferences.getInstance()).setInt(
      _quotaPauseKey,
      nextMonth.millisecondsSinceEpoch,
    );
    return nextMonth;
  }

  Future<Set<String>> _pausedOversizedItems() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_oversizedItemsKey);
    if (raw == null) return <String>{};
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      await prefs.remove(_oversizedItemsKey);
      return <String>{};
    }
    if (decoded is! Map) {
      await prefs.remove(_oversizedItemsKey);
      return <String>{};
    }
    final active = <String, int>{};
    for (final entry in decoded.entries) {
      final untilMs = entry.value;
      if (entry.key is String && untilMs is int && untilMs > nowMs) {
        active[entry.key as String] = untilMs;
      }
    }
    if (active.isEmpty) {
      await prefs.remove(_oversizedItemsKey);
    } else if (active.length != decoded.length) {
      await prefs.setString(_oversizedItemsKey, jsonEncode(active));
    }
    return active.keys.toSet();
  }

  Future<void> _pauseOversizedItemUntilNextMonth(String item) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_oversizedItemsKey);
    final stored = <String, dynamic>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is int) stored[entry.key as String] = entry.value;
          }
        }
      } on FormatException {
        // Replace corrupt local bookkeeping. The recording itself remains in
        // the native queue and is never deleted by this recovery path.
      }
    }
    stored[item] = _nextUtcMonth(DateTime.now().toUtc()).millisecondsSinceEpoch;
    await prefs.setString(_oversizedItemsKey, jsonEncode(stored));
  }

  static DateTime _nextUtcMonth(DateTime now) =>
      now.month == 12 ? DateTime.utc(now.year + 1) : DateTime.utc(now.year, now.month + 1);

  Future<void> _clearExhaustionPause() async {
    await (await SharedPreferences.getInstance()).remove(_quotaPauseKey);
  }

  Future<void> clearQuotaPause() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_quotaPauseKey);
    await prefs.remove(_oversizedItemsKey);
  }

  /// 删掉所有被后端永久拒绝的录音，返回真删掉的条数。
  ///
  /// ⚠️ **不可恢复，所以调用方必须先跟用户确认。** 手表侧的原件在回执之后就删了，
  /// `rejected/` 里那一份是唯一的一份 —— 后端搬而不删就是为了留这个后悔的机会
  /// （那种 400 也可能来自我们自己）。
  Future<int> clearRejected() async {
    if (!_isIOS()) return 0;
    try {
      final deleted = await _channel.invokeMethod<int>('clearRejected') ?? 0;
      if (deleted > 0) {
        // 展示层跟着清 —— 磁盘上都没了，列表里还留着「无法转录」那几行就是在说谎。
        _items.removeWhere((_, item) => item.state == WatchItemState.rejected);
        onItemsChanged?.call();
        onQueueChanged?.call();
      }
      return deleted;
    } catch (e) {
      debugPrint('[Watch] clearRejected failed: $e');
      return 0;
    }
  }

  /// 把 App 里的手动语言开关下发给手表。
  ///
  /// 手表读不到 `LocaleProvider` —— 它是另一台设备上的独立进程，而系统语言看不出用户
  /// 在 App 里手动选过中/英。见 `ios/MemorionWatch/WatchText.swift`。
  Future<void> syncLocale(String code) async {
    if (!_isIOS()) return;
    try {
      await _channel.invokeMethod('syncLocale', {'code': code});
    } catch (e) {
      debugPrint('[Watch] syncLocale failed: $e');
    }
  }
}

/// 一次 `syncPending()` 的结果分类。
///
/// ⚠️ **这几个值刻意分得这么细，因为它们对用户意味着完全不同的事。** 以前 `syncPending`
/// 只返回条数，前四种全都是 0，设置页于是把它们一律显示成「同步失败，稍后会自动重试」——
/// 其中「已经在传了」和「本来就没有」都不是失败，而「还没登录」的下一步动作也不一样。
enum WatchSyncOutcome {
  /// 非 iOS 平台。
  unsupported,

  /// 已经有一轮在跑（并发调用）。**不是失败**，那一轮会把活干完。
  busy,

  /// 鉴权还没就绪（多见于冷启动）。会自动排下一轮。
  notAuthenticated,

  /// 队列本来就是空的。**不是失败**。
  empty,

  /// 至少成功传了一条。
  uploaded,

  /// 有条目失败但可恢复（网络、5xx、短时限流）。会自动排下一轮。
  retryable,

  /// 本月云端额度已用完。文件保留，下月或升级 Pro 后再传。
  quotaBlocked,

  /// 至少一条录音超过本月剩余额度，但较短的录音仍可能继续上传。
  uploadTooLarge,

  /// 有条目被后端永久拒绝、已搬出队列（见 `_isPermanentRejection`）。重试没有意义。
  rejected,
}

/// 单段录音在同步链路上的位置。
enum WatchItemState {
  /// 已经在手机上、还没上传（或上一次可恢复地失败了，等自动重试）。
  waiting,

  /// 正在上传。
  ///
  /// 手表这条路现在传 `deferProcessing: true`，所以这个状态**只是网络上传**，几秒的事。
  /// ⚠️ 但它也覆盖后端**降级成同步**的那种情形（`save_recording=false` 或 GCS 落盘失败），
  /// 那时同一个请求里还要做完 Soniox 转录 + LLM 摘要 —— 2026-08-16 实测 p50 69.3s。
  /// 所以文案不能承诺「马上就好」。两种情形在请求返回之前分不出来，返回后看 `status`。
  uploading,

  /// 后端收下了音频并已存进云端，转录和摘要在服务端后台跑（`status == 'processing'`）。
  ///
  /// ⚠️ **这不等于「已转录」，也不等于「一定会成功」。** 文案刻意只说「已上传」：
  /// 后台可能因为 VAD 判定没有人说话、或 Soniox 故障而产不出对话，而客户端**收不到任何
  /// 通知** —— 那些失败只在后端日志里（对应的音频在 GCS 上，可以重跑）。写成「正在转录…」
  /// 之类的话则会**随时间腐坏**：两分钟后转录早就完事了，那行字还挂在那里。
  uploaded,

  /// 后端在同一个请求里转录 + 生成摘要完了，对话已经在时间线上（同步路径 / 老后端）。
  processed,

  /// 后端永久拒绝（太短 / 没检测到人说话 / 格式不对），已搬出重传队列。
  rejected;

  /// 是否不会再变了。`waiting` 不算终局 —— 它还等着重试。
  ///
  /// `uploaded` 算终局：文件已经不在手机上了，这条队列不会再碰它。后台转录的结果由时间线
  /// 呈现，不回到这个列表里 —— 所以别指望它有一天变成 `processed`。
  bool get isFinal =>
      this == WatchItemState.uploaded || this == WatchItemState.processed || this == WatchItemState.rejected;
}

/// 一段手表录音的同步进度。**可变**，由 `WatchRecordingService` 原地改状态。
class WatchSyncItem {
  /// The original is retained while native clip export waits for a retry.
  bool preparationFailed = false;
  final String? recordingMetadata;
  final String? accountId;

  /// 手机侧的完整路径。上传和 `markUploaded` 都要它。
  final String path;

  /// 按下录音的那一刻（来自文件名里的 epoch 毫秒锚点）。**不是**收到或上传的时刻。
  final DateTime startedAt;

  /// 音频时长。`null` 表示原生没解出来（展示成「--」），**不是 0 秒**。
  Duration? duration;

  WatchItemState state;

  /// 处理完成后后端给的对话 id。
  String? conversationId;

  /// 最近一次失败的 HTTP 状态码，用于区分「被拒」和「网络不好」。
  int? statusCode;

  WatchSyncItem({
    required this.path,
    required this.startedAt,
    this.duration,
    this.state = WatchItemState.waiting,
    this.conversationId,
    this.statusCode,
    this.recordingMetadata,
    this.accountId,
  });

  /// 身份用文件名，不用完整路径 —— 路径里含 App 容器 UUID，重装后同一段录音路径会变。
  String get key => path.split('/').last;
}

class WatchSyncResult {
  final WatchSyncOutcome outcome;
  final int uploaded;
  final int rejected;
  final int retryable;
  final int quotaBlocked;

  const WatchSyncResult(
    this.outcome, {
    this.uploaded = 0,
    this.rejected = 0,
    this.retryable = 0,
    this.quotaBlocked = 0,
  });

  @override
  String toString() => 'WatchSyncResult(${outcome.name}, uploaded=$uploaded, rejected=$rejected, '
      'retryable=$retryable, quotaBlocked=$quotaBlocked)';
}

/// 手表连接状态的快照。
class WatchStatus {
  final bool supported;

  /// `WCSession` 是否已经激活完成。
  ///
  /// ⚠️ **没激活时 `paired` / `appInstalled` 恒为 false，那不是结论、只是「还没查出来」。**
  /// 激活是异步的（`AppDelegate` 里发起），用户在冷启动后几百毫秒内点进设置页就会撞上。
  /// UI 必须把这种情况显示成「正在检查」，否则就是在让用户去配一块已经配好的表。
  final bool activated;
  final bool paired;
  final bool appInstalled;
  final bool reachable;
  final int pendingCount;

  /// 后端永久拒绝、已搬出重传队列的条数（见 `_isPermanentRejection`）。
  ///
  /// ⚠️ **UI 必须显示它。** 搬走之后 `pendingCount` 就归零了，只看那一个数会说
  /// 「全部已同步」—— 而那段录音一条对话都没生成。
  final int rejectedCount;

  const WatchStatus({
    required this.supported,
    required this.activated,
    required this.paired,
    required this.appInstalled,
    required this.reachable,
    required this.pendingCount,
    required this.rejectedCount,
  });

  const WatchStatus.unsupported()
      : supported = false,
        activated = false,
        paired = false,
        appInstalled = false,
        reachable = false,
        pendingCount = 0,
        rejectedCount = 0;

  /// 能不能用手表录音。**刻意不看 `reachable`** —— 手表不在身边照样能录，
  /// 录完的文件由系统排队，等两边再次靠近时自动送达。
  ///
  /// `activated` 不用单独判：没激活时 `paired` / `appInstalled` 本来就是 false。
  bool get usable => supported && paired && appInstalled;
}
