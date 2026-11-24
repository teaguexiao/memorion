import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:memorion/backend/http/api/conversation_shares.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:memorion/widgets/summary_markdown.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

Future<void> showConversationShareSheet(BuildContext context, ServerConversation conversation,
        {ConversationSharingApi? api}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: JXB.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => ConversationShareSheet(conversation: conversation, api: api),
    );

class ConversationShareSheet extends StatefulWidget {
  final ServerConversation conversation;
  final ConversationSharingApi? api;
  const ConversationShareSheet({super.key, required this.conversation, this.api});
  @override
  State<ConversationShareSheet> createState() => _ConversationShareSheetState();
}

class _ConversationShareSheetState extends State<ConversationShareSheet> {
  late final ConversationSharingApi _api;
  ConversationShare? _share;
  bool _loading = true, _busy = false, _uncertain = false;
  String _mode = 'seven_days';
  String? _error;
  String _requestId = const Uuid().v4();
  bool get _active =>
      _share?.active == true &&
      (_share!.expiryMode == 'never' ||
          (_share!.expiryMode == 'seven_days' && (_share!.expiresAt?.isAfter(DateTime.now()) ?? false)));

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? HttpConversationSharingApi();
    _load();
  }

  @override
  void dispose() {
    if (widget.api == null) _api.close();
    super.dispose();
  }

  String _message(Object error) {
    final code = error is ShareFailure ? error.status : 0;
    if (code == 401) return revampText(context, en: 'Please sign in again to manage sharing.', zh: '请重新登录后管理分享。');
    if (code == 409) {
      return revampText(context, en: 'A link already exists. Refresh its status to manage it.', zh: '链接已存在，请刷新状态后管理。');
    }
    if (code == 404) {
      return revampText(context, en: 'This recording or link is no longer available.', zh: '这条录音或链接已不可用。');
    }
    if (code == 429) return revampText(context, en: 'Too many requests. Please try again later.', zh: '操作较频繁，请稍后重试。');
    if (code == 503) return revampText(context, en: 'Link sharing is temporarily unavailable.', zh: '链接分享暂时不可用。');
    return revampText(context,
        en: 'Could not confirm the result. Refresh before trying again.',
        zh: '暂时无法确认操作结果，请先刷新状态。'); // i18n-ignore: bilingual revampText argument
  }

  Future<void> _load() async {
    try {
      final share = await _api.load(widget.conversation.id);
      if (!mounted) return;
      setState(() {
        _share = share;
        _loading = false;
        _uncertain = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _uncertain = true;
          _error = _message(e);
        });
      }
    }
  }

  Future<void> _mutate({bool rotate = false, bool revoke = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (revoke) {
        await _api.revoke(_share!.id);
        if (mounted) setState(() => _share = null);
      } else {
        final result = rotate
            ? await _api.rotate(_share!.id, _requestId)
            : await _api.create(widget.conversation.id, _mode, _requestId);
        if (mounted) setState(() => _share = result);
      }
      _requestId = const Uuid().v4();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _uncertain = true;
          _share = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRotate() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(revampText(context, en: 'Replace this link?', zh: '重新生成链接？')),
              content: Text(revampText(context,
                  en: 'The old link will stop working. Its expiry date will not change.',
                  zh: '旧链接将立即失效，有效期保持不变。')), // i18n-ignore: bilingual revampText argument
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(revampText(context, en: 'Replace link', zh: '重新生成')))
              ],
            ));
    if (ok == true && mounted) {
      _requestId = const Uuid().v4();
      await _mutate(rotate: true);
    }
  }

  String get _shareTitle {
    final title = widget.conversation.structured.title.trim();
    return title.isEmpty ? revampText(context, en: 'Shared conversation · Memorion', zh: '章节分享 · Memorion') : title;
  }

  String get _shareText => '$_shareTitle\n${_share!.url!}';

  Future<void> _send() async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await Share.share(_shareText,
          subject: _shareTitle,
          sharePositionOrigin:
              box == null ? const Rect.fromLTWH(0, 0, 1, 1) : box.localToGlobal(Offset.zero) & box.size);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = revampText(context, en: 'Unable to open sharing. Please copy the link.', zh: '无法打开系统分享，请复制链接。'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(revampText(context, en: 'Share link', zh: '分享链接'),
                      style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600, color: JXB.textPrimary))),
              IconButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  tooltip: revampText(context, en: 'Close', zh: '关闭'))
            ]),
            Text(widget.conversation.structured.title, style: const TextStyle(fontSize: 15, color: JXB.textSecondary)),
            const SizedBox(height: 16),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(revampText(context, en: 'Preview summary', zh: '预览摘要')),
                children: [
                  SummaryMarkdown(
                      data: widget.conversation.structured.overview, style: const TextStyle(fontSize: 14, height: 1.7))
                ]),
            const SizedBox(height: 12),
            Text(revampText(context, en: 'Summary + full transcript', zh: '摘要 + 全文'),
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 4),
            Text(
                revampText(context,
                    en: 'No audio, photos or identity details. Speakers use numbers.', zh: '不含音频、照片和身份资料，说话人以编号显示。'),
                style: const TextStyle(fontSize: 13, color: JXB.textSecondary)),
            const SizedBox(height: 18),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (!_active && !_uncertain) ...[
              Text(revampText(context, en: 'Link expiry', zh: '链接有效期'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'seven_days', label: Text(revampText(context, en: '7 days', zh: '7 天'))),
                        ButtonSegment(value: 'never', label: Text(revampText(context, en: 'Permanent', zh: '永久'))),
                      ],
                      selected: {
                        _mode
                      },
                      onSelectionChanged: _busy
                          ? null
                          : (v) => setState(() {
                                _mode = v.first;
                                _requestId = const Uuid().v4();
                              }))),
              const SizedBox(height: 8),
              Text(
                  _mode == 'never'
                      ? revampText(context,
                          en: 'No automatic expiry. You can stop sharing anytime.',
                          zh: '不会自动到期，你可以随时停止分享。') // i18n-ignore: bilingual revampText argument
                      : revampText(context, en: 'Expires 7 days after creation.', zh: '创建后 7 天自动失效。'),
                  style: const TextStyle(fontSize: 12, color: JXB.textSecondary)),
            ],
            if (_active)
              Text(
                  _share!.expiryMode == 'never'
                      ? revampText(context, en: 'Permanent · you can revoke it anytime', zh: '永久有效 · 可随时停止分享')
                      : '${revampText(context, en: 'Expires', zh: '到期时间')} ${DateFormat('yyyy-MM-dd HH:mm').format(_share!.expiresAt!.toLocal())}',
                  style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 16),
            Text(
                revampText(context,
                    en: 'Anyone with the link can read and forward it. Saved edits to this recording also update the shared content. Check the text before sharing.',
                    zh: '任何获得链接的人都能查看和转发。修改原记录后，分享内容也会更新。请确认正文没有不希望公开的信息。'),
                style: const TextStyle(fontSize: 12, color: JXB.textSecondary, height: 1.7)),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red),
                      key: const Key('share-error'))), // i18n-ignore: widget test identifier
            const SizedBox(height: 16),
            if (_uncertain)
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      onPressed: _busy ? null : _load,
                      child: Text(revampText(context, en: 'Refresh status', zh: '刷新状态'))))
            else if (!_loading && !_active)
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                      onPressed: _busy ? null : () => _mutate(),
                      child: Text(_busy
                          ? revampText(context, en: 'Creating…', zh: '创建中…')
                          : revampText(context, en: 'Create share link', zh: '创建分享链接')))),
            if (_active) ...[
              if (_share!.url != null)
                Row(children: [
                  Expanded(
                      child: OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  await Clipboard.setData(ClipboardData(text: _shareText));
                                  if (context.mounted) {
                                    UndoDeleteHost.showMessage(context, revampText(context, en: 'Title and link copied', zh: '标题和链接已复制'));
                                  }
                                },
                          child: Text(revampText(context, en: 'Copy link', zh: '复制链接')))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: FilledButton(
                          onPressed: _busy ? null : _send, child: Text(revampText(context, en: 'Share', zh: '分享')))),
                ])
              else ...[
                Text(
                    revampText(context,
                        en: 'For privacy, the original link is not stored on this device. Replace it to share again.',
                        zh: '为保护隐私，此设备未保存原链接。可以重新生成后分享。'),
                    style: const TextStyle(fontSize: 12, color: JXB.textSecondary)),
                OutlinedButton(
                    onPressed: _busy ? null : _confirmRotate,
                    child: Text(revampText(context, en: 'Replace link', zh: '重新生成链接'))),
              ],
              TextButton(
                  onPressed: _busy ? null : () => _mutate(revoke: true),
                  child: Text(revampText(context, en: 'Stop sharing', zh: '停止分享'),
                      style: const TextStyle(color: Colors.red))),
            ],
          ]),
        ));
  }
}
