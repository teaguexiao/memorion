import 'dart:async';
import 'package:flutter/material.dart';
import 'package:memorion/services/devices/chiplet_ring/models.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Ring-only storage controls; shares the recording/import controller's lock.
class RingStorageCard extends StatefulWidget {
  final RingSyncController controller;
  final bool connected;
  const RingStorageCard({super.key, required this.controller, required this.connected});
  @override
  State<RingStorageCard> createState() => _RingStorageCardState();
}

class _RingStorageCardState extends State<RingStorageCard> {
  RingDeviceSnapshot? snapshot;
  bool requesting = false, attempted = false, cleared = false;
  Object? error;
  RingSyncController get sync => widget.controller;
  @override
  void initState() {
    super.initState();
    sync.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeRead());
  }

  @override
  void didUpdateWidget(RingStorageCard old) {
    super.didUpdateWidget(old);
    if (old.controller != sync) {
      old.controller.removeListener(changed);
      sync.addListener(changed);
      snapshot = null;
      attempted = false;
      error = null;
      cleared = false;
    }
    if (old.connected != widget.connected) {
      snapshot = null;
      attempted = false;
      error = null;
      cleared = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeRead());
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
    maybeRead();
  }

  void maybeRead() {
    if (mounted && !attempted && widget.connected && !sync.busy) unawaited(read());
  }

  Future<void> read({bool erase = false}) async {
    if (!mounted || requesting || !widget.connected || sync.busy) return;
    setState(() {
      requesting = true;
      attempted = true;
      error = null;
      cleared = false;
    });
    final controller = sync;
    try {
      final value = await controller.inspectDevice(clear: erase, confirmed: erase);
      if (!mounted || controller != sync || !widget.connected) return;
      setState(() {
        snapshot = value;
        cleared = erase;
      });
    } catch (e) {
      if (!mounted || controller != sync) return;
      setState(() {
        snapshot = null;
        error = e;
      });
    } finally {
      if (mounted) setState(() => requesting = false);
      if (mounted && controller != sync) maybeRead();
    }
  }

  Future<void> confirmErase() async {
    if (snapshot == null || sync.busy || requesting || !widget.connected) return;
    final count = snapshot!.files.length;
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(revampText(context, en: 'Clear ring recordings?', zh: '清空戒指录音？')),
              content: Text(revampText(context,
                  en: 'Permanently delete all recordings on this ring (currently $count). Recordings that have not been imported will be lost. Saved phone audio and timeline recordings will be kept.',
                  zh: '永久删除这枚戒指内的全部录音（当前 $count 条）。尚未导入的录音将丢失。手机中已保存的音频和时间线录音会保留。')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(revampText(context, en: 'Cancel', zh: '取消'))),
                TextButton(
                    key: const ValueKey('ring_confirm_erase'),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(revampText(context, en: 'Delete all', zh: '全部删除'),
                        style: const TextStyle(color: JXB.error))),
              ],
            ));
    if (ok == true && mounted) await read(erase: true);
  }

  @override
  void dispose() {
    sync.removeListener(changed);
    super.dispose();
  }

  String size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';

  @override
  Widget build(BuildContext context) {
    final enabled = widget.connected && !requesting && !sync.busy;
    final value = snapshot;
    final canErase = enabled && value != null && value.files.isNotEmpty && value.onlyRecordings;
    return Container(
      key: const ValueKey('ring_storage_card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(revampText(context, en: 'Ring storage', zh: '戒指存储'), style: JXB.body),
        const SizedBox(height: 12),
        if (value != null && widget.connected) ...[
          Text(revampText(context,
              en: '${size(value.free)} free of ${size(value.total)}',
              zh: '可用 ${size(value.free)} / 总容量 ${size(value.total)}')),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value.used / value.total, color: JXB.brandPrimary),
          const SizedBox(height: 8),
          Text(revampText(context,
              en: '${value.files.length} recordings on ring · ${size(value.used)} used',
              zh: '戒指内 ${value.files.length} 条录音 · 已用 ${size(value.used)}')),
          const SizedBox(height: 8),
          Text(
              revampText(context,
                  en: 'Importing keeps the original ring files. To free space, save recordings you want to keep, then clear ring recordings. Firmware behavior when storage is full has not been verified.',
                  zh: '导入后戒指原文件仍保留。要释放空间，请先保存需要保留的录音，再清空戒指录音。存满后的固件行为尚未确认。'),
              style: JXB.caption),
        ] else
          Text(!widget.connected
              ? revampText(context, en: 'Connect to read storage', zh: '连接戒指后可查看存储')
              : error != null
                  ? revampText(context,
                      en: 'Could not verify ring storage. Reconnect and try again.', zh: '无法确认戒指存储状态，请重新连接后重试。')
                  : sync.busy && !requesting
                      ? revampText(context, en: 'Storage query paused', zh: '暂缓读取存储')
                      : revampText(context, en: 'Reading storage…', zh: '正在读取存储…')),
        if (cleared)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(revampText(context, en: 'Ring recordings cleared', zh: '戒指录音已清空'),
                  style: const TextStyle(color: JXB.success))),
        if (value != null && !value.onlyRecordings)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(revampText(context,
                  en: 'Other file types are present. Clearing storage is unavailable.',
                  zh: '戒指内包含其他类型文件，暂不可清空存储。'))), // i18n-ignore: Bilingual revampText.
        if (sync.busy && !requesting)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(revampText(context,
                  en: 'Storage controls are available after recording or sync finishes.',
                  zh: '录音或同步结束后可操作存储。'))), // i18n-ignore: Bilingual revampText.
        const SizedBox(height: 6),
        Wrap(spacing: 12, children: [
          TextButton(
              key: const ValueKey('ring_refresh_storage'),
              onPressed: enabled ? () => read() : null,
              child: Text(revampText(context, en: 'Refresh storage', zh: '刷新存储'))),
          TextButton(
              key: const ValueKey('ring_clear_recordings'),
              onPressed: canErase ? confirmErase : null,
              child: Text(revampText(context, en: 'Clear ring recordings', zh: '清空戒指录音'),
                  style: TextStyle(color: canErase ? JXB.error : JXB.textPlaceholder))),
          if (!widget.connected)
            TextButton(
                key: const ValueKey('ring_reconnect'),
                onPressed: sync.busy ? null : () => sync.reconnect(),
                child: Text(revampText(context, en: 'Reconnect', zh: '重新连接'))),
        ]),
      ]),
    );
  }
}
