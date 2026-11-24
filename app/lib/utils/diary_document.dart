/// 日记正文（day_summary 的 markdown）解析成块，供详情页 / 分享卡 / 分享纯文本共用。
///
/// 后端有两种格式并存（`backend/utils/llm/daily_summary.py` 的模块说明）：
///
/// - **journal**：第一人称散文段落 + 少量 `**加粗**` + 至多一行 `> 原话` +
///   可选的 `### 明天记得` 列表。
/// - **legacy**：`### 今日亮点` 起头的五段报告，段内有散文也有 `-`/`1.` 列表。
///
/// ⚠️ **列表项留在原位，不再统一收进「这天你还提到」。** 旧解析把所有列表项抽出来堆到
/// 文末、把所有标题丢掉，于是旧日记的「关键跟进事项」「今日决定」失去了归属——读起来
/// 是一串没头没尾的条目。现在标题与列表按出现顺序保留成块，两种格式走同一套渲染。
///
/// 只认这几种块，刻意不做通用 markdown：日记的形态是后端清洗过的，渲染需要的是
/// 「段落 / 引语 / 小标题 / 列表」四种可控的排版，而分享卡还要按预算截断——这两件事
/// `MarkdownBody` 都给不了。
library;

enum DiaryBlockKind { paragraph, quote, heading, list }

class DiaryBlock {
  final DiaryBlockKind kind;

  /// paragraph / quote / heading 的文字（paragraph、quote 内可能含 `**加粗**`）。
  final String text;

  /// list 的条目（可能含 `**加粗**`）。
  final List<String> items;

  /// list 是否是编号列表（`1.` / `1、`）。
  final bool ordered;

  const DiaryBlock._(this.kind, {this.text = '', this.items = const [], this.ordered = false});

  const DiaryBlock.paragraph(String text) : this._(DiaryBlockKind.paragraph, text: text);
  const DiaryBlock.quote(String text) : this._(DiaryBlockKind.quote, text: text);
  const DiaryBlock.heading(String text) : this._(DiaryBlockKind.heading, text: text);
  const DiaryBlock.list(List<String> items, {bool ordered = false})
      : this._(DiaryBlockKind.list, items: items, ordered: ordered);

  /// 去掉加粗标记后的纯文字（list 用换行拼起来）。
  String get plainText => kind == DiaryBlockKind.list
      ? items.map(DiaryDocument.stripInline).join('\n')
      : DiaryDocument.stripInline(text);
}

/// 一段带加粗标记的文字拆成的片段。
class DiaryInlineRun {
  final String text;
  final bool bold;
  const DiaryInlineRun(this.text, {this.bold = false});
}

class DiaryDocument {
  final List<DiaryBlock> blocks;
  const DiaryDocument(this.blocks);

  bool get isEmpty => blocks.isEmpty;

  static final RegExp _heading = RegExp(r'^#{1,6}\s+(.+)$');
  static final RegExp _quote = RegExp(r'^>\s?(.*)$');
  // `1.`/`1)` 后面必须有空格，否则「10.5 万」这种正文会被当成编号；`1、` 不要求空格。
  static final RegExp _orderedItem = RegExp(r'^(?:\d+[.)]\s+|\d+、\s*)(.+)$');
  static final RegExp _bulletItem = RegExp(r'^[-*•+]\s+(.+)$');
  static final RegExp _checkbox = RegExp(r'^\[[ xX]\]\s*');
  // 旧数据偶有整行加粗当小标题（`**Key Highlights**`），只认短的、不以句号收尾的。
  static final RegExp _boldLine = RegExp(r'^\*\*([^*]{1,30})\*\*[:：]?$');
  static final RegExp _sentenceEnd = RegExp(r'[。！？.!?…]$');
  static final RegExp _bold = RegExp(r'\*\*(.+?)\*\*');
  static final RegExp _altBold = RegExp(r'__(.+?)__');
  static final RegExp _italic = RegExp(r'(?<![*\w])\*(?!\s)([^*\n]+?)\*(?![*\w])');
  static final RegExp _link = RegExp(r'\[([^\]]+)\]\([^)]+\)');

