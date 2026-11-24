import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/theme/jxb_tokens.dart';

/// One section inside an info dialog: a heading + a list of bullet items.
class _InfoSection {
  final String title;
  final List<String> bullets;
  /// When true, bullets are rendered as numbered steps (1., 2., 3., ...)
  /// instead of dot bullets.
  final bool numbered;

  const _InfoSection({
    required this.title,
    required this.bullets,
    this.numbered = false,
  });
}

/// Show the local "How to charge your device" guide dialog.
///
/// Replaces the previous Intercom-backed article. Single OK button.
Future<void> showChargingGuideDialog(BuildContext context) {
  final s = S.of(context);
  return _showInfoDialog(
    context,
    title: s.chargingGuideTitle,
    sections: [
      _InfoSection(
        title: s.chargingGuideHowToTitle,
        numbered: true,
        bullets: [
          s.chargingGuideStep1,
          s.chargingGuideStep2,
          s.chargingGuideStep3,
          s.chargingGuideStep4,
        ],
      ),
      _InfoSection(
        title: s.chargingGuideTroubleTitle,
        bullets: [
          s.chargingGuideTip1,
          s.chargingGuideTip2,
          s.chargingGuideTip3,
        ],
      ),
    ],
  );
}

/// Show the local "Firmware update guide" dialog.
///
/// Replaces the previous Intercom-backed article. Single OK button.
Future<void> showFirmwareUpdateGuideDialog(BuildContext context) {
  final s = S.of(context);
  return _showInfoDialog(
    context,
    title: s.firmwareGuideTitle,
    sections: [
      _InfoSection(
        title: s.firmwareGuideBeforeTitle,
        bullets: [
          s.firmwareGuideBefore1,
          s.firmwareGuideBefore2,
          s.firmwareGuideBefore3,
        ],
      ),
      _InfoSection(
        title: s.firmwareGuideDuringTitle,
        bullets: [
          s.firmwareGuideDuring1,
          s.firmwareGuideDuring2,
          s.firmwareGuideDuring3,
        ],
      ),
      _InfoSection(
        title: s.firmwareGuideFailTitle,
        bullets: [
          s.firmwareGuideFail1,
          s.firmwareGuideFail2,
          s.firmwareGuideFail3,
        ],
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal implementation
// ─────────────────────────────────────────────────────────────────────────────

Future<void> _showInfoDialog(
  BuildContext context, {
  required String title,
  required List<_InfoSection> sections,
}) {
  final okLabel = S.of(context).okGotIt;
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      if (Platform.isAndroid) {
        return AlertDialog(
          backgroundColor: JXB.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(JXB.radiusCard)),
          contentPadding: const EdgeInsets.only(top: 20, left: 24, right: 24, bottom: 10),
          title: Text(
            title,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              color: JXB.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: _InfoDialogBody(sections: sections),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: JXB.brandPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(JXB.radiusSmall),
                ),
              ),
              child: Text(okLabel),
            ),
          ],
        );
      } else {
        return CupertinoAlertDialog(
          title: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: JXB.fontSans,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: JXB.textPrimary,
              ),
            ),
          ),
          content: _InfoDialogBody(sections: sections),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              isDefaultAction: true,
              child: Text(
                okLabel,
                style: const TextStyle(
                  fontFamily: JXB.fontSans,
                  fontSize: 16,
                  color: JXB.brandPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      }
    },
  );
}

class _InfoDialogBody extends StatelessWidget {
  final List<_InfoSection> sections;

  const _InfoDialogBody({required this.sections});

  @override
  Widget build(BuildContext context) {
    final mediaHeight = MediaQuery.of(context).size.height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mediaHeight * 0.55),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: 16),
              _buildSection(sections[i]),
            ],
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(_InfoSection section) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          section.title,
          style: const TextStyle(
            fontFamily: JXB.fontSans,
            color: JXB.brandPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < section.bullets.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _buildBullet(
            section.bullets[i],
            marker: section.numbered ? '${i + 1}.' : '•',
          ),
        ],
      ],
    );
  }

  Widget _buildBullet(String text, {required String marker}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: Text(
            marker,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              color: JXB.textPlaceholder,
              fontSize: 14,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: JXB.fontSans,
              color: JXB.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
