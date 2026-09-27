import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/chat_view/domain/markdown_table.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_search_highlight.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Renders the Markdown subset agent replies actually use: paragraphs,
/// headings, bullet and numbered lists, block quotes, fenced code blocks,
/// GitHub-style tables (a real table, scrollable when wide, full screen
/// on tap), rules, and inline code, bold,
/// italics and links. Everything else is shown as plain text; no HTML is
/// interpreted. Links open only for http(s) and mailto.
class ChatMarkdown extends StatefulWidget {
  const ChatMarkdown(this.text, {this.style, super.key});

  final String text;
  final TextStyle? style;

  @override
  State<ChatMarkdown> createState() => _ChatMarkdownState();
}

sealed class MarkdownBlock {
  const MarkdownBlock();
}

class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.text);
  final String text;
}

class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading(this.level, this.text);
  final int level;
  final String text;
}

class MarkdownListItem extends MarkdownBlock {
  const MarkdownListItem(this.marker, this.text, this.indent);

  /// `•` or the number with its dot.
  final String marker;
  final String text;
  final int indent;
}

class MarkdownQuote extends MarkdownBlock {
  const MarkdownQuote(this.text);
  final String text;
}

class MarkdownCode extends MarkdownBlock {
  const MarkdownCode(this.code, {this.language});
  final String code;
  final String? language;
}

class MarkdownRule extends MarkdownBlock {
  const MarkdownRule();
}

class MarkdownTableBlock extends MarkdownBlock {
  const MarkdownTableBlock(this.table);
  final MarkdownTable table;
}

/// Splits [text] into blocks. Public for tests.
List<MarkdownBlock> parseMarkdownBlocks(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(MarkdownParagraph(paragraph.join('\n')));
      paragraph.clear();
    }
  }

  final fence = RegExp(r'^\s*(```|~~~)\s*([\w+-]*)');
  final heading = RegExp(r'^(#{1,6})\s+(.*)$');
  final bullet = RegExp(r'^(\s*)[-*+]\s+(?:\[( |x|X)\]\s+)?(.*)$');
  final ordered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
  final rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final fenceMatch = fence.firstMatch(line);
    if (fenceMatch != null) {
      flush();
      final marker = fenceMatch.group(1)!;
      final language = fenceMatch.group(2);
      final code = <String>[];
      i += 1;
      while (i < lines.length && !lines[i].trimLeft().startsWith(marker)) {
        code.add(lines[i]);
        i += 1;
      }
      blocks.add(
        MarkdownCode(
          code.join('\n'),
          language: language == null || language.isEmpty ? null : language,
        ),
      );
      continue;
    }
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    if (MarkdownTables.tryParse(lines, i) case (final table, final span)?) {
      flush();
      blocks.add(MarkdownTableBlock(table));
      i += span - 1;
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      // Pipes without a delimiter row: not a table; show as typed.
      flush();
      final table = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
        table.add(lines[i].trim());
        i += 1;
      }
      i -= 1;
      blocks.add(MarkdownCode(table.join('\n')));
      continue;
    }
    if (rule.hasMatch(line)) {
      flush();
      blocks.add(const MarkdownRule());
      continue;
    }
    if (heading.firstMatch(line) case final match?) {
      flush();
      blocks.add(MarkdownHeading(match.group(1)!.length, match.group(2)!));
      continue;
    }
    if (bullet.firstMatch(line) case final match?) {
      flush();
      final check = match.group(2);
      final marker = check == null
          ? '•'
          : check.trim().isEmpty
          ? '☐'
          : '☑';
      blocks.add(
        MarkdownListItem(marker, match.group(3)!, match.group(1)!.length ~/ 2),
      );
      continue;
    }
    if (ordered.firstMatch(line) case final match?) {
      flush();
      blocks.add(
        MarkdownListItem(
          '${match.group(2)}.',
          match.group(3)!,
          match.group(1)!.length ~/ 2,
        ),
      );
      continue;
    }
    if (line.startsWith('>')) {
      flush();
      final quote = <String>[];
      while (i < lines.length && lines[i].startsWith('>')) {
        quote.add(lines[i].replaceFirst(RegExp(r'^>\s?'), ''));
        i += 1;
      }
      i -= 1;
      blocks.add(MarkdownQuote(quote.join('\n')));
      continue;
    }
    paragraph.add(line);
  }
  flush();
  return blocks;
}

