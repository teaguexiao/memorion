import 'package:markdown/markdown.dart' as md;

/// Selection offsets belong to rendered text, not the stored Markdown source.
/// Keep the source intact and validate a correction against the rendered text
/// before writing it. Repeated phrases must resolve to the selected occurrence.
class MarkdownSummarySelection {
  final MarkdownSummarySource _document;
  final int start;
  final int end;
  final String text;

  MarkdownSummarySelection._(this._document, this.start, this.end, this.text);

  String get source => _document.source;

  String? replaceWith(String replacement) {
    final rawStart = _document._starts[start];
    final rawEnd = _document._ends[end - 1];
    if (rawStart == null || rawEnd == null || rawStart >= rawEnd) return null;
    final expected =
        _document.text.substring(0, start) + MarkdownSummarySource(replacement).text + _document.text.substring(end);
    final starts = <int>[rawStart];
    final ends = <int>[rawEnd];
    const delimiters = '*_~`[]\\';
    var s = rawStart;
    while (s > 0 && rawStart - s < 6 && delimiters.contains(source[s - 1])) {
      starts.add(--s);
    }
    var e = rawEnd;
    while (e < source.length && e - rawEnd < 6 && delimiters.contains(source[e])) {
      ends.add(++e);
    }
    // A selection spanning a link may include its label but stop before the
    // destination. Include the closing link syntax only if validation agrees.
    if (source.startsWith('](', rawEnd)) {
      final close = _document._linkEnd(rawEnd);
      if (close != null) ends.add(close);
    }
    for (final start in starts) {
      for (final end in ends) {
        final candidate = source.replaceRange(start, end, replacement);
        if (MarkdownSummarySource(candidate).text == expected) return candidate;
      }
    }
    return null;
  }
}

class MarkdownSummarySource {
  final String source;
  final _text = StringBuffer();
  final _starts = <int?>[];
  final _ends = <int?>[];
  static final _entityPattern = RegExp(r'&(?:#[0-9]+|#x[0-9a-fA-F]+|[a-zA-Z]+);');
  late final _entities = _entityPattern.allMatches(source).toList();
  final _decodedEntities = <String, String>{};
  int _entityCursor = 0;
  int _cursor = 0;
  bool hasFormatting = false;

  MarkdownSummarySource(this.source) {
    for (final node in _parse(source)) {
      _visit(node);
    }
    hasFormatting = hasFormatting || text.replaceAll('\n', '') != source.replaceAll('\n', '');
  }

  String get text => _text.toString();

  static List<md.Node> _parse(String value) =>
      md.Document(encodeHtml: false, extensionSet: md.ExtensionSet.gitHubFlavored).parseLines(value.split('\n'));

  MarkdownSummarySelection? selection(int start, int end, String selectedText) {
    if (start > end) {
      final previousStart = start;
      start = end;
      end = previousStart;
    }
    if (start < 0 || end > _starts.length || start >= end) return null;
    final selected = text.substring(start, end);
    // SelectionArea inserts separators between different render paragraphs;
    // its aggregate offsets count the text itself, without those separators.
    if (selected.replaceAll('\n', '') != selectedText.replaceAll('\n', '')) return null;
    return MarkdownSummarySelection._(this, start, end, selectedText);
  }

  void _visit(md.Node node, {bool codeBlock = false}) {
    if (node is md.Text) {
      _append(codeBlock ? node.text.trimRight() : node.text);
      return;
    }
    if (node is! md.Element) return;
    if (node.tag != 'p') hasFormatting = true;
    if (node.tag == 'br') {
      _append('\n');
      return;
    }
    for (final child in node.children ?? <md.Node>[]) {
      _visit(child, codeBlock: codeBlock || node.tag == 'pre');
    }
    if (node.tag == 'a' && source.startsWith('](', _cursor)) {
      _cursor = _linkEnd(_cursor) ?? _cursor;
    }
  }

  int? _linkEnd(int start) {
    if (!source.startsWith('](', start)) return null;
    var depth = 1;
    for (var i = start + 2; i < source.length; i++) {
      if (source[i] == '\\') {
        i++;
      } else if (source[i] == '(') {
        depth++;
      } else if (source[i] == ')' && --depth == 0) {
        return i + 1;
      }
    }
    return null;
  }

  void _append(String value) {
    _text.write(value);
    final exact = source.indexOf(value, _cursor);
    if (value.isNotEmpty && exact >= 0) {
      for (var i = 0; i < value.length; i++) {
        _starts.add(exact + i);
        _ends.add(exact + i + 1);
      }
      _cursor = exact + value.length;
      return;
    }
    for (var i = 0; i < value.length; i++) {
      final position = source.indexOf(value[i], _cursor);
      while (_entityCursor < _entities.length && _entities[_entityCursor].end <= _cursor) {
        _entityCursor++;
      }
      final entity = _entityCursor < _entities.length ? _entities[_entityCursor] : null;
      if (entity != null) {
        final decoded = _decodedEntities.putIfAbsent(
            entity.group(0)!, () => _parse(entity.group(0)!).map((n) => n.textContent).join());
        if (decoded.isNotEmpty && value.startsWith(decoded, i) && (position < 0 || entity.start <= position)) {
          for (var j = 0; j < decoded.length; j++) {
            _starts.add(entity.start);
            _ends.add(entity.end);
          }
          _cursor = entity.end;
          i += decoded.length - 1;
          continue;
        }
      }
      _starts.add(position >= 0 ? position : null);
      _ends.add(position >= 0 ? position + 1 : null);
      if (position >= 0) _cursor = position + 1;
    }
  }
}
