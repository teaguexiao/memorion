import 'dart:async';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:intl/intl.dart';
import 'package:memorion/backend/http/api/audio_jobs.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

String audioJobLabel(BuildContext context, AudioProcessingJob job, {bool compact = false}) {
  if (job.status == 'completed' && job.discarded) {
    if (compact) return revampText(context, en: 'Filtered', zh: '已过滤');
    return revampText(context, en: 'Processed · filtered', zh: '处理完成 · 已过滤');
  }
  if (job.status == 'failed') return revampText(context, en: compact ? 'Failed' : 'Processing failed', zh: '处理失败');
  if (job.status == 'retry_wait') {
    return compact
        ? revampText(context, en: 'Retry queued', zh: '待重试')
        : revampText(context, en: 'Waiting to retry', zh: '等待自动重试');
  }
  if (job.status == 'cancelled') return revampText(context, en: 'Cancelled', zh: '已取消');
  if (job.status == 'completed') return revampText(context, en: 'Completed', zh: '已完成');
  if (job.status == 'uploading') {
    return compact
        ? revampText(context, en: 'Awaiting upload', zh: '待上传')
        : revampText(context, en: 'Waiting for upload', zh: '等待上传完成');
  }
  if (job.status == 'queued') {
    return compact
        ? revampText(context, en: 'Queued', zh: '排队中')
        : revampText(context, en: 'Saved to cloud · queued', zh: '已保存到云端 · 排队中');
  }
  if (compact) {
    return switch (job.stage) {
      'validate' => revampText(context, en: 'Checking', zh: '检查中'),
      'transcribe' => revampText(context, en: 'Transcribing', zh: '转录中'),
      'summarize' => revampText(context, en: 'Summarizing', zh: '总结中'),
      'publish' => revampText(context, en: 'Saving', zh: '保存中'),
      _ => revampText(context, en: 'Processing', zh: '处理中'),
    };
  }
  return switch (job.stage) {
    'validate' => revampText(context, en: 'Checking audio', zh: '检查音频中'),
    'transcribe' => revampText(context, en: 'Transcribing', zh: '转录中'),
    'speakers' => revampText(context, en: 'Identifying speakers', zh: '识别说话人中'),
    'summarize' => revampText(context, en: 'Generating summary', zh: '生成摘要中'),
    'publish' => revampText(context, en: 'Saving conversation', zh: '保存对话中'),
    _ => revampText(context, en: 'Processing', zh: '处理中'),
  };
}

String audioJobError(BuildContext context, String? code) => switch (code) {
      'invalid_audio' => revampText(context,
          en: 'The audio format is invalid. Please upload a valid recording.',
          zh: '录音格式无效，请重新上传有效录音。'), // i18n-ignore: English half of the adjacent revampText translation.
      'no_speech' => revampText(context, en: 'No recognizable speech. Your audio is kept.', zh: '未识别到清晰语音，音频已保留。'),
      'audio_integrity' =>
        revampText(context, en: 'Audio integrity check failed. Upload the original again.', zh: '音频完整性校验失败，请重新上传原文件。'),
      'provider_auth' => revampText(context,
          en: 'The transcription service is unavailable. Your audio is kept.',
          zh: '转录服务暂时不可用，音频已保留。'), // i18n-ignore: English half of the adjacent revampText translation.
      'provider_rate_limit' =>
        revampText(context, en: 'The transcription service is busy. Retrying automatically.', zh: '转录服务繁忙，将自动重试。'),
      'provider_submission_unknown' => revampText(context,
          en: 'Transcription submission needs verification. Your audio is kept; contact support.',
          zh: '转录提交状态需要核对，音频已保留，请联系支持。'),
      'provider_job_missing' => revampText(context,
          en: 'The transcription task could not be found. Your audio is kept; contact support.',
          zh: '未找到转录任务，音频已保留，请联系支持。'),
      'workflow_delivery_failed' =>
        revampText(context, en: 'Workflow sync failed. Your conversation is saved.', zh: '工作流同步失败，对话已保存。'),
      _ => revampText(context,
          en: 'Processing was interrupted. Your cloud audio and completed steps are kept.',
          zh: '处理暂时中断，云端音频及已完成的步骤均已保留。'),
    };

class AudioJobsPage extends StatefulWidget {
  final AudioJobsApi? api;
  const AudioJobsPage({super.key, this.api});
  @override
  State<AudioJobsPage> createState() => _AudioJobsPageState();
}