/// The text of each searchable run of [text] as [ChatMarkdown] shows it,
/// in display order: one per paragraph, heading, list item, quote and code
/// block, and one per table cell (headers first). Search matches count
/// against these, so a highlight lands where the text is on screen.
List<String> markdownSearchSegments(String text) => [
  for (final block in parseMarkdownBlocks(text))
    ...switch (block) {
      MarkdownParagraph(:final text) ||
      MarkdownHeading(:final text) ||
      MarkdownListItem(:final text) ||
      MarkdownQuote(:final text) => [markdownPlainInline(text)],
      MarkdownCode(:final code) => [code],
      MarkdownRule() => const <String>[],
      MarkdownTableBlock(:final table) => [
        for (final cell in table.headers) markdownPlainInline(cell),
        for (final row in table.rows)
          for (final cell in row) markdownPlainInline(cell),
      ],
    },
];

/// [text] without its Markdown: what "Copy" puts on the clipboard. Lists
/// keep their markers, tables become tab-separated rows.
String markdownToPlainText(String text) {
  final out = StringBuffer();
  MarkdownBlock? previous;
  for (final block in parseMarkdownBlocks(text)) {
    if (previous != null) {
      out.write(
        previous is MarkdownListItem && block is MarkdownListItem
            ? '\n'
            : '\n\n',
      );
    }
    previous = block;
    out.write(switch (block) {
      MarkdownParagraph(:final text) ||
      MarkdownHeading(:final text) ||
      MarkdownQuote(:final text) => markdownPlainInline(text),
      MarkdownListItem(:final marker, :final text, :final indent) =>
        '${'  ' * indent}$marker ${markdownPlainInline(text)}',
      MarkdownCode(:final code) => code,
      MarkdownRule() => '---',
      MarkdownTableBlock(:final table) => [
        table.headers.map(markdownPlainInline).join('\t'),
        for (final row in table.rows) row.map(markdownPlainInline).join('\t'),
      ].join('\n'),
    });
  }
  return out.toString();
}

/// The text [markdownSpans] shows for [text] (the same rules, no spans).
String markdownPlainInline(String text) {
  final out = StringBuffer();
  var index = 0;
  for (final match in _inline.allMatches(text)) {
    out.write(text.substring(index, match.start));
    index = match.end;
    if (match.group(1) case final code?) {
      out.write(code);
    } else if (match.group(2) ?? match.group(3) case final bold?) {
      out.write(markdownPlainInline(bold));
    } else if (match.group(4) ?? match.group(5) case final italic?) {
      out.write(italic);
    } else {
      final label = match.group(6) ?? match.group(8)!;
      final url = match.group(7) ?? match.group(8)!;
      out.write(
        _safeLink(url) == null && label != url ? '$label ($url)' : label,
      );
    }
  }
  out.write(text.substring(index));
  return out.toString();
}

