import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/pages/today_chapters/device_detail_page.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/device_provider.dart';
import 'package:memorion/services/wals.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// 传统 BLE 设备详情下的待同步录音管理；离线导入设备使用各自的录音页。
/// 仅显示真实队列和进行中的同步，不承诺连接后自动补传。
class SyncStatusPage extends StatefulWidget {
  const SyncStatusPage({super.key});

  @override
  State<SyncStatusPage> createState() => _SyncStatusPageState();
}

class _SyncStatusPageState extends State<SyncStatusPage> {
  bool _deleting = false;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.light(useMaterial3: false).copyWith(
        scaffoldBackgroundColor: JXB.bgApp,
        colorScheme: const ColorScheme.light(primary: JXB.brandPrimary),
      ),
      child: DefaultTextStyle(
        style: JXB.body,
        child: Scaffold(
          backgroundColor: JXB.bgApp,
          body: SafeArea(
            child: Column(
              children: [
                _detailBar(context),
                Expanded(
                  child: Consumer2<DeviceProvider, ConversationProvider>(
                    builder: (context, dp, cp, _) => _body(context, dp, cp),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, DeviceProvider dp, ConversationProvider cp) {
    final connected = dp.isConnected && dp.connectedDevice != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      children: [
        _statusCard(context, connected, _syncing(cp), cp.missingWals.isNotEmpty),
        const SizedBox(height: 22),
        _sectionLabel(revampText(context, en: 'Pending Recordings', zh: '待同步录音')),
        const SizedBox(height: 10),
        ..._buildSyncList(context, cp, dp),
        if (cp.missingWals.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
              revampText(context,
                  en: 'These recordings have not finished syncing. Deleting them cannot be undone.',
                  zh: '这些录音尚未完成同步，删除后无法恢复。'),
              style: JXB.bodySmall),
          const SizedBox(height: 8),
          TextButton(
            key: const ValueKey('delete_all_pending_recordings'),
            onPressed:
                _canDelete(cp, dp, cp.missingWals) ? () => _confirmDelete(context, cp, [...cp.missingWals]) : null,
            style: TextButton.styleFrom(foregroundColor: JXB.error),
            child: Text(revampText(context, en: 'Delete all pending recordings', zh: '删除全部待同步录音')),
          ),
        ],
      ],
    );
  }

  Widget _detailBar(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(
                  width: 36, height: 36, child: Icon(Icons.chevron_left_rounded, size: 26, color: JXB.textPrimary)),
            ),
            Expanded(
              child: Text(revampText(context, en: 'Sync Status', zh: '同步状态'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: JXB.fontSans, fontSize: 16, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
            ),
            const SizedBox(width: 36),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context, bool connected, bool syncing, bool pending) {
    if (!connected && !syncing) {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DeviceDetailPage())),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
              color: JXB.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: JXB.border, width: 1)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(revampText(context, en: 'Device Not Connected', zh: '设备未连接'),
                        style: const TextStyle(
                            fontFamily: JXB.fontSans,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: JXB.textPrimary)),
                    const SizedBox(height: 8),
                    Text(
                        revampText(context,
                            en: 'Phone recordings stay available here. Connect your device to view its pending recordings.',
                            zh: '手机中的待同步录音会保留在这里。连接设备后可查看设备中的待同步录音。'),
                        style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20, color: JXB.textPlaceholder),
            ],
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              syncing
                  ? revampText(context, en: 'Syncing recordings', zh: '正在同步录音')
                  : pending
                      ? revampText(context, en: 'Device connected · Pending recordings', zh: '设备已连接 · 有待同步录音')
                      : revampText(context, en: 'Device connected · No pending recordings', zh: '设备已连接 · 暂无待同步录音'),
              style: const TextStyle(
                  fontFamily: JXB.fontSans, fontSize: 17, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
          const SizedBox(height: 8),
          Text(
              revampText(context,
                  en: 'Recordings remain here until synced or deleted.', zh: '未完成同步的录音会保留在这里，直到同步完成或被删除。'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textSecondary)),
        ],
      ),
    );
  }

