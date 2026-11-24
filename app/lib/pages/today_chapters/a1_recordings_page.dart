import 'dart:async';
import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/dingtalk_a1/protocol.dart';
import 'package:memorion/services/devices/dingtalk_a1/sync_controller.dart';
import 'package:memorion/services/devices/offline_recordings/import_store.dart';
import 'package:memorion/services/devices/offline_recordings/models.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'a1_setup_page.dart';
import 'recorder_widgets.dart';
import 'audio_jobs_page.dart';

class A1RecordingsPage extends StatefulWidget {
  final BtDevice device;
  final A1SyncController? controller;
  const A1RecordingsPage({super.key, required this.device, this.controller});
  @override
  State<A1RecordingsPage> createState() => _A1RecordingsPageState();
}

class _A1RecordingsPageState extends State<A1RecordingsPage> with WidgetsBindingObserver {
  late final A1SyncController _sync =
      widget.controller ?? ServiceManager.instance().a1Sync.controllerFor(widget.device);
  final _scroll = ScrollController();
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _playerState;
  Timer? _poll;
  bool _foreground = true;
  bool _refreshQueued = false;
  int _page = 0;
  int? _playingId;
  int? _preparingId;
  int _playbackEpoch = 0;
  static const _pageSize = 20;
  int get _lastPage => _sync.recordings.isEmpty ? 0 : (_sync.recordings.length - 1) ~/ _pageSize;
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
    if (!_sync.ownerActive) {
      unawaited(_player?.stop());
      _playingId = null;
    }
    setState(() => _page = _page.clamp(0, _lastPage));
    if (_refreshQueued && _sync.ownerActive && !_sync.busy && !_sync.loading) {
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
    _playerState?.cancel();
    _player?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _message(String message) {
    if (mounted) UndoDeleteHost.showMessage(context, message);
  }

  Future<void> _auto(bool enabled) async {
    if (enabled) {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                backgroundColor: JXB.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                scrollable: true,
                title: Text(revampText(context, en: 'Automatically import recordings?', zh: '开启自动导入？')),
                content: Text(revampText(context,
                    en: 'Recordings on this A1 will be downloaded and uploaded to your Memorion account for transcription and summaries while connected. Enable this only for recordings you are authorized to import. Device originals are kept.',
                    zh: '连接时会自动下载这台 A1 上的录音，并上传到你的 Memorion 账号进行转录和总结。请确认你有权导入这些录音，设备原文件会保留。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(revampText(context, en: 'Enable', zh: '开启'))),
                ],
              ));
      if (accepted != true || !mounted) return;
    }
    try {
      await _sync.setAutoSync(enabled);
    } catch (e) {
      if (mounted) _message(a1ErrorText(context, e));
    }
  }

