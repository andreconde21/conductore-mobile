import 'package:conduit/features/diff_view/domain/word_diff.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/code_languages.dart';
import 'package:flutter/widgets.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// One run of a highlighted diff line: its text, its syntax colour (null:
/// the line's own style) and whether word diff marks it as changed.
typedef DiffSyntaxRun = ({String text, TextStyle? style, bool changed});

/// Syntax colours for diff lines, by the file's extension (the same
/// languages and themes as the file viewer). Each line is highlighted on
/// its own, so a string or comment that spans lines is coloured only where
/// it starts; that is enough to read a diff and keeps a 2 MB diff lazy.
class DiffSyntax {
  DiffSyntax._();

  static final _highlight = Highlight();
  static final _registered = <String>{};
  static final _cache = <String, List<({String text, TextStyle? style})>>{};
  static const _cacheMax = 4000;

  /// Lines longer than this stay plain (minified files).
  static const maxLineLength = 600;

  /// The language id for [path], or null when it has none (plain text).
  static String? languageFor(String path) {
    final name = path.split('/').last;
    final language = codeLanguageForFile(name);
    if (language.id == 'plaintext') return null;
    if (_registered.add(language.id)) {
      _highlight.registerLanguage(language.id, language.mode);
    }
    return language.id;
  }

  static Map<String, TextStyle> _theme(Brightness brightness) =>
      brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;

  /// [text] split into coloured runs (null when it should stay plain).
  static List<({String text, TextStyle? style})>? highlight(
    String text,
    String language,
    Brightness brightness,
  ) {
    if (text.isEmpty || text.length > maxLineLength) return null;
    final key = '${brightness.name}\u0000$language\u0000$text';
    final cached = _cache[key];
    if (cached != null) return cached;
    List<({String text, TextStyle? style})> runs;
    try {
      final renderer = TextSpanRenderer(null, _theme(brightness));
      _highlight.highlight(code: text, language: language).render(renderer);
      runs = [];
      final span = renderer.span;
      if (span != null) _flatten(span, null, runs);
    } on Object {
      return null;
    }
    if (_cache.length >= _cacheMax) _cache.remove(_cache.keys.first);
    _cache[key] = runs;
    return runs;
  }

  static void _flatten(
    InlineSpan span,
    TextStyle? inherited,
    List<({String text, TextStyle? style})> out,
  ) {
    if (span is! TextSpan) return;
    final style = inherited == null
        ? span.style
        : (span.style == null ? inherited : inherited.merge(span.style));
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      // Only colour and weight: the diff line keeps its font and size.
      out.add((
        text: text,
        style: style == null
            ? null
            : TextStyle(
                color: style.color,
                fontWeight: style.fontWeight,
                fontStyle: style.fontStyle,
              ),
      ));
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      _flatten(child, style, out);
    }
  }

  /// Lays [words] (word-diff marks) over [syntax] (colours): every run
  /// keeps both its colour and whether it changed.
  static List<DiffSyntaxRun> merge(
    List<({String text, TextStyle? style})> syntax,
    List<WordDiffSpan>? words,
  ) {
    if (words == null || words.every((w) => !w.changed)) {
      return [
        for (final s in syntax) (text: s.text, style: s.style, changed: false),
      ];
    }
    final out = <DiffSyntaxRun>[];
    var si = 0;
    var sOff = 0;
    var wi = 0;
    var wOff = 0;
    while (si < syntax.length && wi < words.length) {
      final s = syntax[si];
      final w = words[wi];
      final take = [
        s.text.length - sOff,
        w.text.length - wOff,
      ].reduce((a, b) => a < b ? a : b);
      if (take > 0) {
        out.add((
          text: s.text.substring(sOff, sOff + take),
          style: s.style,
          changed: w.changed,
        ));
      }
      sOff += take;
      wOff += take;
      if (sOff >= s.text.length) {
        si++;
        sOff = 0;
      }
      if (wOff >= w.text.length) {
        wi++;
        wOff = 0;
      }
    }
    // Whatever one side has left (they cover the same text).
    for (; si < syntax.length; si++, sOff = 0) {
      final rest = syntax[si].text.substring(sOff);
      if (rest.isNotEmpty) {
        out.add((text: rest, style: syntax[si].style, changed: false));
      }
    }
    return out;
  }
}
