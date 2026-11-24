// Synthetic recordings used only for repeatable UI and transport checks.
import 'package:memorion/backend/schema/chat_session.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';

ChatSession session(List<String> ids, {String id = 'linked'}) =>
    ChatSession(id: id, messageIds: [], createdAt: DateTime(2026), contextConversationIds: ids);
ServerMessageChunk done(String text) => ServerMessageChunk('answer', '', MessageChunkType.done,
    message: ServerMessage('answer', DateTime(2026), text, MessageSender.ai, MessageType.text, null, false, []));
ServerConversation source(String id, {bool long = false}) => ServerConversation(
        id: id,
        createdAt: DateTime(2026, 10, 17, 10, 30),
        startedAt: DateTime(2026, 10, 17, 10, 30),
        finishedAt: DateTime(2026, 10, 17, 12),
        structured:
            Structured('上午和团队的固件拉锯战', long ? List.filled(30, '讨论固件兼容性，先修复升级风险，再核对测试报告。').join('\n\n') : '讨论固件兼容性。'),
        transcriptSegments: [
          TranscriptSegment(
              id: '$id-seg',
              text: '我们慢一点没关系，别让用户升级变砖。',
              speaker: 'SPEAKER_00',
              isUser: true,
              personId: null,
              start: 0,
              end: 10,
              translations: [])
        ]);
