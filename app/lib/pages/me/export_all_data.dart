import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<void> exportAllData(BuildContext context) async {
  final s = S.of(context);
  final navigator = Navigator.of(context);
  final showMessage = UndoDeleteHost.messageSink(context);

  bool cancelled = false;
  bool dialogOpen = true;
  final fetchedNotifier = ValueNotifier<int>(0);

  void dismissDialog() {
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
  }

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: JXB.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        s.exportAllData,
        style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(JXB.brandPrimary),
            ),
          ),
          const SizedBox(height: 20),
          Text(s.exportingData, style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.textSecondary, fontSize: 14)),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: fetchedNotifier,
            builder: (_, count, __) => Text(
              '$count',
              style: const TextStyle(fontFamily: JXB.fontNumber, color: JXB.textPrimary, fontSize: 24, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            dismissDialog();
          },
          child: Text(s.cancel, style: const TextStyle(fontFamily: JXB.fontSans, color: JXB.textSecondary, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );

  try {
    List<ServerConversation> allConversations = [];
    int offset = 0;
    const batchSize = 50;

    while (!cancelled) {
      final batch = await getConversations(
        limit: batchSize,
        offset: offset,
        includeDiscarded: true,
      );
      if (batch.isEmpty) break;
      allConversations.addAll(batch);
      offset += batch.length;
      fetchedNotifier.value = allConversations.length;
      if (batch.length < batchSize) break;
    }

    if (cancelled) return;

    if (allConversations.isEmpty) {
      dismissDialog();
      showMessage(s.noConversationsToExport);
      return;
    }

    final exportData = {
      'export_date': DateTime.now().toUtc().toIso8601String(),
      'total_conversations': allConversations.length,
      'conversations': allConversations.map((c) {
        final json = c.toJson();
        json['transcript_text'] = c.getTranscript(generate: true);
        json['summary_text'] = c.structured.toString();
        return json;
      }).toList(),
    };

    final directory = await getApplicationDocumentsDirectory();
    final date = DateTime.now();
    final timestamp = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final file = File('${directory.path}/memorion_export_$timestamp.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(exportData));

    if (cancelled) return;
    dismissDialog();

    HapticFeedback.mediumImpact();
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      text: s.exportShareText,
    );
  } catch (e) {
    debugPrint('exportAllData error: $e');
    if (!cancelled) {
      dismissDialog();
      showMessage(s.exportFailed);
    }
  } finally {
    fetchedNotifier.dispose();
  }
}
