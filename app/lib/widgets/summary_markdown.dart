import 'package:flutter/gestures.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/markdown_summary_selection.dart';
import 'package:url_launcher/url_launcher.dart';

typedef SummaryMarkdownContextMenuBuilder = Widget Function(
  BuildContext context,
  SelectableRegionState state,
  String selectedText,
  MarkdownSummarySelection? selection,
);

/// Shared renderer for recording details, merged chapters and share previews.
/// Plain summaries retain their existing selection/editor behavior.
class SummaryMarkdown extends StatefulWidget {
  final String data;
  final void Function(String evidenceId, Offset anchor)? onSpeakerTap;
  final TextStyle? style;
  final bool selectable;
  final EditableTextContextMenuBuilder? plainContextMenuBuilder;
  final SummaryMarkdownContextMenuBuilder? markdownContextMenuBuilder;

  const SummaryMarkdown({
    super.key,
    required this.data,
    this.onSpeakerTap,
    this.style,
    this.selectable = true,
    this.plainContextMenuBuilder,
    this.markdownContextMenuBuilder,
  });

  @override
  State<SummaryMarkdown> createState() => _SummaryMarkdownState();
}

class _SummaryMarkdownState extends State<SummaryMarkdown> {
  final _selection = SelectionListenerNotifier();
  late MarkdownSummarySource _source;
  String _selectedText = '';
  Offset _tapPosition = Offset.zero;
  final Map<String, TapGestureRecognizer> _speakerRecognizers = {};

  @override
  void initState() {
    super.initState();
    _source = MarkdownSummarySource(widget.data);
  }

  @override
  void didUpdateWidget(SummaryMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _source = MarkdownSummarySource(widget.data);
      _selectedText = '';
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    for (final recognizer in _speakerRecognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? JXB.body.copyWith(height: 1.8);
    if (!_source.hasFormatting) {
      return widget.selectable
          ? SelectableText(widget.data, style: base, contextMenuBuilder: widget.plainContextMenuBuilder)
          : Text(widget.data, style: base);
    }
    final body = MarkdownBody(
      data: widget.data,
      softLineBreak: true,
      inlineSyntaxes: [_SpeakerLinkSyntax()],
      builders: {
        'speaker': _SpeakerLinkBuilder(base, (id) {
          final recognizer = _speakerRecognizers.putIfAbsent(id, TapGestureRecognizer.new);
          recognizer.onTap = () => widget.onSpeakerTap?.call(id, _tapPosition);
          return recognizer;
        })
      },
      onTapLink: (text, href, title) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null && const ['https', 'http', 'mailto'].contains(uri.scheme)) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      // Bullets are visual structure, not part of a text selection's offsets.
      bulletBuilder: (parameters) => SelectionContainer.disabled(
        child: Text(parameters.style == BulletStyle.orderedList ? '${parameters.index + 1}.' : '•', style: base),
      ),
      styleSheet: MarkdownStyleSheet(
        p: base,
        h1: base.copyWith(fontSize: 22, fontWeight: FontWeight.w700, height: 1.4),
        h2: base.copyWith(fontSize: 20, fontWeight: FontWeight.w700, height: 1.4),
        h3: base.copyWith(fontSize: 18, fontWeight: FontWeight.w600, height: 1.4),
        h4: base.copyWith(fontWeight: FontWeight.w600),
        h5: base.copyWith(fontWeight: FontWeight.w600),
        h6: base.copyWith(fontWeight: FontWeight.w600),
        strong: base.copyWith(fontWeight: FontWeight.w700),
        em: base.copyWith(fontStyle: FontStyle.italic),
        a: base.copyWith(color: JXB.brandPrimary, decoration: TextDecoration.underline),
        listBullet: base,
        blockquote: base.copyWith(color: JXB.textSecondary),
        blockquoteDecoration: const BoxDecoration(border: Border(left: BorderSide(color: JXB.border, width: 3))),
        code: base.copyWith(fontFamily: 'monospace', backgroundColor: JXB.bgApp),
        codeblockDecoration: BoxDecoration(color: JXB.bgApp, borderRadius: BorderRadius.circular(8)),
        tableHead: base.copyWith(fontWeight: FontWeight.w600),
        tableBody: base,
        tableBorder: TableBorder.all(color: JXB.border),
        pPadding: EdgeInsets.zero,
        blockSpacing: 12,
      ),
    );
    if (!widget.selectable) return body;
    return SelectionArea(
      onSelectionChanged: (content) => _selectedText = content?.plainText ?? '',
      contextMenuBuilder: (context, state) {
        final range = _selection.selection.range;
        final selected = range == null ? null : _source.selection(range.startOffset, range.endOffset, _selectedText);
        return widget.markdownContextMenuBuilder?.call(context, state, _selectedText, selected) ??
            AdaptiveTextSelectionToolbar.selectableRegion(selectableRegionState: state);
      },
      child: Listener(
          onPointerDown: (event) => _tapPosition = event.position,
          child: SelectionListener(selectionNotifier: _selection, child: body)),
    );
  }
}

/// Retain Markdown's link parsing/escaping, but give evidence links their own
/// inline tag. Overriding the 'a' builder skips flutter_markdown's link-handler
/// pop and makes following ordinary prose inherit the preceding link's tap.
class _SpeakerLinkSyntax extends md.LinkSyntax {
  @override
  md.Node createNode(String destination, String? title, {required List<md.Node> Function() getChildren}) {
    final element = super.createNode(destination, title, getChildren: getChildren) as md.Element;
    if (!RegExp(r'^speaker:e[a-f0-9]{16}$').hasMatch(element.attributes['href'] ?? '')) return element;
    return md.Element('speaker', element.children)..attributes.addAll(element.attributes);
  }
}

class _SpeakerLinkBuilder extends MarkdownElementBuilder {
  final TextStyle base;
  final TapGestureRecognizer Function(String) recognizer;
  _SpeakerLinkBuilder(this.base, this.recognizer);
  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final href = element.attributes['href'] ?? '';
    if (!href.startsWith('speaker:')) return null;
    final confirmed = element.attributes['title'] == 'confirmed';
    return RichText(
        text: TextSpan(
            text: element.textContent,
            recognizer: recognizer(href.substring(8)),
            style: (parentStyle ?? base).copyWith(
                fontWeight: FontWeight.w500,
                color: confirmed ? const Color(0xFF4172B1) : const Color(0xFF54A4FD),
                decoration: confirmed ? TextDecoration.none : TextDecoration.underline,
                decorationStyle: TextDecorationStyle.dotted,
                decorationColor: const Color(0xFF54A4FD))));
  }
}
