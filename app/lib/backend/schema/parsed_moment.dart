/// Parsed representation of a Moment's markdown text content.
///
/// This model extracts structured data from the raw markdown text
/// for display in cards and detail pages.
class ParsedMoment {
  /// The title extracted from the markdown (e.g., "A Productive Saturday")
  final String title;

  /// The full summary text paragraph
  final String summaryText;

  /// List of key highlights extracted from bullet points
  final List<String> highlights;

  /// List of action items/tasks extracted
  final List<String> actionItems;

  /// Preview text for card display (2-3 lines, ~100 characters)
  final String previewText;

  const ParsedMoment({
    required this.title,
    required this.summaryText,
    required this.highlights,
    required this.actionItems,
    required this.previewText,
  });

  /// Creates an empty ParsedMoment with default values
  factory ParsedMoment.empty() {
    return const ParsedMoment(
      title: 'Daily Summary',
      summaryText: '',
      highlights: [],
      actionItems: [],
      previewText: '',
    );
  }

  /// Whether this moment has any highlights
  bool get hasHighlights => highlights.isNotEmpty;

  /// Whether this moment has any action items
  bool get hasActionItems => actionItems.isNotEmpty;

  /// Whether the summary text is not empty
  bool get hasSummary => summaryText.isNotEmpty;
}
