import 'package:flutter/material.dart';
import 'package:memorion/widgets/undo_delete_host.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/insight.dart';
import 'package:memorion/pages/today_chapters/chapter_detail_page.dart';
import 'package:memorion/pages/today_chapters/transcript_page.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:provider/provider.dart';

/// 按会话 id 打开 P-11 章节详情：先查已加载缓存（秒开），未命中才走网络。
/// 洞察卡 evidence「点原话跳取证」（P-31 / 分享页）共用；与 Ask 页引用卡同套路。
Future<void> openConversationById(BuildContext context, String conversationId) async {
  ServerConversation? convo;
  for (final c in context.read<ConversationProvider>().conversations) {
    if (c.id == conversationId) {
      convo = c;
      break;
    }
  }
  convo ??= await getConversationById(conversationId);
  if (!context.mounted) return;
  if (convo == null) {
    UndoDeleteHost.showMessage(context, revampText(context, en: 'Failed to open, please retry', zh: '打开失败，请重试'));
    return;
  }
  final target = convo;
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChapterDetailPage(conversation: target)),
  );
}

/// evidence 行的可点包装：有 conversationId 才可点（尾部小箭头做可点暗示），
/// 没有就原样返回。P-31 证据框用；分享页蓝卡为保持截图干净不加箭头，单独接。
///
/// ⚠️ 判据用 [InsightEvidence.canOpen] 而不是 `isNotEmpty`——生成侧曾把字面量
/// 「未知」填进这个字段，非空字符串照样过判空，箭头照样出现，点下去跳一个不存在
/// 的对话。
class EvidenceTapWrap extends StatelessWidget {
  final String? conversationId;
  final Widget child;

  const EvidenceTapWrap({super.key, required this.conversationId, required this.child});

  @override
  Widget build(BuildContext context) {
    final cid = conversationId;
    if (cid == null || !canOpenConversationId(cid)) return child;
    return GestureDetector(
      onTap: () => openConversationById(context, cid),
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: child),
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 2),
            child: Icon(Icons.chevron_right_rounded, size: 15, color: JXB.textPlaceholder),
          ),
        ],
      ),
    );
  }
}

/// Continue at the selected Watch mark, with the actual source transcript and audio offset.
Future<bool> openWatchConversationMoment(BuildContext context, String conversationId, double offset) async {
  final conversation = await getConversationById(conversationId);
  if (!context.mounted || conversation == null) return false;
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TranscriptPage(
    conversation: conversation, initialOffsetSeconds: offset,
  )));
  return true;
}
