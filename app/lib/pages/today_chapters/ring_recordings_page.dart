import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/http/audio_upload_transport.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/providers/undo_delete_controller.dart';
import 'package:memorion/services/devices/chiplet_ring/models.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';
import 'package:memorion/services/services.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'audio_jobs_page.dart';
import 'recorder_widgets.dart';
import 'widgets/swipe_action_row.dart';

class RingRecordingsPage extends StatefulWidget {
  final BtDevice device;
  final RingSyncController? controller;
  final AudioJobsApi? jobsApi;
  const RingRecordingsPage({super.key, required this.device, this.controller, this.jobsApi});
  @override
  State<RingRecordingsPage> createState() => _RingRecordingsPageState();
}

class _RingRecordingsPageState extends State<RingRecordingsPage> with WidgetsBindingObserver {
  late final RingSyncController sync;
  final scroll = ScrollController();
  final player = AudioPlayer();
  Timer? poll;
  StreamSubscription<PlayerState>? playerState;
  int page = 0;
  String? openId, playingId;
  static const pageSize = 20;
  List<RingRecording> get files => sync.recordings.where((r) => !sync.isRemoving(r.id)).toList();
  int get lastPage => files.isEmpty ? 0 : (files.length - 1) ~/ pageSize;
  @override
  void initState() {
    super.initState();
    sync = widget.controller ?? ServiceManager.instance().ringSync.controllerFor(widget.device);
    sync.addListener(updated);
    WidgetsBinding.instance.addObserver(this);
    unawaited(sync.sync());
    poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent != false) unawaited(sync.refreshProcessing());
    });
    playerState = player.playerStateStream.listen((state) {
      if (mounted && state.processingState == ProcessingState.completed) setState(() => playingId = null);
    });
  }

  void updated() {
    if (mounted) setState(() => page = page.clamp(0, lastPage));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(sync.sync());
    } else {
      unawaited(player.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sync.removeListener(updated);
    poll?.cancel();
    unawaited(playerState?.cancel());
    unawaited(player.dispose());
    scroll.dispose();
    super.dispose();
  }

  String date(RingRecording file) {
    final time = file.startedAt?.toLocal() ?? file.unverifiedDeviceTime;
    return time == null
        ? revampText(context, en: 'Recording time unknown', zh: '录音时间未知')
        : DateFormat('yyyy-MM-dd HH:mm:ss').format(time);
  }

  String stage(RingStage? value) => switch (value) {
        RingStage.downloading => revampText(context, en: 'Downloading over Bluetooth', zh: '蓝牙传输中'),
        RingStage.downloaded => revampText(context, en: 'Downloaded', zh: '已下载'),
        RingStage.uploading => revampText(context, en: 'Uploading', zh: '上传中'),
        RingStage.processing => revampText(context, en: 'Processing', zh: '处理中'),
        RingStage.completed => revampText(context, en: 'Completed', zh: '已完成'),
        RingStage.failed => revampText(context, en: 'Sync failed', zh: '同步失败'),
        RingStage.unsupported => revampText(context, en: 'Audio format not supported yet', zh: '暂不支持此音频格式'),
        RingStage.needsTime => revampText(context, en: 'Confirm recording time', zh: '请确认录音时间'),
        _ => revampText(context, en: 'Waiting to sync', zh: '等待同步'),
      };
  String error(Object value) {
    if (value is AudioUploadFailure) {
      return switch (value.issue) {
        AudioUploadIssue.quota =>
          revampText(context, en: 'Usage limit reached. Upgrade your plan, then retry.', zh: '已达到使用额度，升级套餐后可重试。'),
        AudioUploadIssue.auth => revampText(context, en: 'Sign in again to resume sync.', zh: '请重新登录以继续同步。'),
        AudioUploadIssue.noSpeech =>
          revampText(context, en: 'No recognizable speech. Your audio is kept.', zh: '未识别到清晰语音，音频已保留。'),
        AudioUploadIssue.duration =>
          revampText(context, en: 'Recordings must be between 5 seconds and 8 hours.', zh: '录音时长需在 5 秒到 8 小时之间。'),
        AudioUploadIssue.inFlight =>
          revampText(context, en: 'Confirming the previous upload. Please refresh later.', zh: '正在确认上次上传结果，请稍后刷新。'),
        _ => revampText(context,
            en: 'Upload interrupted. The completed download is kept; retry when online.', // i18n-ignore: Bilingual via revampText.
            zh: '上传中断，已下载的音频保留，联网后可重试。'),
      };
    }
    if (value is FormatException) {
      return revampText(context,
          en: 'Audio validation failed. Reconnect and retry; this file has not been uploaded.',
          zh: '音频校验失败，请重新连接后重试，该文件尚未上传。');
    }
    return revampText(context,
        en: 'The ring did not finish this operation. Wake it or reconnect, then retry.', // i18n-ignore: Bilingual via revampText.
        zh: '戒指未完成操作，请唤醒或重新连接后重试。');
  }

  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (value) {
      if (mounted) UndoDeleteHost.showMessage(context, error(value));
    }
  }

  Future<void> confirmTime(RingRecording file) async {
    final now = DateTime.now();
    final deviceTime = file.unverifiedDeviceTime;
    final initial = deviceTime != null && !deviceTime.isAfter(now) ? deviceTime : now;
    final selected =
        await showDatePicker(context: context, initialDate: initial, firstDate: DateTime(2020), lastDate: now);
    if (!mounted || selected == null) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (!mounted || time == null) return;
    await act(
        () => sync.confirmTime(file, DateTime(selected.year, selected.month, selected.day, time.hour, time.minute)));
  }

  Future<void> delete(RingRecording file) async {
    if (!sync.canRemove(file.id)) return;
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(revampText(ctx, en: 'Remove this recording?', zh: '删除这条记录？')),
                content: Text(revampText(ctx,
                    en: 'Remove local audio and stop syncing this recording. The original on the ring and existing timeline content are kept.',
                    zh: '删除本地音频，并停止同步这条录音。戒指上的原文件和已生成的时间线内容会保留。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false), child: Text(revampText(ctx, en: 'Cancel', zh: '取消'))),
                  TextButton(
                      key: const ValueKey('ring_delete_confirm'),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(revampText(ctx, en: 'Remove', zh: '删除')))
                ]));
    if (!mounted || confirm != true) return;
    if (playingId == file.id) {
      await player.stop();
      if (!mounted) return;
      setState(() => playingId = null);
    }
    if (!sync.reserveRemoval(file.id)) return;
    final undo = context.read<UndoDeleteController>();
    if (!undo.add(UndoDeletion(
        key: 'chiplet_ring:${widget.device.id}:${file.id}',
        kind: DeleteKind.recording,
        title: date(file),
        commit: () => sync.commitRemoval(file.id),
        cancel: () => sync.cancelRemoval(file.id)))) {
      sync.cancelRemoval(file.id);
    }
  }

  Future<void> play(RingRecording file) async {
    try {
      if (playingId == file.id) {
        await player.stop();
        if (mounted) setState(() => playingId = null);
        return;
      }
      final path = await sync.localAudioPath(file.id);
      if (path == null) return;
      await player.setFilePath(path);
      if (!mounted) return;
      setState(() => playingId = file.id);
      unawaited(player.play().catchError((Object _) {
        if (mounted) {
          setState(() => playingId = null);
          UndoDeleteHost.showMessage(context, revampText(context, en: 'Could not play local audio.', zh: '无法播放本地音频。'));
        }
      }));
    } catch (_) {
      if (mounted) {
        UndoDeleteHost.showMessage(context, revampText(context, en: 'Could not play local audio.', zh: '无法播放本地音频。'));
      }
    }
  }

  Widget row(RingRecording file) {
    final current = sync.stages[file.id];
    final job = sync.jobs[file.id];
    final completed = current == RingStage.completed || current == RingStage.processing;
    final transferring = current == RingStage.downloading || current == RingStage.uploading;
    final meta = [
      recorderDurationLabel(context, sync.durations[file.id], estimated: false),
      '${(file.size / 1024).toStringAsFixed(1)} KB'
    ].join(' · ');
    return SwipeActionRow(
        key: ValueKey('ring_swipe_${file.id}'),
        open: openId == file.id,
        onOpenChanged: (open) => setState(() => openId = open ? file.id : null),
        actions: sync.canRemove(file.id)
            ? [
                SwipeAction(
                    icon: Icons.delete_outline,
                    iconColor: JXB.error,
                    background: const Color(0xFFFAE3E3),
                    semanticLabel: revampText(context, en: 'Remove', zh: '删除'),
                    onTap: () => delete(file))
              ]
            : [],
        child: RecorderFileCard(
            key: ValueKey('ring_recording_${file.id}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Match the Soundcore card: timestamp/metadata on the left,
              // shared progress ring or compact status/action on the right.
              Row(children: [
                Expanded(
                    child: RecorderFileHeading(
                  date: date(file),
                  metadata: meta,
                  metadataKey: ValueKey('ring_metadata_${file.id}'),
                  status: [
                    if (!completed && job == null)
                      Text(stage(current),
                          key: ValueKey('ring_status_${file.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: JXB.caption.copyWith(color: transferring ? JXB.brandPrimary : JXB.textSecondary)),
                    if (file.startedAt == null && file.unverifiedDeviceTime != null)
                      Text(revampText(context, en: 'Device time · unconfirmed', zh: '设备时间 · 待确认'),
                          style: JXB.caption.copyWith(color: JXB.textSecondary)),
                  ],
                )),
                const SizedBox(width: JXB.space2),
                if (completed || job != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: Tooltip(
                      message: job != null ? audioJobLabel(context, job) : stage(current),
                      child: Text(job != null ? audioJobLabel(context, job, compact: true) : stage(current),
                          key: ValueKey('ring_status_${file.id}'),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style:
                              JXB.caption.copyWith(color: job?.needsAttention == true ? JXB.error : JXB.brandPrimary)),
                    ),
                  )
                else if (transferring)
                  RecorderProgressRing(
                    fraction: sync.activeId == file.id && sync.totalBytes > 0 ? sync.bytes / sync.totalBytes : null,
                    label: current == RingStage.uploading
                        ? revampText(context, en: 'Upload progress', zh: '上传进度')
                        : revampText(context, en: 'Bluetooth download progress', zh: '蓝牙下载进度'),
                    progressKey: ValueKey(current == RingStage.uploading
                        ? 'ring_upload_progress_${file.id}'
                        : 'ring_download_progress_${file.id}'),
                  )
                else if (current == RingStage.needsTime)
                  TextButton(
                    key: ValueKey('ring_confirm_time_${file.id}'),
                    onPressed: sync.busy ? null : () => confirmTime(file),
                    child: Text(revampText(context, en: 'Set time', zh: '设置时间')),
                  )
                else if (current != RingStage.unsupported)
                  TextButton(
                    key: ValueKey('ring_sync_${file.id}'),
                    style: TextButton.styleFrom(
                        minimumSize: const Size(48, JXB.sizeTouch),
                        padding: const EdgeInsets.symmetric(horizontal: JXB.space2),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: JXB.metaButton),
                    onPressed: sync.busy ? null : () => act(() => sync.retry(file.id)),
                    child: Text(current == RingStage.failed
                        ? revampText(context, en: 'Retry', zh: '重试')
                        : revampText(context, en: 'Sync', zh: '同步')),
                  ),
              ]),
              if (file.startedAt == null && file.unverifiedDeviceTime == null)
                Text(file.name, style: JXB.caption.copyWith(color: JXB.textSecondary)),
              if (sync.errors[file.id] != null)
                Text(error(sync.errors[file.id]!), style: JXB.caption.copyWith(color: JXB.error)),
              if (job?.needsAttention == true)
                Text(audioJobError(context, job?.errorCode), style: JXB.caption.copyWith(color: JXB.error)),
              Wrap(alignment: WrapAlignment.end, children: [
                if (sync.localAudio.contains(file.id) && sync.activeId != file.id)
                  Semantics(
                      container: true,
                      child: IconButton(
                          tooltip: playingId == file.id
                              ? revampText(context, en: 'Stop playback', zh: '停止播放')
                              : revampText(context, en: 'Play local audio', zh: '播放本地音频'),
                          icon: Icon(playingId == file.id ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                          onPressed: () => play(file))),
                if (job?.canRetry == true)
                  TextButton(
                      onPressed: sync.busy ? null : () => act(() => sync.retry(file.id)),
                      child: Text(revampText(context, en: 'Retry processing', zh: '重试处理'))),
              ]),
            ])));
  }

  @override
  Widget build(BuildContext context) {
    final visible = files.skip(page * pageSize).take(pageSize);
    final uploaded = files.where((file) => sync.receipts.containsKey(file.id)).length;
    final active = files.where((file) => file.id == sync.activeId).firstOrNull;
    return RecorderPage(
        title: revampText(context, en: 'Ring recordings', zh: '戒指录音'),
        onRefresh: () async {
          setState(() => page = 0);
          await sync.sync();
        },
        scrollController: scroll,
        children: [
          RecorderPanel(
            key: const ValueKey('ring_refresh_status'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                sync.loading
                    ? revampText(context, en: 'Reading recorder…', zh: '正在读取设备录音…')
                    : sync.deviceFileCount == null
                        ? (sync.readError != null
                            ? revampText(context, en: 'Refresh failed', zh: '刷新失败')
                            : revampText(context, en: 'Waiting for ring connection', zh: '等待连接戒指'))
                        : revampText(context,
                            en: '${sync.deviceFileCount} recordings on device', zh: '设备中有 ${sync.deviceFileCount} 条录音'),
                style: JXB.body,
              ),
              if (sync.lastRefresh != null) ...[
                const SizedBox(height: 6),
                Text(
                  revampText(context,
                      en: 'Last checked: ${DateFormat('HH:mm:ss').format(sync.lastRefresh!)}',
                      zh: '上次刷新：${DateFormat('HH:mm:ss').format(sync.lastRefresh!)}'),
                  style: JXB.body.copyWith(color: JXB.textSecondary),
                ),
              ],
              if (!sync.loading) ...[
                if (sync.deviceFileCount == null && files.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    revampText(context,
                        en: 'Showing known recordings. The device list will update after reconnecting.',
                        zh: '显示已读取的录音，连接设备后更新列表。'),
                    style: JXB.bodySmall.copyWith(color: JXB.textSecondary),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  revampText(context,
                      en: 'Pending: ${files.length - uploaded} · Uploaded: $uploaded',
                      zh: '待同步 ${files.length - uploaded} 条 · 已上传 $uploaded 条'),
                  style: JXB.body.copyWith(color: JXB.textSecondary),
                ),
              ],
              if (active != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${date(active)} · ${stage(sync.stages[active.id])}'
                    '${sync.totalBytes > 0 ? ' · ${(sync.bytes / 1024).toStringAsFixed(1)} / ${(sync.totalBytes / 1024).toStringAsFixed(1)} KB' : ''}',
                    key: const ValueKey('ring_active_sync'),
                    style: JXB.bodySmall.copyWith(color: JXB.brandPrimary),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 14),
          Text(
            revampText(context,
                en: 'Recordings sync automatically when connected. You can leave this page while downloading or uploading; results appear in your timeline.',
                zh: '设备连接后自动同步录音。下载或上传时可以返回其他页面，转录结果会出现在时间线中。'),
            style: JXB.body.copyWith(color: JXB.textSecondary),
          ),
          AudioJobsLink(api: widget.jobsApi, onReturn: () => unawaited(sync.refreshProcessing())),
          const SizedBox(height: JXB.space3),
          RecorderPanel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
                sync.connected
                    ? revampText(context, en: 'Ring connected · Bluetooth sync', zh: '戒指已连接 · 蓝牙同步')
                    : revampText(context, en: 'Ring disconnected · local history available', zh: '戒指未连接 · 可查看本地历史'),
                style: JXB.bodySmall),
            if (!sync.connected)
              TextButton(
                  key: const ValueKey('ring_reconnect'),
                  onPressed: sync.busy ? null : () => act(sync.reconnect),
                  child: Text(revampText(context, en: 'Reconnect', zh: '重新连接'))),
            Text(
                revampText(context,
                    en: 'Record with the ring microphone while connected. Audio is saved on this phone, then uploaded for transcription after you stop.',
                    zh: '连接后使用戒指麦克风录音，音频先保存到手机，停止后上传转写。'),
                style: JXB.caption.copyWith(color: JXB.textSecondary)),
            const SizedBox(height: 8),
            Text(
                revampText(context,
                    en: 'Keep the ring connected until you stop recording. Refresh to sync recordings stored on the ring.',
                    zh: '录音期间请保持戒指连接。刷新可同步戒指上已有的录音。'),
                style: JXB.caption.copyWith(color: JXB.textSecondary)),
            if (sync.recording)
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (sync.recordingStartedAt != null)
                      Text(DateFormat('yyyy-MM-dd HH:mm:ss').format(sync.recordingStartedAt!.toLocal()),
                          key: const ValueKey('ring_recording_started_at'), style: JXB.bodySmall),
                    Text(
                      revampText(context, en: 'Recording · ', zh: '录音中 · ') +
                          recorderDurationLabel(context, sync.recordingDuration, estimated: false),
                      key: const ValueKey('ring_recording_duration'),
                      style: JXB.bodySmall.copyWith(color: JXB.brandPrimary),
                    ),
                  ]),
                ),
                RecorderProgressRing(
                    key: const ValueKey('ring_recording_active'),
                    progressKey: const ValueKey('ring_recording_indicator'),
                    fraction: null,
                    estimated: false,
                    label: revampText(context, en: 'Recording', zh: '录音中')),
              ]),
            if (sync.recordingError != null)
              Text(error(sync.recordingError!), style: JXB.caption.copyWith(color: JXB.error)),
            ElevatedButton(
                key: const ValueKey('ring_record_toggle'),
                onPressed: sync.recordBusy || (!sync.recording && (sync.busy || !sync.connected))
                    ? null
                    : () => act(sync.recording ? sync.stopRecording : sync.startRecording),
                child: Text(sync.recordBusy
                    ? revampText(context, en: 'Please wait', zh: '请稍候')
                    : sync.recording
                        ? revampText(context, en: 'Stop and sync', zh: '停止并同步')
                        : revampText(context, en: 'Start ring recording', zh: '开始戒指录音'))),
          ])),
          const SizedBox(height: JXB.space3),
          if (uploaded > 0)
            Text(revampText(context, en: 'Recordings · cloud status updates after upload', zh: '录音列表 · 上传后显示云端处理状态'),
                style: JXB.bodySmall),
          if (sync.loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (sync.readError != null)
            RecorderPanel(child: Text(error(sync.readError!), style: JXB.caption.copyWith(color: JXB.error))),
          if (files.isEmpty && !sync.loading)
            RecorderPanel(
                child: Text(revampText(context,
                    en: 'No recordings yet. Connect your ring and start recording, or refresh to read device files.',
                    zh: '暂无录音。连接戒指后开始录音，或刷新读取设备文件。'))),
          const SizedBox(height: JXB.space3),
          ...visible.map(row),
          if (files.isNotEmpty)
            RecorderPagination(
                keyPrefix: 'ring',
                page: page,
                count: files.length,
                pageSize: pageSize,
                onChanged: (value) {
                  setState(() {
                    page = value;
                    openId = null;
                  });
                  if (scroll.hasClients) scroll.jumpTo(0);
                }),
          const SizedBox(height: 12),
          Text(revampText(context, en: 'Original recordings stay on the device.', zh: '设备中的原录音会保留。'),
              style: JXB.body.copyWith(color: JXB.textSecondary)),
          TextButton(
              key: const ValueKey('ring_copy_diagnostics'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(
                    text:
                        'ChipletRing\nhardware=${widget.device.hardwareRevision}\nfirmware=${widget.device.firmwareRevision}\nconnected=${sync.connected}\ndeviceFiles=${sync.deviceFileCount}\nerror=${sync.readError}\nfailures=${sync.errors.values.join('; ')}'));
                if (context.mounted) {
                  UndoDeleteHost.showMessage(context, revampText(context, en: 'Diagnostics copied', zh: '诊断信息已复制'));
                }
              },
              child: Text(revampText(context, en: 'Copy connection diagnostics', zh: '复制连接诊断'))),
        ]);
  }
}
