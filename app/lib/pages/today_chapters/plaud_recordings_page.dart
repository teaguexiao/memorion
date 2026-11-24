import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:intl/intl.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';
import 'package:memorion/services/devices/plaud/sync_controller.dart';
import 'package:memorion/services/devices/plaud/wifi_connector.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'plaud_setup_page.dart';
import 'recorder_widgets.dart';
import 'audio_jobs_page.dart';

class PlaudRecordingsPage extends StatefulWidget {
  final BtDevice device;
  final PlaudSyncController? controller;
  final Future<bool> Function(Uri)? openGuide;
  const PlaudRecordingsPage({super.key, required this.device, this.controller, this.openGuide});
  @override
  State<PlaudRecordingsPage> createState() => _PlaudRecordingsPageState();
}

class _PlaudRecordingsPageState extends State<PlaudRecordingsPage> with WidgetsBindingObserver {
  late final PlaudSyncController _sync =
      widget.controller ?? ServiceManager.instance().plaudSync.controllerFor(widget.device);
  final _scroll = ScrollController();
  Timer? _poll;
  bool _foreground = true;
  bool _refreshQueued = false;
  bool _openingGuide = false;
  bool _guideFailed = false;
  bool _confirmingWifi = false;
  int _page = 0;
  static const _pageSize = 20;
  int get _lastPage => _sync.recordings.isEmpty ? 0 : (_sync.recordings.length - 1) ~/ _pageSize;
  // Background checks must not insert a spinner or collapse the summary above
  // an already displayed list, including while Bluetooth is reconnecting.
  bool get _initialLoading => _sync.loading && _sync.lastRefresh == null && _sync.recordings.isEmpty;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync.addListener(_updated);
    unawaited(_sync.refresh());
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _foreground && ModalRoute.of(context)?.isCurrent != false) unawaited(_sync.refreshProcessing());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && mounted) unawaited(_sync.refreshProcessing());
  }

  void _updated() {
    if (!mounted) return;
    setState(() => _page = _page.clamp(0, _lastPage));
    if (_refreshQueued && _sync.ownerActive && !_sync.busy && !_sync.loading && _sync.wifiState == null) {
      _refreshQueued = false;
      // Avoid starting another controller operation inside its notification.
      unawaited(Future<void>.microtask(() async {
        if (mounted) await _refresh();
      }));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync.removeListener(_updated);
    _poll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _message(String message) {
    if (mounted) UndoDeleteHost.showMessage(context, message);
  }

  Future<void> _openGuide() async {
    if (_openingGuide) return;
    setState(() {
      _openingGuide = true;
      _guideFailed = false;
    });
    final uri = plaudSetupGuideUri(context);
    try {
      final opened = await (widget.openGuide?.call(uri) ?? launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened) throw const FormatException();
    } catch (_) {
      if (mounted) setState(() => _guideFailed = true);
    } finally {
      if (mounted) setState(() => _openingGuide = false);
    }
  }

  Future<void> _credentials() async {
    try {
      await _sync.updateAuthorization(() async {
        if (!mounted) return;
        final saved = await Navigator.of(context)
            .push<bool>(MaterialPageRoute(builder: (_) => PlaudSetupPage(device: widget.device)));
        if (saved != true || !mounted || !_sync.ownerActive) return;
        final devices = ServiceManager.instance().device;
        await devices.forceDisconnect(widget.device.id);
        if (!_sync.ownerActive) return;
        await devices.ensureConnection(widget.device.id, force: true);
      });
    } catch (e) {
      if (mounted) _message(plaudErrorText(context, e));
    }
  }

  Future<void> _refresh() async {
    if (!_sync.ownerActive) return;
    setState(() => _page = 0);
    if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
    if (_sync.busy || _sync.loading || _sync.wifiState != null) {
      _refreshQueued = true;
      _message(revampText(context,
          en: 'Refresh queued. The list will update after the current sync finishes.',
          zh: '刷新已排队，当前同步完成后会更新文件列表。')); // i18n-ignore: Bilingual via revampText.
      return;
    }
    await _sync.refresh();
  }

  int get _uploadedCount => _sync.recordings
      .where((r) => {OfflineImportStage.uploaded, OfflineImportStage.processed}.contains(_sync.stages[r.id]))
      .length;

  Future<void> _confirmWifiTransfer() async {
    if (_confirmingWifi || _sync.wifiState != null || !_sync.ownerActive) return;
    setState(() => _confirmingWifi = true);
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                key: const ValueKey('plaud_wifi_confirmation'),
                backgroundColor: JXB.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                scrollable: true,
                title: Text(revampText(dialogContext, en: 'Switch to recorder Wi-Fi?', zh: '切换到 PLAUD Note Wi-Fi？')),
                content: Text(
                    revampText(dialogContext,
                        en: 'Bluetooth downloading will pause and your phone will temporarily join the recorder’s hotspot, which has no internet access. Online services may be interrupted.\n\nKeep Memorion open during transfer. Completed downloads are kept; an unfinished recording restarts over Wi-Fi. After leaving the hotspot, uploads resume when internet access returns. Cancel to keep syncing over Bluetooth.',
                        zh: '将暂停蓝牙下载，手机会暂时连接 PLAUD Note 热点。该热点无法上网，期间网络访问可能中断。\n\n传输时请保持 Memorion 在前台。已完整下载的文件会保留，未完成的录音会通过 Wi-Fi 从头下载。退出热点并恢复网络后自动上传转录。取消则继续使用蓝牙同步。'),
                    style: JXB.bodySmall.copyWith(color: JXB.textSecondary)),
                actions: [
                  TextButton(
                      key: const ValueKey('plaud_wifi_cancel'),
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: Text(revampText(dialogContext, en: 'Cancel', zh: '取消'))),
                  TextButton(
                      key: const ValueKey('plaud_wifi_confirm'),
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: Text(revampText(dialogContext, en: 'Switch to Wi-Fi', zh: '确认切换'))),
                ],
              ));
    } finally {
      if (mounted) setState(() => _confirmingWifi = false);
    }
    if (mounted && confirmed == true && _sync.ownerActive) await _sync.syncOverWifi();
  }

  Widget _wifiOption() {
    final state = _sync.wifiState;
    final label = switch (state) {
      PlaudWifiPhase.preparing => revampText(context, en: 'Preparing Wi-Fi transfer…', zh: '正在准备切换到 Wi-Fi…'),
      PlaudWifiPhase.openingHotspot => revampText(context, en: 'Enabling recorder hotspot…', zh: '正在开启设备热点…'),
      PlaudWifiPhase.joining => revampText(context, en: 'Joining recorder Wi-Fi…', zh: '正在加入设备 Wi-Fi，请确认系统提示…'),
      PlaudWifiPhase.verifyingNetwork =>
        revampText(context, en: 'Waiting for the recorder network…', zh: '正在等待设备网络就绪…'),
      PlaudWifiPhase.connecting => revampText(context, en: 'Establishing Wi-Fi transfer…', zh: '正在建立 Wi-Fi 传输连接…'),
      PlaudWifiPhase.downloading => revampText(context, en: 'Downloading over Wi-Fi…', zh: '正在通过 Wi-Fi 下载…'),
      PlaudWifiPhase.restoring => revampText(context, en: 'Disconnecting recorder Wi-Fi…', zh: '正在退出设备 Wi-Fi…'),
      null => revampText(context, en: 'Wi-Fi direct transfer', zh: 'Wi-Fi 直连传输'),
    };
    return Container(
      key: const ValueKey('plaud_wifi_option'),
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(
          key: const ValueKey('plaud_wifi_start'),
          onPressed: _confirmingWifi || state != null || !_sync.ownerActive ? null : _confirmWifiTransfer,
          icon: state == null
              ? const Icon(Icons.wifi, size: 20)
              : const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          label: Text(label),
          style: TextButton.styleFrom(minimumSize: const Size(0, JXB.sizeTouch), alignment: Alignment.centerLeft),
        ),
        Text(
            revampText(context,
                en: 'Sync uses Bluetooth by default. For faster downloads, tap here and confirm the temporary Wi-Fi change.',
                zh: '默认通过蓝牙自动同步。如需加快下载，可点此确认后临时切换到设备 Wi-Fi。'),
            style: JXB.bodySmall.copyWith(color: JXB.textSecondary)),
        if (state == PlaudWifiPhase.downloading && _sync.totalBytes > 0)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: _sync.bytes / _sync.totalBytes)),
        if (_sync.wifiNothingToDownload)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  revampText(context,
                      en: 'All recordings are already downloaded. Wi-Fi is not needed; pending uploads use your internet connection.',
                      zh: '录音已全部下载到手机，无需切换 Wi-Fi；待上传文件会通过当前网络上传。'),
                  style: JXB.bodySmall)),
        if (_sync.wifiError != null)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  state == PlaudWifiPhase.restoring
                      ? revampText(context,
                          en: 'Still leaving recorder Wi-Fi. Recovery will retry automatically; uploads remain paused.',
                          zh: '正在恢复网络，会自动重试；恢复前暂停上传。')
                      : revampText(context,
                          en: 'Wi-Fi transfer did not finish. Completed downloads are kept; Bluetooth sync will resume after reconnection.',
                          zh: 'Wi-Fi 传输未完成，已完整下载的录音会保留，重新连接后继续蓝牙同步。'),
                  style: JXB.bodySmall.copyWith(color: JXB.error))),
      ]),
    );
  }

  Widget _activeSyncSummary() {
    final recording = _sync.recordings.where((file) => file.id == _sync.activeId).firstOrNull;
    if (recording == null) return const SizedBox.shrink();
    final date = DateFormat('MM-dd HH:mm').format(recording.startedAt.toLocal());
    return Padding(
      key: const ValueKey('plaud_active_sync'),
      padding: const EdgeInsets.only(top: JXB.space2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(revampText(context, en: 'Syncing recording from $date', zh: '正在同步 $date 的录音'),
            style: JXB.bodySmall.copyWith(color: JXB.brandPrimary)),
        Text(_stageLabel(_sync.stages[recording.id]), style: JXB.caption.copyWith(color: JXB.brandPrimary)),
      ]),
    );
  }

  Widget _summary() => RecorderPanel(
        key: const ValueKey('plaud_refresh_status'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              _initialLoading
                  ? revampText(context, en: 'Reading recorder…', zh: '正在读取设备录音…')
                  : _sync.connected && _sync.deviceFileCount != null
                      ? revampText(context,
                          en: '${_sync.deviceFileCount} recordings on device', zh: '设备中有 ${_sync.deviceFileCount} 条录音')
                      : _sync.error != null
                          ? revampText(context, en: 'Refresh failed', zh: '刷新失败')
                          : revampText(context, en: 'Waiting for recorder connection', zh: '等待连接设备'),
              style: JXB.body),
          if (_sync.lastRefresh != null) ...[
            const SizedBox(height: 6),
            Text(
                revampText(context,
                    en: 'Last checked: ${DateFormat('HH:mm:ss').format(_sync.lastRefresh!)}',
                    zh: '上次刷新：${DateFormat('HH:mm:ss').format(_sync.lastRefresh!)}'),
                style: JXB.body.copyWith(color: JXB.textSecondary)),
          ],
          if (!_initialLoading) ...[
            if (!_sync.connected && _sync.recordings.isNotEmpty) ...[
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
                    en: 'Pending: ${_sync.recordings.length - _uploadedCount} · Uploaded: $_uploadedCount',
                    zh: '待同步 ${_sync.recordings.length - _uploadedCount} 条 · 已上传 $_uploadedCount 条'),
                style: JXB.body.copyWith(color: JXB.textSecondary)),
          ],
          if (_sync.activeId != null) _activeSyncSummary(),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final available = _sync.ownerActive && !_sync.busy && !_sync.loading && _sync.wifiState == null;
    return RecorderPage(
      title: revampText(context, en: 'PLAUD Note recordings', zh: 'PLAUD Note 录音'),
      onRefresh: _refresh,
      scrollController: _scroll,
      children: [
        _summary(),
        const SizedBox(height: 14),
        Text(
            revampText(context,
                en: 'Recordings sync automatically when the device is connected. You can leave this page while downloading or uploading; results appear in your timeline.',
                zh: '设备连接后自动同步录音。下载或上传时可以返回其他页面，转录结果会出现在时间线中。'),
            style: JXB.body.copyWith(color: JXB.textSecondary)),
        if (_sync.wifiAvailable) _wifiOption(),
        AudioJobsLink(onReturn: () => unawaited(_sync.refreshProcessing())),
        if (_uploadedCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: JXB.space2),
            child: Text(
              revampText(context, en: 'Recordings · cloud status updates after upload', zh: '录音列表 · 上传后显示云端处理状态'),
              style: JXB.bodySmall,
            ),
          ),
        if (_sync.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(plaudErrorText(context, _sync.error), style: JXB.body.copyWith(color: JXB.error)),
          ),
        if (!_sync.ownerActive)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child:
                Text(plaudErrorText(context, const PlaudException(PlaudIssue.identityRequired)), style: JXB.bodySmall),
          ),
        if (_initialLoading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (_sync.recordings.isEmpty && !_initialLoading && _sync.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
                revampText(context,
                    en: 'No completed recordings loaded. Connect Note after recording ends to sync automatically.',
                    zh: '尚未读取已完成的录音，结束录音后连接 Note 即可自动同步。'),
                style: JXB.body),
          ),
        const SizedBox(height: JXB.space3),
        for (final r in _sync.recordings.skip(_page * _pageSize).take(_pageSize)) _recording(context, r, available),
        if (_sync.recordings.isNotEmpty)
          RecorderPagination(
              keyPrefix: 'plaud',
              page: _page,
              count: _sync.recordings.length,
              pageSize: _pageSize,
              onChanged: _changePage),
        const SizedBox(height: 12),
        Text(revampText(context, en: 'Original recordings stay on the device.', zh: '设备中的原录音会保留。'),
            style: JXB.body.copyWith(color: JXB.textSecondary)),
        Text(
            revampText(context,
                en: 'Supports ordinary recordings on original Note. Live captions and some button-marked recordings are not supported yet.',
                zh: '支持原版 Note 的普通录音，暂不支持实时字幕及部分带按键标记的录音。'),
            style: JXB.bodySmall),
        Wrap(
          spacing: 12,
          children: [
            TextButton.icon(
              key: const ValueKey('plaud_device_credentials'),
              onPressed: _openingGuide ? null : _openGuide,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(revampText(context, en: 'Device authorization', zh: '设备授权')),
            ),
            TextButton.icon(
              key: const ValueKey('plaud_update_credentials'),
              onPressed: available ? _credentials : null,
              icon: const Icon(Icons.file_open_outlined, size: 16),
              label: Text(revampText(context, en: 'Import authorization file', zh: '导入授权文件')),
            ),
          ],
        ),
        if (_guideFailed) ...[
          // i18n-ignore: Bilingual message is provided by revampText below.
          Text(
              revampText(context,
                  en: 'Could not open the guide. Copy this address into your browser.', zh: '未能打开指引，请复制此网址到浏览器。'),
              style: JXB.bodySmall),
          SelectableText(plaudSetupGuideUri(context).toString(), style: JXB.bodySmall),
        ],
      ],
    );
  }

  void _changePage(int page) {
    setState(() => _page = page);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  String _stageLabel(OfflineImportStage? stage) => switch (stage) {
        OfflineImportStage.downloading => revampText(context,
            en: 'Bluetooth · ${(_sync.bytes / 1024).round()} KB downloaded',
            zh: '蓝牙 · 已下载 ${(_sync.bytes / 1024).round()} KB'),
        OfflineImportStage.downloaded => revampText(context, en: 'Downloaded · waiting to upload', zh: '已下载 · 待上传'),
        OfflineImportStage.uploading => _sync.uploadProgress == 1
            ? revampText(context, en: 'Sent · waiting for server confirmation…', zh: '已发送 · 等待服务器确认…')
            : revampText(context, en: 'Uploading', zh: '上传中'),
        OfflineImportStage.uploaded =>
          revampText(context, en: 'Uploaded · check your timeline for results', zh: '已上传 · 转录结果请查看时间线'),
        OfflineImportStage.processed => revampText(context, en: 'Completed', zh: '已完成'),
        null => revampText(context, en: 'Queued', zh: '待同步'),
      };

  Widget _recording(BuildContext context, OfflineRecording recording, bool available) {
    final id = recording.id;
    final stage = _sync.stages[id];
    final active = _sync.activeId == id;
    final issue = _sync.errors[id];
    final measured = _sync.details[id]?.duration;
    final date = recording.hasValidTimestamp(DateTime.now())
        ? DateFormat('yyyy-MM-dd HH:mm:ss').format(recording.startedAt.toLocal())
        : revampText(context, en: 'Unsupported recording timestamp', zh: '暂不支持此录音时间格式');
    final job = _sync.processingJobs[id];
    final completed = {OfflineImportStage.uploaded, OfflineImportStage.processed}.contains(stage);
    return RecorderFileCard(
      key: ValueKey('plaud_recording_$id'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: RecorderFileHeading(
              date: date,
              metadata:
                  recorderDurationLabel(context, measured ?? recording.estimatedDuration, estimated: measured == null),
              metadataKey: ValueKey('plaud_metadata_$id'),
              status: [
                if (!completed && issue == null)
                  Tooltip(
                    message: _stageLabel(stage),
                    child: Text(_stageLabel(stage),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: JXB.caption.copyWith(color: active ? JXB.brandPrimary : JXB.textSecondary)),
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
                      : stage == OfflineImportStage.processed
                          ? revampText(context, en: 'Completed', zh: '已完成')
                          : revampText(context, en: 'Uploaded', zh: '已上传'),
                  key: ValueKey('plaud_status_$id'),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: JXB.caption.copyWith(color: job?.status == 'failed' ? JXB.error : JXB.brandPrimary),
                ),
              ),
            )
          else if (active)
            RecorderProgressRing(
              fraction: stage == OfflineImportStage.uploading
                  ? _sync.uploadProgress
                  : _sync.totalBytes > 0
                      ? _sync.bytes / _sync.totalBytes
                      : null,
              label: stage == OfflineImportStage.uploading
                  ? revampText(context, en: 'Upload progress', zh: '上传进度')
                  : revampText(context, en: 'Download progress', zh: '下载进度'),
              progressKey: ValueKey(
                  stage == OfflineImportStage.uploading ? 'plaud_upload_progress_$id' : 'plaud_download_progress_$id'),
            )
          else
            Tooltip(
              message: issue != null
                  ? revampText(context, en: 'Retry sync', zh: '重试同步')
                  : revampText(context, en: 'Sync recording', zh: '同步录音'),
              child: TextButton(
                key: ValueKey('plaud_sync_$id'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, JXB.sizeTouch),
                  padding: const EdgeInsets.symmetric(horizontal: JXB.space2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: JXB.metaButton,
                ),
                onPressed: available ? () => _sync.importOne(recording, retry: true) : null,
                child: Text(issue != null
                    ? revampText(context, en: 'Retry', zh: '重试')
                    : revampText(context, en: 'Sync', zh: '同步')),
              ),
            ),
        ]),
        if (job?.errorCode != null)
          Padding(
            padding: const EdgeInsets.only(top: JXB.space2),
            child: Text(audioJobError(context, job!.errorCode), style: JXB.bodySmall.copyWith(color: JXB.error)),
          ),
        if (issue != null)
          Padding(
            padding: const EdgeInsets.only(top: JXB.space2),
            child: Text(issue is OfflineImportException ? _uploadError(context, issue) : plaudErrorText(context, issue),
                style: JXB.caption.copyWith(color: JXB.error)),
          ),
      ]),
    );
  }

  String _uploadError(BuildContext context, OfflineImportException error) {
    if (error.failure?.issue == AudioUploadIssue.duration) {
      return revampText(context,
          en: 'Import supports recordings from 5 seconds to 8 hours. Your audio is kept.',
          zh: '支持导入 5 秒到 8 小时的录音，音频已保留。');
    }
    return revampText(context,
        en: 'Upload did not finish. The audio is saved on this phone; retry when online.',
        zh: '上传未完成，音频已保存在手机上，可联网后重试。');
  }
}
