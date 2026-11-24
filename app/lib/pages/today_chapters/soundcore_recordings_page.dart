import 'package:provider/provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'dart:async';
import 'recorder_widgets.dart';
import 'widgets/swipe_action_row.dart';
import 'package:memorion/pages/today_chapters/audio_jobs_page.dart';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/services/devices/soundcore/import_store.dart';
import 'package:memorion/services/devices/soundcore/protocol.dart';
import 'package:memorion/services/devices/soundcore/protocol_error.dart';
import 'package:memorion/services/devices/soundcore/sync_controller.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

class SoundcoreRecordingsPage extends StatefulWidget {
  final BtDevice device;
  final SoundcoreSyncController? controller;
  const SoundcoreRecordingsPage({super.key, required this.device, this.controller});

  @override
  State<SoundcoreRecordingsPage> createState() => _SoundcoreRecordingsPageState();
}

class _SoundcoreRecordingsPageState extends State<SoundcoreRecordingsPage> with WidgetsBindingObserver {
  late final SoundcoreSyncController _sync;
  bool _confirmingWifi = false;
  Timer? _processingTimer;
  bool _foreground = true;
  static const _pageSize = 20;
  final _scrollController = ScrollController();
  int _page = 0;
  int? _openRecordingId;
  Completer<void>? _refreshWaiter;
  int get _lastPage => _recordings.isEmpty ? 0 : (_recordings.length - 1) ~/ _pageSize;
  List<SoundcoreRecording> get _recordings => _sync.recordings.where((r) => !_sync.isRemoving(r.id)).toList();
  Map<int, SoundcoreImportStage> get _stages => _sync.stages;
  Map<int, SoundcoreRecordingDetails> get _details => _sync.details;
  bool get _loading => _sync.loading;
  int? get _activeId => _sync.activeId;
  int get _bytes => _sync.bytes;
  DateTime? get _lastRefresh => _sync.lastRefresh;
  int? get _deviceFileCount => _sync.deviceFileCount;
  int? get _recordStatus => _sync.recordStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync = widget.controller ?? ServiceManager.instance().soundcoreSync.controllerFor(widget.device);
    _sync.addListener(_updated);
    unawaited(_sync.sync().then((_) async {
      if (mounted && _foreground) await _sync.refreshProcessing(includeTerminal: true);
    }));
    _processingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _foreground && ModalRoute.of(context)?.isCurrent != false) {
        unawaited(_sync.refreshProcessing());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && mounted && ModalRoute.of(context)?.isCurrent != false) {
      unawaited(_sync.refreshProcessing(includeTerminal: true));
    }
  }

  void _updated() {
    if (mounted) {
      setState(() {
        _page = _page.clamp(0, _lastPage);
        if (_openRecordingId != null && !_sync.canRemove(_openRecordingId!)) _openRecordingId = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _processingTimer?.cancel();
    _sync.removeListener(_updated);
    _scrollController.dispose();
    if (_refreshWaiter?.isCompleted == false) _refreshWaiter!.complete();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshWaiter != null) return;
    setState(() => _page = 0);
    if (_scrollController.hasClients && _scrollController.offset > 0) _scrollController.jumpTo(0);
    if (_sync.busy || _loading || _sync.wifiState != null) {
      unawaited(_sync.sync());
      // i18n-ignore: English and Chinese copy supplied together through revampText.
      UndoDeleteHost.showMessage(context, revampText(context,
            en: 'Refresh queued. The list will update after the current sync finishes.', zh: '刷新已排队，当前同步完成后会更新文件列表。'));
      return;
    }
    // Sync owns the whole transfer queue. The pull indicator only waits for
    // discovery, so downloading a large recording does not keep it spinning.
    final previousRefresh = _lastRefresh;
    final waiter = _refreshWaiter = Completer<void>();
    var reading = false;
    void listed() {
      if (_loading) reading = true;
      if ((_lastRefresh != previousRefresh || (reading && !_loading)) && !waiter.isCompleted) waiter.complete();
    }

    _sync.addListener(listed);
    unawaited(_sync.sync().then((_) {
      if (!waiter.isCompleted) waiter.complete();
    }, onError: (Object error, StackTrace stack) {
      if (!waiter.isCompleted) waiter.completeError(error, stack);
    }));
    try {
      await waiter.future;
      if (mounted) unawaited(_sync.refreshProcessing(includeTerminal: true));
    } catch (error) {
      if (mounted) UndoDeleteHost.showMessage(context, _readError(error));
    } finally {
      _sync.removeListener(listed);
      _refreshWaiter = null;
    }
  }

  void _changePage(int page) {
    setState(() {
      _page = page.clamp(0, _lastPage);
      _openRecordingId = null;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Widget _pagination() => RecorderPagination(
        keyPrefix: 'soundcore',
        page: _page,
        count: _recordings.length,
        pageSize: _pageSize,
        onChanged: _changePage,
      );

  Future<void> _confirmWifiTransfer() async {
    if (_confirmingWifi || _sync.wifiState != null || _recordStatus == 1 || _recordStatus == 2) return;
    setState(() => _confirmingWifi = true);
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('soundcore_wifi_confirmation'),
          backgroundColor: JXB.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          scrollable: true,
          title: Text(revampText(dialogContext, en: 'Switch to recorder Wi-Fi?', zh: '切换到录音豆 Wi-Fi？')),
          content: Text(
            revampText(
              dialogContext,
              en: 'Your phone will temporarily leave its current Wi-Fi network and join the recorder’s hotspot, which has no internet access. Online services may be interrupted.\n\nAny Bluetooth download will stop immediately. That file will restart over Wi-Fi; completed downloads are kept. After leaving the hotspot, uploads resume when internet access returns. Cancel to keep syncing over Bluetooth.',
              zh: '手机会暂时断开当前 Wi-Fi，连接录音豆的热点。该热点无法上网，期间网络访问可能中断。\n\n正在进行的蓝牙下载会立即停止，当前文件改用 Wi-Fi 从头下载，已完整下载的文件会保留。退出热点并恢复网络后自动上传转录。取消则继续使用蓝牙同步。',
            ),
            style: JXB.bodySmall.copyWith(color: JXB.textSecondary),
          ),
          actions: [
            TextButton(
              key: const ValueKey('soundcore_wifi_cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(revampText(dialogContext, en: 'Cancel', zh: '取消')),
            ),
            TextButton(
              key: const ValueKey('soundcore_wifi_confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(revampText(dialogContext, en: 'Switch to Wi-Fi', zh: '确认切换')),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _confirmingWifi = false);
    }
    // Dismissing the dialog or leaving the page never requests a network change.
    if (!mounted || confirmed != true || _recordStatus == 1 || _recordStatus == 2) return;
    await _sync.syncOverWifi();
  }

  String _readError(Object error) {
    if (error is TimeoutException) {
      return revampText(context,
          en: 'The recorder did not answer in time. Wake it or reconnect; sync will retry automatically.',
          zh: '录音豆响应超时。请唤醒设备或重新连接，同步会自动重试。');
    }
    if (error is FormatException) {
      return revampText(context,
          en: 'The recorder returned an unsupported format. Copy the connection diagnostics to help investigate.',
          zh: '录音豆返回的格式暂不支持。可复制连接诊断帮助排查。');
    }
    return revampText(
      context,
      en: 'Could not read the recorder. Reconnect SOUNDCORE to resume sync.',
      zh: '未能读取录音豆，请重新连接 SOUNDCORE 以继续同步。',
    );
  }

  String _importError(Object error) {
    if (error is SoundcoreImportException) {
      final issue = error.failure?.issue ?? AudioUploadFailure.http(error.statusCode ?? 0, '').issue;
      if (error.statusCode == 400 && issue == AudioUploadIssue.unknown) {
        return revampText(context,
            en: 'The server rejected this recording (HTTP 400). The original is saved.',
            zh: '服务器拒绝了这段录音（HTTP 400），原录音已保留。');
      }
      final message = switch (issue) {
        AudioUploadIssue.inFlight => revampText(context,
            en: 'The server is already processing this recording. It will be checked again automatically (HTTP 409).',
            zh: '服务器正在处理这段录音，稍后会自动重试确认（HTTP 409）。'),
        AudioUploadIssue.server => revampText(context,
            en: 'The server could not finish this request (HTTP ${error.statusCode}). Audio is saved; retrying later.',
            zh: '服务器暂时未能完成请求（HTTP ${error.statusCode}）。录音已保留，稍后自动重试。'),
        AudioUploadIssue.timeout => revampText(context,
            en: 'Upload timed out. Audio is saved; check your internet connection and retry.',
            zh: '上传或等待服务器响应超时。录音已保留，请检查网络后重试。'),
        AudioUploadIssue.network => revampText(context,
            en: 'Network connection failed. Leave recorder Wi-Fi and reconnect to the internet; audio is saved.',
            zh: '网络连接失败。请退出录音豆 Wi-Fi 并恢复联网，录音已保留。'),
        AudioUploadIssue.auth =>
          revampText(context, en: 'Sign in again to resume uploads. Audio is saved.', zh: '请重新登录以继续上传，录音已保留。'),
        AudioUploadIssue.quota => revampText(context,
            en: 'The server is limiting uploads or the account has insufficient quota. Audio is saved.',
            zh: '服务器限制了请求，或账户额度不足。录音已保留。'),
        AudioUploadIssue.tooLarge => revampText(context,
            en: 'The server rejected this file as too large (HTTP 413). Audio is saved.',
            zh: '服务器拒绝了过大的文件（HTTP 413），录音已保留。'),
        AudioUploadIssue.duration when error.failure?.errorCode == SoundcoreImportException.durationTooShort =>
          revampText(context,
              en: 'Shorter than 5 seconds; not uploaded. Original audio is saved.', zh: '录音不足 5 秒，未上传。原录音已保留。'),
        AudioUploadIssue.duration when error.failure?.errorCode == SoundcoreImportException.durationTooLong =>
          revampText(context,
              en: 'Longer than 8 hours; not uploaded. Original audio is saved.', zh: '录音超过 8 小时，未上传。原录音已保留。'),
        AudioUploadIssue.duration when error.failure?.errorCode == SoundcoreImportException.durationEstimateTooLong =>
          revampText(context,
              en: 'Estimated over 8 hours; skipped. The original remains on the recorder. Retry to check its actual length.',
              zh: '预计超过 8 小时，已跳过，原录音仍在录音豆上。可点重试核实实际时长。'),
        AudioUploadIssue.duration => revampText(context,
            en: 'Transcription supports recordings from 5 seconds to 8 hours. Audio is saved.',
            zh: '转录支持 5 秒至 8 小时的录音，原录音已保留。'),
        // i18n-ignore: English and Chinese copy provided together through revampText.
        AudioUploadIssue.format => revampText(context,
            en: 'The server could not decode this audio. The original is saved.', zh: '服务器无法解码此音频，原录音已保留。'),
        AudioUploadIssue.noSpeech => revampText(context,
            en: 'The server detected no clear speech. The original is saved.', zh: '服务器未检测到清晰人声，原录音已保留。'),
        AudioUploadIssue.invalidResponse => revampText(context,
            en: 'The server returned an invalid response. Audio is saved; retrying later.',
            zh: '服务器返回内容异常。录音已保留，稍后自动重试。'),
        AudioUploadIssue.unknown => revampText(context,
            en: 'Upload failed${error.statusCode == null ? '' : ' (HTTP ${error.statusCode})'}. Audio is saved; retrying later.',
            zh: '上传失败${error.statusCode == null ? '' : '（HTTP ${error.statusCode}）'}。录音已保留，稍后自动重试。'),
      };
      return message;
    }
    return revampText(context,
        en: 'Download incomplete. Reconnect to resume sync; the original audio is kept.',
        zh: '下载未完成，请重新连接后继续同步，原录音已保留。');
  }

  Future<void> _copyDiagnostics() async {
    final text = _sync.diagnostics;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    UndoDeleteHost.showMessage(context, revampText(context, en: 'Connection diagnostics copied', zh: '已复制连接诊断'));
  }

  String _durationLabel(SoundcoreRecording recording) {
    final measured = _details[recording.id]?.duration;
    return recorderDurationLabel(context, measured ?? recording.estimatedDuration, estimated: measured == null);
  }

  String? _sizeLabel(SoundcoreRecording recording) {
    final size = _details[recording.id]?.sizeBytes;
    if (size == null) return null;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _waitingLabel(int id) => switch (_sync.waitReason(id)) {
        SoundcoreSyncWaitReason.signIn => revampText(context, en: 'Sign in to sync', zh: '请登录后同步'),
        SoundcoreSyncWaitReason.checkingCloud => revampText(context, en: 'Checking cloud status', zh: '正在核对云端状态'),
        SoundcoreSyncWaitReason.cloudCheckRequired => _sync.cloudLookupError == null
            ? revampText(context, en: 'Cloud status check required', zh: '待核对云端状态')
            // i18n-ignore: Both English and Chinese are provided through revampText.
            : revampText(context,
                en: 'Cloud status unavailable. Reconnect to the internet to check again.', zh: '暂时无法核对云端状态，联网后重试。'),
        SoundcoreSyncWaitReason.wifi =>
          revampText(context, en: 'Waiting for Wi-Fi transfer to finish', zh: '等待 Wi-Fi 传输结束并恢复网络'),
        SoundcoreSyncWaitReason.recording => revampText(context, en: 'Waiting for recording to end', zh: '等待设备结束录音'),
        SoundcoreSyncWaitReason.connection => revampText(context, en: 'Waiting for recorder connection', zh: '等待连接录音豆'),
        SoundcoreSyncWaitReason.retryDelay => revampText(context, en: 'Waiting to retry automatically', zh: '等待自动重试'),
        SoundcoreSyncWaitReason.queued => _sync.isSyncRequested(id)
            ? revampText(context, en: 'Sync requested · next in queue', zh: '已请求同步 · 优先排队')
            : _stageLabel(_stages[id]),
      };

  Future<void> _confirmDelete(SoundcoreRecording recording) async {
    if (!_sync.canRemove(recording.id)) return;
    final date = DateFormat('yyyy-MM-dd HH:mm:ss').format(recording.startedAt.toLocal());
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('soundcore_delete_confirmation'),
        backgroundColor: JXB.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        scrollable: true,
        title: Text(revampText(dialogContext, en: 'Delete this record?', zh: '删除这条记录？')),
        content: Text(revampText(dialogContext,
            en: 'Remove the recording from $date from this list and stop automatically syncing it from the recorder. The original on the recorder and any existing timeline content will be kept.',
            zh: '将 $date 的录音从此列表删除，并停止从录音豆自动同步这条录音。录音豆上的原文件和已生成的时间线内容会保留。')),
        actions: [
          TextButton(
            key: const ValueKey('soundcore_delete_cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(revampText(dialogContext, en: 'Cancel', zh: '取消')),
          ),
          TextButton(
            key: const ValueKey('soundcore_delete_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: JXB.error),
            child: Text(revampText(dialogContext, en: 'Delete', zh: '删除')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final undo = context.read<UndoDeleteController>();
    final sync = _sync;
    final page = _page;
    if (!sync.reserveRemoval(recording.id)) return;
    final added = undo.add(UndoDeletion(
      key: 'soundcore:${widget.device.id}:${recording.id}',
      kind: DeleteKind.recording,
      title: date,
      commit: () async {
        await sync.commitReservedRemoval(recording.id);
        return true;
      },
      cancel: () {
        sync.cancelRemoval(recording.id);
        if (mounted) setState(() => _page = page.clamp(0, _lastPage));
      },
    ));
    if (!added) sync.cancelRemoval(recording.id);
  }

  Widget _recordingRow(SoundcoreRecording recording) {
    final removing = _sync.isRemoving(recording.id);
    return SwipeActionRow(
      key: ValueKey('soundcore_swipe_${recording.id}'), // i18n-ignore: Widget identifier.
      open: _openRecordingId == recording.id,
      onOpenChanged: (open) => setState(() => _openRecordingId = open ? recording.id : null),
      actions: _sync.canRemove(recording.id)
          ? [
              SwipeAction(
                icon: Icons.delete_outline_rounded,
                iconColor: JXB.error,
                background: const Color(0xFFFAE3E3),
                semanticLabel: revampText(context, en: 'Delete', zh: '删除'),
                onTap: () => _confirmDelete(recording),
              ),
            ]
          : const [],
      child: AbsorbPointer(
        absorbing: removing,
        child: Opacity(opacity: removing ? 0.4 : 1, child: _recordingCard(recording)),
      ),
    );
  }

  Widget _recordingCard(SoundcoreRecording recording) {
    final stage = _stages[recording.id];
    final completed = stage == SoundcoreImportStage.uploaded || stage == SoundcoreImportStage.processed;
    final transferring = stage == SoundcoreImportStage.downloading || stage == SoundcoreImportStage.uploading;
    final failure = _sync.failures[recording.id];
    final job = _sync.processingJobs[recording.id];
    final retryLabel = revampText(context, en: 'Retry sync', zh: '重试同步');
    final requested = _sync.isSyncRequested(recording.id);
    final size = _sizeLabel(recording);
    return RecorderFileCard(
      key: ValueKey('soundcore_recording_${recording.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: RecorderFileHeading(
                  date: DateFormat('yyyy-MM-dd HH:mm:ss').format(recording.startedAt.toLocal()),
                  metadata: [_durationLabel(recording), if (size != null) size].join(' · '),
                  metadataKey: ValueKey('soundcore_metadata_${recording.id}'), // i18n-ignore: Widget identifier.
                  status: [
                    if (transferring) Text(_stageLabel(stage), style: JXB.caption.copyWith(color: JXB.brandPrimary)),
                    if (!completed && !transferring && failure == null)
                      Tooltip(
                        message: _waitingLabel(recording.id),
                        child: Text(_waitingLabel(recording.id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: JXB.caption.copyWith(color: JXB.textSecondary)),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: JXB.space2),
              if (completed || job != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Tooltip(
                    message: job != null ? audioJobLabel(context, job) : _stageLabel(stage),
                    child: Text(
                      job != null
                          ? audioJobLabel(context, job, compact: true)
                          : stage == SoundcoreImportStage.processed
                              ? revampText(context, en: 'Completed', zh: '已完成')
                              : revampText(context, en: 'Uploaded', zh: '已上传'),
                      key: ValueKey('soundcore_status_${recording.id}'), // i18n-ignore: Widget identifier.
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: JXB.caption.copyWith(color: job?.status == 'failed' ? Colors.red : JXB.brandPrimary),
                    ),
                  ),
                )
              else if (transferring && _activeId == recording.id)
                _downloadRing(recording.id, uploading: stage == SoundcoreImportStage.uploading)
              else if (transferring)
                const SizedBox(
                  width: JXB.sizeTouch,
                  height: JXB.sizeTouch,
                  child:
                      Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                )
              else if (!completed && _sync.needsCloudCheck(recording.id))
                TextButton(
                  key: ValueKey('soundcore_check_${recording.id}'), // i18n-ignore: Widget identifier.
                  onPressed: _sync.loading || _sync.waitReason(recording.id) == SoundcoreSyncWaitReason.signIn
                      ? null
                      : () => _sync.sync(),
                  child: Text(_sync.isCheckingCloud(recording.id)
                      ? revampText(context, en: 'Checking', zh: '核对中')
                      : _sync.cloudLookupError != null
                          ? revampText(context, en: 'Check again', zh: '重试核对')
                          : revampText(context, en: 'Check status', zh: '核对状态')),
                )
              else if (!completed)
                Tooltip(
                  message: failure != null ? retryLabel : revampText(context, en: 'Sync recording', zh: '同步录音'),
                  child: TextButton(
                    key: ValueKey('soundcore_sync_${recording.id}'), // i18n-ignore: Widget identifier.
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, JXB.sizeTouch),
                      padding: const EdgeInsets.symmetric(horizontal: JXB.space2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: JXB.metaButton,
                    ),
                    onPressed: requested ||
                            _activeId == recording.id ||
                            _sync.waitReason(recording.id) == SoundcoreSyncWaitReason.signIn
                        ? null
                        : () => _sync.retry(recording.id),
                    child: Text(requested
                        ? revampText(context, en: 'Queued', zh: '已排队')
                        : failure != null
                            ? revampText(context, en: 'Retry', zh: '重试')
                            : revampText(context, en: 'Sync', zh: '同步')),
                  ),
                ),
            ],
          ),
          if (job?.errorCode != null)
            Padding(
              padding: const EdgeInsets.only(top: JXB.space2),
              child: Text(audioJobError(context, job!.errorCode), style: JXB.bodySmall.copyWith(color: Colors.red)),
            ),
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(top: JXB.space2),
              child: Text(_importError(failure), style: JXB.caption.copyWith(color: Colors.red.shade700)),
            ),
          if (job?.canRetry == true)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _sync.retryingProcessing.contains(recording.id)
                    ? null
                    : () async {
                        try {
                          await _sync.retryProcessing(recording.id);
                        } catch (_) {
                          if (mounted) {
                            // i18n-ignore: English and Chinese copy provided together through revampText.
                            UndoDeleteHost.showMessage(context, revampText(context,
                                    en: 'Could not retry. Please try again.', zh: '重试未成功，请稍后再试。'));
                          }
                        }
                      },
                child: Text(revampText(context, en: 'Retry processing', zh: '重试处理')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _downloadRing(int id, {bool uploading = false}) {
    final fraction = uploading
        ? (_sync.awaitingUploadConfirmation ? 1.0 : _sync.uploadEstimate?.fraction)
        : _sync.downloadEstimate?.fraction;
    return RecorderProgressRing(
      fraction: fraction,
      estimated: true,
      label: uploading
          ? revampText(context, en: 'Estimated upload progress', zh: '预计上传进度')
          : revampText(context, en: 'Estimated download progress', zh: '预计下载进度'),
      progressKey: ValueKey(uploading ? 'soundcore_upload_progress_$id' : 'soundcore_download_progress_$id'),
    );
  }

  String _downloadLabel() {
    final transport =
        _sync.wifiState == SoundcoreWifiState.downloading ? 'Wi-Fi' : revampText(context, en: 'Bluetooth', zh: '蓝牙');
    final estimate = _sync.downloadEstimate;
    if (estimate?.waitingForData == true) {
      return revampText(context, en: '$transport · Waiting for data…', zh: '$transport · 等待设备传输…');
    }
    final remaining = estimate?.remaining;
    if (remaining == null) {
      return revampText(context,
          en: '$transport · ${(_bytes / 1024).round()} KB downloaded',
          zh: '$transport · 已下载 ${(_bytes / 1024).round()} KB');
    }
    // Round up to five seconds: this is an estimate, not a precise countdown.
    final seconds = ((remaining.inMilliseconds / 5000).ceil() * 5).clamp(5, 359999);
    final hours = seconds ~/ 3600;
    final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    final time = '${hours > 0 ? '$hours:' : ''}$minutes:$rest';
    return revampText(context, en: '$transport · ~$time left', zh: '$transport · 约剩余 $time');
  }

  String _uploadLabel() {
    if (_sync.awaitingUploadConfirmation) {
      return revampText(context, en: 'Sent · waiting for server confirmation…', zh: '已发送 · 等待服务器确认…');
    }
    final estimate = _sync.uploadEstimate;
    if (estimate?.waitingForData == true) {
      return revampText(context, en: 'Upload paused · waiting for network…', zh: '上传暂无进展 · 正在等待网络…');
    }
    final remaining = estimate?.remaining;
    if (remaining != null) {
      final seconds = ((remaining.inMilliseconds / 5000).ceil() * 5).clamp(5, 359999);
      return revampText(context, en: 'Uploading · about $seconds s left', zh: '上传中 · 约剩余 $seconds 秒');
    }
    return revampText(context,
        en: 'Uploading · ${(_sync.uploadBytes / 1024).round()} KB sent',
        zh: '上传中 · 已发送 ${(_sync.uploadBytes / 1024).round()} KB');
  }

  String _stageLabel(SoundcoreImportStage? stage) => switch (stage) {
        SoundcoreImportStage.downloading => _downloadLabel(),
        SoundcoreImportStage.downloaded => revampText(context, en: 'Downloaded · waiting to upload', zh: '已下载 · 待上传'),
        SoundcoreImportStage.uploading => _uploadLabel(),
        SoundcoreImportStage.uploaded =>
          revampText(context, en: 'Uploaded · check your timeline for results', zh: '已上传 · 转录结果请查看时间线'),
        SoundcoreImportStage.processed => revampText(context, en: 'Completed', zh: '已完成'),
        null => revampText(context, en: 'Queued', zh: '待同步'),
      };

  Widget _activeSyncSummary() {
    final recording = _recordings.where((file) => file.id == _activeId).firstOrNull;
    if (recording == null) return const SizedBox.shrink();
    final date = DateFormat('MM-dd HH:mm').format(recording.startedAt.toLocal());
    return Padding(
      key: const ValueKey('soundcore_active_sync'),
      padding: const EdgeInsets.only(top: JXB.space2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(revampText(context, en: 'Syncing recording from $date', zh: '正在同步 $date 的录音'),
            style: JXB.bodySmall.copyWith(color: JXB.brandPrimary)),
        Text(_stageLabel(_stages[recording.id]), style: JXB.caption.copyWith(color: JXB.brandPrimary)),
      ]),
    );
  }

  Widget _wifiOption() {
    final state = _sync.wifiState;
    final label = switch (state) {
      SoundcoreWifiState.preparing => revampText(context, en: 'Preparing Wi-Fi transfer…', zh: '正在停止蓝牙下载，准备切换…'),
      SoundcoreWifiState.reconnecting =>
        revampText(context, en: 'Reconnecting recorder controls…', zh: '正在重新连接录音豆控制通道…'),
      SoundcoreWifiState.openingHotspot => revampText(context, en: 'Enabling recorder hotspot…', zh: '正在开启录音豆热点…'),
      SoundcoreWifiState.waitingForHotspot =>
        revampText(context, en: 'Waiting for hotspot startup…', zh: '正在等待热点就绪，约 10 秒…'),
      SoundcoreWifiState.joining => revampText(context, en: 'Joining recorder Wi-Fi…', zh: '正在加入录音豆 Wi-Fi，请确认系统提示…'),
      SoundcoreWifiState.verifyingNetwork =>
        revampText(context, en: 'Waiting for the recorder network…', zh: '正在等待录音豆网络就绪…'),
      SoundcoreWifiState.connecting => revampText(context, en: 'Establishing Wi-Fi transfer…', zh: '正在建立 Wi-Fi 传输连接…'),
      SoundcoreWifiState.downloading => revampText(context, en: 'Downloading over Wi-Fi…', zh: '正在通过 Wi-Fi 下载…'),
      SoundcoreWifiState.restoring => revampText(context, en: 'Disconnecting recorder Wi-Fi…', zh: '正在退出录音豆 Wi-Fi…'),
      null => revampText(context, en: 'Wi-Fi direct transfer', zh: 'Wi-Fi 直连传输'),
    };
    return Container(
      key: const ValueKey('soundcore_wifi_option'),
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(
          key: const ValueKey('soundcore_wifi_start'),
          onPressed: _confirmingWifi || state != null || _recordStatus == 1 || _recordStatus == 2
              ? null
              : _confirmWifiTransfer,
          icon: state == null
              ? const Icon(Icons.wifi, size: 20)
              : const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          label: Text(label),
          style: TextButton.styleFrom(minimumSize: const Size(0, JXB.sizeTouch), alignment: Alignment.centerLeft),
        ),
        Text(
            revampText(context,
                en: 'Sync uses Bluetooth by default. For faster downloads, tap here and confirm the temporary Wi-Fi change.',
                zh: '默认通过蓝牙自动同步。如需加快下载，可点此确认后临时切换到录音豆 Wi-Fi。'),
            style: JXB.bodySmall.copyWith(color: JXB.textSecondary)),
        if (_sync.wifiNothingToDownload)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                revampText(context,
                    en: 'All recordings are already downloaded. Wi-Fi is not needed; pending uploads use your internet connection.',
                    zh: '录音已全部下载到手机，无需切换 Wi-Fi；待上传文件会通过当前网络上传。'),
                style: JXB.bodySmall),
          ),
        if (_sync.wifiAwaitingCloudCheck)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
                revampText(context,
                    en: 'Some recordings still need a cloud status check. Reconnect to the internet and check them again.',
                    zh: '尚有录音需要核对云端状态，请联网后重试核对。'),
                style: JXB.bodySmall),
          ),
        if (_sync.wifiError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_wifiError(_sync.wifiError!), style: JXB.bodySmall.copyWith(color: Colors.red.shade700)),
          ),
      ]),
    );
  }

  String _wifiError(Object error) {
    final cause = error is SoundcoreWifiFailure ? error.cause : error;
    if (cause is SoundcoreProtocolException) {
      return revampText(context,
          en: 'Wi-Fi connected, but audio data validation failed. This incomplete file was not saved. Copy connection diagnostics below to help investigate, then retry.',
          zh: 'Wi-Fi 已连接，但音频数据校验失败，本次未完成的文件没有保存。请复制下方连接诊断以便排查，然后重试。');
    }
    final phase = error is SoundcoreWifiFailure ? error.phase : null;
    return switch (phase) {
      SoundcoreWifiPhase.openingHotspot || SoundcoreWifiPhase.waitingForHotspot => revampText(context,
          en: 'The recorder hotspot did not start. Keep it awake and retry. Bluetooth sync can continue.',
          zh: '录音豆热点未能启动，请保持设备唤醒后重试。可继续通过蓝牙同步。'),
      SoundcoreWifiPhase.joining => revampText(context,
          en: 'Could not join the recorder hotspot. Allow the Wi-Fi join prompt and retry. Bluetooth sync can continue.',
          zh: '未能加入录音豆热点，请允许系统的 Wi-Fi 加入提示后重试。可继续通过蓝牙同步。'),
      SoundcoreWifiPhase.verifyingNetwork => revampText(context,
          en: 'The Wi-Fi request was accepted, but the recorder network is not ready. Keep the recorder nearby and retry.',
          zh: '系统已接受加入请求，但录音豆网络尚未就绪。请将录音豆放在手机附近后重试。'),
      SoundcoreWifiPhase.connecting => revampText(context,
          en: 'The recorder network is ready, but the transfer connection failed. Check Memorion’s Local Network permission in Settings, then retry.',
          zh: '录音豆网络已就绪，但传输连接未能建立。请检查系统设置中 Memorion 的本地网络权限后重试。'),
      SoundcoreWifiPhase.downloading when _sync.wifiFailedStep == SoundcoreTransferStep.checkingRecorder => revampText(
          context,
          en: 'Wi-Fi transfer connected, but the download session could not be prepared. Reconnect the recorder and retry.',
          zh: 'Wi-Fi 传输通道已连接，但下载会话未能就绪。请重新连接录音豆后重试。'),
      SoundcoreWifiPhase.downloading => revampText(context,
          en: _sync.wifiFailedBytes > 0
              ? 'Wi-Fi downloaded some audio, then the transfer failed. Completed downloads are kept. Reconnect the recorder and retry.'
              : 'Wi-Fi transfer connected, but no audio was downloaded. Reconnect the recorder and retry.',
          zh: _sync.wifiFailedBytes > 0
              ? 'Wi-Fi 已收到部分音频，但传输未完成。已完整下载的录音会保留，请重新连接录音豆后重试。'
              : 'Wi-Fi 传输通道已连接，但尚未下载到音频。请重新连接录音豆后重试。'),
      SoundcoreWifiPhase.restoring => revampText(context,
          en: 'Could not finish leaving the recorder hotspot. Downloaded audio is kept; uploads resume when internet access returns.',
          zh: '退出录音豆热点时出现问题。已下载的录音会保留，恢复网络后继续上传。'),
      null => revampText(context,
          en: 'Wi-Fi transfer did not complete. Reconnect the recorder and retry. Downloaded audio is kept.',
          zh: 'Wi-Fi 传输未完成，请重新连接录音豆后重试，已下载的录音会保留。'),
    };
  }

  int get _cloudCheckCount =>
      _recordings.where((recording) => recording.id != _activeId && _sync.needsCloudCheck(recording.id)).length;

  int get _uploadedCount => _recordings
      .where((recording) =>
          _stages[recording.id] == SoundcoreImportStage.uploaded ||
          _stages[recording.id] == SoundcoreImportStage.processed)
      .length;

  @override
  Widget build(BuildContext context) {
    return RecorderPage(
      title: revampText(context, en: 'SOUNDCORE recordings', zh: 'SOUNDCORE 录音'),
      onRefresh: _refresh,
      scrollController: _scrollController,
      children: [
        RecorderPanel(
          key: const ValueKey('soundcore_refresh_status'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                _loading
                    ? revampText(context, en: 'Reading recorder…', zh: '正在读取设备录音…')
                    : _deviceFileCount == null
                        ? (_sync.error != null
                            ? revampText(context, en: 'Refresh failed', zh: '刷新失败')
                            : revampText(context, en: 'Waiting for recorder connection', zh: '等待连接录音豆'))
                        : revampText(context,
                            en: '$_deviceFileCount recordings on device', zh: '设备中有 $_deviceFileCount 条录音'),
                style: JXB.body),
            if (_lastRefresh != null) ...[
              const SizedBox(height: 6),
              Text(
                  revampText(context,
                      en: 'Last checked: ${DateFormat('HH:mm:ss').format(_lastRefresh!)}',
                      zh: '上次刷新：${DateFormat('HH:mm:ss').format(_lastRefresh!)}'),
                  style: JXB.body.copyWith(color: JXB.textSecondary)),
            ],
            if (!_loading) ...[
              if (_deviceFileCount == null && _recordings.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                    revampText(context,
                        en: 'Showing known recordings. The device list will update after reconnecting.',
                        zh: '显示已读取的录音，连接设备后更新列表。'),
                    style: JXB.bodySmall.copyWith(color: JXB.textSecondary)),
              ],
              const SizedBox(height: 6),
              Text(
                  revampText(context,
                      en: 'Pending: ${_recordings.length - _uploadedCount - _cloudCheckCount} · Uploaded: $_uploadedCount',
                      zh: '待同步 ${_recordings.length - _uploadedCount - _cloudCheckCount} 条 · 已上传 $_uploadedCount 条'),
                  style: JXB.body.copyWith(color: JXB.textSecondary)),
              if (_cloudCheckCount > 0)
                Text(revampText(context, en: 'Checking cloud status: $_cloudCheckCount', zh: '待核对 $_cloudCheckCount 条'),
                    style: JXB.body.copyWith(color: JXB.textSecondary)),
            ],
            if (_activeId != null) _activeSyncSummary(),
            if (_sync.reconnectingBluetooth)
              Text(revampText(context, en: 'Restoring Bluetooth sync…', zh: '正在恢复蓝牙同步…'),
                  style: JXB.bodySmall.copyWith(color: JXB.brandPrimary)),
          ]),
        ),
        const SizedBox(height: 14),
        Text(
            revampText(context,
                en: 'Recordings sync automatically when connected. You can leave this page while downloading or uploading; results appear in your timeline.',
                zh: '设备连接后自动同步录音。下载或上传时可以返回其他页面，转录结果会出现在时间线中。'),
            style: JXB.body.copyWith(color: JXB.textSecondary)),
        AudioJobsLink(onReturn: () => unawaited(_sync.refreshProcessing(includeTerminal: true))),
        if (_sync.wifiAvailable) _wifiOption(),
        if (_uploadedCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: JXB.space2),
            child: Text(
              revampText(context, en: 'Recordings · cloud status updates after upload', zh: '录音列表 · 上传后显示云端处理状态'),
              style: JXB.bodySmall,
            ),
          ),
        if (_recordStatus == 1 || _recordStatus == 2)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                  revampText(context,
                      en: 'Recording is active or paused. New downloads will start automatically after recording ends.',
                      zh: '设备正在录音或暂停中，结束录音后将自动开始下载。'),
                  style: JXB.body)),
        if (_sync.cacheError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
                revampText(context,
                    en: 'Import history is unavailable. Check sign-in and available phone storage.',
                    zh: '暂时无法读取导入记录，请确认已登录且手机存储空间充足。'),
                style: JXB.body),
          ),
        if (_sync.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(_readError(_sync.error!), style: JXB.body.copyWith(color: Colors.red.shade700)),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!_loading && _recordings.isEmpty && _sync.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
                revampText(context,
                    en: 'No completed recordings yet. New recordings will sync automatically after recording ends.',
                    zh: '暂时没有已完成的录音，结束录音后将自动同步。'),
                style: JXB.body),
          ),
        const SizedBox(height: JXB.space3),
        for (final recording in _recordings.skip(_page * _pageSize).take(_pageSize)) _recordingRow(recording),
        if (_recordings.isNotEmpty) _pagination(),
        const SizedBox(height: 12),
        Text(revampText(context, en: 'Original recordings stay on the device.', zh: '设备中的原录音会保留。'),
            style: JXB.body.copyWith(color: JXB.textSecondary)),
        TextButton.icon(
          key: const ValueKey('soundcore_copy_diagnostics'),
          onPressed: _copyDiagnostics,
          icon: const Icon(Icons.copy, size: 16),
          label: Text(revampText(context, en: 'Copy connection diagnostics', zh: '复制连接诊断')),
        ),
      ],
    );
  }
}