  List<Widget> _buildSyncList(BuildContext context, ConversationProvider cp, DeviceProvider dp) {
    final items = <Widget>[];
    // 真数据：待同步 / 同步中（missingWals，按时间倒序）。
    final sorted = [...cp.missingWals]..sort((a, b) => b.timerStart.compareTo(a.timerStart));
    for (final w in sorted) {
      final status = w.status == WalStatus.inProgress || w.isSyncing ? _SyncState.syncing : _SyncState.pending;
      items.add(_syncRow(context, w, status, cp, dp));
      items.add(const SizedBox(height: 12));
    }
    if (items.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 30),
          alignment: Alignment.center,
          child: Text(revampText(context, en: 'No pending recordings', zh: '暂无待同步录音'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 14, color: JXB.textPlaceholder)),
        ),
      ];
    }
    return items;
  }

  Widget _syncRow(BuildContext context, Wal wal, _SyncState state, ConversationProvider cp, DeviceProvider dp) {
    final mins = (wal.seconds / 60).round();
    late final String label;
    late final Color fg;
    late final Color bg;
    switch (state) {
      case _SyncState.syncing:
        label = revampText(context, en: 'Syncing', zh: '同步中');
        fg = JXB.brandPrimary;
        bg = const Color(0x17007AFF);
      case _SyncState.pending:
        label = revampText(context, en: 'Pending', zh: '待同步');
        fg = JXB.textSecondary;
        bg = const Color(0x1A808594);
    }
    return Container(
      key: ValueKey('pending_recording_${wal.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: JXB.border, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_fmtTime(wal.timerStart),
              style: const TextStyle(
                  fontFamily: JXB.fontSans, fontSize: 15, fontWeight: FontWeight.w700, color: JXB.textPrimary)),
          const SizedBox(height: 3),
          Text(
              wal.storage == WalStorage.sdcard
                  ? revampText(context, en: 'On device · $mins min', zh: '设备中 · 时长 $mins 分')
                  : revampText(context, en: 'On phone · $mins min', zh: '手机中 · 时长 $mins 分'),
              style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: JXB.textSecondary)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
                      child: Text(label,
                          style: TextStyle(
                              fontFamily: JXB.fontSans, fontSize: 13, fontWeight: FontWeight.w700, color: fg)),
                    ))),
            IconButton(
              key: ValueKey('delete_pending_${wal.id}'),
              tooltip: revampText(context, en: 'Delete recording', zh: '删除录音'),
              color: JXB.error,
              onPressed: _canDelete(cp, dp, [wal]) ? () => _confirmDelete(context, cp, [wal]) : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
          ]),
        ],
      ),
    );
  }

  bool _syncing(ConversationProvider cp) =>
      cp.isSyncing || cp.multipleSyncs.isNotEmpty || cp.missingWals.any((w) => w.isSyncing);

  bool _canDelete(ConversationProvider cp, DeviceProvider dp, List<Wal> wals) =>
      !_deleting &&
      !_syncing(cp) &&
      wals.every((w) =>
          w.status == WalStatus.miss &&
          (w.storage != WalStorage.sdcard || (dp.canStreamAudio && dp.connectedDevice?.id == w.device)));

  Future<void> _confirmDelete(BuildContext context, ConversationProvider cp, List<Wal> wals) async {
    setState(() => _deleting = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: JXB.surface,
          title: Text(
              wals.length == 1
                  ? revampText(context, en: 'Delete pending recording?', zh: '删除待同步录音？')
                  : revampText(context, en: 'Delete pending recordings?', zh: '删除待同步录音？'),
              style: JXB.sectionTitle),
          content: Text(
              revampText(context,
                  en: wals.length == 1
                      ? 'Delete this recording from phone or device storage? Unsynced content cannot be recovered.'
                      : 'Delete these ${wals.length} recordings from their phone or device storage? Unsynced content cannot be recovered.',
                  zh: '将从手机或设备中删除这 ${wals.length} 段录音，未同步的内容将无法恢复。'),
              style: JXB.body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
            TextButton(
              key: const ValueKey('confirm_delete_pending_recordings'),
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: JXB.error),
              child: Text(revampText(context, en: 'Delete', zh: '删除')),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      // Delete only the confirmed snapshot; newly arrived recordings are untouched.
      for (final wal in wals) {
        await cp.deletePendingWal(wal);
      }
    } catch (error) {
      debugPrint('Pending recording deletion failed: $error');
      if (context.mounted) {
        UndoDeleteHost.showMessage(context, revampText(context,
                en: 'Could not delete recordings. Check the device connection and wait for syncing to finish, then try again.',
                zh: '未能删除录音，请检查设备连接并等待同步结束后重试。'));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Widget _sectionLabel(String text) {
    return Row(
      children: [
        Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(color: JXB.brandPrimary, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 7),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontFamily: JXB.fontSans, fontSize: 14, fontWeight: FontWeight.w700, color: JXB.textSecondary)),
        ),
      ],
    );
  }

  String _fmtTime(int epochSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

enum _SyncState { syncing, pending }
