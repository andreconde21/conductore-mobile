import 'package:conduit/features/chat_view/domain/chat_search_text.dart';
import 'package:flutter/material.dart';

/// What the find bar marks in one thread row: every match of [query], and
/// the current one ([current]: its text run and which match in that run)
/// stronger. Rows read it through [forItem]; a run is one piece of text
/// the row shows, numbered as in `chatSearchSegments`.
class ChatSearchHighlight extends InheritedWidget {
  const ChatSearchHighlight({
    required this.itemId,
    required this.query,
    required super.child,
    this.current,
    super.key,
  });

  /// The thread item this row shows (a Task card's nested cards are other
  /// calls, and must not take its marks).
  final String itemId;
  final String query;
  final (int segment, int occurrence)? current;

  static const _match = TextStyle(backgroundColor: Color(0x80FFC107));
  static const _current = TextStyle(
    backgroundColor: Color(0xFFFF9800),
    color: Colors.black,
  );

  /// The marks around [context], or null while there are none.
  static ChatSearchHighlight? maybeOf(BuildContext context) {
    final highlight = context
        .dependOnInheritedWidgetOfExactType<ChatSearchHighlight>();
    return highlight == null || highlight.query.trim().isEmpty
        ? null
        : highlight;
  }

  /// The marks for [itemId]'s own row, else null.
  static ChatSearchHighlight? forItem(BuildContext context, String itemId) {
    final highlight = maybeOf(context);
    return highlight?.itemId == itemId ? highlight : null;
  }

  /// Whether the row has the current match (cards open to show it).
  bool get hasCurrent => current != null;

  /// [spans] (the text of run [segment]) with the matches marked.
  List<InlineSpan> mark(int segment, List<InlineSpan> spans) =>
      markSearchMatches(
        spans,
        query,
        current: current?.$1 == segment ? current!.$2 : null,
      );

  /// Every match marked, none as the current one.
  List<InlineSpan> markAll(List<InlineSpan> spans) =>
      markSearchMatches(spans, query);

  /// Plain [text] (run [segment]) as marked spans.
  TextSpan text(int segment, String text) =>
      TextSpan(children: mark(segment, [TextSpan(text: text)]));

  @override
  bool updateShouldNotify(ChatSearchHighlight oldWidget) =>
      itemId != oldWidget.itemId ||
      query != oldWidget.query ||
      current != oldWidget.current;
}

/// Run [segment] of [itemId]'s row as [Text]: plain [text], or with its
/// search matches marked while the find bar has some here.
class ChatHighlightedText extends StatelessWidget {
  const ChatHighlightedText(
    this.text, {
    required this.itemId,
    required this.segment,
    this.style,
    this.maxLines,
    this.overflow,
    super.key,
  });

  final String text;
  final String itemId;
  final int segment;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final highlight = ChatSearchHighlight.forItem(context, itemId);
    if (highlight == null) {
      return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    }
    return Text.rich(
      highlight.text(segment, text),
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// [spans] with each match of [query] in their text given a highlight
/// background; the [current]-th match (0-based) gets the stronger one.
/// Link taps keep working on marked pieces.
List<InlineSpan> markSearchMatches(
  List<InlineSpan> spans,
  String query, {
  int? current,
}) {
  final plain = StringBuffer();
  void collect(InlineSpan span) {
    if (span is! TextSpan) return;
    plain.write(span.text ?? '');
    span.children?.forEach(collect);
  }

  spans.forEach(collect);
  final ranges = chatSearchRanges(plain.toString(), query);
  if (ranges.isEmpty) return spans;
  var offset = 0;
  InlineSpan walk(InlineSpan span) {
    if (span is! TextSpan) return span;
    final text = span.text;
    final pieces = <InlineSpan>[];
    if (text != null && text.isNotEmpty) {
      final start = offset;
      final end = offset + text.length;
      offset = end;
      var at = start;
      for (var i = 0; i < ranges.length; i++) {
        final (from, to) = ranges[i];
        if (to <= start || from >= end) continue;
        final a = from < start ? start : from;
        final b = to > end ? end : to;
        if (a > at) {
          pieces.add(
            TextSpan(
              text: text.substring(at - start, a - start),
              recognizer: span.recognizer,
            ),
          );
        }
        pieces.add(
          TextSpan(
            text: text.substring(a - start, b - start),
            style: i == current
                ? ChatSearchHighlight._current
                : ChatSearchHighlight._match,
            recognizer: span.recognizer,
          ),
        );
        at = b;
      }
      if (pieces.isNotEmpty && at < end) {
        pieces.add(
          TextSpan(
            text: text.substring(at - start),
            recognizer: span.recognizer,
          ),
        );
      }
    }
    final children = span.children?.map(walk).toList();
    if (pieces.isEmpty) {
      if (children == null) return span;
      return TextSpan(
        text: text,
        style: span.style,
        recognizer: span.recognizer,
        children: children,
      );
    }
    return TextSpan(style: span.style, children: [...pieces, ...?children]);
  }

  return spans.map(walk).toList();
}