class _ChatMarkdownState extends State<ChatMarkdown> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  List<InlineSpan> _spans(String text, TextStyle base) =>
      markdownSpans(text, base, Theme.of(context), _recognizers);

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final base = widget.style ?? theme.textTheme.bodyMedium!;
    final blocks = parseMarkdownBlocks(widget.text);
    final children = <Widget>[];
    // Search highlights, per run in markdownSearchSegments order.
    final highlight = ChatSearchHighlight.maybeOf(context);
    var segment = 0;
    List<InlineSpan> marked(String text, TextStyle base, {bool code = false}) {
      final spans = code ? [TextSpan(text: text)] : _spans(text, base);
      final index = segment++;
      return highlight == null ? spans : highlight.mark(index, spans);
    }

    // Table cells are laid out later (and maybe more than once), so they
    // get every match marked but not the current one.
    List<InlineSpan> cell(String text, TextStyle base) {
      final spans = _spans(text, base);
      return highlight == null ? spans : highlight.markAll(spans);
    }

    for (final block in blocks) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 6));
      }
      children.add(switch (block) {
        MarkdownParagraph(:final text) => Text.rich(
          TextSpan(children: marked(text, base)),
          style: base,
        ),
        MarkdownHeading(:final level, :final text) => Text.rich(
          TextSpan(children: marked(text, base)),
          style: base.copyWith(
            fontWeight: FontWeight.w800,
            fontSize:
                (base.fontSize ?? 14) *
                (level <= 1
                    ? 1.3
                    : level == 2
                    ? 1.18
                    : 1.06),
          ),
        ),
        MarkdownListItem(:final marker, :final text, :final indent) => Padding(
          padding: EdgeInsets.only(left: 4.0 + indent * 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: marker.length > 2 ? 28 : 18,
                child: Text(marker, style: base),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: marked(text, base)),
                  style: base,
                ),
              ),
            ],
          ),
        ),
        MarkdownQuote(:final text) => Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: theme.colorScheme.outline, width: 3),
            ),
          ),
          child: Text.rich(
            TextSpan(children: marked(text, base)),
            style: base.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        MarkdownCode(:final code) => _CodeBlock(
          code: code,
          spans: marked(code, base, code: true),
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) * 0.88,
          ),
        ),
        MarkdownRule() => Divider(color: theme.colorScheme.outlineVariant),
        MarkdownTableBlock(:final table) => MarkdownTableView(
          table: table,
          style: base,
          spans: cell,
        ),
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// A fenced code block, scrollable sideways, with a copy button on it.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.code,
    required this.spans,
    required this.style,
  });

  final String code;
  final List<InlineSpan> spans;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // Room on the right for the copy button.
            padding: const EdgeInsets.fromLTRB(10, 10, 40, 10),
            child: Text.rich(TextSpan(children: spans), style: style),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              key: const ValueKey('markdown-code-copy'),
              tooltip: 'Copy code',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              color: scheme.onSurfaceVariant,
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: code)));
                ScaffoldMessenger.maybeOf(context)
                  ?..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text('Code copied')));
              },
              icon: const Icon(Icons.copy_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

/// Builds the inline spans of one cell.
typedef MarkdownSpans = List<InlineSpan> Function(String text, TextStyle base);

/// A Markdown table: 1px muted borders, bold header row, per-column
/// alignment, wrapping cells. Columns get their natural width within
/// [minColumn]..[maxColumn]; when they do not fit the screen the table
/// scrolls sideways instead of squashing. A tap opens it full screen.
class MarkdownTableView extends StatelessWidget {
  const MarkdownTableView({
    required this.table,
    required this.style,
    required this.spans,
    this.maxColumn = 240,
    this.fullScreen = false,
    super.key,
  });

  final MarkdownTable table;
  final TextStyle style;
  final MarkdownSpans spans;
  final double maxColumn;
  final bool fullScreen;

  static const minColumn = 72.0;
  static const _cellPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);

  /// Natural column widths, clamped. Public for tests.
  List<double> columnWidths(TextScaler scaler) {
    final widths = List<double>.filled(table.columns, minColumn);
    void measure(int column, String text, {bool bold = false}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: bold ? style.copyWith(fontWeight: FontWeight.w700) : style,
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final width = painter.width + _cellPadding.horizontal + 2;
      painter.dispose();
      if (width > widths[column]) widths[column] = width;
    }

    for (var c = 0; c < table.columns; c++) {
      measure(c, table.headers[c], bold: true);
      for (final row in table.rows) {
        measure(c, row[c]);
      }
      widths[c] = widths[c].clamp(minColumn, maxColumn);
    }
    return widths;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final widths = columnWidths(MediaQuery.textScalerOf(context));
    final natural = widths.fold<double>(0, (sum, w) => sum + w);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final fits = natural <= available;
        final Map<int, TableColumnWidth> columnWidths = {
          for (var c = 0; c < widths.length; c++)
            c: fits ? FlexColumnWidth(widths[c]) : FixedColumnWidth(widths[c]),
        };
        Widget cell(
          String text,
          MarkdownTableAlign align, {
          bool header = false,
        }) {
          final textAlign = switch (align) {
            MarkdownTableAlign.start => TextAlign.start,
            MarkdownTableAlign.center => TextAlign.center,
            MarkdownTableAlign.end => TextAlign.end,
          };
          final cellStyle = header
              ? style.copyWith(fontWeight: FontWeight.w700)
              : style;
          return Padding(
            padding: _cellPadding,
            child: Text.rich(
              TextSpan(children: spans(text, cellStyle)),
              style: cellStyle,
              textAlign: textAlign,
            ),
          );
        }

        final tableWidget = Table(
          key: const ValueKey('markdown-table'),
          columnWidths: columnWidths,
          border: TableBorder.all(color: scheme.outlineVariant),
          children: [
            TableRow(
              decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
              children: [
                for (var c = 0; c < table.columns; c++)
                  cell(table.headers[c], table.aligns[c], header: true),
              ],
            ),
            for (final row in table.rows)
              TableRow(
                children: [
                  for (var c = 0; c < table.columns; c++)
                    cell(row[c], table.aligns[c]),
                ],
              ),
          ],
        );
        final sized = fits
            ? tableWidget
            : _SidewaysScroll(
                child: SizedBox(width: natural, child: tableWidget),
              );
        if (fullScreen) return sized;
        // The expand control sits in a caption bar under the table, never
        // over a cell (it used to cover the last header's text).
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Desktop: a click on the table selects text, only the button
            // opens it.
            if (PlatformFeatures.isDesktop)
              sized
            else
              GestureDetector(
                onTap: () => openFullScreen(context),
                child: sized,
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('markdown-table-expand'),
                onPressed: () => openFullScreen(context),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 28),
                  foregroundColor: scheme.onSurfaceVariant,
                  textStyle: theme.textTheme.labelSmall,
                ),
                icon: const Icon(Icons.open_in_full_rounded, size: 14),
                label: const Text('Open table'),
              ),
            ),
          ],
        );
      },
    );
  }

  void openFullScreen(BuildContext context) {
    // Phones: a full-screen page; desktop: a large dialog over the chat.
    unawaited(
      pushAdaptivePage<void>(
        context,
        fullscreenDialog: true,
        desktopMaxWidth: 1100,
        builder: (context) => _FullScreenTable(table: table, style: style),
      ),
    );
  }
}

