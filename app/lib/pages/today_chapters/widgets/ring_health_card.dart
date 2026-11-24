import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:memorion/services/devices/chiplet_ring/health.dart';
import 'package:memorion/services/devices/chiplet_ring/sync_controller.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Intentionally mounted only by the ring device-detail page.
class RingHealthCard extends StatefulWidget {
  final RingSyncController controller;
  final bool connected;
  const RingHealthCard({super.key, required this.controller, required this.connected});
  @override
  State<RingHealthCard> createState() => _RingHealthCardState();
}

class _RingHealthCardState extends State<RingHealthCard>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin<RingHealthCard> {
  static const refreshInterval = Duration(minutes: 5);
  RingHealthSnapshot? snapshot;
  DateTime? lastReadAt;
  bool requesting = false;
  Object? readError;
  int epoch = 0;
  bool expanded = false, automaticDue = false, automaticScheduled = false;
  late bool foreground;
  Timer? refreshTimer;
  @override
  bool get wantKeepAlive => expanded;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    scheduleAutomaticRead();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) scheduleAutomaticRead();
  }

  @override
  void didUpdateWidget(RingHealthCard old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(changed);
      widget.controller.addListener(changed);
    }
    if (old.controller != widget.controller || (!old.connected && widget.connected)) {
      epoch++;
      snapshot = null;
      lastReadAt = null;
      readError = null;
      requesting = false;
      automaticDue = expanded;
    } else if (old.connected && !widget.connected) {
      // A native timeout also disconnects BLE. Keep the failed read visible
      // instead of resetting it to an apparently unread/empty snapshot.
      snapshot = null;
      lastReadAt = null;
    }
    scheduleAutomaticRead();
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
    scheduleAutomaticRead();
  }

  bool get automaticEligible =>
      mounted &&
      expanded &&
      foreground &&
      widget.connected &&
      widget.controller.isCurrentOwner() &&
      ModalRoute.isCurrentOf(context) != false;

  void armTimer() {
    refreshTimer?.cancel();
    if (!expanded) return;
    refreshTimer = Timer.periodic(refreshInterval, (_) {
      automaticDue = true;
      scheduleAutomaticRead();
    });
  }

  void expansionChanged(bool value) {
    expanded = value;
    updateKeepAlive();
    automaticDue = value;
    armTimer();
    scheduleAutomaticRead();
  }

  void scheduleAutomaticRead() {
    if (!automaticDue || automaticScheduled || !automaticEligible || requesting || widget.controller.busy) return;
    automaticScheduled = true;
    // Notifications may arrive while the parent is building, or while another
    // maintenance operation releases its lock. Recheck after that stack ends.
    scheduleMicrotask(() {
      automaticScheduled = false;
      if (automaticDue && automaticEligible && !requesting && !widget.controller.busy) unawaited(read());
    });
  }

  Future<void> read() async {
    if (!mounted || requesting || !widget.connected || !widget.controller.isCurrentOwner() || widget.controller.busy) {
      return;
    }
    automaticDue = false;
    armTimer();
    final token = ++epoch;
    final controller = widget.controller;
    setState(() {
      requesting = true;
      readError = null;
    });
    try {
      final value = await controller.inspectHealth();
      if (mounted && token == epoch && widget.connected) {
        setState(() {
          snapshot = value;
          lastReadAt = DateTime.now();
        });
      }
    } catch (error) {
      if (mounted && token == epoch) setState(() => readError = error);
    } finally {
      if (mounted && token == epoch) {
        setState(() => requesting = false);
        scheduleAutomaticRead();
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(changed);
    super.dispose();
  }

  String display(RingHealthMetric metric, RingHealthValue? data) {
    if (data == null) {
      if (metric.vendorAlgorithm) return revampText(context, en: 'Vendor service not connected', zh: '厂商算法尚未接通');
      if (requesting) return revampText(context, en: 'Reading…', zh: '正在读取…');
      if (readError != null) {
        return revampText(context, en: 'Read failed · availability unconfirmed', zh: '读取失败 · 尚未确认是否有数据');
      }
      return snapshot == null
          ? revampText(context, en: 'Read to check availability', zh: '读取后查看数据')
          : revampText(context, en: 'No data · support varies by model', zh: '暂无数据 · 支持情况依型号而定');
    }
    if (metric.id == 'temperature') {
      // Do not turn a raw vendor integer into a Celsius value without a
      // verified scale for this hardware revision.
      return revampText(context, en: 'Received · unit not yet verified', zh: '已读取 · 温度单位待核验');
    }
    if (metric.id == 'sleepStage') {
      const en = ['Awake', 'Light sleep', 'Deep sleep', 'REM'];
      const zh = ['清醒', '浅睡', '深睡', '快速眼动'];
      return revampText(context, en: en[data.value - 1], zh: zh[data.value - 1]);
    }
    return '${data.value}${metric.unit.isEmpty ? '' : ' ${metric.unit}'}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final enabled = widget.connected && widget.controller.isCurrentOwner() && !requesting && !widget.controller.busy;
    return Container(
      key: const ValueKey('ring_health_card'),
      decoration: BoxDecoration(
          color: JXB.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: JXB.border)),
      child: ExpansionTile(
        key: const ValueKey('ring_health_expand'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        onExpansionChanged: expansionChanged,
        title: Text(revampText(context, en: 'Ring health metrics', zh: '戒指健康指标'), style: JXB.body),
        subtitle: Text(revampText(context, en: 'Official features · device details only', zh: '厂商指标 · 仅在设备详情展示'),
            style: const TextStyle(fontSize: 12, color: JXB.textSecondary)),
        children: [
          Align(
              alignment: Alignment.centerLeft,
              child: Text(revampText(context,
                  en: 'Latest available device records from the past 7 days. Some features require another ring model or a vendor service.',
                  zh: '查看最近 7 天内各指标最新可用的设备记录。部分功能需要特定戒指型号或厂商算法服务。'))),
          const SizedBox(height: 8),
          Text(
            revampText(context,
                en: 'Reads all available stored metrics together; this does not start a new measurement. While this section is expanded and the page is in the foreground, it refreshes every 5 minutes. Recording or transfer defers the refresh.',
                zh: '一次读取全部可用的已存指标，不会启动新的测量。展开此栏且页面在前台时，每 5 分钟自动读取一次；录音或传输期间暂缓。'),
            key: const ValueKey('ring_health_auto_refresh_note'),
            style: JXB.caption.copyWith(color: JXB.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            revampText(context,
                en: 'Wear the ring snugly against your skin and wait for its collection cycle for measurements such as heart rate and oxygen. The generic guide lists hourly collection for some measurements; this ring’s schedule and support are not confirmed. Blood pressure, glucose and sleep analysis also need compatible firmware or vendor services.',
                zh: '心率、血氧等需要贴肤佩戴并等待采集周期。通用文档提到部分指标每小时采集，但这枚戒指的周期与支持情况尚未确认。血压、血糖、睡眠分析还需要匹配固件或厂商服务，并非戴久就能显示全部指标。'),
            key: const ValueKey('ring_health_collection_note'),
            style: JXB.caption.copyWith(color: JXB.textSecondary),
          ),
          const SizedBox(height: 8),
          if (readError != null)
            Text(
              readError is PlatformException && (readError as PlatformException).code == 'timeout'
                  ? revampText(context,
                      en:
                          'The ring did not respond to the health request. This does not mean there are no measurements, and wearing it longer may not fix it. Reconnect to retry; firmware support still needs verification.',
                      zh: '戒指未响应健康读取请求。这不代表没有测量数据，也不能保证延长佩戴就能解决。可重新连接后重试，固件支持仍需核验。')
                  : revampText(context,
                      en: 'Health read failed; availability has not been confirmed. Reconnect and retry.',
                      zh: '健康读取失败，尚未确认是否有数据。请重新连接后重试。'),
              key: const ValueKey('ring_health_read_failed'),
              style: const TextStyle(color: JXB.error),
            ),
          if (snapshot != null)
            Text(
              snapshot!.metrics.isEmpty
                  ? revampText(context,
                      en:
                          'Read completed · ${snapshot!.recordCount} records · no valid measurements in the past 7 days.',
                      zh: '读取完成 · ${snapshot!.recordCount} 条记录 · 最近 7 天暂无有效测量值。')
                  : revampText(context,
                      en: 'Read completed · ${snapshot!.recordCount} records · ${snapshot!.metrics.length} available metrics.',
                      zh: '读取完成 · ${snapshot!.recordCount} 条记录 · ${snapshot!.metrics.length} 项可用指标。'),
              key: const ValueKey('ring_health_read_result'),
              style: JXB.caption,
            ),
          if (lastReadAt != null)
            Text(
              revampText(context,
                  en: 'Last successful read: ${DateFormat('HH:mm:ss').format(lastReadAt!.toLocal())}${readError != null || requesting ? ' · showing previous data' : ''}',
                  zh: '上次成功读取：${DateFormat('HH:mm:ss').format(lastReadAt!.toLocal())}${readError != null || requesting ? ' · 正在显示上次数据' : ''}'),
              key: const ValueKey('ring_health_last_read'),
              style: JXB.caption,
            ),
          if (!widget.connected) Text(revampText(context, en: 'Connect the ring to read data', zh: '连接戒指后可读取数据')),
          if (widget.controller.busy && !requesting)
            Text(revampText(context, en: 'Available after recording or sync finishes', zh: '录音或同步结束后可读取')),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  key: const ValueKey('ring_refresh_health'),
                  onPressed: enabled ? read : null,
                  child: Text(requesting
                      ? revampText(context, en: 'Reading…', zh: '正在读取…')
                      : revampText(context, en: 'Read all metrics', zh: '读取全部指标')))),
          for (final metric in ringHealthMetrics) ...[
            const Divider(height: 16, color: JXB.border),
            Align(alignment: Alignment.centerLeft, child: Text(revampText(context, en: metric.en, zh: metric.zh))),
            Align(
                alignment: Alignment.centerLeft,
                child: Text(display(metric, snapshot?.metrics[metric.id]),
                    key: ValueKey('ring_health_${metric.id}'),
                    style: const TextStyle(fontSize: 13, color: JXB.textSecondary))),
            if (snapshot?.metrics[metric.id] case final RingHealthValue data)
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text(DateFormat('yyyy-MM-dd HH:mm').format(data.time.toLocal()),
                      style: const TextStyle(fontSize: 11, color: JXB.textPlaceholder))),
          ],
        ],
      ),
    );
  }
}
