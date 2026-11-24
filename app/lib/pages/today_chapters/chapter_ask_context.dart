import 'package:memorion/backend/schema/conversation.dart';

class ChapterAskContext {
  ChapterAskContext(
      {required this.title,
      required this.subtitle,
      required List<String> conversationIds,
      required List<ServerConversation> sources})
      : conversationIds = List.unmodifiable(conversationIds.toSet()),
        sources = List.unmodifiable(sources);
  final String title;
  final String subtitle;
  final List<String> conversationIds;
  final List<ServerConversation> sources;

  /// A quote is rendered only when it literally occurs in a source transcript.
  /// Generated highlights alone are not evidence of a verbatim quote.
  ({String text, String conversationId})? get verifiedQuote {
    for (final source in sources) {
      for (final text in source.structured.highlights) {
        final value = text.trim();
        if (value.isNotEmpty && source.transcriptSegments.any((s) => s.text.contains(value))) {
          return (text: value, conversationId: source.id);
        }
      }
    }
    return null;
  }
}