/// A table wider than the bubble, scrolled sideways; on desktop with an
/// always-visible scrollbar, since a mouse has no sideways swipe.
class _SidewaysScroll extends StatefulWidget {
  const _SidewaysScroll({required this.child});

  final Widget child;

  @override
  State<_SidewaysScroll> createState() => _SidewaysScrollState();
}

class _SidewaysScrollState extends State<_SidewaysScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = PlatformFeatures.isDesktop;
    final scroll = SingleChildScrollView(
      key: const ValueKey('markdown-table-scroll'),
      controller: desktop ? _controller : null,
      scrollDirection: Axis.horizontal,
      padding: desktop ? const EdgeInsets.only(bottom: 10) : null,
      child: widget.child,
    );
    if (!desktop) return scroll;
    return Scrollbar(
      key: const ValueKey('markdown-table-scrollbar'),
      controller: _controller,
      thumbVisibility: true,
      child: scroll,
    );
  }
}

/// The table on its own page, scrollable both ways, with its own link
/// recognizers (the chat bubble's are rebuilt on every poll).
class _FullScreenTable extends StatefulWidget {
  const _FullScreenTable({required this.table, required this.style});

  final MarkdownTable table;
  final TextStyle style;

  @override
  State<_FullScreenTable> createState() => _FullScreenTableState();
}

class _FullScreenTableState extends State<_FullScreenTable> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _dispose();
    final table = widget.table;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Table · ${table.rows.length} '
          'row${table.rows.length == 1 ? '' : 's'}',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('markdown-table-full'),
          padding: const EdgeInsets.all(12),
          child: MarkdownTableView(
            table: table,
            style: widget.style,
            spans: (text, base) =>
                markdownSpans(text, base, theme, _recognizers),
            maxColumn: 420,
            fullScreen: true,
          ),
        ),
      ),
    );
  }
}

/// Inline Markdown (code, bold, italics, links) as spans. Link taps use
/// recognizers added to [recognizers]; the caller disposes them.
final _inline = RegExp(
  r'`([^`\n]+)`' // 1 inline code
  r'|\*\*([^*\n]+?)\*\*' // 2 bold
  r'|__([^_\n]+?)__' // 3 bold
  r'|(?<![\w*])\*([^*\n]+?)\*(?!\w)' // 4 italic
  r'|(?<!\w)_([^_\n]+?)_(?!\w)' // 5 italic
  r'|\[([^\]\n]+)\]\(([^)\s]+)\)' // 6, 7 link
  r'|(https?://[^\s<>()]+[^\s<>().,;:!?])', // 8 bare URL
);

List<InlineSpan> markdownSpans(
  String text,
  TextStyle base,
  ThemeData theme,
  List<TapGestureRecognizer> recognizers,
) {
  final spans = <InlineSpan>[];
  var index = 0;
  for (final match in _inline.allMatches(text)) {
    if (match.start > index) {
      spans.add(TextSpan(text: text.substring(index, match.start)));
    }
    index = match.end;
    if (match.group(1) case final code?) {
      spans.add(
        TextSpan(
          text: code,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) * 0.92,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      );
    } else if (match.group(2) ?? match.group(3) case final bold?) {
      spans.add(
        TextSpan(
          style: const TextStyle(fontWeight: FontWeight.w700),
          children: markdownSpans(bold, base, theme, recognizers),
        ),
      );
    } else if (match.group(4) ?? match.group(5) case final italic?) {
      spans.add(
        TextSpan(
          text: italic,
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    } else {
      final label = match.group(6) ?? match.group(8)!;
      final url = match.group(7) ?? match.group(8)!;
      spans.add(_link(label, url, theme, recognizers));
    }
  }
  if (index < text.length) {
    spans.add(TextSpan(text: text.substring(index)));
  }
  return spans;
}

InlineSpan _link(
  String label,
  String url,
  ThemeData theme,
  List<TapGestureRecognizer> recognizers,
) {
  final uri = _safeLink(url);
  if (uri == null) {
    return TextSpan(text: label == url ? url : '$label ($url)');
  }
  final recognizer = TapGestureRecognizer()
    ..onTap = () => launchUrl(uri, mode: LaunchMode.externalApplication);
  recognizers.add(recognizer);
  return TextSpan(
    text: label,
    recognizer: recognizer,
    style: TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    ),
  );
}

/// [url] when it may open (http, https, mailto), else null.
Uri? _safeLink(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
          (uri.scheme == 'https' ||
              uri.scheme == 'http' ||
              uri.scheme == 'mailto')
      ? uri
      : null;
}