  Future<void> _credentials() async {
    final saved =
        await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => A1SetupPage(device: widget.device)));
    if (saved != true || !mounted) return;
    try {
      final devices = ServiceManager.instance().device;
      await devices.forceDisconnect(widget.device.id);
      await devices.ensureConnection(widget.device.id, force: true);
      await _sync.refresh();
    } catch (e) {
      if (mounted) _message(a1ErrorText(context, e));
    }
  }

  Future<void> _play(int id) async {
    if (_preparingId != null) return;
    final epoch = ++_playbackEpoch;
    setState(() => _preparingId = id);
    try {
      if (_playingId == id) {
        await _player?.stop();
        if (mounted) setState(() => _playingId = null);
        return;
      }
      final file = await _sync.playable(id);
      if (file == null || !mounted || !_sync.ownerActive) return;
      _player ??= AudioPlayer();
      _playerState ??= _player!.playerStateStream.listen((state) {
        if (mounted && state.processingState == ProcessingState.completed) setState(() => _playingId = null);
      });
      await _player!.setFilePath(file.path);
      if (!mounted || !_sync.ownerActive) {
        await _player!.stop();
        return;
      }
      setState(() => _playingId = id);
      unawaited(_player!.play().catchError((Object error) {
        if (mounted && epoch == _playbackEpoch) {
          setState(() => _playingId = null);
          _message(a1ErrorText(context, error));
        }
      }));
    } catch (e) {
      if (mounted && epoch == _playbackEpoch) {
        setState(() => _playingId = null);
        _message(a1ErrorText(context, e));
      }
    } finally {
      if (mounted && epoch == _playbackEpoch) setState(() => _preparingId = null);
    }
  }

  Future<void> _refresh() async {
    if (!_sync.ownerActive) return;
    setState(() => _page = 0);
    if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
    if (_sync.busy || _sync.loading) {
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

  Widget _summary() => RecorderPanel(
        key: const ValueKey('a1_refresh_status'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              _sync.loading
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
          if (!_sync.loading) ...[
            if (!_sync.connected && _sync.recordings.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                  revampText(context,
                      en: 'Showing known recordings. The device list will update after reconnecting.',
                      zh: '显示已读取的录音，连接设备后更新列表。'),
                  style: JXB.bodySmall),
            ],
            const SizedBox(height: 6),
            Text(
                revampText(context,
                    en: 'Pending: ${_sync.recordings.length - _uploadedCount} · Uploaded: $_uploadedCount',
                    zh: '待同步 ${_sync.recordings.length - _uploadedCount} 条 · 已上传 $_uploadedCount 条'),
                style: JXB.body.copyWith(color: JXB.textSecondary)),
          ],
          if (_sync.connected && _sync.info != null) ...[
            const SizedBox(height: 6),
            Text(_infoText(context, _sync.info!), style: JXB.bodySmall),
          ],
          if (_sync.activeId != null) ...[
            const SizedBox(height: JXB.space2),
            Text(_stageLabel(_sync.stages[_sync.activeId]), style: JXB.bodySmall.copyWith(color: JXB.brandPrimary)),
          ],
        ]),
      );

  Widget _recordingControls(bool available) {
    final info = _sync.info!;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: RecorderPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(revampText(context, en: 'Recording controls', zh: '录音控制'), style: JXB.body),
          const SizedBox(height: JXB.space2),
          Wrap(spacing: JXB.space2, children: [
            if (info.audioStatus == 'idle')
              OutlinedButton.icon(
                  onPressed: available ? () => _sync.recordingControl('start') : null,
                  icon: const Icon(Icons.fiber_manual_record, size: 16),
                  label: Text(revampText(context, en: 'Start recording', zh: '开始录音'))),
            if ({'recording', 'rec_streaming'}.contains(info.audioStatus))
              OutlinedButton.icon(
                  onPressed: available ? () => _sync.recordingControl('pause') : null,
                  icon: const Icon(Icons.pause, size: 16),
                  label: Text(revampText(context, en: 'Pause', zh: '暂停'))),
            if (info.audioStatus == 'paused')
              OutlinedButton.icon(
                  onPressed: available ? () => _sync.recordingControl('resume') : null,
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: Text(revampText(context, en: 'Resume', zh: '继续录音'))),
            if (info.recording)
              OutlinedButton.icon(
                  onPressed: available ? () => _sync.recordingControl('stop') : null,
                  icon: const Icon(Icons.stop, size: 16),
                  label: Text(revampText(context, en: 'Stop recording', zh: '结束录音'))),
          ]),
          if (info.recording)
            Text(
                revampText(context,
                    en: 'Recording is active or paused. Sync completed recordings after recording ends.',
                    zh: '设备正在录音或暂停中，结束录音后可同步。'),
                style: JXB.bodySmall),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final available = _sync.ownerActive && !_sync.busy && !_sync.loading;
    return RecorderPage(
      title: revampText(context, en: 'DingTalk A1 recordings', zh: '钉钉 A1 录音'),
      onRefresh: _refresh,
      scrollController: _scroll,
      children: [
        _summary(),
        const SizedBox(height: 14),
        Text(
            revampText(context,
                en: 'Sync completed recordings manually or enable automatic sync. You can leave this page while downloading or uploading; results appear in your timeline.',
                zh: '可手动同步录音，也可开启自动同步。下载或上传时可以返回其他页面，转录结果会出现在时间线中。'),
            style: JXB.body.copyWith(color: JXB.textSecondary)),
        AudioJobsLink(onReturn: () => unawaited(_sync.refreshProcessing())),
        RecorderPanel(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: JXB.brandPrimary,
            value: _sync.autoSync,
            onChanged: _sync.ownerActive ? _auto : null,
            title: Text(revampText(context, en: 'Automatic sync', zh: '自动同步'), style: JXB.body),
            subtitle: Text(
                revampText(context,
                    en: 'Upload recordings to Memorion for transcription and summaries.',
                    zh: '上传录音到 Memorion，生成转录和总结。'),
                style: JXB.bodySmall),
          ),
        ),
        if (_sync.connected && _sync.info != null) _recordingControls(available),
        if (_sync.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(a1ErrorText(context, _sync.error), style: JXB.body.copyWith(color: JXB.error)),
          ),
        if (!_sync.ownerActive)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(a1ErrorText(context, const A1Exception(A1Issue.identityRequired)), style: JXB.bodySmall),
          ),
        if (_sync.loading)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (_sync.recordings.isEmpty && !_sync.loading && _sync.error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
                revampText(context,
                    en: 'No completed recordings loaded. Connect A1 after recording ends, then refresh.',
                    zh: '尚未读取已完成的录音，结束录音后连接 A1 并刷新。'),
                style: JXB.body),
          ),
        const SizedBox(height: JXB.space3),
        for (final r in _sync.recordings.skip(_page * _pageSize).take(_pageSize)) _recording(context, r, available),
        if (_sync.recordings.isNotEmpty)
          RecorderPagination(
              keyPrefix: 'a1',
              page: _page,
              count: _sync.recordings.length,
              pageSize: _pageSize,
              onChanged: _changePage),
        const SizedBox(height: 12),
        Text(revampText(context, en: 'Original recordings stay on the device.', zh: '设备中的原录音会保留。'),
            style: JXB.body.copyWith(color: JXB.textSecondary)),
        Text(revampText(context, en: 'Live captions and encrypted audio are not supported yet.', zh: '暂不支持实时字幕和加密音频。'),
            style: JXB.bodySmall),
        TextButton.icon(
          key: const ValueKey('a1_device_credentials'),
          onPressed: available ? _credentials : null,
          icon: const Icon(Icons.key_outlined, size: 16),
          label: Text(revampText(context, en: 'Device authorization', zh: '设备授权')),
        ),
      ],
    );
  }

  void _changePage(int page) {
    setState(() => _page = page);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  String _infoText(BuildContext context, A1Info info) {
    final battery = info.battery < 0 ? '—' : '${info.battery}%';
    final storage = info.freeStorageMb < 0 ? '—' : '${info.freeStorageMb} MB';
    return revampText(context, en: 'Battery $battery · Free $storage', zh: '电量 $battery · 剩余 $storage');
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
    final saved = {
      OfflineImportStage.downloaded,
      OfflineImportStage.uploading,
      OfflineImportStage.uploaded,
      OfflineImportStage.processed
    }.contains(stage);
    return RecorderFileCard(
      key: ValueKey('a1_recording_$id'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: RecorderFileHeading(
              date: date,
              metadata:
                  recorderDurationLabel(context, measured ?? recording.estimatedDuration, estimated: measured == null),
              metadataKey: ValueKey('a1_metadata_$id'),
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
                  key: ValueKey('a1_status_$id'),
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
                  stage == OfflineImportStage.uploading ? 'a1_upload_progress_$id' : 'a1_download_progress_$id'),
            )
          else
            Tooltip(
              message: issue != null
                  ? revampText(context, en: 'Retry sync', zh: '重试同步')
                  : revampText(context, en: 'Sync recording', zh: '同步录音'),
              child: TextButton(
                key: ValueKey('a1_sync_$id'),
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
            child: Text(issue is OfflineImportException ? _uploadError(context, issue) : a1ErrorText(context, issue),
                style: JXB.caption.copyWith(color: JXB.error)),
          ),
        if (saved)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _sync.ownerActive && _preparingId == null ? () => _play(id) : null,
              icon: Icon(_playingId == id ? Icons.stop : Icons.play_arrow, size: 16),
              label: Text(_preparingId == id
                  ? revampText(context, en: 'Preparing…', zh: '准备中…')
                  : _playingId == id
                      ? revampText(context, en: 'Stop', zh: '停止')
                      : revampText(context, en: 'Listen', zh: '试听')),
            ),
          ),
      ]),
    );
  }

  String _uploadError(BuildContext context, OfflineImportException error) {
    if (error.failure?.issue == AudioUploadIssue.duration) {
      return revampText(context,
          en: 'Import supports recordings from 5 seconds to 2 hours. Your audio is kept.',
          zh: '支持导入 5 秒到 2 小时的录音，音频已保留。');
    }
    return revampText(context,
        en: 'Upload did not finish. The audio is saved on this phone; retry when online.',
        zh: '上传未完成，音频已保存在手机上，可联网后重试。');
  }
}