class _AudioJobsPageState extends State<AudioJobsPage> with WidgetsBindingObserver {
  late final AudioJobsApi _api = widget.api ?? AudioJobsApi();
  late final String _owner = _api.ownerId;
  List<AudioProcessingJob> _jobs = [];
  String? _next;
  bool _loading = false;
  bool _reloadAfterLoad = false;
  bool _failed = false;
  bool _active = true;
  final Set<String> _retrying = {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_active) unawaited(_load());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || !mounted) return;
    if (_owner != _api.ownerId) {
      setState(() {
        _jobs = [];
        _next = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await _api.list(before: more ? _next : null);
      if (mounted && _owner == _api.ownerId) {
        setState(() {
          _jobs = more ? [..._jobs, ...result.items] : result.items;
          _next = result.nextCursor;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_reloadAfterLoad) {
          _reloadAfterLoad = false;
          unawaited(_load());
        }
      }
    }
  }

  Future<void> _retry(AudioProcessingJob job) async {
    if (!_retrying.add(job.id)) return;
    setState(() {});
    try {
      await _api.retry(job.id);
      if (_loading) {
        _reloadAfterLoad = true;
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted) {
        UndoDeleteHost.showMessage(
            context, revampText(context, en: 'Could not retry. Please refresh and try again.', zh: '重试未成功，请刷新后再试。'));
      }
    } finally {
      if (mounted) setState(() => _retrying.remove(job.id));
    }
  }

  String _followupLabel(String stage) => switch (stage) {
        'timeline' => revampText(context, en: 'Timeline', zh: '时间线'),
        'memories' => revampText(context, en: 'Memories', zh: '记忆提取'),
        'people' => revampText(context, en: 'People', zh: '人物提取'),
        'search' => revampText(context, en: 'Search', zh: '搜索索引'),
        'webhooks' => revampText(context, en: 'Workflow sync', zh: '工作流同步'),
        'emotion' => revampText(context, en: 'Emotion insights', zh: '情绪洞察'),
        _ => revampText(context, en: 'Finishing up', zh: '后续处理'),
      };

  Widget _status(AudioProcessingJob job) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(audioJobLabel(context, job),
            style: TextStyle(color: job.status == 'failed' ? Colors.red : JXB.brandPrimary)),
        if (job.errorCode != null) Text(audioJobError(context, job.errorCode)),
        if (job.status == 'retry_wait' && job.nextAttemptAt != null)
          Text(revampText(context, en: 'Next attempt: ', zh: '下次尝试：') +
              DateFormat('HH:mm:ss').format(job.nextAttemptAt!.toLocal())),
        if (job.canRetry)
          TextButton(
            key: ValueKey('retry_job_${job.id}'),
            onPressed: _retrying.contains(job.id) ? null : () => _retry(job),
            child: Text(revampText(context, en: 'Retry processing', zh: '重试处理')),
          ),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: JXB.bgApp,
        appBar: AppBar(title: Text(revampText(context, en: 'Recording processing', zh: '录音处理'))),
        body: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Text(revampText(context,
                  en: 'Cloud tasks for your account appear here after upload. Retrying uses the saved audio; no recorder connection is needed.',
                  zh: '此处显示当前账号已上传录音的云端任务，尚未上传的录音不会显示。重试复用云端音频，无需连接设备。')),
              if (_loading) const LinearProgressIndicator(),
              if (_failed)
                Text(revampText(context,
                    en: 'Could not refresh processing status. Pull down to retry.',
                    zh: '暂时无法更新处理状态，请下拉重试。')), // i18n-ignore: English half of the adjacent revampText translation.
              if (!_loading && !_failed && _jobs.isEmpty)
                Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(revampText(context, en: 'No recording tasks yet', zh: '暂无录音处理任务'))),
              for (final job in _jobs)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(DateFormat('yyyy-MM-dd HH:mm:ss').format(job.startedAt.toLocal())),
                            _status(job),
                            if (job.followups.any((child) => child.status != 'completed'))
                              ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                title: Text(revampText(context, en: 'Follow-up processing', zh: '后续处理')),
                                children: [
                                  for (final child in job.followups.where((child) => child.status != 'completed'))
                                    Padding(
                                        padding: const EdgeInsets.only(bottom: 12),
                                        child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [Text(_followupLabel(child.stage)), _status(child)]))
                                ],
                              ),
                          ],
                        ))),
              if (_next != null)
                TextButton(
                    onPressed: _loading ? null : () => _load(more: true),
                    child: Text(revampText(context, en: 'Load more', zh: '加载更多'))),
            ])),
      );
}

class AudioJobsLink extends StatelessWidget {
  final VoidCallback? onReturn;
  final AudioJobsApi? api;
  const AudioJobsLink({super.key, this.onReturn, this.api});
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.cloud_sync_outlined),
        title: Text(revampText(context, en: 'Recording processing', zh: '录音处理')),
        subtitle: Text(revampText(context, en: 'View progress and retry failed tasks', zh: '查看云端进度与重试失败任务')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AudioJobsPage(api: api)));
          if (context.mounted) onReturn?.call();
        },
      );
}
