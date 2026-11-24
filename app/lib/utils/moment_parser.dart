import 'package:memorion/backend/schema/parsed_moment.dart';
import 'package:memorion/utils/localization_helper.dart';

/// Utility class for parsing markdown moment text into structured data.
class MomentParser {
  /// Parses raw markdown text into a [ParsedMoment] model.
  ///
  /// Extracts:
  /// - Title from `# Title` or `## Title` headers
  /// - Key highlights from bullet points under "Key Highlights" section
  /// - Action items from bullet points under "Action Items" section
  /// - Preview text (first ~100 characters at natural break points)
  static ParsedMoment parse(String text, {DateTime? date}) {
    if (text.isEmpty) {
      return ParsedMoment(
        title: _generateDefaultTitle(date),
        summaryText: '',
        highlights: [],
        actionItems: [],
        previewText: '',
      );
    }

    final title = _extractTitle(text, date);
    final summaryText = _extractSummary(text);
    final highlights = _extractHighlights(text);
    final actionItems = _extractActionItems(text);
    final previewText = _generatePreview(summaryText, text);

    return ParsedMoment(
      title: title,
      summaryText: summaryText,
      highlights: highlights,
      actionItems: actionItems,
      previewText: previewText,
    );
  }

  /// Extracts title from markdown headers or generates a default one.
  static String _extractTitle(String text, DateTime? date) {
    // Try to find ## Title or # Title pattern
    final headerPatterns = [
      RegExp(r'^##\s+(.+)$', multiLine: true),
      RegExp(r'^#\s+(.+)$', multiLine: true),
    ];

    for (final pattern in headerPatterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final title = match.group(1)?.trim() ?? '';
        // Skip if it's a section header like "Key Highlights"
        if (!_isSectionHeader(title)) {
          return title;
        }
      }
    }

    // Try to find a whole-line **Title**. Must be the whole line: journal-style
    // diaries bold short phrases inside prose ("**周五**终于定了"), and a
    // prefix match would turn that phrase into the page title.
    final boldPattern = RegExp(r'^\*\*([^*\n]+?)\*\*\s*$', multiLine: true);
    final boldMatch = boldPattern.firstMatch(text);
    if (boldMatch != null) {
      final title = boldMatch.group(1)?.trim() ?? '';
      if (!_isSectionHeader(title) && title.length < 100) {
        return title;
      }
    }

