import 'package:flutter/material.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Shared presentation for offline recorders; each device keeps its own controller.
class RecorderPage extends StatelessWidget {
  final String title;
  final Future<void> Function() onRefresh;
  final ScrollController scrollController;
  final List<Widget> children;
  const RecorderPage({
    super.key,
    required this.title,
    required this.onRefresh,
    required this.scrollController,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: JXB.bgApp,
        appBar: AppBar(
          backgroundColor: JXB.bgApp,
          foregroundColor: JXB.textPrimary,
          title: Text(title),
          actions: [
            IconButton(
              tooltip: revampText(context, en: 'Refresh', zh: '刷新'),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            controller: scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(18),
            children: children,
          ),
        ),
      );
}

class RecorderPanel extends StatelessWidget {
  final Widget child;
  const RecorderPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: JXB.surface, borderRadius: BorderRadius.circular(14)),
        child: child,
      );
}

class RecorderFileCard extends StatelessWidget {
  final Widget child;
  const RecorderFileCard({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Card(
        color: JXB.surface,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: JXB.space2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(JXB.radiusControl),
          side: const BorderSide(color: JXB.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: JXB.space3, vertical: JXB.space2),
          child: child,
        ),
      );
}

class RecorderFileHeading extends StatelessWidget {
  final String date;
  final String metadata;
  final Key? metadataKey;
  final List<Widget> status;
  const RecorderFileHeading({
    super.key,
    required this.date,
    required this.metadata,
    this.metadataKey,
    this.status = const [],
  });

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(date,
              style: JXB.bodySmall.copyWith(
                fontFamily: JXB.fontNumber,
                fontFamilyFallback: const [JXB.fontSans],
                color: JXB.textPrimary,
                fontWeight: FontWeight.w500,
              )),
          const SizedBox(height: 2),
          Text(metadata,
              key: metadataKey,
              style: JXB.caption.copyWith(
                fontFamily: JXB.fontNumber,
                fontFamilyFallback: const [JXB.fontSans],
                color: JXB.textSecondary,
              )),
          ...status,
        ],
      );
}

class RecorderPagination extends StatelessWidget {
  final String keyPrefix;
  final int page;
  final int count;
  final int pageSize;
  final ValueChanged<int> onChanged;
  const RecorderPagination({
    super.key,
    required this.keyPrefix,
    required this.page,
    required this.count,
    required this.pageSize,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final lastPage = count == 0 ? 0 : (count - 1) ~/ pageSize;
    final start = count == 0 ? 0 : page * pageSize + 1;
    final end = ((page + 1) * pageSize).clamp(0, count);
    return Column(children: [
      Text(
        revampText(context, en: '$start–$end of $count', zh: '$start–$end 条，共 $count 条'),
        key: ValueKey('${keyPrefix}_page_range'),
        style: JXB.caption.copyWith(color: JXB.textSecondary),
      ),
      if (lastPage > 0)
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(
            child: TextButton(
              key: ValueKey('${keyPrefix}_previous_page'),
              onPressed: page > 0 ? () => onChanged(page - 1) : null,
              child: Text(revampText(context, en: 'Previous', zh: '上一页')),
            ),
          ),
          Expanded(
            child: Text('${page + 1} / ${lastPage + 1}',
                textAlign: TextAlign.center, key: ValueKey('${keyPrefix}_page_number')),
          ),
          Expanded(
            child: TextButton(
              key: ValueKey('${keyPrefix}_next_page'),
              onPressed: page < lastPage ? () => onChanged(page + 1) : null,
              child: Text(revampText(context, en: 'Next', zh: '下一页')),
            ),
          ),
        ]),
    ]);
  }
}

class RecorderProgressRing extends StatelessWidget {
  final double? fraction;
  final String label;
  final Key progressKey;
  final bool estimated;
  const RecorderProgressRing({
    super.key,
    required this.fraction,
    required this.label,
    required this.progressKey,
    this.estimated = false,
  });

  @override
  Widget build(BuildContext context) {
    final progress = fraction?.clamp(0.0, 1.0);
    final percent = progress == null ? null : (progress * 100).floor();
    return Semantics(
      label: label,
      value: percent == null
          ? null
          : estimated
              ? revampText(context, en: 'About $percent%', zh: '约 $percent%')
              : '$percent%',
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: JXB.sizeTouch,
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                  key: progressKey,
                  value: progress,
                  strokeWidth: 3,
                  backgroundColor: JXB.border,
                  color: JXB.brandPrimary,
                ),
              ),
            ),
            if (percent != null)
              Text('${estimated ? '≈' : ''}$percent%',
                  style: JXB.caption.copyWith(fontFamily: JXB.fontNumber, fontSize: 10)),
          ]),
        ),
      ),
    );
  }
}

String recorderDurationLabel(BuildContext context, Duration? duration, {required bool estimated}) {
  if (duration == null) return revampText(context, en: 'Duration unknown', zh: '时长未知');
  final seconds = (duration.inMilliseconds / 1000).ceil();
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return '${estimated ? '≈ ' : ''}${hours > 0 ? '$hours:' : ''}$minutes:$remainder';
}