  static DiaryDocument parse(String markdown) {
    final blocks = <DiaryBlock>[];
    final paragraph = <String>[];
    final quote = <String>[];
    final items = <String>[];
    var ordered = false;

    void flushParagraph() {
      if (paragraph.isNotEmpty) blocks.add(DiaryBlock.paragraph(paragraph.join('\n')));
      paragraph.clear();
    }

    void flushQuote() {
      if (quote.isNotEmpty) blocks.add(DiaryBlock.quote(quote.join('\n')));
      quote.clear();
    }

    void flushList() {
      if (items.isNotEmpty) blocks.add(DiaryBlock.list(List.of(items), ordered: ordered));
      items.clear();
    }

    void flushAll() {
      flushParagraph();
      flushQuote();
      flushList();
    }

    for (final raw in markdown.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) {
        // 列表项之间的空行不拆列表（legacy 偶有「1.\n\n2.」）；其余空行即分段。
        flushParagraph();
        flushQuote();
        continue;
      }

      final heading = _heading.firstMatch(line) ?? _shortBoldLine(line);
      if (heading != null) {
        flushAll();
        final title = stripInline(heading.group(1)!).replaceAll(RegExp(r'[:：]$'), '').trim();
        if (title.isNotEmpty) blocks.add(DiaryBlock.heading(title));
        continue;
      }

      final q = _quote.firstMatch(line);
      if (q != null) {
        flushParagraph();
        flushList();
        final text = _normalizeInline(q.group(1)!.trim());
        if (text.isNotEmpty) quote.add(text);
        continue;
      }

      final o = _orderedItem.firstMatch(line);
      final b = o == null ? _bulletItem.firstMatch(line) : null;
      if (o != null || b != null) {
        flushParagraph();
        flushQuote();
        final isOrdered = o != null;
        if (items.isNotEmpty && isOrdered != ordered) flushList();
        ordered = isOrdered;
        final text = _normalizeInline((o ?? b)!.group(1)!.replaceFirst(_checkbox, '').trim());
        if (text.isNotEmpty) items.add(text);
        continue;
      }

      flushQuote();
      flushList();
      final text = _normalizeInline(line);
      if (text.isNotEmpty) paragraph.add(text);
    }
    flushAll();
    return DiaryDocument(blocks);
  }

  static RegExpMatch? _shortBoldLine(String line) {
    final m = _boldLine.firstMatch(line);
    if (m == null || _sentenceEnd.hasMatch(m.group(1)!.trim())) return null;
    return m;
  }

  /// 统一成「只剩 `**加粗**`」：`__x__` 视同加粗，斜体 / 代码 / 链接标记去掉。
  /// 不成对的 `**` 也去掉，否则会以字面量出现在页面上。
  static String _normalizeInline(String text) {
    var out = text
        .replaceAllMapped(_altBold, (m) => '**${m[1]}**')
        .replaceAllMapped(_link, (m) => m[1]!)
        .replaceAll('`', '');
    out = _protectBold(out, (s) => s.replaceAllMapped(_italic, (m) => m[1]!));
    if ('**'.allMatches(out).length.isOdd) out = out.replaceAll('**', '');
    return out.trim();
  }

  /// 在加粗片段之外施加 [transform]，避免斜体规则啃掉 `**` 的一半。
  static String _protectBold(String text, String Function(String) transform) {
    final buf = StringBuffer();
    var last = 0;
    for (final m in _bold.allMatches(text)) {
      buf.write(transform(text.substring(last, m.start)));
      buf.write(m[0]);
      last = m.end;
    }
    buf.write(transform(text.substring(last)));
    return buf.toString();
  }

  static String stripInline(String text) => text.replaceAllMapped(_bold, (m) => m[1]!).replaceAll('**', '');

  /// 把含 `**加粗**` 的文字拆成片段，渲染成 TextSpan 用。
  static List<DiaryInlineRun> inlineRuns(String text) {
    final runs = <DiaryInlineRun>[];
    var last = 0;
    for (final m in _bold.allMatches(text)) {
      if (m.start > last) runs.add(DiaryInlineRun(text.substring(last, m.start)));
      runs.add(DiaryInlineRun(m[1]!, bold: true));
      last = m.end;
    }
    if (last < text.length) runs.add(DiaryInlineRun(text.substring(last)));
    return runs;
  }

  /// 分享面板的纯文本：块之间空一行，引语加引号，列表加圆点 / 编号。
  String toPlainText() {
    final out = <String>[];
    for (final block in blocks) {
      switch (block.kind) {
        case DiaryBlockKind.paragraph:
        case DiaryBlockKind.heading:
          out.add(block.plainText);
        case DiaryBlockKind.quote:
          final t = block.plainText;
          out.add(RegExp(r'''^["“「『']''').hasMatch(t) ? t : '“$t”');
        case DiaryBlockKind.list:
          final lines = <String>[];
          for (var i = 0; i < block.items.length; i++) {
            final item = stripInline(block.items[i]);
            lines.add(block.ordered ? '${i + 1}. $item' : '· $item'); // i18n-ignore: language-neutral list markers
          }
          out.add(lines.join('\n'));
      }
    }
    return out.join('\n\n');
  }
}