    return _generateDefaultTitle(date);
  }

  /// Checks if a title is a section header that should be skipped.
  static bool _isSectionHeader(String title) {
    final sectionHeaders = [
      'key highlights',
      'highlights',
      'action items',
      'tasks',
      'to-do',
      'todo',
      'summary',
      'day summary',
      'overview',
    ];
    return sectionHeaders.contains(title.toLowerCase());
  }

  /// Generates a default title based on the date.
  static String _generateDefaultTitle(DateTime? date) {
    if (date == null) {
      return appT((s) => s.momentDailySummary, 'Daily Summary');
    }

    // 1=Monday, 7=Sunday
    switch (date.weekday) {
      case DateTime.monday:
        return appT((s) => s.momentMondaySummary, 'Monday Summary');
      case DateTime.tuesday:
        return appT((s) => s.momentTuesdaySummary, 'Tuesday Summary');
      case DateTime.wednesday:
        return appT((s) => s.momentWednesdaySummary, 'Wednesday Summary');
      case DateTime.thursday:
        return appT((s) => s.momentThursdaySummary, 'Thursday Summary');
      case DateTime.friday:
        return appT((s) => s.momentFridaySummary, 'Friday Summary');
      case DateTime.saturday:
        return appT((s) => s.momentSaturdaySummary, 'Saturday Summary');
      case DateTime.sunday:
        return appT((s) => s.momentSundaySummary, 'Sunday Summary');
      default:
        return appT((s) => s.momentDailySummary, 'Daily Summary');
    }
  }

  /// Extracts the main summary text, excluding section headers and lists.
  static String _extractSummary(String text) {
    final lines = text.split('\n');
    final summaryLines = <String>[];
    bool inSectionHeader = false;

    for (final line in lines) {
      final trimmed = line.trim();

      // Skip empty lines at the start
      if (summaryLines.isEmpty && trimmed.isEmpty) continue;

      // Skip markdown headers
      if (trimmed.startsWith('#')) {
        inSectionHeader = _isSectionHeader(trimmed.replaceAll('#', '').trim());
        continue;
      }

      // Skip section content if we're in a known section
      if (inSectionHeader && (trimmed.startsWith('-') || trimmed.startsWith('*') || trimmed.startsWith('['))) {
        continue;
      }

      // Reset section flag on new non-list content
      if (!trimmed.startsWith('-') && !trimmed.startsWith('*') && trimmed.isNotEmpty) {
        inSectionHeader = false;
      }

      // Skip bullet points that are likely highlights or action items
      if (_isHighlightOrActionLine(trimmed)) continue;

      // Add paragraph content
      if (trimmed.isNotEmpty && !trimmed.startsWith('-') && !trimmed.startsWith('*')) {
        summaryLines.add(trimmed);
      }
    }

    return summaryLines.join('\n').trim();
  }

  /// Checks if a line is likely a highlight or action item.
  static bool _isHighlightOrActionLine(String line) {
    final lowered = line.toLowerCase();
    return lowered.contains('- [') || // Checkbox
        lowered.contains('* [') ||
        (line.startsWith('- ') && _isAfterSectionHeader(line));
  }

  static bool _isAfterSectionHeader(String line) {
    // This is a simplified check - in practice we track state
    return false;
  }

  /// Extracts key highlights from the text.
  static List<String> _extractHighlights(String text) {
    return _extractSection(text, [
      'key highlights',
      'highlights',
      'key moments',
      'notable moments',
    ]);
  }

  /// Extracts action items from the text.
  static List<String> _extractActionItems(String text) {
    return _extractSection(text, [
      'action items',
      'tasks',
      'to-do',
      'todo',
      'next steps',
      'follow-up',
      'follow up',
    ]);
  }

  /// Extracts bullet points from a named section.
  static List<String> _extractSection(String text, List<String> sectionNames) {
    final lines = text.split('\n');
    final items = <String>[];
    bool inSection = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final lowered = line.toLowerCase();

      // Check if this is a section header
      bool isHeader = false;
      for (final name in sectionNames) {
        if (lowered.contains(name)) {
          // Could be ## Key Highlights or **Key Highlights** or just Key Highlights:
          if (line.startsWith('#') ||
              line.startsWith('**') ||
              line.endsWith(':') ||
              lowered == name) {
            isHeader = true;
            break;
          }
        }
      }

      if (isHeader) {
        inSection = true;
        continue;
      }

      // If in section, collect bullet points
      if (inSection) {
        // Stop if we hit another header
        if (line.startsWith('#') || (line.startsWith('**') && line.endsWith('**'))) {
          inSection = false;
          continue;
        }

        // Collect bullet items
        if (line.startsWith('- ') || line.startsWith('* ')) {
          String item = line.substring(2).trim();
          // Remove checkbox markers
          item = item.replaceAll(RegExp(r'^\[.\]\s*'), '');
          if (item.isNotEmpty) {
            items.add(item);
          }
        }

        // Stop on empty line followed by non-bullet content
        if (line.isEmpty && i + 1 < lines.length) {
          final nextLine = lines[i + 1].trim();
          if (!nextLine.startsWith('-') && !nextLine.startsWith('*') && nextLine.isNotEmpty) {
            inSection = false;
          }
        }
      }
    }

    return items;
  }

  /// Generates a preview text for card display.
  static String _generatePreview(String summaryText, String fullText) {
    // Use summary if available, otherwise use full text
    String source = summaryText.isNotEmpty ? summaryText : fullText;

    // Remove markdown formatting
    source = _stripMarkdown(source);

    if (source.isEmpty) return '';

    // Target ~100 characters, break at natural points
    if (source.length <= 120) return source;

    // Find a good break point
    int breakPoint = 100;

    // Try to break at sentence end
    final sentenceEnd = source.lastIndexOf(RegExp(r'[.!?]\s'), 120);
    if (sentenceEnd > 50) {
      breakPoint = sentenceEnd + 1;
    } else {
      // Try to break at comma or space
      final commaBreak = source.lastIndexOf(', ', 120);
      if (commaBreak > 50) {
        breakPoint = commaBreak;
      } else {
        final spaceBreak = source.lastIndexOf(' ', 120);
        if (spaceBreak > 50) {
          breakPoint = spaceBreak;
        }
      }
    }

    return '${source.substring(0, breakPoint).trim()}...';
  }

  /// Removes markdown formatting from text.
  static String _stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '') // Headers
        .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1') // Bold
        .replaceAll(RegExp(r'\*(.+?)\*'), r'$1') // Italic
        .replaceAll(RegExp(r'__(.+?)__'), r'$1') // Bold alt
        .replaceAll(RegExp(r'_(.+?)_'), r'$1') // Italic alt
        .replaceAll(RegExp(r'`(.+?)`'), r'$1') // Code
        .replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '') // Bullets
        .replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '') // Numbered
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1') // Links
        .replaceAll(RegExp(r'\n{3,}'), '\n\n') // Multiple newlines
        .trim();
  }
}
